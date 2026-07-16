//
//  AppleIntelligenceCompletionEngine.swift
//  KeyType
//
//  Higher-level completion-engine seam plus the Apple Intelligence Foundation Models adapter.
//  Foundation Models returns generated text rather than tokenizer logits, so it belongs behind
//  `CompletionGenerating` and deliberately does not pretend to be a `LocalModelRuntime`.
//

import AutocompleteCore
import ConstrainedGeneration
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Lifecycle operations the app needs in addition to the shared `CompletionGenerating` contract.
/// The llama constrained decoder already implements all four methods; text-only providers can use
/// the conservative defaults for warmup, teardown, and correction validation.
protocol CompletionEngine: CompletionGenerating {
    nonisolated var supportsTokenHealing: Bool { get }
    nonisolated var maxPromptTokens: Int { get }
    nonisolated func warmUp(for request: CompletionRequest) async throws
    nonisolated func shutdown() async
    nonisolated func validateCorrectionCandidates(
        _ candidates: [CorrectionCandidate],
        prefixBeforeWord: String,
        suffixWindow: String,
        priorPredictionReplacement: String?,
        thresholds: CorrectionValidationThresholds
    ) async throws -> [CorrectionCandidate]
}

extension CompletionEngine {
    nonisolated var supportsTokenHealing: Bool { false }
    nonisolated var maxPromptTokens: Int { 600 }
    nonisolated func warmUp(for request: CompletionRequest) async throws {}
    nonisolated func shutdown() async {}

    /// Foundation Models does not expose the token logits used by KeyType's correction scorer.
    /// Preserve the system spell/grammar candidates unchanged instead of fabricating a score.
    nonisolated func validateCorrectionCandidates(
        _ candidates: [CorrectionCandidate],
        prefixBeforeWord: String,
        suffixWindow: String,
        priorPredictionReplacement: String?,
        thresholds: CorrectionValidationThresholds
    ) async throws -> [CorrectionCandidate] {
        candidates.filter { $0.source == .spellcheckOnly }
    }
}

extension ConstrainedGenerationEngine: CompletionEngine {
    nonisolated var supportsTokenHealing: Bool { true }
    nonisolated var maxPromptTokens: Int { 4_096 }
}

enum AppleIntelligenceModelAvailability: Equatable, LocalizedError, Sendable {
    case available
    case requiresMacOS26
    case frameworkUnavailable
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unsupportedLocale
    case unavailable

    nonisolated var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    nonisolated var message: String {
        switch self {
        case .available:
            return "Ready — completions stay on this Mac."
        case .requiresMacOS26:
            return "Requires macOS 26 or later."
        case .frameworkUnavailable:
            return "This build does not include Apple's Foundation Models framework."
        case .deviceNotEligible:
            return "Apple Intelligence requires an eligible Apple silicon Mac."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in System Settings to use this model."
        case .modelNotReady:
            return "Apple Intelligence is still downloading or preparing its on-device model."
        case .unsupportedLocale:
            return "Apple Intelligence does not support the current language or locale."
        case .unavailable:
            return "Apple Intelligence is currently unavailable."
        }
    }

    nonisolated var errorDescription: String? {
        "Siri AI (Apple Intelligence) is unavailable. \(message)"
    }
}

enum AppleIntelligenceModelSupport {
    nonisolated static var availability: AppleIntelligenceModelAvailability {
        guard #available(macOS 26.0, *) else { return .requiresMacOS26 }
#if canImport(FoundationModels)
        return availableModelStatus()
#else
        return .frameworkUnavailable
#endif
    }

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    nonisolated private static func availableModelStatus() -> AppleIntelligenceModelAvailability {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return model.supportsLocale() ? .available : .unsupportedLocale
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady):
            return .modelNotReady
        @unknown default:
            return .unavailable
        }
    }
#endif
}

/// A framework-independent engine whose responder is injectable. Production injects a fresh
/// `LanguageModelSession` per keystroke; tests inject a deterministic closure and need no real
/// Apple Intelligence model, hardware eligibility, or network access.
final class AppleIntelligenceCompletionEngine: CompletionEngine, @unchecked Sendable {
    /// A byte cap is deliberately stricter than the prompt builder's English-centric chars/token
    /// estimate. Even if every UTF-8 byte became its own token, the prompt plus system instructions
    /// and short response remain below Foundation Models' 4,096-token context window.
    nonisolated static let maxPromptUTF8Bytes = 2_600
    nonisolated static let boundaryMarkerTokenAllowance = 4

    typealias Responder = @Sendable (
        _ prompt: String,
        _ instructions: String,
        _ maximumResponseTokens: Int
    ) async throws -> String

    private nonisolated let respond: Responder

    nonisolated init(respond: @escaping Responder) {
        self.respond = respond
    }

