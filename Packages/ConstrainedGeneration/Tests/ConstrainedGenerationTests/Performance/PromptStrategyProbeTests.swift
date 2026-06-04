import AppCompatibility
import AutocompleteCore
@testable import ConstrainedGeneration
import LlamaModelRuntime
import ModelRuntime
import Prompting
import TokenProfiles
import XCTest

/// Throwaway investigation harness (not an assertion suite). Answers two questions:
///
///   1. Why are completions near-perfect in `QualitativeDemoTests` but poor in the running app?
///      The demos feed the model the *raw* before-cursor string; production feeds the full
///      `PromptBuilder` output (instruction header + bracketed metadata sections). This probe runs
///      BOTH through the same loaded model so the gap is visible side by side.
///
///   2. Is opt-in native fill-in-the-middle viable on our Qwen3.5-2B-Base GGUF for mid-line
///      completion? The vocab ships `<|fim_prefix|>` / `<|fim_suffix|>` / `<|fim_middle|>`; this
///      probe encodes them as real control tokens (via `tokenizeAllowingSpecial`) and greedily
///      decodes the middle.
///
/// Skip-gated on the GGUF + ACPF profile being present. Run with:
///   swift test --package-path Packages/ConstrainedGeneration \
///     --filter PromptStrategyProbeTests -c release
final class PromptStrategyProbeTests: XCTestCase {
    private static let family = "qwen3-v151936"

