import AutocompleteCore
@testable import ConstrainedGeneration
import LlamaModelRuntime
import ModelRuntime
import Prompting
import TokenProfiles
import XCTest

/// On-device latency profiler for the production completion path. Not an assertion suite — it
/// attributes wall-clock time across the decode loop so we can see the bottleneck. Wraps the real
/// `LlamaModelRuntime` and, after each `prepare`, reads `lastPrepareDecodedCount` to separate true
/// KV-cache reuse (≈0 tokens decoded) from full re-prefills (whole prompt decoded again).
///
/// Run: swift test --package-path Packages/ConstrainedGeneration \
///   --filter LatencyProfileTests -c release
final class LatencyProfileTests: XCTestCase {
    private static let family = "qwen3-v151936"

    /// Records what the engine asks of the runtime, classifying each prepare by how many tokens it
    /// actually pushed through `llama_decode`.
    private final class ProfilingRuntime: LocalModelRuntime {
        let wrapped: LlamaModelRuntime
        var metadata: ModelMetadata { wrapped.metadata }
        var tokenizer: ModelTokenizing { wrapped.tokenizer }

        private(set) var prepareCalls = 0
        private(set) var reuseHits = 0          // prepare that decoded 0 tokens (full reuse)
        private(set) var appendCalls = 0        // prepare that decoded a small suffix
        private(set) var fullPrefillCalls = 0   // prepare that re-decoded (almost) the whole prompt
        private(set) var tokensDecoded = 0      // total tokens through llama_decode
        private(set) var prepareSeconds = 0.0
        private(set) var logitsCalls = 0
        private(set) var logitsSeconds = 0.0
        private var lastPromptCount = 0

        init(_ runtime: LlamaModelRuntime) { self.wrapped = runtime }

        func prepare(promptTokens: [TokenID]) async throws {
            let start = DispatchTime.now()
            try await wrapped.prepare(promptTokens: promptTokens)
            prepareSeconds += seconds(since: start)
            prepareCalls += 1
            let decoded = await wrapped.lastPrepareDecodedCount
            tokensDecoded += decoded
            classifyAnchorDecode(decoded, anchorCount: promptTokens.count)
            lastPromptCount = promptTokens.count
        }

        /// The engine drives this (ADR-018). `lastPrepareDecodedCount` reflects only the *anchor*
        /// component (0 when reused), so the branch's own suffix decode is added on top.
        func anchoredLogits(anchor: [TokenID], suffix: [TokenID]) async throws -> [TokenLogit] {
            let start = DispatchTime.now()
            let result = try await wrapped.anchoredLogits(anchor: anchor, suffix: suffix)
            prepareSeconds += seconds(since: start)
            prepareCalls += 1
            let anchorDecoded = await wrapped.lastPrepareDecodedCount
            tokensDecoded += anchorDecoded + suffix.count
            classifyAnchorDecode(anchorDecoded, anchorCount: anchor.count)
            lastPromptCount = anchor.count
            return result
        }

        private func classifyAnchorDecode(_ decoded: Int, anchorCount: Int) {
            if decoded == 0 {
                reuseHits += 1
            } else if decoded >= max(1, anchorCount - 1) {
                fullPrefillCalls += 1
            } else {
                appendCalls += 1
            }
        }

        func logitsForNextToken() async throws -> [TokenLogit] {
            let start = DispatchTime.now()
            let result = try await wrapped.logitsForNextToken()
            logitsSeconds += seconds(since: start)
            logitsCalls += 1
            return result
        }

        func decodeNext(tokenID: TokenID) async throws { try await wrapped.decodeNext(tokenID: tokenID) }
        func resetKVCache() async { await wrapped.resetKVCache() }

