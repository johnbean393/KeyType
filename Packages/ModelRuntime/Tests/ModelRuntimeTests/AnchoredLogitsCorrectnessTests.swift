import AutocompleteCore
import LlamaModelRuntime
import ModelRuntime
import XCTest

/// Gates the KV-fork optimization (ADR-018): `anchoredLogits` must produce the SAME next-token
/// distribution as a from-scratch decode of `anchor + suffix`. If `llama_memory_seq_cp` were
/// incorrect on this model's hybrid memory, the forked logits would diverge here and we'd fall back
/// to snapshot/restore before shipping. On-device only (skips without the GGUF).
final class AnchoredLogitsCorrectnessTests: XCTestCase {
    private func makeRuntime(
        enableKVFork: Bool,
        anchorSnapshotHistoryLimit: Int = 8
    ) throws -> LlamaModelRuntime {
        try XCTSkipUnless(
            ModelContainer.defaultModelExists(),
            "Model file not present at \(ModelContainer.defaultModelFilename); skipping"
        )
        return try LlamaModelRuntime(
            modelURL: try ModelContainer.modelURL(),
            contextLength: 2048,
            reuseThreshold: 8,
            enableKVFork: enableKVFork,
            anchorSnapshotHistoryLimit: anchorSnapshotHistoryLimit
        )
    }

    /// Ground truth: clear + full decode of `anchor + suffix`, returning the raw next-token logits.
    private func groundTruthLogits(_ runtime: LlamaModelRuntime, anchor: [TokenID], suffix: [TokenID]) async throws -> [TokenLogit] {
        await runtime.resetKVCache()
        try await runtime.prepare(promptTokens: anchor + suffix)
        return try await runtime.logitsForNextToken()
    }

    private func topK(_ logits: [TokenLogit], _ k: Int) -> [TokenID] {
        logits.sorted { $0.logit > $1.logit }.prefix(k).map(\.tokenID)
    }

    private func argmax(_ logits: [TokenLogit]) -> TokenID? {
        logits.max { $0.logit < $1.logit }?.tokenID
    }

    /// The project's documented correctness envelope for KV-reuse / batched decode on this hybrid
    /// recurrent model (ADR-012/018/043): the **argmax is identical** and the **top-k set is
    /// identical**. Only the order of near-tied tokens at ranks 3+ may shuffle (≤~0.12 logit drift
    /// from the parallel/split recurrent path), which never changes the displayed (top) candidate.
    private func assertSameDistribution(
        _ got: [TokenLogit], _ expected: [TokenLogit], k: Int = 5,
        _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(argmax(got), argmax(expected), "argmax diverged: \(message)", file: file, line: line)
        XCTAssertEqual(
            Set(topK(got, k)), Set(topK(expected, k)),
            "top-\(k) set diverged: \(message)", file: file, line: line
        )
    }

    func testForkedLogitsMatchFullDecode() async throws {
        let runtime = try makeRuntime(enableKVFork: true)
        let tok = runtime.tokenizer
        let anchorText = "The capital of France is Paris. The capital of Italy is Rome. The capital of Spain is"
        let anchor = try tok.tokenize(anchorText)

        let suffixes: [[TokenID]] = [
            [],                                   // root branch (empty suffix)
            try tok.tokenize(" Mad"),
            try tok.tokenize(" the"),
            try tok.tokenize(" a beautiful")
        ]

        for suffix in suffixes {
            // Ground truth uses a *separate* runtime so it can't accidentally benefit from resident
            // state left by the fork path.
            let truthRuntime = try makeRuntime(enableKVFork: true)
            let expected = try await groundTruthLogits(truthRuntime, anchor: anchor, suffix: suffix)
            let forked = try await runtime.anchoredLogits(anchor: anchor, suffix: suffix)
            assertSameDistribution(
                forked, expected,
                "forked snapshot/restore vs full decode for suffix \(suffix)"
            )
        }
    }

