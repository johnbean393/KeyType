import AutocompleteCore
@testable import ConstrainedGeneration
import LlamaModelRuntime
import ModelRuntime
import Prompting
import TokenProfiles
import XCTest

// NOTE: temporary latency-investigation harness (ADR-043 follow-up). Skip-gated on the GGUF.

/// Temporary micro-benchmark (latency investigation). Separates the *one-time prefill* cost from
/// the *per-branch restore+decode* cost so we can attribute the ~87 ms warm completion latency to
/// either (a) processing the prompt once, or (b) the 12 anchored restore/decode calls the beam
/// makes. Run:
///   swift test --package-path Packages/ConstrainedGeneration --filter PrefillVsBranchMicroBench -c release
final class PrefillVsBranchMicroBench: XCTestCase {
    private static let family = "qwen3-v151936"

    private func load(
        incremental: Bool = true,
        anchorSnapshotHistoryLimit: Int = 8
    ) throws -> LlamaModelRuntime {
        try XCTSkipUnless(ModelContainer.defaultModelExists(), "GGUF missing; skipping")
        return try LlamaModelRuntime(
            modelURL: try ModelContainer.modelURL(), contextLength: 2048,
            enableKVFork: true,
            enableIncrementalBeam: incremental,
            anchorSnapshotHistoryLimit: anchorSnapshotHistoryLimit
        )
    }

