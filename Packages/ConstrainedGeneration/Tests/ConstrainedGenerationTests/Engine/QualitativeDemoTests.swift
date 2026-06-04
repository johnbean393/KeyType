import AppKit
import AutocompleteCore
@testable import ConstrainedGeneration
import LlamaModelRuntime
import ModelRuntime
import TokenProfiles
import XCTest

/// Not an assertion suite — prints real completions for a handful of prompts so we can eyeball
/// quality, plus per-completion latency so we can judge in-app responsiveness. Skip-gated on the
/// GGUF + ACPF profile being present.
final class QualitativeDemoTests: XCTestCase {
    private static let family = "qwen3-v151936"

    private func loadEngine(
        configuration: DecodingConfiguration = DecodingConfiguration(maxCandidates: 5),
        recognizer: WordRecognizing? = nil
    ) throws -> (engine: ConstrainedGenerationEngine, loadSeconds: Double) {
        try XCTSkipUnless(ModelContainer.defaultModelExists(), "GGUF missing; skipping demo")
        let profileURL = try ModelContainer.profileURL(family: Self.family)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: profileURL.path),
            "profile missing; skipping demo"
        )

        let start = DispatchTime.now()
        let runtime = try LlamaModelRuntime(modelURL: try ModelContainer.modelURL(), contextLength: 1024)
        let profile = try MmapAutocompleteProfile.open(
            at: profileURL,
            tokenizerVocabSize: runtime.metadata.vocabularySize,
            tokenizerBytes: { try runtime.tokenizer.rawBytes(for: $0) },
            expectedModelFamily: Self.family
        )
        let engine = ConstrainedGenerationEngine(
            runtime: runtime,
            profile: profile,
            configuration: configuration,
            wordRecognizer: recognizer
        )
        let loadSeconds = elapsed(since: start)
        return (engine, loadSeconds)
    }

    /// Sweeps `branchWidth` to show the latency/quality trade-off for a short (4-token) completion.
    func testBranchWidthSweep() async throws {
        let target = AppTarget(bundleIdentifier: "com.test.app", appName: "Test")
        let prompts = [
            "The weather today is",
            "Thanks so much for your",
            "Looking forward to hearing",
            "A quick brown fox",
            "The capital of France is"
        ]
        let widths = [8, 5, 3, 2, 1]

        print("\n================ KeyType branchWidth sweep (maxTokens=4) ================")
        for width in widths {
            let (engine, _) = try loadEngine(
                configuration: DecodingConfiguration(branchWidth: width, maxCandidates: 5)
            )
            // Warm up (cold KV cache / first-call effects excluded from the mean).
            _ = try await engine.completions(for: makeRequest(prompts[0], target: target, maxTokens: 4))

            var samples: [Double] = []
            var foxTop = "—"
            for prompt in prompts {
                let request = makeRequest(prompt, target: target, maxTokens: 4)
                let start = DispatchTime.now()
                let candidates = try await engine.completions(for: request)
                samples.append(elapsed(since: start) * 1000)
                if prompt == "A quick brown fox" { foxTop = candidates.first.map { display($0.text) } ?? "(none)" }
            }
            let mean = samples.reduce(0, +) / Double(samples.count)
            print(String(format: "branchWidth=%d  warm mean %6.0f ms   fox→%@", width, mean, foxTop))
        }
        print("========================================================================\n")
    }

    func testPrintExampleGenerations() async throws {
        let (engine, loadSeconds) = try loadEngine()
        let target = AppTarget(bundleIdentifier: "com.test.app", appName: "Test")
        let prompts = [
            "A quick brown fox",
            "The quick brown fox jumps over the lazy",
            "The capital of France is",
            "To be or not to",
            "I will see you tom",
            "def add(a, b):\n    return a +",
            "Once upon a"
        ]

        print("\n================ KeyType qualitative generations ================")
        print(String(format: "model + profile load: %.0f ms", loadSeconds * 1000))
        for prompt in prompts {
            let request = makeRequest(prompt, target: target, maxTokens: 6)
            let candidates = try await engine.completions(for: request)
            print("\nPROMPT: \(display(prompt))")
            if candidates.isEmpty { print("  (suppressed — no candidate)") }
            for (i, c) in candidates.enumerated() {
                let score = String(format: "%.3f", c.logProbability)
                print("  [\(i)] \(display(c.text))   (logp=\(score), width=\(c.displayWidth), tokens=\(c.tokenIDs.count))")
            }
        }
        print("\n=================================================================\n")
    }

    /// A broad sweep of English strings — questions, emails, lists, code, contractions, numbers,
    /// mid-word completions — with the real `NSSpellChecker` typo guard wired in, so we can eyeball
    /// quality and confirm the guard doesn't over-suppress.
    func testPrintVariedStrings() async throws {
        let (engine, _) = try loadEngine(recognizer: SpellCheckRecognizer())
        let target = AppTarget(bundleIdentifier: "com.test.app", appName: "Test")
        let prompts = [
            "Could you please let me",
            "I can't believe it's already",
            "The total comes to $42.50 and the",
            "On Monday we have 3",
            "Her email address is jane.doe@",
            "TODO: refactor the parser to",
            "The U.S. economy grew by",
            "He said, \"I'll be there",
            "https://www.example.com/path?query=",
            "I will see you tom",
            "Thank you for your patience and",
            "import numpy as np\n",
            "for i in range(10):\n    ",
            "Best regards,\n",
            "The mitochondria is the powerhouse of the"
        ]

        print("\n================ KeyType varied strings (maxTokens=6, spell guard on) ================")
        for prompt in prompts {
            let request = makeRequest(prompt, target: target, maxTokens: 6, language: "en")
            let candidates = try await engine.completions(for: request)
            print("\nPROMPT: \(display(prompt))")
            if candidates.isEmpty { print("  (suppressed — no candidate)") }
            for (i, c) in candidates.prefix(3).enumerated() {
                print("  [\(i)] \(display(c.text))")
            }
        }
        print("\n=====================================================================================\n")
    }

    /// Production-like inputs the old demos never covered: trailing whitespace at the caret,
    /// after-cursor default suppression, and suffix collisions. Mirrors what the live app captures,
    /// and applies the same `CaretBoundary.reconcile` the app uses so the printed "field" column is
    /// what the user would actually see inserted. FIM is configured, but AppCompatibility leaves
    /// mid-line completion off by default. See ADR-082.
    func testPrintProductionLikeInputs() async throws {
        let (engine, _) = try loadEngine(
            configuration: DecodingConfiguration(maxCandidates: 5, enableFillInMiddle: true)
        )
        let target = AppTarget(bundleIdentifier: "com.test.app", appName: "Test")

        // (before-cursor, after-cursor)
        let cases: [(String, String)] = [
            ("The capital of France is ", ""),         // trailing space (append)
            ("I'll see you ", ""),                     // trailing space (append)
            ("Thanks so much for your ", ""),          // trailing space (append)
            ("The capital of ", "is Paris."),          // mid-line: fill "France"
            ("Please ", " me know if you have any questions."), // mid-line: fill "let"
            ("def add(a, b):\n    return ", "\n")       // mid-line code: fill "a + b"
        ]

        print("\n================ KeyType production-like inputs (default mid-line policy) ================")
        for (before, after) in cases {
            // The prompt string mimics the PromptBuilder boundary fix (trailing-trimmed prefix);
            // an opt-in FIM target would ignore it and assemble from context.
            let promptText = String(before.reversed().drop { $0.isWhitespace }.reversed())
            let request = CompletionRequest(
                context: TextFieldContext(beforeCursor: before, afterCursor: after, target: target),
                prompt: promptText,
                mode: .prose,
                maxCompletionTokens: 6,
                maxDisplayWidth: 60
            )
            let candidates = try await engine.completions(for: request)
            print("\nBEFORE: \(display(before))   AFTER: \(display(after))")
            if candidates.isEmpty { print("  (suppressed — no candidate)") }
            for (i, c) in candidates.prefix(2).enumerated() {
                let reconciled = CaretBoundary.reconcile(c.text, beforeCursor: before)
                let field = before + reconciled + after
                let warn = field.contains("  ") ? "  [DOUBLE SPACE]" : ""
                print("  [\(i)] raw=\(display(c.text)) → field=\(display(field))\(warn)")
            }
        }
        print("\n========================================================================\n")
    }

    /// Completions across many languages/scripts, each with its `detectedLanguage` set so the typo
    /// guard uses the right dictionary (and is conservatively inert where none exists).
    func testPrintMultilingualGenerations() async throws {
        let (engine, loadSeconds) = try loadEngine(recognizer: SpellCheckRecognizer())
        let target = AppTarget(bundleIdentifier: "com.test.app", appName: "Test")

        // (language tag, [prompts ending exactly at the cursor])
        let groups: [(String, [String])] = [
            ("en", ["The capital of France is", "Once upon a time there was a"]),
            ("fr", ["La capitale de la France est", "Je vous écris pour vous informer que"]),
            ("de", ["Die Hauptstadt von Deutschland ist", "Ich freue mich darauf, von"]),
            ("es", ["La capital de España es", "Le escribo para informarle que"]),
            ("it", ["La capitale d'Italia è", "Ti scrivo per dirti che"]),
            ("pt", ["A capital do Brasil é", "Estou escrevendo para informar que"]),
            ("nl", ["De hoofdstad van Nederland is"]),
            ("ru", ["Столица России —", "Я пишу вам, чтобы сообщить, что"]),
            ("zh", ["中国的首都是", "今天的天气"]),
            ("ja", ["日本の首都は", "今日の天気は"]),
            ("ko", ["한국의 수도는", "오늘 날씨는"]),
            ("ar", ["عاصمة مصر هي", "أكتب إليك لإبلاغك بأن"]),
            ("hi", ["भारत की राजधानी है", "मैं आपको यह बताने के लिए लिख रहा हूँ कि"])
        ]

        print("\n================ KeyType multilingual generations (maxTokens=6) ================")
        print(String(format: "model + profile load: %.0f ms", loadSeconds * 1000))
        for (language, prompts) in groups {
            print("\n----- \(language) -----")
            for prompt in prompts {
                let request = makeRequest(prompt, target: target, maxTokens: 6, language: language)
                let candidates = try await engine.completions(for: request)
                print("PROMPT: \(display(prompt))")
                if candidates.isEmpty { print("  (suppressed — no candidate)") }
                for (i, c) in candidates.prefix(2).enumerated() {
                    print("  [\(i)] \(display(c.text))   (tokens=\(c.tokenIDs.count), width=\(c.displayWidth))")
                }
            }
        }
        print("\n===============================================================================\n")
    }

    /// Generates longer passages (high `maxCompletionTokens` + wide display) so we can judge how
    /// coherent the constrained beam stays well past the 4-token autocomplete default. Run with
    /// `-c release` for representative latency.
    func testPrintLongCompletions() async throws {
        let (engine, _) = try loadEngine(
            configuration: DecodingConfiguration(branchWidth: 4, maxCandidates: 3)
        )
        let target = AppTarget(bundleIdentifier: "com.test.app", appName: "Test")
        let prompts = [
            "A quick brown fox",
            "The history of the Roman Empire is",
            "To make a good cup of coffee, you",
            "Dear hiring manager, I am writing to apply for",
            "The most important thing to remember when learning to program is",
            "Once upon a time, in a village at the edge of a great forest,",
            "def fibonacci(n):\n    "
        ]

        for maxTokens in [16, 32] {
            print("\n========== KeyType long completions (maxTokens=\(maxTokens)) ==========")
            for prompt in prompts {
                let request = CompletionRequest(
                    context: TextFieldContext(beforeCursor: prompt, target: target),
                    prompt: prompt,
                    mode: .prose,
                    maxCompletionTokens: maxTokens,
                    maxDisplayWidth: 400
                )
                let start = DispatchTime.now()
                let candidates = try await engine.completions(for: request)
                let ms = elapsed(since: start) * 1000

                print("\nPROMPT: \(display(prompt))   (\(Int(ms)) ms)")
                if candidates.isEmpty { print("  (suppressed — no candidate)") }
                for (i, c) in candidates.enumerated() {
                    let score = String(format: "%.2f", c.logProbability)
                    print("  [\(i)] \(display(c.text))")
                    print("       (logp=\(score), width=\(c.displayWidth), tokens=\(c.tokenIDs.count))")
                }
            }
            print("\n====================================================================\n")
        }
    }

    /// Measures steady-state (warm-model) completion latency, which is what a user feels while
    /// typing. The first generation (cold KV cache) is reported separately and excluded from the
    /// warm statistics.
    func testCompletionLatency() async throws {
        let (engine, loadSeconds) = try loadEngine()
        let target = AppTarget(bundleIdentifier: "com.test.app", appName: "Test")

        // A typical keystroke triggers a short completion (default cap is 4 tokens).
        let prompts = [
            "The weather today is",
            "Thanks so much for your",
            "I am writing to let you know that",
            "Let me know if you have any",
            "The meeting is scheduled for",
            "Please find attached the",
            "Looking forward to hearing",
            "def add(a, b):\n    return a +"
        ]

        // Cold start: first completion after load (KV cache empty, no warm paths).
        let coldRequest = makeRequest(prompts[0], target: target, maxTokens: 4)
        let coldStart = DispatchTime.now()
        _ = try await engine.completions(for: coldRequest)
        let coldMs = elapsed(since: coldStart) * 1000

        // Warm runs.
        var samples: [Double] = []
        for prompt in prompts {
            let request = makeRequest(prompt, target: target, maxTokens: 4)
            let start = DispatchTime.now()
            _ = try await engine.completions(for: request)
            samples.append(elapsed(since: start) * 1000)
        }

        let sorted = samples.sorted()
        let mean = samples.reduce(0, +) / Double(samples.count)
        let p50 = sorted[sorted.count / 2]
        let p90 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.9).rounded(.down)))]
        let minV = sorted.first ?? 0
        let maxV = sorted.last ?? 0

        print("\n================ KeyType completion latency (maxTokens=4) ================")
        print(String(format: "model + profile load : %7.0f ms", loadSeconds * 1000))
        print(String(format: "cold first completion: %7.0f ms", coldMs))
        print(String(format: "warm mean            : %7.0f ms", mean))
        print(String(format: "warm p50             : %7.0f ms", p50))
        print(String(format: "warm p90             : %7.0f ms", p90))
        print(String(format: "warm min / max       : %7.0f / %.0f ms", minV, maxV))
        print("per-prompt:")
        for (prompt, ms) in zip(prompts, samples) {
            print(String(format: "  %7.0f ms  %@", ms, display(prompt)))
        }
        print("==========================================================================\n")
    }

    /// Isolates where the per-completion time actually goes: raw decode tps, prefill tps,
    /// the cost of materializing the full logits vector, and the cost of `TokenSampler.rank`.
    func testPhaseBreakdown() async throws {
        try XCTSkipUnless(ModelContainer.defaultModelExists(), "GGUF missing; skipping")
        let profileURL = try ModelContainer.profileURL(family: Self.family)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: profileURL.path), "profile missing; skipping")

        let runtime = try LlamaModelRuntime(modelURL: try ModelContainer.modelURL(), contextLength: 4096)
        let profile = try MmapAutocompleteProfile.open(
            at: profileURL,
            tokenizerVocabSize: runtime.metadata.vocabularySize,
            tokenizerBytes: { try runtime.tokenizer.rawBytes(for: $0) },
            expectedModelFamily: Self.family
        )

        let prompt = try runtime.tokenizer.tokenize("The quick brown fox jumps over the lazy")

        // --- Raw decode tps: prepare once, then decode 128 single tokens (warm). ---
        try await runtime.prepare(promptTokens: prompt)
        let decodeStart = DispatchTime.now()
        let decodeCount = 128
        var tok: TokenID = prompt.last ?? 0
        for _ in 0..<decodeCount {
            try await runtime.decodeNext(tokenID: tok)
            // cheap argmax to advance
            let logits = try await runtime.logitsForNextToken()
            tok = logits.max(by: { $0.logit < $1.logit })?.tokenID ?? 0
        }
        let decodeSec = elapsed(since: decodeStart)

        // --- logitsForNextToken cost in isolation (full 151936-wide copy). ---
        let logitsStart = DispatchTime.now()
        let logitsIters = 50
        var lastLogits: [TokenLogit] = []
        for _ in 0..<logitsIters { lastLogits = try await runtime.logitsForNextToken() }
        let logitsSec = elapsed(since: logitsStart)

        // --- TokenSampler.rank cost in isolation. ---
        let sampleStart = DispatchTime.now()
        let sampleIters = 50
        for _ in 0..<sampleIters {
            _ = TokenSampler.rank(
                logits: lastLogits,
                mode: .prose,
                profile: profile,
                configuration: DecodingConfiguration(),
                isAdmissible: { profile.tokenAllowed($0, afterRequiredPrefix: []) }
            )
        }
        let sampleSec = elapsed(since: sampleStart)

        // --- Per-branch prepare cost: full clear + re-decode of an 11-token prompt, 20 times
        //     (mimics what the engine does for every divergent branch today). ---
        let extended = prompt + [TokenID(100), TokenID(200), TokenID(300)]
        let prepareIters = 20
        let prepareStart = DispatchTime.now()
        for i in 0..<prepareIters {
            // Force divergence each time so the runtime takes the clear+full-redecode path.
            await runtime.resetKVCache()
            try await runtime.prepare(promptTokens: extended + [TokenID(i % 7 + 1)])
        }
        let prepareSec = elapsed(since: prepareStart)

        print("\n================ KeyType phase breakdown ================")
        print(String(format: "raw decode      : %6.1f tok/s  (%.2f ms/tok over %d toks)",
                     Double(decodeCount) / decodeSec, decodeSec * 1000 / Double(decodeCount), decodeCount))
        print(String(format: "logitsForNextTok: %6.2f ms/call (151936-wide copy)", logitsSec * 1000 / Double(logitsIters)))
        print(String(format: "TokenSampler.rank: %6.2f ms/call", sampleSec * 1000 / Double(sampleIters)))
        print(String(format: "prepare (clear + re-decode %d toks): %6.2f ms/call",
                     extended.count + 1, prepareSec * 1000 / Double(prepareIters)))
        print("=========================================================\n")
    }

    private func makeRequest(
        _ prompt: String,
        target: AppTarget,
        maxTokens: Int,
        language: String? = nil
    ) -> CompletionRequest {
        CompletionRequest(
            context: TextFieldContext(beforeCursor: prompt, target: target, detectedLanguage: language),
            prompt: prompt,
            mode: .prose,
            maxCompletionTokens: maxTokens,
            maxDisplayWidth: 60
        )
    }

    private func elapsed(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    private func display(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}

/// `WordRecognizing` backed by `NSSpellChecker` (mirrors the app target's `SystemWordRecognizer`)
/// so the demos exercise the real typo guard. Conservative: anything the checker can't evaluate is
/// reported as recognised.
private struct SpellCheckRecognizer: WordRecognizing {
    func recognizes(_ word: String, language: String?) async -> Bool {
        guard !word.isEmpty else { return true }
        return await MainActor.run {
            let checker = NSSpellChecker.shared
            let resolved = SpellCheckRecognizer.resolveLanguage(language, checker: checker)
            checker.automaticallyIdentifiesLanguages = (resolved == nil)
            let misspelled = checker.checkSpelling(
                of: word,
                startingAt: 0,
                language: resolved,
                wrap: false,
                inSpellDocumentWithTag: 0,
                wordCount: nil
            )
            return misspelled.location == NSNotFound
        }
    }

    private static func resolveLanguage(_ requested: String?, checker: NSSpellChecker) -> String? {
        guard let requested, !requested.isEmpty else { return nil }
        let normalized = requested.replacingOccurrences(of: "-", with: "_")
        let available = checker.availableLanguages
        if available.contains(normalized) { return normalized }
        let base = String(normalized.prefix { $0 != "_" })
        if available.contains(base) { return base }
        return nil
    }
}