    nonisolated static func make() throws -> AppleIntelligenceCompletionEngine {
        let availability = AppleIntelligenceModelSupport.availability
        guard availability.isAvailable else { throw availability }

#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return makeAvailableEngine()
        }
#endif
        throw AppleIntelligenceModelAvailability.frameworkUnavailable
    }

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    nonisolated private static func makeAvailableEngine() -> AppleIntelligenceCompletionEngine {
        let model = SystemLanguageModel.default
        return AppleIntelligenceCompletionEngine { prompt, instructions, maximumResponseTokens in
            // Sessions retain a transcript and reject overlapping calls. A fresh one-shot session
            // prevents cross-keystroke context leakage and lets rapid replacement tasks run safely.
            let session = LanguageModelSession(model: model, instructions: instructions)
            let options = GenerationOptions(
                sampling: .greedy,
                maximumResponseTokens: maximumResponseTokens
            )
            let response = try await session.respond(to: prompt, options: options)
            return response.content
        }
    }
#endif

    nonisolated func completions(for request: CompletionRequest) async throws -> [CompletionCandidate] {
        guard request.maxCompletionTokens > 0, request.maxDisplayWidth > 0 else { return [] }
        // The system API does not expose token-level confidence. KeyType's mid-line safety gate
        // therefore cannot evaluate these responses honestly, so suppress before spending latency.
        guard request.context.afterCursor.isEmpty else { return [] }
        try Task.checkCancellation()
        let raw = try await respond(
            Self.prompt(for: request),
            Self.instructions(for: request),
            request.maxCompletionTokens + Self.boundaryMarkerTokenAllowance
        )
        // A superseded keystroke must never paint a late system-model response.
        try Task.checkCancellation()
        guard let candidate = Self.candidate(from: raw, request: request) else { return [] }
        return [candidate]
    }

    nonisolated static func instructions(for request: CompletionRequest) -> String {
        [
            "Act as an inline autocomplete engine. Output one short continuation after <CURSOR>.",
            "The output must begin with exactly one boundary marker:",
            "S: means insert one space before the remaining output.",
            "J: means join the remaining output directly to the preceding text.",
            "Return the marker followed immediately by only new characters. Never repeat input text.",
            "Use J: when completing an unfinished word, identifier, or command fragment at the cursor.",
            "Examples: \"Please send<CURSOR>\" becomes \"S:the file\". \"See you tom<CURSOR>\" becomes \"J:orrow\".",
            "\"France is<CURSOR>\" becomes \"S:Paris\". \"let pri<CURSOR>\" becomes \"J:nt\".",
            "\"git che<CURSOR>\" becomes \"J:ckout\".",
            "The input mode is \(modeName(request.mode)).",
            "Return no explanation, label, quotation marks, or Markdown.",
            "Keep the continuation within \(request.maxDisplayWidth) characters and approximately \(request.maxCompletionTokens) tokens."
        ]
        .joined(separator: "\n")
    }

    nonisolated private static func modeName(_ mode: CompletionMode) -> String {
        switch mode {
        case .prose: return "prose"
        case .code: return "code"
        case .terminal: return "terminal"
        case .emoji: return "emoji"
        case .correction: return "correction"
        }
    }

    /// The existing prompt retains app metadata, personalization, and custom writing instructions.
    /// Repeat only the live tail at the end so the system model has an unambiguous final cursor and
    /// does not confuse KeyType's structured context with text that should be emitted.
    nonisolated static func prompt(for request: CompletionRequest) -> String {
        let liveTail = String(request.context.beforeCursor.suffix(512))
        let prompt = """
        \(request.prompt)

        ## Exact insertion target
        The final <CURSOR> below is the insertion point. Text before it is existing text and must not be repeated.
        \(liveTail)<CURSOR>
        """
        return suffixOfPrompt(prompt, withinUTF8ByteBudget: maxPromptUTF8Bytes)
    }

    nonisolated private static func suffixOfPrompt(
        _ prompt: String,
        withinUTF8ByteBudget budget: Int
    ) -> String {
        guard prompt.utf8.count > budget else { return prompt }
        var start = prompt.endIndex
        var remaining = budget
        while start > prompt.startIndex {
            let previous = prompt.index(before: start)
            let byteCount = prompt[previous..<start].utf8.count
            guard byteCount <= remaining else { break }
            remaining -= byteCount
            start = previous
        }
        return String(prompt[start...])
    }

    nonisolated static func candidate(
        from rawResponse: String,
        request: CompletionRequest
    ) -> CompletionCandidate? {
        // Foundation Models commonly normalizes leading whitespace in free-form string responses.
        // The explicit marker makes the insertion boundary unambiguous, after which it is removed.
        let marked = rawResponse.trimmingCharacters(in: .newlines)
        let insertsSpace: Bool
        let payload: Substring
        if marked.hasPrefix("S:") {
            insertsSpace = true
            payload = marked.dropFirst(2)
        } else if marked.hasPrefix("J:") {
            insertsSpace = false
            payload = marked.dropFirst(2)
        } else {
            return nil
        }
        guard let first = payload.first, !first.isWhitespace else { return nil }
        guard !payload.hasPrefix("```") && !payload.hasSuffix("```") else { return nil }

        var text = String(payload)
        if insertsSpace, request.context.beforeCursor.last?.isWhitespace != true {
            text.insert(" ", at: text.startIndex)
        }
        guard !text.isEmpty, text.count <= request.maxDisplayWidth else { return nil }
        if !request.requiredPrefixBytes.isEmpty {
            guard Array(text.utf8).starts(with: request.requiredPrefixBytes) else { return nil }
        }
        return CompletionCandidate(text: text, mode: request.mode)
    }
}