    private func load() throws -> (runtime: LlamaModelRuntime, profile: MmapAutocompleteProfile) {
        try XCTSkipUnless(ModelContainer.defaultModelExists(), "GGUF missing; skipping probe")
        let profileURL = try ModelContainer.profileURL(family: Self.family)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: profileURL.path),
            "profile missing; skipping probe"
        )
        let runtime = try LlamaModelRuntime(modelURL: try ModelContainer.modelURL(), contextLength: 2048)
        let profile = try MmapAutocompleteProfile.open(
            at: profileURL,
            tokenizerVocabSize: runtime.metadata.vocabularySize,
            tokenizerBytes: { try runtime.tokenizer.rawBytes(for: $0) },
            expectedModelFamily: Self.family
        )
        return (runtime, profile)
    }

    private func makeEngine(
        _ runtime: LlamaModelRuntime,
        _ profile: MmapAutocompleteProfile,
        fim: Bool = false
    ) -> ConstrainedGenerationEngine {
        let compatibilityStore = fim
            ? AppCompatibilityStore(overrides: [
                TargetOverride(bundleIdentifier: target.bundleIdentifier, midLineCompletionsEnabled: true)
            ])
            : AppCompatibilityStore()
        return ConstrainedGenerationEngine(
            runtime: runtime,
            profile: profile,
            compatibilityStore: compatibilityStore,
            configuration: DecodingConfiguration(maxCandidates: 5, enableFillInMiddle: fim)
        )
    }

    private let target = AppTarget(
        bundleIdentifier: "com.apple.TextEdit",
        appName: "TextEdit",
        windowTitle: "Untitled"
    )

    func testPromptStrategyProbe() async throws {
        let (runtime, profile) = try load()
        let engine = makeEngine(runtime, profile)
        let fimEngine = makeEngine(runtime, profile, fim: true)
        let maxNew = 6

        // Confirm the FIM markers really collapse to single control tokens on this model.
        let llamaTok = try XCTUnwrap(runtime.tokenizer as? LlamaTokenizer, "expected LlamaTokenizer")
        let fimPre = try llamaTok.tokenizeAllowingSpecial("<|fim_prefix|>")
        let fimSuf = try llamaTok.tokenizeAllowingSpecial("<|fim_suffix|>")
        let fimMid = try llamaTok.tokenizeAllowingSpecial("<|fim_middle|>")
        let literalPre = try llamaTok.tokenize("<|fim_prefix|>")

        print("\n================ KeyType prompt-strategy probe ================")
        print("FIM token check: <|fim_prefix|>→\(fimPre) (special)  vs  \(literalPre) (literal)")
        print("                 <|fim_suffix|>→\(fimSuf)   <|fim_middle|>→\(fimMid)")
        print("(special encodings should be a single id each; literal should be several)\n")

        // ---- End-of-line cases: afterCursor is empty (append at the caret) ----
        let endOfLine = [
            "The capital of France is ",
            "I will see you tom",
            "Thanks so much for your "
        ]
        print("---- END-OF-LINE (append) : production prompt vs clean continuation ----")
        for before in endOfLine {
            let prodPrompt = productionPrompt(before: before, after: "")
            let prodEngine = try await engineTop(engine, prompt: prodPrompt, before: before, after: "", maxNew: maxNew)
            let cleanEngine = try await engineTop(engine, prompt: before, before: before, after: "", maxNew: maxNew)
            let cleanGreedy = try await greedy(runtime, tokens: llamaTok.tokenize(before), maxNew: maxNew)

            print("\nBEFORE: \(disp(before))")
            print("  (A) production prompt → engine : \(disp(prodEngine))")
            print("  (B) clean continuation → engine: \(disp(cleanEngine))")
            print("  (B) clean continuation → greedy: \(disp(cleanGreedy))")
        }

        // ---- Trailing-whitespace sensitivity: the suspected test/prod divergence ----
        // Unit-test prompts end at a word ("…is"); the live caret usually carries the space the
        // user just typed ("…is "). Show both, clean and production, and flag a leading space in
        // the output (which would produce a double space on insertion).
        let pairs = ["The capital of France is", "Thanks so much for your", "I am writing to let you"]
        print("\n---- TRAILING-SPACE SENSITIVITY + boundary reconcile (validates #1) ----")
        for base in pairs {
            for before in [base, base + " "] {
                let prodEngine = try await engineTop(engine, prompt: productionPrompt(before: before, after: ""), before: before, after: "", maxNew: maxNew)
                // What actually gets inserted after CaretBoundary reconciliation.
                let inserted = CaretBoundary.reconcile(prodEngine, beforeCursor: before)
                let combined = before + inserted
                let doubleSpace = combined.contains("  ") ? "  [DOUBLE SPACE]" : ""
                print("BEFORE: \(disp(before))")
                print("   prod→engine: \(disp(prodEngine))   →reconciled: \(disp(inserted))   field=\(disp(combined))\(doubleSpace)")
            }
        }

        // ---- Mid-line cases: afterCursor is non-empty (fill in the gap) ----
        // (before, after, what a human would insert)
        let midLine: [(String, String, String)] = [
            ("The capital of ", "is Paris.", "France "),
            ("Please ", " me know if you have any questions.", "let"),
            ("def add(a, b):\n    return ", "\n", "a + b")
        ]
        print("\n---- MID-LINE (fill) : default policy vs opt-in native FIM (greedy + engine) ----")
        print("(default production policy suppresses after-cursor; opt-in FIM applies context windowing + suffix-overlap truncation + suffix-likelihood rerank)")
        for (before, after, want) in midLine {
            let prodPrompt = productionPrompt(before: before, after: after)
            let prodEngine = try await engineTop(engine, prompt: prodPrompt, before: before, after: after, maxNew: maxNew)
            let fimTokens = fimPre + (try llamaTok.tokenize(before)) + fimSuf + (try llamaTok.tokenize(after)) + fimMid
            let fimGreedy = try await greedy(runtime, tokens: fimTokens, maxNew: maxNew)
            // End-to-end: FIM-enabled engine (assembles FIM internally from context, truncates any
            // suffix overlap, and reranks by suffix-join likelihood) + reconcile. Print the top two
            // candidates so the rerank's ordering is visible.
            let fimRequest = CompletionRequest(
                context: TextFieldContext(
                    beforeCursor: before,
                    afterCursor: after,
                    geometry: TextFieldGeometry(isAtEndOfLine: false),
                    target: target,
                    detectedLanguage: "en"
                ),
                prompt: prodPrompt,
                mode: .prose,
                maxCompletionTokens: maxNew,
                maxDisplayWidth: 60
            )
            let fimCandidates = try await fimEngine.completions(for: fimRequest)
            let fimRanked = fimCandidates.prefix(2).map { candidate -> String in
                disp(CaretBoundary.reconcile(candidate.text, beforeCursor: before))
            }

            print("\nBEFORE: \(disp(before))   AFTER: \(disp(after))   (want ≈ \(disp(want)))")
            print("  (A) default policy → engine                : \(disp(prodEngine))")
            print("  (C) opt-in native FIM → greedy             : \(disp(fimGreedy))")
            print("  (C) opt-in native FIM → engine (top-2, reconciled): \(fimRanked.isEmpty ? "(suppressed)" : fimRanked.joined(separator: ", "))")
        }
        print("\n===============================================================\n")
    }

    /// Confirms the mid-word *ranking* defect is a tokenization-boundary artifact, and that token
    /// healing fixes it. For each mid-word prefix we print the engine's ranked candidates:
    ///   (A) current behaviour — full prefix ("…is gre"), no constraint. The prefix ends mid-token,
    ///       so the model continues from a subword state and "greasy" can outrank "great".
    ///   (C) healed — back up to the last token boundary ("…is") and constrain regeneration to the
    ///       removed bytes (" gre") via requiredPrefixBytes. The model now picks the natural
    ///       whole-word token " great". The displayed completion strips the already-typed heal text.
    func testMidWordHealingProbe() async throws {
        let (runtime, profile) = try load()
        let engine = makeEngine(runtime, profile)
        let cases = [
            "The weather is gre",
            "I will see you tom",
            "This is a necess",
            "Let's go to the be"
        ]
        print("\n================ mid-word token-healing probe ================")
        for before in cases {
            guard let (head, heal) = Self.healSplit(before) else { continue }
            let plain = try await engineCandidates(
                engine, prompt: productionPrompt(before: before, after: ""), before: before, prefix: []
            )
            let healed = try await engineCandidates(
                engine, prompt: productionPrompt(before: head, after: ""), before: head, prefix: Array(heal.utf8)
            )
            print("\nBEFORE: \(disp(before))   head=\(disp(head))  heal=\(disp(heal))")
            print("  (A) no heal : \(plain.map { disp($0.text) }.joined(separator: ", "))")
            print("  (C) healed  : \(healed.map { disp($0.text) }.joined(separator: ", "))")
            if let best = healed.first {
                let shown = best.text.hasPrefix(heal) ? String(best.text.dropFirst(heal.count)) : best.text
                print("      → shown after stripping heal: \(disp(shown))   field=\(disp(before + shown))")
            }
        }
        print("\n==============================================================\n")
    }

    /// Splits a mid-word prefix into the head (up to the last clean token boundary) and the heal
    /// text (the last whitespace + the partial word). `nil` when the prefix does not end mid-word.
    static func healSplit(_ before: String) -> (head: String, heal: String)? {
        guard let last = before.last, !last.isWhitespace else { return nil }
        var start = before.endIndex
        while start > before.startIndex {
            let p = before.index(before: start)
            if before[p].isWhitespace { break }
            start = p
        }
        if start > before.startIndex {
            let p = before.index(before: start)
            if before[p].isWhitespace { start = p } // fold the single separating space into the heal text
        }
        return (String(before[..<start]), String(before[start...]))
    }

    // MARK: - Helpers

    private func engineCandidates(
        _ engine: ConstrainedGenerationEngine,
        prompt: String,
        before: String,
        prefix: [UInt8]
    ) async throws -> [CompletionCandidate] {
        let request = CompletionRequest(
            context: TextFieldContext(beforeCursor: before, afterCursor: "", target: target, detectedLanguage: "en"),
            prompt: prompt,
            requiredPrefixBytes: prefix,
            mode: .prose,
            maxCompletionTokens: 6,
            maxDisplayWidth: 60
        )
        return try await engine.completions(for: request)
    }

    private func productionPrompt(before: String, after: String) -> String {
        let ctx = TextFieldContext(
            beforeCursor: before,
            afterCursor: after,
            target: target,
            detectedLanguage: "en"
        )
        return PromptBuilder().buildPrompt(context: ctx).prompt
    }

    private func engineTop(
        _ engine: ConstrainedGenerationEngine,
        prompt: String,
        before: String,
        after: String,
        maxNew: Int
    ) async throws -> String {
        let request = CompletionRequest(
            context: TextFieldContext(beforeCursor: before, afterCursor: after, target: target, detectedLanguage: "en"),
            prompt: prompt,
            mode: .prose,
            maxCompletionTokens: maxNew,
            maxDisplayWidth: 60
        )
        let candidates = try await engine.completions(for: request)
        return candidates.first?.text ?? "(none)"
    }

    /// Greedy (argmax) decode of up to `maxNew` tokens from a fully-specified token prompt,
    /// stopping on any end-of-generation token. Bypasses the constraint engine so we see the
    /// model's raw behavior for a given prompt *encoding* (the point of the probe).
    private func greedy(_ runtime: LlamaModelRuntime, tokens: [TokenID], maxNew: Int) async throws -> String {
        let introspector = runtime.makeIntrospector()
        try await runtime.prepare(promptTokens: tokens)
        var out: [TokenID] = []
        for _ in 0..<maxNew {
            let logits = try await runtime.logitsForNextToken()
            guard let best = logits.max(by: { $0.logit < $1.logit })?.tokenID else { break }
            if introspector.isEOG(best) { break }
            out.append(best)
            try await runtime.decodeNext(tokenID: best)
        }
        return try runtime.tokenizer.detokenize(out)
    }

    private func disp(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