    /// The fork path must keep the anchor resident so repeated branches (and cross-keystroke
    /// appends) reuse it: after a fresh anchor decode, each forked branch should decode only its own
    /// suffix, and an anchor that extends the resident one should decode only the appended tokens.
    func testAnchorResidencyDecodesOnlySuffixAndTypedDelta() async throws {
        let runtime = try makeRuntime(enableKVFork: true)
        let tok = runtime.tokenizer
        let anchor = try tok.tokenize("I am writing to let you know that the meeting tomorrow")
        await runtime.resetKVCache()

        // First branch establishes the anchor (full decode) ...
        _ = try await runtime.anchoredLogits(anchor: anchor, suffix: try tok.tokenize(" is"))
        let afterAnchor = await runtime.lastPrepareDecodedCount
        XCTAssertEqual(afterAnchor, anchor.count, "first call should decode the whole anchor once")

        // ... subsequent branches with the SAME anchor must not re-decode it (ensureResident = 0).
        _ = try await runtime.anchoredLogits(anchor: anchor, suffix: try tok.tokenize(" has"))
        let afterSameAnchor = await runtime.lastPrepareDecodedCount
        XCTAssertEqual(afterSameAnchor, 0, "same anchor must stay resident across branches")

        // Cross-keystroke: anchor grows by the newly typed tokens; only those are decoded.
        let typed = try tok.tokenize(" at")
        let grown = anchor + typed
        _ = try await runtime.anchoredLogits(anchor: grown, suffix: [])
        let afterGrowth = await runtime.lastPrepareDecodedCount
        XCTAssertEqual(afterGrowth, typed.count, "only the typed delta should be decoded")
    }

    /// Character-by-character typing can retokenize the last word, so the new prompt is not a
    /// literal token append of the previous one. The runtime should restore a recent exact-prefix
    /// anchor snapshot and decode forward from there, rather than clearing and decoding the whole
    /// prompt again.
    func testAnchorHistoryReusesRetokenizedTypingPrefix() async throws {
        let probe = try makeRuntime(enableKVFork: true)
        let tok = probe.tokenizer
        let seed = "I am writing to let you know that the meeting scheduled for tomorrow"
        let phraseCandidates = [
            " afternoon",
            " has been moved",
            " internationalization",
            " autocomplete behavior",
            " personalization latency"
        ]

        var selection: (phrase: String, anchors: [[TokenID]], retokenized: [Int])?
        for phrase in phraseCandidates {
            var anchors = [try tok.tokenize(seed)]
            var text = seed
            for character in phrase {
                text.append(character)
                anchors.append(try tok.tokenize(text))
            }

            var history: [[TokenID]] = []
            var retokenized: [Int] = []
            for index in anchors.indices {
                let current = anchors[index]
                if index > 0 {
                    let previous = anchors[index - 1]
                    let common = Self.commonPrefixLength(previous, current)
                    let historicalPrefix = history
                        .filter { $0.count < current.count && Self.hasPrefix(current, prefix: $0) }
                        .map(\.count)
                        .max() ?? 0
                    if common < previous.count, historicalPrefix > 0 {
                        retokenized.append(index)
                    }
                }
                history.append(current)
            }

            if !retokenized.isEmpty {
                selection = (phrase, anchors, retokenized)
                break
            }
        }

        guard let selection else {
            throw XCTSkip("Tokenizer did not produce a retokenized typing prefix for probe phrases")
        }

        func run(historyLimit: Int) async throws -> (decoded: [Int], topSets: [Set<TokenID>], argmaxes: [TokenID?]) {
            let runtime = try makeRuntime(enableKVFork: true, anchorSnapshotHistoryLimit: historyLimit)
            var decoded: [Int] = []
            var topSets: [Set<TokenID>] = []
            var argmaxes: [TokenID?] = []
            for anchor in selection.anchors {
                let logits = try await runtime.anchoredLogits(anchor: anchor, suffix: [])
                decoded.append(await runtime.lastPrepareDecodedCount)
                topSets.append(Set(topK(logits, 5)))
                argmaxes.append(argmax(logits))
            }
            await runtime.shutdown()
            return (decoded, topSets, argmaxes)
        }

        let withoutHistory = try await run(historyLimit: 0)
        let withHistory = try await run(historyLimit: 8)
        XCTAssertEqual(withHistory.argmaxes, withoutHistory.argmaxes)
        XCTAssertEqual(withHistory.topSets, withoutHistory.topSets)

        let offDecoded = selection.retokenized.reduce(0) { $0 + withoutHistory.decoded[$1] }
        let onDecoded = selection.retokenized.reduce(0) { $0 + withHistory.decoded[$1] }
        XCTAssertLessThan(
            onDecoded, offDecoded,
            "historical anchor reuse should decode fewer prompt tokens on retokenized typing"
        )
        print("[anchor-history] phrase=\"\(selection.phrase)\" retokenizedSteps=\(selection.retokenized.count) decodedWithout=\(offDecoded) decodedWith=\(onDecoded)")
    }