        private func seconds(since start: DispatchTime) -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        }
    }

    private func load(enableKVFork: Bool = true) throws -> (LlamaModelRuntime, MmapAutocompleteProfile) {
        try XCTSkipUnless(ModelContainer.defaultModelExists(), "GGUF missing; skipping profile")
        let profileURL = try ModelContainer.profileURL(family: Self.family)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: profileURL.path), "profile missing")
        let runtime = try LlamaModelRuntime(modelURL: try ModelContainer.modelURL(), contextLength: 2048, enableKVFork: enableKVFork)
        let profile = try MmapAutocompleteProfile.open(
            at: profileURL,
            tokenizerVocabSize: runtime.metadata.vocabularySize,
            tokenizerBytes: { try runtime.tokenizer.rawBytes(for: $0) },
            expectedModelFamily: Self.family
        )
        return (runtime, profile)
    }

    private static let paragraph = """
    Thanks so much for sending over the draft earlier today. I read through the whole thing on \
    the train home and I think the overall direction is exactly right. The section on rollout in \
    particular felt clear and well argued, and I don't have much to add there. One thing I wanted \
    to flag before we share it more widely is that the timeline in the second half still assumes \
    the data migration finishes before the end of the quarter, and I'm
    """

    func testProfileProductionLatency() async throws {
        let (raw, profile) = try load()
        let target = AppTarget(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit", windowTitle: "Untitled")

        // Cases mirror the live app: prose append + a mid-line fill (FIM path). beforeCursor lengths
        // span a realistic short/medium/long spread.
        let cases: [(name: String, before: String, after: String)] = [
            ("short append", "Thanks so much for your ", ""),
            ("medium append", "I am writing to let you know that the meeting scheduled for tomorrow ", ""),
            ("long append (paragraph)", Self.paragraph, ""),
            ("mid-line FIM", "The capital of ", "is one of the largest cities in Europe.")
        ]

        print("\n================ KeyType production latency profile ================")
        print("config: branchWidth=\(DecodingConfiguration().branchWidth) maxTokens=4 maxWidth=60 FIM=on\n")

        for c in cases {
            let runtime = ProfilingRuntime(raw)
            await runtime.resetKVCache()
            let engine = ConstrainedGenerationEngine(
                runtime: runtime,
                profile: profile,
                configuration: DecodingConfiguration(maxCandidates: 5, enableFillInMiddle: true)
            )
            let promptText = PromptBuilder().buildPrompt(
                context: TextFieldContext(beforeCursor: c.before, afterCursor: c.after, target: target, detectedLanguage: "en")
            ).prompt
            let promptTokens = try raw.tokenizer.tokenize(promptText).count

            let request = CompletionRequest(
                context: TextFieldContext(beforeCursor: c.before, afterCursor: c.after, target: target, detectedLanguage: "en"),
                prompt: promptText,
                mode: .prose,
                maxCompletionTokens: 4,
                maxDisplayWidth: 60
            )

            // Warm once (so model/Metal kernels are hot), then time.
            _ = try await engine.completions(for: request)

            let timed = ProfilingRuntime(raw)
            await timed.resetKVCache()
            let timedEngine = ConstrainedGenerationEngine(
                runtime: timed,
                profile: profile,
                configuration: DecodingConfiguration(maxCandidates: 5, enableFillInMiddle: true)
            )
            let start = DispatchTime.now()
            let candidates = try await timedEngine.completions(for: request)
            let total = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000

            print("---- \(c.name) ----")
            print(String(format: "  prompt tokens     : %d", promptTokens))
            print(String(format: "  TOTAL             : %7.1f ms", total * 1000))
            print(String(format: "  prepare (decode)  : %7.1f ms  (%.0f%%)  calls=%d",
                         timed.prepareSeconds * 1000, timed.prepareSeconds / total * 100, timed.prepareCalls))
            print(String(format: "    ├─ full prefills: %d  (re-decode whole prompt)", timed.fullPrefillCalls))
            print(String(format: "    ├─ appends      : %d  (decode small suffix)", timed.appendCalls))
            print(String(format: "    └─ reuse hits   : %d  (0 tokens decoded)", timed.reuseHits))
            print(String(format: "  tokens decoded    : %d  (≈%d full prompts' worth)",
                         timed.tokensDecoded, promptTokens == 0 ? 0 : timed.tokensDecoded / max(1, promptTokens)))
            print(String(format: "  logits read       : %7.1f ms  (%.0f%%)  calls=%d",
                         timed.logitsSeconds * 1000, timed.logitsSeconds / total * 100, timed.logitsCalls))
            let other = (total - timed.prepareSeconds - timed.logitsSeconds) * 1000
            print(String(format: "  sampling + other  : %7.1f ms  (%.0f%%)", other, other / (total * 1000) * 100))
            print("  candidates        : \(candidates.map(\.text))\n")
        }
        print("====================================================================\n")
    }

    /// Asserts the ADR-018 win: with KV fork on, the base prompt is prefilled exactly **once** per
    /// completion (the rest of the branches reuse the resident anchor), collapsing total decoded
    /// tokens and wall-clock latency versus the legacy decode-the-whole-prompt-per-branch path.
    func testAnchoredReuseReducesPrefillsAndLatency() async throws {
        let target = AppTarget(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit", windowTitle: "Untitled")
        let before = "I am writing to let you know that the meeting scheduled for tomorrow "
        let context = TextFieldContext(beforeCursor: before, afterCursor: "", target: target, detectedLanguage: "en")
        let promptText = PromptBuilder().buildPrompt(context: context).prompt
        let request = CompletionRequest(
            context: context, prompt: promptText, mode: .prose, maxCompletionTokens: 4, maxDisplayWidth: 60
        )
        let config = DecodingConfiguration(maxCandidates: 5, enableFillInMiddle: true)

        func measure(enableKVFork: Bool) async throws -> (prefills: Int, tokens: Int, seconds: Double) {
            let (raw, profile) = try load(enableKVFork: enableKVFork)
            // Warm (hot kernels), then time on a fresh profiling wrapper.
            let warm = ProfilingRuntime(raw); await warm.resetKVCache()
            _ = try await ConstrainedGenerationEngine(runtime: warm, profile: profile, configuration: config).completions(for: request)

            let timed = ProfilingRuntime(raw); await timed.resetKVCache()
            let engine = ConstrainedGenerationEngine(runtime: timed, profile: profile, configuration: config)
            let start = DispatchTime.now()
            _ = try await engine.completions(for: request)
            let secs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
            return (timed.fullPrefillCalls, timed.tokensDecoded, secs)
        }

        let off = try await measure(enableKVFork: false)
        let on = try await measure(enableKVFork: true)

        print("\n================ ADR-018 reuse vs baseline ================")
        print(String(format: "  baseline (fork off): fullPrefills=%2d  tokensDecoded=%4d  %6.1f ms", off.prefills, off.tokens, off.seconds * 1000))
        print(String(format: "  anchored (fork on) : fullPrefills=%2d  tokensDecoded=%4d  %6.1f ms", on.prefills, on.tokens, on.seconds * 1000))
        print(String(format: "  tokensDecoded reduction: %.1fx   latency reduction: %.1fx", Double(off.tokens) / Double(max(1, on.tokens)), off.seconds / max(0.0001, on.seconds)))
        print("===========================================================\n")

        // The anchor is decoded exactly once; every other branch reuses it.
        XCTAssertEqual(on.prefills, 1, "fork should prefill the base prompt exactly once per completion")
        XCTAssertGreaterThan(off.prefills, 1, "baseline should re-prefill per divergent branch")
        // Deterministic work proxy: decoded tokens collapse well past 2x.
        XCTAssertGreaterThan(Double(off.tokens) / Double(max(1, on.tokens)), 2.0, "decoded tokens should drop >2x")
        // Wall-clock: expected ~6-10x; assert a guarded >1.5x to tolerate timing noise.
        XCTAssertGreaterThan(off.seconds / max(0.0001, on.seconds), 1.5, "anchored latency should be well under baseline")
    }

    /// Confirms the dominant lever on the *baseline* path: full prefills (and thus latency) scale
    /// with branch width, since every divergent branch forces a KV clear + full re-decode. Run with
    /// fork off so the legacy scaling is visible (with fork on, prefills stay at 1 regardless).
    func testBranchWidthSweep() async throws {
        let (raw, profile) = try load(enableKVFork: false)
        let target = AppTarget(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit", windowTitle: "Untitled")
        let before = "I am writing to let you know that the meeting scheduled for tomorrow "
        let promptText = PromptBuilder().buildPrompt(
            context: TextFieldContext(beforeCursor: before, afterCursor: "", target: target, detectedLanguage: "en")
        ).prompt
        let request = CompletionRequest(
            context: TextFieldContext(beforeCursor: before, afterCursor: "", target: target, detectedLanguage: "en"),
            prompt: promptText, mode: .prose, maxCompletionTokens: 4, maxDisplayWidth: 60
        )

        print("\n================ branch-width sweep (medium append) ================")
        for width in [1, 2, 3, 4] {
            let config = DecodingConfiguration(branchWidth: width, maxCandidates: 5, enableFillInMiddle: true)
            // warm
            let warm = ProfilingRuntime(raw); await warm.resetKVCache()
            _ = try await ConstrainedGenerationEngine(runtime: warm, profile: profile, configuration: config).completions(for: request)

            let timed = ProfilingRuntime(raw); await timed.resetKVCache()
            let engine = ConstrainedGenerationEngine(runtime: timed, profile: profile, configuration: config)
            let start = DispatchTime.now()
            let candidates = try await engine.completions(for: request)
            let total = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
            print(String(format: "  branchWidth=%d : %6.1f ms   fullPrefills=%2d  tokensDecoded=%4d  topCandidate=%@",
                         width, total * 1000, timed.fullPrefillCalls, timed.tokensDecoded,
                         candidates.first.map { "\"\($0.text)\"" } ?? "—"))
        }
        print("====================================================================\n")
    }
}
