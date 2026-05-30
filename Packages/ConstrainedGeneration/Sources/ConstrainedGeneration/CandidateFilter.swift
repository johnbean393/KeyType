import AppCompatibility
import AutocompleteCore
import Foundation

/// Synchronous dictionary lookup used by the output-stage typo net.
///
/// `CandidateFiltering.suppressionReason(...)` is synchronous, but `WordRecognizing` (ADR-015) is
/// `async` only because its `NSSpellChecker` backing is main-actor affine — the underlying spell
/// check is itself synchronous. When the filter already runs on the main actor the app can supply
/// a synchronous adapter. Implementations MUST be conservative and return `true` whenever unsure
/// (unknown language / no dictionary / proper nouns) so the net never suppresses a real word.
public protocol SynchronousWordRecognizing {
    func recognizes(_ word: String, language: String?) -> Bool
}

/// Output filter for the full `SuppressionReason` taxonomy (see `docs/01-architecture.md` — the
/// "[AutocompleteCore] output filters" stage). It is the last gate before a candidate is shown:
/// given a single `CompletionCandidate` and the originating `CompletionRequest`, it returns the
/// first reason the candidate must be suppressed, or `nil` to display it.
///
/// Most of these reasons are *also* enforced upstream during constrained decoding (the engine
/// drops over-width / invalid-UTF-8 / inadmissible-prefix branches, and the in-beam
/// `CurrentWordTypoGuard` removes misspellings before they are ranked). This filter re-checks them
/// as a cheap, deterministic, independently-testable safety net that also folds in the app/policy
/// gates and the "is this actually insertable" question, so the UI layer can stay dumb.
///
/// It lives in `ConstrainedGeneration` rather than a new package because it needs the
/// `AppCompatibility` policy table (for the app gates) and `AutocompleteCore` contract, both of
/// which this package already links — see ADR-016.
public final class DefaultCandidateFilter: CandidateFiltering {
    private let compatibilityStore: AppCompatibilityStore
    private let wordRecognizer: SynchronousWordRecognizing?

    public init(
        compatibilityStore: AppCompatibilityStore = AppCompatibilityStore(),
        wordRecognizer: SynchronousWordRecognizing? = nil
    ) {
        self.compatibilityStore = compatibilityStore
        self.wordRecognizer = wordRecognizer
    }

    public func suppressionReason(
        for candidate: CompletionCandidate,
        request: CompletionRequest
    ) -> SuppressionReason? {
        // 1. App / policy gates — cheap and decisive. A field where completion is off, mid-line is
        //    disallowed (and text follows the cursor), or Tab acceptance is disabled (the only way
        //    to accept) should show nothing at all.
        let policy = compatibilityStore.policy(for: request.context)
        if policy.excludesSecureField { return .secureFieldExcluded }
        if !policy.isCompletionEnabled { return .completionsDisabled }
        if !policy.allowsMidLineCompletion, !request.context.afterCursor.isEmpty {
            return .midLineCompletionDisabled
        }
        if !policy.allowsTabAcceptance { return .tabShortcutsDisabled }

        // 2. Nothing to show.
        if candidate.text.isEmpty { return .noCandidate }

        // 3. UTF-8 validity. A Swift `String` is already well-formed UTF-8, so the residual check
        //    is for the replacement scalar U+FFFD — the fingerprint of a lossy detokenisation that
        //    slipped through. (The decoder drops genuinely malformed byte sequences upstream.)
        if candidate.text.unicodeScalars.contains("\u{FFFD}") { return .invalidUTF8 }

        // 4. Required prefix. The candidate must be consistent with the bytes the request demands
        //    it begin with: it either extends the prefix or is a partial step toward it (mirrors
        //    the decoder's `tokenAllowed(_:afterRequiredPrefix:)` admissibility invariant).
        if !Self.satisfiesRequiredPrefix(Array(candidate.text.utf8), request.requiredPrefixBytes) {
            return .requiredPrefixNotSatisfied
        }

        // 5. Display width and token-length caps.
        if candidate.displayWidth > request.maxDisplayWidth { return .displayWidthExceeded }
        if candidate.tokenIDs.count > request.maxCompletionTokens {
            return .maxCompletionLengthExceeded
        }

        // 6. Insertion safety — whitespace-only or control-character-bearing text is not safely
        //    insertable as an inline completion.
        if !Self.isInsertionSafe(candidate.text) { return .insertionUnsafe }

        // 7. Final typo net (the in-beam guard of ADR-015 is the primary defence).
        if looksLikeCurrentWordTypo(candidate: candidate, request: request) {
            return .currentWordLooksLikeTypo
        }

        return nil
    }

    // MARK: - Required prefix

    /// `true` when `bytes` is consistent with `prefix`: either it begins with the whole prefix or
    /// it is itself a leading slice of the prefix.
    static func satisfiesRequiredPrefix(_ bytes: [UInt8], _ prefix: [UInt8]) -> Bool {
        if prefix.isEmpty { return true }
        return bytes.starts(with: prefix) || prefix.starts(with: bytes)
    }

    // MARK: - Insertion safety

    /// A candidate is unsafe to insert if it is empty / whitespace-only, carries any control
    /// character (C0 controls including tab and newline, or DEL), or has no alphanumeric content at
    /// all. The last rule drops noise-only suggestions (`"..."`, `"…"`, `"—"`) that are never a
    /// useful inline continuation; alphanumerics span every script, so CJK/Thai completions pass.
    static func isInsertionSafe(_ text: String) -> Bool {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        for scalar in text.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F { return false }
        }
        if text.rangeOfCharacter(from: .alphanumerics) == nil { return false }
        return true
    }

    // MARK: - Current-word typo net

    /// Synchronous mirror of `CurrentWordTypoGuard`'s judgement, applied to a finalised candidate:
    /// reconstruct the word the user is completing (typed stem + the candidate's leading word) and,
    /// if it has *closed* into a misspelling, suppress. Conservative by construction — same
    /// eligibility rules as the in-beam guard, and silent unless a recogniser is wired.
    private func looksLikeCurrentWordTypo(
        candidate: CompletionCandidate,
        request: CompletionRequest
    ) -> Bool {
        guard let wordRecognizer else { return false }
        guard request.mode == .prose || request.mode == .correction else { return false }

        let stem = CurrentWordTypoGuard.trailingWord(of: request.context.beforeCursor)
        guard !stem.isEmpty else { return false } // model started a fresh word — its own, leave it

        let lead = CurrentWordTypoGuard.leadingWord(of: candidate.text)
        guard !lead.isEmpty else { return false } // completion opened on a boundary — not our word
        guard lead.count < candidate.text.count else { return false } // word still open → never judge

        let word = stem + lead
        guard CurrentWordTypoGuard.isEligible(word) else { return false }

        let contextWords = CurrentWordTypoGuard.words(in: request.context.beforeCursor)
            .union(CurrentWordTypoGuard.words(in: request.context.afterCursor))
        if contextWords.contains(word.lowercased()) { return false } // already-used term, not a typo

        return !wordRecognizer.recognizes(word, language: request.context.detectedLanguage)
    }
}