    /// Gates the batched beam-frontier expansion (ADR-043): `anchoredLogitsBatch` must produce the
    /// SAME next-token distribution for each branch as scoring that branch on its own with
    /// `anchoredLogits`. If multi-sequence seeding or batched decode diverged on this model's hybrid
    /// memory, the top-k would differ here and we'd fall back to the per-branch path.
    func testBatchedFrontierMatchesPerBranch() async throws {
        let runtime = try makeRuntime(enableKVFork: true)
        let tok = runtime.tokenizer
        let anchorText = "The capital of France is Paris. The capital of Italy is Rome. The capital of Spain is"
        let anchor = try tok.tokenize(anchorText)

        let suffixes: [[TokenID]] = [
            [],                              // root branch (cached anchor-end logits)
            try tok.tokenize(" Mad"),
            try tok.tokenize(" the largest"),
            try tok.tokenize(" a"),
            try tok.tokenize(" Barcelona and")
        ]

        // Per-branch ground truth from the single-branch path (itself gated against full decode).
        var perBranch: [[TokenLogit]] = []
        for suffix in suffixes {
            perBranch.append(try await runtime.anchoredLogits(anchor: anchor, suffix: suffix))
        }

        // One batched call must reproduce every branch's distribution, in input order.
        let batched = try await runtime.anchoredLogitsBatch(anchor: anchor, suffixes: suffixes)
        XCTAssertEqual(batched.count, suffixes.count)
        for (i, logits) in batched.enumerated() {
            assertSameDistribution(logits, perBranch[i], "batched branch \(i) vs per-branch for suffix \(suffixes[i])")
        }
    }

    /// A frontier wider than `n_seq_max` must still be correct: the runtime chunks it into multiple
    /// batched decodes, and every branch's logits must match the per-branch path regardless of which
    /// chunk it landed in. `maxSequences: 2` forces chunking with a 5-branch frontier.
    func testBatchedFrontierChunksBeyondSeqMax() async throws {
        try XCTSkipUnless(ModelContainer.defaultModelExists(), "Model file not present; skipping")
        let runtime = try LlamaModelRuntime(
            modelURL: try ModelContainer.modelURL(), contextLength: 2048, enableKVFork: true, maxSequences: 2
        )
        let tok = runtime.tokenizer
        let anchor = try tok.tokenize("I am writing to let you know that the meeting tomorrow")
        let suffixes: [[TokenID]] = [
            try tok.tokenize(" is"), try tok.tokenize(" has"), try tok.tokenize(" will"),
            try tok.tokenize(" at"), try tok.tokenize(" might be")
        ]

        var perBranch: [[TokenLogit]] = []
        for suffix in suffixes {
            perBranch.append(try await runtime.anchoredLogits(anchor: anchor, suffix: suffix))
        }
        let batched = try await runtime.anchoredLogitsBatch(anchor: anchor, suffixes: suffixes)
        for (i, logits) in batched.enumerated() {
            assertSameDistribution(logits, perBranch[i], "chunked batch branch \(i)")
        }
    }

    /// Max absolute logit drift between two distributions over the union of their top tokens — the
    /// quantitative form of the project's correctness envelope (ADR-012/018/043/046: ≤~0.12).
    private func maxLogitDrift(_ p: [TokenLogit], _ q: [TokenLogit], over tokens: Set<TokenID>) -> Float {
        let pm = Dictionary(uniqueKeysWithValues: p.map { ($0.tokenID, $0.logit) })
        let qm = Dictionary(uniqueKeysWithValues: q.map { ($0.tokenID, $0.logit) })
        var m: Float = 0
        for t in tokens { m = max(m, abs((pm[t] ?? 0) - (qm[t] ?? 0))) }
        return m
    }

    private static func commonPrefixLength(_ a: [TokenID], _ b: [TokenID]) -> Int {
        var i = 0
        let n = min(a.count, b.count)
        while i < n && a[i] == b[i] { i += 1 }
        return i
    }

    private static func hasPrefix(_ tokens: [TokenID], prefix: [TokenID]) -> Bool {
        guard prefix.count <= tokens.count else { return false }
        for i in prefix.indices where tokens[i] != prefix[i] { return false }
        return true
    }

