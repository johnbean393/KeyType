import AutocompleteCore
import LlamaModelRuntime
import ModelRuntime
import XCTest

/// Gates the KV-fork optimization (ADR-018): `anchoredLogits` must produce the SAME next-token
/// distribution as a from-scratch decode of `anchor + suffix`. If `llama_memory_seq_cp` were
/// incorrect on this model's hybrid memory, the forked logits would diverge here and we'd fall back
/// to snapshot/restore before shipping. On-device only (skips without the GGUF).
final class AnchoredLogitsCorrectnessTests: XCTestCase {
    private func makeRuntime(enableKVFork: Bool) throws -> LlamaModelRuntime {
        try XCTSkipUnless(
            ModelContainer.defaultModelExists(),
            "Model file not present at \(ModelContainer.defaultModelFilename); skipping"
        )
        return try LlamaModelRuntime(
            modelURL: try ModelContainer.modelURL(),
            contextLength: 2048,
            reuseThreshold: 8,
            enableKVFork: enableKVFork
        )
    }

    /// Ground truth: clear + full decode of `anchor + suffix`, top-k token ids by logit.
    private func groundTruthTopK(_ runtime: LlamaModelRuntime, anchor: [TokenID], suffix: [TokenID], k: Int) async throws -> [TokenID] {
        await runtime.resetKVCache()
        try await runtime.prepare(promptTokens: anchor + suffix)
        let logits = try await runtime.logitsForNextToken()
        return topK(logits, k)
    }

    private func topK(_ logits: [TokenLogit], _ k: Int) -> [TokenID] {
        logits.sorted { $0.logit > $1.logit }.prefix(k).map(\.tokenID)
    }

    private func argmax(_ logits: [TokenLogit]) -> TokenID? {
        logits.max { $0.logit < $1.logit }?.tokenID
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
            let expected = try await groundTruthTopK(truthRuntime, anchor: anchor, suffix: suffix, k: 5)

            let forked = try await runtime.anchoredLogits(anchor: anchor, suffix: suffix)
            let got = topK(forked, 5)

            XCTAssertEqual(
                got, expected,
                "forked top-5 diverged from full decode for suffix \(suffix). If this fails, seq_cp is unsafe on this model — switch anchoredLogits to llama_state_seq_get/set_data."
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

    /// Disabling the flag falls back to the default full-decode path and must still be correct.
    func testDisabledForkMatchesFullDecode() async throws {
        let runtime = try makeRuntime(enableKVFork: false)
        let tok = runtime.tokenizer
        let anchor = try tok.tokenize("Once upon a time there was a")
        let suffix = try tok.tokenize(" small")

        let truthRuntime = try makeRuntime(enableKVFork: false)
        let expected = try await groundTruthTopK(truthRuntime, anchor: anchor, suffix: suffix, k: 5)
        let got = topK(try await runtime.anchoredLogits(anchor: anchor, suffix: suffix), 5)
        XCTAssertEqual(got, expected)
    }
}