    private func openProfile(_ runtime: LlamaModelRuntime) throws -> MmapAutocompleteProfile {
        let profileURL = try ModelContainer.profileURL(family: Self.family)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: profileURL.path), "profile missing")
        return try MmapAutocompleteProfile.open(
            at: profileURL,
            tokenizerVocabSize: runtime.metadata.vocabularySize,
            tokenizerBytes: { try runtime.tokenizer.rawBytes(for: $0) },
            expectedModelFamily: Self.family
        )
    }

    /// ADR-045: separates the COLD completion (fresh cache: clear + full prompt decode +
    /// sync — what the other benches measure because they `resetKVCache()` each iteration) from the
    /// WARM/append completion (ADR-018 cross-keystroke path: restore the prior anchor, decode only
    /// the newly-typed delta). Real typing is the warm path; the cold number is a one-time/cache-miss
    /// cost. Run:
    ///   swift test --package-path Packages/ConstrainedGeneration --filter testColdVsWarmCompletion -c release
    func testColdVsWarmCompletion() async throws {
        let runtime = try load()
        let profile = try openProfile(runtime)
        let config = DecodingConfiguration(maxCandidates: 5, enableFillInMiddle: true)
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile, configuration: config)
        let target = AppTarget(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit", windowTitle: "Untitled")

        func request(_ before: String) -> CompletionRequest {
            let ctx = TextFieldContext(beforeCursor: before, afterCursor: "", target: target, detectedLanguage: "en")
            let prompt = PromptBuilder().buildPrompt(context: ctx).prompt
            return CompletionRequest(context: ctx, prompt: prompt, mode: .prose, maxCompletionTokens: 4, maxDisplayWidth: 60)
        }

        let base = "I am writing to let you know that the meeting scheduled for tomorrow "
        let promptTokens = try runtime.tokenizer.tokenize(PromptBuilder().buildPrompt(
            context: TextFieldContext(beforeCursor: base, afterCursor: "", target: target, detectedLanguage: "en")).prompt).count

        // COLD: reset the cache before every completion (forces clear + full prompt decode).
        _ = try await engine.completions(for: request(base)) // warm kernels
        var coldBest = Double.greatestFiniteMagnitude
        for _ in 0..<5 {
            await runtime.resetKVCache()
            let s = try await seconds { _ = try await engine.completions(for: request(base)) } * 1000
            coldBest = min(coldBest, s)
        }

        // WARM/append: simulate typing — keep the cache, grow the prompt one word per keystroke so
        // `ensureAnchor` decodes only the typed delta (ADR-018). Measure each keystroke's completion.
        let words = ["afternoon", "has", "been", "moved", "to", "a", "later", "time", "so", "that", "everyone", "can"]
        await runtime.resetKVCache()
        _ = try await engine.completions(for: request(base)) // prime the anchor
        var warmTimes: [Double] = []
        var deltaTokens: [Int] = []
        var promptLens: [Int] = []
        var typed = base
        let prevPromptToks = try runtime.tokenizer.tokenize(PromptBuilder().buildPrompt(
            context: TextFieldContext(beforeCursor: base, afterCursor: "", target: target, detectedLanguage: "en")).prompt)
        var prevToks = prevPromptToks
        for w in words {
            typed += w + " "
            let req = request(typed)
            let toks = try runtime.tokenizer.tokenize(req.prompt)
            promptLens.append(toks.count)
            deltaTokens.append(Self.commonPrefix(prevToks, toks))
            prevToks = toks
            let s = try await seconds { _ = try await engine.completions(for: req) } * 1000
            warmTimes.append(s)
        }
        let warmBest = warmTimes.min() ?? 0
        let warmMean = warmTimes.reduce(0, +) / Double(warmTimes.count)

        print("\n================ cold vs warm (append) completion ================")
        print(String(format: "  prompt tokens (base)            : %d", promptTokens))
        print(String(format: "  COLD  (resetKVCache each)       : %.1f ms   ◄ what LatencyProfile/sweep report", coldBest))
        print(String(format: "  WARM  (append delta, ADR-018)   : best %.1f ms | mean %.1f ms   ◄ real typing", warmBest, warmMean))
        print("  per-keystroke warm latency (ms) : \(warmTimes.map { String(format: "%.1f", $0) })")
        print("  prompt tokens / keystroke       : \(promptLens)")
        print("  shared prefix w/ prev prompt    : \(deltaTokens)   (≈ promptLen ⇒ pure append; ≪ ⇒ prefix rewritten)")
        print(String(format: "  cold − warm                     : %.1f ms attributable to full prompt (re)decode", coldBest - warmBest))
        print("==================================================================\n")

        await runtime.shutdown()
    }

    /// ADR-046 A/B: warm-path (cross-keystroke append) completion latency with incremental beam
    /// decoding ON vs OFF (reseed). Simulates typing so each completion reuses the resident frontier
    /// and decodes only one new token per branch per level. Run:
    ///   swift test --package-path Packages/ConstrainedGeneration --filter testIncrementalWarmSpeedup -c release
    func testIncrementalWarmSpeedup() async throws {
        let target = AppTarget(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit", windowTitle: "Untitled")
        let base = "I am writing to let you know that the meeting scheduled for tomorrow "
        let words = ["afternoon", "has", "been", "moved", "to", "a", "later", "time", "so", "that", "everyone", "can"]

        func warmRun(incremental: Bool) async throws -> (best: Double, mean: Double) {
            let runtime = try load(incremental: incremental)
            let profile = try openProfile(runtime)
            let config = DecodingConfiguration(maxCandidates: 5, enableFillInMiddle: true)
            let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile, configuration: config)
            func request(_ before: String) -> CompletionRequest {
                let ctx = TextFieldContext(beforeCursor: before, afterCursor: "", target: target, detectedLanguage: "en")
                let prompt = PromptBuilder().buildPrompt(context: ctx).prompt
                return CompletionRequest(context: ctx, prompt: prompt, mode: .prose, maxCompletionTokens: 4, maxDisplayWidth: 60)
            }
            await runtime.resetKVCache()
            _ = try await engine.completions(for: request(base)) // prime the anchor
            var typed = base
            var times: [Double] = []
            for w in words {
                typed += w + " "
                let req = request(typed)
                let s = try await seconds { _ = try await engine.completions(for: req) } * 1000
                times.append(s)
            }
            await runtime.shutdown()
            return (times.min() ?? 0, times.reduce(0, +) / Double(times.count))
        }

        // Run reseed first then incremental (then again, to discount any first-run kernel warmup).
        _ = try await warmRun(incremental: false)
        let off = try await warmRun(incremental: false)
        let on = try await warmRun(incremental: true)

        print("\n================ ADR-046 incremental beam: warm-path A/B ================")
        print(String(format: "  reseed (incremental OFF) : best %.1f ms | mean %.1f ms", off.best, off.mean))
        print(String(format: "  incremental (ON)         : best %.1f ms | mean %.1f ms", on.best, on.mean))
        print(String(format: "  speedup (mean)           : %.2fx  (%.1f ms saved)", off.mean / on.mean, off.mean - on.mean))
        print("========================================================================\n")
    }

    /// Retokenized character-by-character typing A/B for the bounded anchor-history cache. When
    /// BPE rewrites the final word, the current anchor is not a pure append of the previous anchor;
    /// history can still restore an older exact-prefix snapshot and decode forward. This validates
    /// the shipped engine output, not only low-level logits.
    func testRetokenizedTypingAnchorHistoryPreservesCompletionsAndLatency() async throws {
        let target = AppTarget(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit", windowTitle: "Untitled")
        let seed = "I am writing to let you know that the meeting scheduled for tomorrow"
        let phraseCandidates = [
            " afternoon",
            " has been moved",
            " internationalization",
            " autocomplete behavior",
            " personalization latency"
        ]

        let probe = try load()
        func request(_ before: String) -> CompletionRequest {
            let ctx = TextFieldContext(beforeCursor: before, afterCursor: "", target: target, detectedLanguage: "en")
            let prompt = PromptBuilder().buildPrompt(context: ctx).prompt
            return CompletionRequest(context: ctx, prompt: prompt, mode: .prose, maxCompletionTokens: 4, maxDisplayWidth: 60)
        }
        func promptTokens(_ before: String) throws -> [TokenID] {
            try probe.tokenizer.tokenize(request(before).prompt)
        }

        var selected: (phrase: String, inputs: [String], retokenized: [Int])?
        for phrase in phraseCandidates {
            var inputs = [seed]
            var typed = seed
            for character in phrase {
                typed.append(character)
                inputs.append(typed)
            }
            let anchors = try inputs.map(promptTokens)
            var history: [[TokenID]] = []
            var retokenized: [Int] = []
            for index in anchors.indices {
                let current = anchors[index]
                if index > 0 {
                    let previous = anchors[index - 1]
                    let common = Self.commonPrefix(previous, current)
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
                selected = (phrase, inputs, retokenized)
                break
            }
        }
        await probe.shutdown()

        guard let selected else {
            throw XCTSkip("Tokenizer did not produce a retokenized production prompt for probe phrases")
        }

        final class AnchorDecodeRecorder: LocalModelRuntime {
            let wrapped: LlamaModelRuntime
            var metadata: ModelMetadata { wrapped.metadata }
            var tokenizer: ModelTokenizing { wrapped.tokenizer }
            private(set) var anchorDecodedThisCompletion = 0

            init(_ wrapped: LlamaModelRuntime) {
                self.wrapped = wrapped
            }

            func resetCompletionCounters() {
                anchorDecodedThisCompletion = 0
            }

            func prepare(promptTokens: [TokenID]) async throws {
                try await wrapped.prepare(promptTokens: promptTokens)
                anchorDecodedThisCompletion += await wrapped.lastPrepareDecodedCount
            }

            func logitsForNextToken() async throws -> [TokenLogit] {
                try await wrapped.logitsForNextToken()
            }

            func decodeNext(tokenID: TokenID) async throws {
                try await wrapped.decodeNext(tokenID: tokenID)
            }

            func resetKVCache() async {
                await wrapped.resetKVCache()
                resetCompletionCounters()
            }

            func shutdown() async {
                await wrapped.shutdown()
            }

            func anchoredLogits(anchor: [TokenID], suffix: [TokenID]) async throws -> [TokenLogit] {
                let result = try await wrapped.anchoredLogits(anchor: anchor, suffix: suffix)
                anchorDecodedThisCompletion += await wrapped.lastPrepareDecodedCount
                return result
            }

            func anchoredLogitsBatch(anchor: [TokenID], suffixes: [[TokenID]]) async throws -> [[TokenLogit]] {
                let result = try await wrapped.anchoredLogitsBatch(anchor: anchor, suffixes: suffixes)
                anchorDecodedThisCompletion += await wrapped.lastPrepareDecodedCount
                return result
            }
        }

        struct RunResult {
            var candidates: [[String]]
            var candidateSets: [Set<String>]
            var visible: [String?]
            var times: [Double]
            var anchorDecoded: [Int]
        }

        func visibleText(from candidates: [CompletionCandidate], request: CompletionRequest) -> String? {
            guard let best = candidates.first else { return nil }
            let filter = DefaultCandidateFilter()
            guard filter.suppressionReason(for: best, request: request) == nil else { return nil }

            var shown = CaretBoundary.reconcile(best.text, beforeCursor: request.context.beforeCursor)
            if request.context.afterCursor.isEmpty {
                while let last = shown.last, last.isWhitespace { shown.removeLast() }
            }
            return shown.isEmpty ? nil : shown
        }

        func run(historyLimit: Int) async throws -> RunResult {
            let raw = try load(anchorSnapshotHistoryLimit: historyLimit)
            let runtime = AnchorDecodeRecorder(raw)
            let profile = try openProfile(raw)
            let engine = ConstrainedGenerationEngine(
                runtime: runtime,
                profile: profile,
                configuration: DecodingConfiguration(maxCandidates: 5, enableFillInMiddle: true)
            )

            _ = try await engine.completions(for: request(seed)) // warm kernels
            await runtime.resetKVCache()

            var candidates: [[String]] = []
            var candidateSets: [Set<String>] = []
            var visible: [String?] = []
            var times: [Double] = []
            var anchorDecoded: [Int] = []
            for input in selected.inputs {
                runtime.resetCompletionCounters()
                let req = request(input)
                let start = DispatchTime.now()
                let result = try await engine.completions(for: req)
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                candidates.append(result.map(\.text))
                candidateSets.append(Set(result.map(\.text)))
                visible.append(visibleText(from: result, request: req))
                times.append(ms)
                anchorDecoded.append(runtime.anchorDecodedThisCompletion)
            }

            await runtime.shutdown()
            return RunResult(
                candidates: candidates,
                candidateSets: candidateSets,
                visible: visible,
                times: times,
                anchorDecoded: anchorDecoded
            )
        }

        let withoutHistory = try await run(historyLimit: 0)
        let withHistory = try await run(historyLimit: 8)
        XCTAssertEqual(withHistory.visible, withoutHistory.visible)
        XCTAssertEqual(withHistory.candidateSets, withoutHistory.candidateSets)

        let offDecoded = selected.retokenized.reduce(0) { $0 + withoutHistory.anchorDecoded[$1] }
        let onDecoded = selected.retokenized.reduce(0) { $0 + withHistory.anchorDecoded[$1] }
        let offTime = selected.retokenized.reduce(0) { $0 + withoutHistory.times[$1] }
        let onTime = selected.retokenized.reduce(0) { $0 + withHistory.times[$1] }
        let lowerRankOrderChanges = zip(withHistory.candidates, withoutHistory.candidates)
            .filter { $0 != $1 }
            .count
        XCTAssertLessThan(onDecoded, offDecoded)
        #if !DEBUG
        XCTAssertLessThan(onTime, offTime)
        #endif

        let speedup = offTime / max(0.0001, onTime)
        print("\n================ retokenized typing anchor-history A/B ================")
        print("  phrase                         : \"\(selected.phrase)\"")
        print("  retokenized steps              : \(selected.retokenized.count) / \(selected.inputs.count - 1)")
        print("  visible suggestions            : unchanged")
        print("  candidate sets                 : unchanged")
        print("  lower-rank order changes       : \(lowerRankOrderChanges)")
        print(String(format: "  anchor tokens decoded          : off %d | on %d | %.2fx reduction",
                     offDecoded, onDecoded, Double(offDecoded) / Double(max(1, onDecoded))))
        print(String(format: "  retokenized-step latency        : off %.1f ms | on %.1f ms | %.2fx speedup",
                     offTime, onTime, speedup))
        print("=======================================================================\n")
    }

    /// Records each `anchoredLogitsBatch` (one per beam level): how many branches, their suffix
    /// lengths, and wall time — so we can see the per-level cost and the re-decoded-suffix waste
    /// (the batched path reseeds the anchor and re-decodes each branch's FULL suffix every level).
    private final class LevelRecorder: LocalModelRuntime {
        let wrapped: LlamaModelRuntime
        var metadata: ModelMetadata { wrapped.metadata }
        var tokenizer: ModelTokenizing { wrapped.tokenizer }
        struct Level { var branches: Int; var suffixTokens: Int; var maxSuffix: Int; var ms: Double }
        private(set) var levels: [Level] = []
        init(_ r: LlamaModelRuntime) { wrapped = r }
        func reset() { levels = [] }

        func anchoredLogitsBatch(anchor: [TokenID], suffixes: [[TokenID]]) async throws -> [[TokenLogit]] {
            let start = DispatchTime.now()
            let r = try await wrapped.anchoredLogitsBatch(anchor: anchor, suffixes: suffixes)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            let nonEmpty = suffixes.filter { !$0.isEmpty }
            levels.append(Level(branches: nonEmpty.count,
                                suffixTokens: nonEmpty.reduce(0) { $0 + $1.count },
                                maxSuffix: nonEmpty.map(\.count).max() ?? 0, ms: ms))
            return r
        }
        func prepare(promptTokens: [TokenID]) async throws { try await wrapped.prepare(promptTokens: promptTokens) }
        func logitsForNextToken() async throws -> [TokenLogit] { try await wrapped.logitsForNextToken() }
        func decodeNext(tokenID: TokenID) async throws { try await wrapped.decodeNext(tokenID: tokenID) }
        func resetKVCache() async { await wrapped.resetKVCache() }
        func shutdown() async { await wrapped.shutdown() }
    }

    /// Per-level breakdown of the beam (ADR-045 lever #2). Shows branches/suffix-tokens/ms per level
    /// on a WARM completion, and totals the re-decoded suffix tokens that incremental decoding could
    /// avoid. Run:
    ///   swift test --package-path Packages/ConstrainedGeneration --filter testBeamLevelProfile -c release
    func testBeamLevelProfile() async throws {
        let runtime = try load()
        let profile = try openProfile(runtime)
        let config = DecodingConfiguration(maxCandidates: 5, enableFillInMiddle: true)
        let rec = LevelRecorder(runtime)
        let target = AppTarget(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit", windowTitle: "Untitled")

        func run(_ before: String) async throws -> [String] {
            let ctx = TextFieldContext(beforeCursor: before, afterCursor: "", target: target, detectedLanguage: "en")
            let prompt = PromptBuilder().buildPrompt(context: ctx).prompt
            let req = CompletionRequest(context: ctx, prompt: prompt, mode: .prose, maxCompletionTokens: 4, maxDisplayWidth: 60)
            let engine = ConstrainedGenerationEngine(runtime: rec, profile: profile, configuration: config)
            return try await engine.completions(for: req).map(\.text)
        }

        let cases = [
            "I am writing to let you know that the meeting scheduled for tomorrow ",
            "Thanks so much for your help with ",
            "The quick brown fox jumps over the ",
            "Please find attached the report for ",
        ]
        await runtime.resetKVCache()
        _ = try await run(cases[0]) // warm kernels + prime anchor

        print("\n================ beam per-level profile (warm, ADR-045 #2) ================")
        for before in cases {
            rec.reset()
            let cands = try await run(before)
            let total = rec.levels.reduce(0.0) { $0 + $1.ms }
            let reDecoded = rec.levels.reduce(0) { $0 + $1.suffixTokens }
            let incremental = rec.levels.reduce(0) { $0 + $1.branches } // 1 new token/branch/level
            print("  \"\(before.suffix(30))\" → \(cands.first.map { "\"\($0)\"" } ?? "—")   total \(String(format: "%.1f", total)) ms")
            for (i, l) in rec.levels.enumerated() {
                print(String(format: "     level %d: %d branch  suffixTok=%d (max %d)  %.1f ms", i + 1, l.branches, l.suffixTokens, l.maxSuffix, l.ms))
            }
            print("     re-decoded suffix tokens: \(reDecoded)  vs incremental (1/branch/level): \(incremental)  ⇒ \(reDecoded - incremental) wasted")
        }
        print("==========================================================================\n")
        await runtime.shutdown()
    }

    private static func commonPrefix(_ a: [TokenID], _ b: [TokenID]) -> Int {
        var n = 0
        while n < a.count, n < b.count, a[n] == b[n] { n += 1 }
        return n
    }

    private static func hasPrefix(_ tokens: [TokenID], prefix: [TokenID]) -> Bool {
        guard prefix.count <= tokens.count else { return false }
        for index in prefix.indices where tokens[index] != prefix[index] { return false }
        return true
    }

    /// Min-of-`runs` wall-clock seconds of an async op (min rejects scheduler/thermal noise).
    private func minSeconds(_ runs: Int, _ block: () async throws -> Void) async rethrows -> Double {
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<runs {
            let start = DispatchTime.now()
            try await block()
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000)
        }
        return best
    }

    /// Ordinary least-squares slope/intercept for y = intercept + slope·x over a few sample points.
    private func linearFit(_ xs: [Double], _ ys: [Double]) -> (intercept: Double, slope: Double) {
        let n = Double(xs.count)
        let sx = xs.reduce(0, +), sy = ys.reduce(0, +)
        let sxx = zip(xs, xs).reduce(0) { $0 + $1.0 * $1.1 }
        let sxy = zip(xs, ys).reduce(0) { $0 + $1.0 * $1.1 }
        let slope = (n * sxy - sx * sy) / (n * sxx - sx * sx)
        return ((sy - slope * sx) / n, slope)
    }

    /// Detailed component profile (ADR-043 follow-up). Times directly-measurable primitives and
    /// linear-fits the ones that scale (prefill length, branch depth, batch width) so we can split
    /// the per-`llama_decode` *fixed floor* (full-model weight stream) from the per-token *forward*
    /// compute, the *restore* cost, and CPU-side readback/sampling — then reconcile against a real
    /// completion. Run:
    ///   swift test --package-path Packages/ConstrainedGeneration --filter testDetailedComponentProfile -c release
    func testDetailedComponentProfile() async throws {
        let runtime = try load()
        let profile = try openProfile(runtime)
        let config = DecodingConfiguration(maxCandidates: 5, enableFillInMiddle: true)

        // A long token source so we can take prefixes of arbitrary length.
        let longText = String(repeating: "The quick brown fox jumps over the lazy dog near the riverbank, and then ", count: 24)
        let longTokens = try runtime.tokenizer.tokenize(longText)
        func prefix(_ n: Int) -> [TokenID] { Array(longTokens.prefix(n)) }

        let anchor = prefix(128)
        let t0 = anchor.last ?? 0
        let t1 = anchor.dropLast().last ?? 0
        func suffix(_ k: Int) -> [TokenID] { (0..<k).map { $0 % 2 == 0 ? t0 : t1 } }

        // Warm kernels.
        await runtime.resetKVCache()
        _ = try await runtime.anchoredLogits(anchor: anchor, suffix: [])

        // ---- A. Cold prefill scaling: clear + decode N tokens, logits on last only ----
        let prefillNs = [16, 32, 64, 128, 256]
        var prefillMs: [Double] = []
        for n in prefillNs {
            let p = prefix(n)
            let s = try await minSeconds(5) {
                await runtime.resetKVCache()
                _ = try await runtime.anchoredLogits(anchor: p, suffix: [])
            }
            prefillMs.append(s * 1000)
        }
        let prefillFit = linearFit(prefillNs.map(Double.init), prefillMs)

        // ---- A2. Isolate snapshot CAPTURE. The no-capture baseline MUST force a GPU sync (read
        //          logits), else the deferred async decode compute leaks into the delta and inflates
        //          "capture" to ~20 ms (the original ADR-044 mis-measurement). prepare()+logits reads
        //          decode+sync without get_data; anchoredLogits() additionally captures. ----
        let capN = prefix(128)
        let decodeSyncNoCaptureMs = try await minSeconds(6) {
            await runtime.resetKVCache()
            try await runtime.prepare(promptTokens: capN)
            _ = try await runtime.logitsForNextToken()
        } * 1000
        let decodeAndCaptureMs = try await minSeconds(6) {
            await runtime.resetKVCache()
            _ = try await runtime.anchoredLogits(anchor: capN, suffix: [])
        } * 1000
        let captureMs = decodeAndCaptureMs - decodeSyncNoCaptureMs

        // ---- B. Branch depth scaling: resident anchor, restore + decode K-token suffix ----
        _ = try await runtime.anchoredLogits(anchor: anchor, suffix: [])  // make anchor resident
        let branchKs = [1, 2, 3, 4, 6, 8]
        var branchMs: [Double] = []
        for k in branchKs {
            let suf = suffix(k)
            let s = try await minSeconds(8) { _ = try await runtime.anchoredLogits(anchor: anchor, suffix: suf) }
            branchMs.append(s * 1000)
        }
        let branchFit = linearFit(branchKs.map(Double.init), branchMs)

        // ---- C. Batched width amortization: W branches (suffix len 1) in ONE decode ----
        let widths = [1, 2, 3, 4]
        var widthMs: [Double] = []
        for w in widths {
            let sufs = Array(repeating: suffix(1), count: w)
            let s = try await minSeconds(8) { _ = try await runtime.anchoredLogitsBatch(anchor: anchor, suffixes: sufs) }
            widthMs.append(s * 1000)
        }
        let widthFit = linearFit(widths.map(Double.init), widthMs)

        // ---- D. CPU-side readback + materialization (logitsForNextToken) ----
        _ = try await runtime.anchoredLogits(anchor: anchor, suffix: suffix(1))
        let readbackMs = try await minSeconds(20) { _ = try await runtime.logitsForNextToken() } * 1000

        // ---- E. CPU-side sampler (TokenSampler.rank over the real vocab) ----
        let logits = try await runtime.anchoredLogits(anchor: anchor, suffix: suffix(1))
        var samplerMs = Double.greatestFiniteMagnitude
        for _ in 0..<20 {
            let start = DispatchTime.now()
            _ = TokenSampler.rank(logits: logits, mode: .prose, profile: profile, configuration: config, isAdmissible: { _ in true })
            samplerMs = min(samplerMs, Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        }

        // ---- F. Model size cross-check for the per-decode weight-stream floor ----
        let modelURL = try ModelContainer.modelURL()
        let modelAttrs = try? FileManager.default.attributesOfItem(atPath: modelURL.path)
        let modelBytes = (modelAttrs?[.size] as? NSNumber)?.intValue ?? 0
        let modelGiB = Double(modelBytes) / 1_073_741_824.0
        // ---- Derived components ----
        // The width-fit INTERCEPT (W→0) is the true per-`llama_decode` floor: dispatch + full-model
        // weight stream, with no per-branch restore/forward/LM-row. The branch fit's intercept adds
        // exactly one restore on top of that floor.
        let perDecodeFloor = widthFit.intercept
        let restoreCost = max(0, branchFit.intercept - widthFit.intercept) // branch floor = floor + 1 restore
        let perTokenForwardSmall = branchFit.slope         // small-batch sequential forward / token
        let perTokenForwardParallel = prefillFit.slope     // parallel prefill forward / token
        let perBranchMarginal = widthFit.slope             // restore + forward + extra LM-head row per added branch
        // Effective BW implied if the per-decode floor were a pure full-model weight stream.
        let impliedBWGiBs = perDecodeFloor > 0 ? modelGiB / (perDecodeFloor / 1000.0) : 0

        print("\n================ KeyType detailed component profile (ADR-043) ================")
        print(String(format: "  model: %@  (%.2f GiB on disk)", modelURL.lastPathComponent, modelGiB))
        print("  -- raw measurements (min-of-N, warm, release) --")
        print("  A) cold prefill (ms) by tokens \(prefillNs): \(prefillMs.map { String(format: "%.1f", $0) })")
        print(String(format: "     fit: %.2f ms + %.3f ms/token   (intercept = per-decode floor; slope = parallel fwd/token)", prefillFit.intercept, prefillFit.slope))
        print("  B) branch restore+decode (ms) by depth \(branchKs): \(branchMs.map { String(format: "%.1f", $0) })")
        print(String(format: "     fit: %.2f ms + %.3f ms/token   (intercept = floor+restore; slope = small-batch fwd/token)", branchFit.intercept, branchFit.slope))
        print("  C) batched width (ms) by branches \(widths): \(widthMs.map { String(format: "%.1f", $0) })")
        print(String(format: "     fit: %.2f ms + %.3f ms/branch  (slope = per-added-branch restore+fwd+LM-row)", widthFit.intercept, widthFit.slope))
        print(String(format: "  D) logitsForNextToken readback+materialize : %.3f ms", readbackMs))
        print(String(format: "  E) TokenSampler.rank over full vocab        : %.3f ms", samplerMs))
        print(String(format: "  F) decode+sync NO-capture(128): %.2f ms   |   decode+capture(128) : %.2f ms", decodeSyncNoCaptureMs, decodeAndCaptureMs))
        print("  -- derived primitives --")
        print(String(format: "     per-decode FIXED floor (dispatch + full-model weight stream) : %.2f ms", perDecodeFloor))
        print(String(format: "       └─ implied effective bandwidth if pure weight stream      : %.0f GiB/s (model %.2f GiB)", impliedBWGiBs, modelGiB))
        print(String(format: "     snapshot CAPTURE (llama_state_seq_get_data, synced baseline) : %.2f ms  ◄ cheap (ADR-045 corrects ADR-044)", captureMs))
        print(String(format: "     COLD prompt decode+sync (clear+full re-decode, 128 tok)     : %.2f ms  ◄ the real one-time cost", decodeSyncNoCaptureMs))
        print(String(format: "     snapshot restore  (set_data, per branch seed)                : %.2f ms", restoreCost))
        print(String(format: "     forward / token  — parallel(prefill) %.3f | small-batch %.3f ms", perTokenForwardParallel, perTokenForwardSmall))
        print(String(format: "     per-added-branch marginal in a batched decode                : %.2f ms", perBranchMarginal))

        // ---- Reconcile against a real depth-4 width-4 completion ----
        let target = AppTarget(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit", windowTitle: "Untitled")
        let before = "I am writing to let you know that the meeting scheduled for tomorrow "
        let ctx = TextFieldContext(beforeCursor: before, afterCursor: "", target: target, detectedLanguage: "en")
        let promptText = PromptBuilder().buildPrompt(context: ctx).prompt
        let promptTokens = try runtime.tokenizer.tokenize(promptText).count
        let request = CompletionRequest(context: ctx, prompt: promptText, mode: .prose, maxCompletionTokens: 4, maxDisplayWidth: 60)
        await runtime.resetKVCache()
        _ = try await ConstrainedGenerationEngine(runtime: runtime, profile: profile, configuration: config).completions(for: request)
        let real = try await minSeconds(3) {
            await runtime.resetKVCache()
            _ = try await ConstrainedGenerationEngine(runtime: runtime, profile: profile, configuration: config).completions(for: request)
        } * 1000

        // Model the COLD path: one full prompt decode+sync (clear path — measured directly at F, not
        // the warm batched floor, because clearing the cache triggers a much larger Metal floor),
        // a cheap capture, then 3 batched frontier levels, plus CPU readback/sampling per branch.
        let modeledPromptDecode = decodeSyncNoCaptureMs
        let modeledLevels = (1...3).reduce(0.0) { acc, d in
            acc + perDecodeFloor + 4.0 * (restoreCost + perTokenForwardSmall * Double(d))
        }
        let modeledSampling = 13.0 * (readbackMs + samplerMs)
        let modeled = modeledPromptDecode + captureMs + modeledLevels + modeledSampling

        print("  -- reconciliation: real depth-4 width-4 completion --")
        print(String(format: "     prompt tokens %d", promptTokens))
        print(String(format: "     measured completion        : %.1f ms", real))
        print(String(format: "     modeled from primitives    : %.1f ms", modeled))
        print(String(format: "       ├─ prompt decode (1×)    : %.1f ms (%.0f%%)", modeledPromptDecode, modeledPromptDecode / modeled * 100))
        print(String(format: "       ├─ snapshot capture (1×) : %.1f ms (%.0f%%)", captureMs, captureMs / modeled * 100))
        print(String(format: "       ├─ 3 batched levels      : %.1f ms (%.0f%%)", modeledLevels, modeledLevels / modeled * 100))
        print(String(format: "       └─ readback+sampling     : %.1f ms (%.0f%%)", modeledSampling, modeledSampling / modeled * 100))
        print("=============================================================================\n")

        await runtime.shutdown()
    }

    /// Sweeps `maxSequences` (n_seq_max) to show that latency is flat across it once it covers the
    /// active beam width — extra sequence slots only reserve recurrent buffers, they are not a matmul
    /// batch dimension, so there is no power-of-two effect.
    func testMaxSequencesSweep() async throws {
        try XCTSkipUnless(ModelContainer.defaultModelExists(), "GGUF missing; skipping")
        let profileURL = try ModelContainer.profileURL(family: Self.family)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: profileURL.path), "profile missing")

        let target = AppTarget(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit", windowTitle: "Untitled")
        let before = "I am writing to let you know that the meeting scheduled for tomorrow "
        let context = TextFieldContext(beforeCursor: before, afterCursor: "", target: target, detectedLanguage: "en")
        let promptText = PromptBuilder().buildPrompt(context: context).prompt
        let request = CompletionRequest(
            context: context, prompt: promptText, mode: .prose, maxCompletionTokens: 4, maxDisplayWidth: 60
        )
        let config = DecodingConfiguration(maxCandidates: 5, enableFillInMiddle: true)

        print("\n================ maxSequences (n_seq_max) sweep ================")
        for maxSeq in [1, 2, 3, 4, 5, 8] {
            let runtime = try LlamaModelRuntime(
                modelURL: try ModelContainer.modelURL(), contextLength: 2048, enableKVFork: true, maxSequences: maxSeq
            )
            let profile = try MmapAutocompleteProfile.open(
                at: profileURL,
                tokenizerVocabSize: runtime.metadata.vocabularySize,
                tokenizerBytes: { try runtime.tokenizer.rawBytes(for: $0) },
                expectedModelFamily: Self.family
            )
            func once() async throws -> (Double, [String]) {
                await runtime.resetKVCache()
                let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile, configuration: config)
                let start = DispatchTime.now()
                let cands = try await engine.completions(for: request)
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                return (ms, cands.map(\.text))
            }
            _ = try await once() // warm
            var best = Double.greatestFiniteMagnitude
            var cands: [String] = []
            for _ in 0..<3 { let (ms, c) = try await once(); best = min(best, ms); cands = c } // min of 3 (cold each)
            print(String(format: "  maxSequences=%d : %6.1f ms   top=%@", maxSeq, best, cands.first.map { "\"\($0)\"" } ?? "—"))
            await runtime.shutdown()
        }
        print("==============================================================================\n")
    }

    private func seconds(_ block: () async throws -> Void) async rethrows -> Double {
        let start = DispatchTime.now()
        try await block()
        return Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    func testPrefillVsBranchCost() async throws {
        let runtime = try load()
        let target = AppTarget(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit", windowTitle: "Untitled")
        let before = "I am writing to let you know that the meeting scheduled for tomorrow "
        let prompt = PromptBuilder().buildPrompt(
            context: TextFieldContext(beforeCursor: before, afterCursor: "", target: target, detectedLanguage: "en")
        ).prompt
        let anchor = try runtime.tokenizer.tokenize(prompt)

        // A couple of plausible continuation tokens to feed as branch suffixes.
        let t1 = anchor.last ?? 0
        let t2 = anchor.dropLast().last ?? 0

        // Warm: hot kernels + first prefill.
        await runtime.resetKVCache()
        _ = try await runtime.anchoredLogits(anchor: anchor, suffix: [])

        // 1) Cold full prefill (clear, decode the whole anchor, snapshot, read logits).
        var prefill = 0.0
        let prefillRuns = 5
        for _ in 0..<prefillRuns {
            await runtime.resetKVCache()
            prefill += try await seconds { _ = try await runtime.anchoredLogits(anchor: anchor, suffix: []) }
        }
        prefill /= Double(prefillRuns)

        // Ensure the anchor snapshot is resident for the per-branch measurements below.
        _ = try await runtime.anchoredLogits(anchor: anchor, suffix: [])

        // 2) Cached root (empty suffix): no decode, cached anchor-end logits.
        var root = 0.0
        let rootRuns = 20
        for _ in 0..<rootRuns {
            root += try await seconds { _ = try await runtime.anchoredLogits(anchor: anchor, suffix: []) }
        }
        root /= Double(rootRuns)

        // 3) Per-branch: restore anchor snapshot + decode a 1-token suffix + read logits.
        var branch1 = 0.0
        let branchRuns = 20
        for i in 0..<branchRuns {
            let tok = (i % 2 == 0) ? t1 : t2
            branch1 += try await seconds { _ = try await runtime.anchoredLogits(anchor: anchor, suffix: [tok]) }
        }
        branch1 /= Double(branchRuns)

        // 4) Per-branch with a 3-token suffix (deeper beam level): restore + decode 3 tokens.
        var branch3 = 0.0
        for i in 0..<branchRuns {
            let tok = (i % 2 == 0) ? t1 : t2
            branch3 += try await seconds { _ = try await runtime.anchoredLogits(anchor: anchor, suffix: [tok, t2, t1]) }
        }
        branch3 /= Double(branchRuns)

        // 5) Pure greedy append: decode 1 token with NO restore (the cost a single-branch / greedy
        //    step pays). Isolates llama_decode launch+compute from the snapshot-restore overhead.
        await runtime.resetKVCache()
        _ = try await runtime.anchoredLogits(anchor: anchor, suffix: [])
        var greedy = 0.0
        let greedyRuns = 20
        for i in 0..<greedyRuns {
            let tok = (i % 2 == 0) ? t1 : t2
            greedy += try await seconds {
                try await runtime.decodeNext(tokenID: tok)
                _ = try await runtime.logitsForNextToken()
            }
        }
        greedy /= Double(greedyRuns)

        // Model a depth-4 width-4 beam: 1 prefill + 1 cached root + 4×(1-tok) + 4×(2-tok) + 4×(3-tok).
        // Approximate the 2-tok cost as the midpoint of branch1 and branch3.
        let branch2 = (branch1 + branch3) / 2
        let modeled = prefill + root + 4 * branch1 + 4 * branch2 + 4 * branch3

        print("\n================ prefill vs per-branch micro-bench ================")
        print(String(format: "  anchor tokens                 : %d", anchor.count))
        print(String(format: "  1) cold full prefill          : %7.2f ms", prefill * 1000))
        print(String(format: "  2) cached root (empty suffix) : %7.2f ms", root * 1000))
        print(String(format: "  3) restore + decode 1 token   : %7.2f ms", branch1 * 1000))
        print(String(format: "  4) restore + decode 3 tokens  : %7.2f ms", branch3 * 1000))
        print(String(format: "  5) greedy append 1 tok (no restore): %7.2f ms", greedy * 1000))
        print(String(format: "     → restore overhead alone   : %7.2f ms (branch1 minus greedy)", (branch1 - greedy) * 1000))
        let marginalPerToken: Double = (branch3 - branch1) / 2
        let restoreOverhead: Double = branch1 - marginalPerToken
        let branchShare: Double = 4 * branch1 + 4 * branch2 + 4 * branch3
        print(String(format: "     → marginal cost / token     : %7.2f ms (decode-bound part)", marginalPerToken * 1000))
        print(String(format: "     → restore + fixed overhead  : %7.2f ms (branch1 minus 1 token)", restoreOverhead * 1000))
        print(String(format: "  modeled depth4xwidth4 total   : %7.2f ms", modeled * 1000))
        print(String(format: "     prefill share              : %5.1f%%", prefill / modeled * 100))
        print(String(format: "     12 branch expansions       : %5.1f%%", branchShare / modeled * 100))
        print("==================================================================\n")

        await runtime.shutdown()
    }
}