    /// Gates incremental beam decoding (ADR-046): when consecutive `anchoredLogitsBatch` calls form a
    /// beam frontier (each level's suffixes extend the previous level's by one token), the runtime
    /// keeps each branch resident and decodes only the new token — extending in place for a 1-child
    /// parent, forking via snapshot/restore for a split. Across a 3-level frontier that exercises
    /// root forks, in-place extension, and a mid-beam split, the incremental logits must stay inside
    /// the documented logit envelope of both the ADR-043 reseed path and a clean single-sequence
    /// full decode.
    ///
    /// The bound is quantitative (max |Δlogit| over the top tokens) rather than a top-k *set* match:
    /// on this hybrid recurrent model the multi-sequence batched decode already drifts up to ~0.12
    /// from a sequential decode (ADR-043), enough to reorder — and for adversarial near-tied tokens,
    /// re-set — ranks 3+. What must hold is that incremental adds no drift beyond that envelope; the
    /// engine-level candidate-equality test covers argmax stability on realistic (well-separated)
    /// continuations.
    func testIncrementalFrontierWithinEnvelope() async throws {
        try XCTSkipUnless(ModelContainer.defaultModelExists(), "Model file not present; skipping")
        func make(_ incremental: Bool) throws -> LlamaModelRuntime {
            try LlamaModelRuntime(
                modelURL: try ModelContainer.modelURL(), contextLength: 2048,
                enableKVFork: true, enableIncrementalBeam: incremental
            )
        }
        let inc = try make(true)
        let reseed = try make(false)
        let tok = inc.tokenizer
        let anchor = try tok.tokenize("The capital of France is Paris. The capital of Italy is Rome. The capital of Spain is")

        // A pool of distinct, valid token ids to assemble a well-formed frontier tree from. The
        // tokens need not be likely continuations — every path scores whatever frontier we build.
        let pool = try tok.tokenize(" one two three four five six seven eight nine ten")
        try XCTSkipUnless(pool.count >= 8, "tokenizer produced too few tokens for the frontier")
        let (a, b, c) = (pool[0], pool[1], pool[2])
        let (x, y, z, w) = (pool[3], pool[4], pool[5], pool[6])
        let extra = pool[7]

        // Level 1 forks the root three ways; level 2 keeps `a`/`c` 1:1 (in-place extend) and splits
        // `b` two ways (fork); level 3 extends every surviving branch 1:1.
        let levels: [[[TokenID]]] = [
            [[a], [b], [c]],
            [[a, x], [b, y], [b, z], [c, w]],
            [[a, x, extra], [b, y, extra], [b, z, extra], [c, w, extra]],
        ]

        // The batched path (reseed or incremental) already drifts from a sequential decode by the
        // documented envelope; incremental must not exceed it, and must track reseed even tighter.
        let envelope: Float = 0.12
        let incVsReseedBound: Float = 0.06

        // Start each beam at the root so the runtime resets any prior frontier, as the engine does.
        _ = try await inc.anchoredLogitsBatch(anchor: anchor, suffixes: [[]])
        _ = try await reseed.anchoredLogitsBatch(anchor: anchor, suffixes: [[]])

        for (depth, suffixes) in levels.enumerated() {
            let got = try await inc.anchoredLogitsBatch(anchor: anchor, suffixes: suffixes)
            let expected = try await reseed.anchoredLogitsBatch(anchor: anchor, suffixes: suffixes)
            XCTAssertEqual(got.count, suffixes.count)
            for (i, suffix) in suffixes.enumerated() {
                let truth = try await groundTruthLogits(try make(false), anchor: anchor, suffix: suffix)
                let top = Set(topK(truth, 8) + topK(got[i], 8) + topK(expected[i], 8))
                let incVsTruth = maxLogitDrift(got[i], truth, over: top)
                let incVsReseed = maxLogitDrift(got[i], expected[i], over: top)
                XCTAssertLessThanOrEqual(
                    incVsTruth, envelope,
                    "incremental level \(depth) branch \(i) (suffix \(suffix)) drifts \(incVsTruth) from full decode"
                )
                XCTAssertLessThanOrEqual(
                    incVsReseed, incVsReseedBound,
                    "incremental level \(depth) branch \(i) (suffix \(suffix)) drifts \(incVsReseed) from reseed"
                )
                // Argmax must still match the reseed path for well-separated branches (no near-tie).
                let sorted = expected[i].sorted { $0.logit > $1.logit }
                if sorted.count >= 2, sorted[0].logit - sorted[1].logit > envelope {
                    XCTAssertEqual(
                        argmax(got[i]), argmax(expected[i]),
                        "incremental flipped a well-separated argmax at level \(depth) branch \(i)"
                    )
                }
            }
        }
    }

    /// Disabling the flag falls back to the default full-decode path and must still be correct.
    func testDisabledForkMatchesFullDecode() async throws {
        let runtime = try makeRuntime(enableKVFork: false)
        let tok = runtime.tokenizer
        let anchor = try tok.tokenize("Once upon a time there was a")
        let suffix = try tok.tokenize(" small")

        let truthRuntime = try makeRuntime(enableKVFork: false)
        let expected = try await groundTruthLogits(truthRuntime, anchor: anchor, suffix: suffix)
        let got = try await runtime.anchoredLogits(anchor: anchor, suffix: suffix)
        assertSameDistribution(got, expected, "fork-disabled vs full decode")
    }
}
