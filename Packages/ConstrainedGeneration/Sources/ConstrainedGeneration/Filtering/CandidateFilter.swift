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

    /// `false` only when `prefix` cannot begin **any** word in the dictionary for `language` — used
    /// to drop a mid-word completion left open on a dead-end stem (`"th"` → `"x"` → `"thx"`). MUST be
    /// conservative: return `true` whenever unsure (no dictionary, unknown language, empty prefix, off
    /// the main thread) so a legitimate in-progress word is never suppressed. A default returns `true`
    /// so existing recognisers keep the gate inert until they opt in.
    func canCompleteWord(prefix: String, language: String?) -> Bool
}

public extension SynchronousWordRecognizing {
    func canCompleteWord(prefix: String, language: String?) -> Bool { true }
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

        // 6a. CJK script net: once the live caret is inside CJK text, a Latin-leading continuation
        //     is almost always pinyin/romanization leakage from the base model or IME composition.
        //     Suppress it rather than showing visibly wrong ghost text.
        if Self.hasCJKScriptMismatch(candidate.text, request: request) {
            return .scriptMismatch
        }

        // 6b. Mid-word charset net (the in-beam `MidWordCharsetGuard` is the primary defence): a
        //     prose completion that closes the typed word with a garbage symbol ("gre"→"at$") or
        //     piles up punctuation ("....") is corruption, not insertable text. See ADR-052.
        if MidWordCharsetGuard.violates(completion: candidate.text, request: request) {
            return .insertionUnsafe
        }
        if MidWordBoundaryGuard.violates(completion: candidate.text, request: request) {
            return .insertionUnsafe
        }

        // 7. Suffix-duplication net (the engine drops these too; this is the documented last gate).
        //    A mid-line / FIM completion that just reproduces the text already after the caret would
        //    duplicate the user's own words on accept — suppress it. See ADR-049.
        if SuffixOverlapGuard.duplicatesSuffix(
            completion: candidate.text,
            beforeCursor: request.context.beforeCursor,
            afterCursor: request.context.afterCursor
        ) {
            return .duplicatesAfterCursor
        }

        // 8. Final typo net (the in-beam guard of ADR-015 is the primary defence).
        if looksLikeCurrentWordTypo(candidate: candidate, request: request) {
            return .currentWordLooksLikeTypo
        }

        // 9. Dead-end mid-word net: the word is still *open* on a stem that can't begin any
        //    dictionary word, so it could never resolve to a real word (e.g. a lone "x" after
        //    "th"). Catches the small-model failure of completing mid-word with a useless single
        //    letter. See ADR-052.
        if currentWordIsDeadEnd(candidate: candidate, request: request) {
            return .currentWordHasNoValidCompletion
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

    static func hasCJKScriptMismatch(_ text: String, request: CompletionRequest) -> Bool {
        guard request.mode == .prose || request.mode == .correction else { return false }
        guard let last = request.context.beforeCursor.last, !last.isWhitespace else { return false }
        guard TextScriptProfile.lastSubstantiveScript(in: request.context.beforeCursor) == .cjk else {
            return false
        }
        return TextScriptProfile.firstSubstantiveScript(in: text) == .latin
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

        // For a healed request (ADR-019) the candidate re-emits the typed stem (`" coll…"`); strip it
        // so the leading word is the genuinely-new continuation rather than an empty leading-space run
        // — otherwise healed mid-word completions slip past the net entirely (ADR-025 follow-up).
        let judged = request.requiredPrefixBytes.isEmpty
            ? candidate.text
            : MidWordHealing.strip(candidate.text, heal: String(decoding: request.requiredPrefixBytes, as: UTF8.self))

        let lead = CurrentWordTypoGuard.leadingWord(of: judged)
        guard !lead.isEmpty else { return false } // completion opened on a boundary — not our word
        guard lead.count < judged.count else { return false } // word still open → never judge

        let word = stem + lead
        guard CurrentWordTypoGuard.isEligible(word) else { return false }

        let contextWords = CurrentWordTypoGuard.words(in: request.context.beforeCursor)
            .union(CurrentWordTypoGuard.words(in: request.context.afterCursor))
        if contextWords.contains(word.lowercased()) { return false } // already-used term, not a typo

        return !wordRecognizer.recognizes(word, language: request.context.detectedLanguage)
    }

    // MARK: - Dead-end mid-word net

    /// `true` when the candidate leaves the user's current word *open* on a stem that cannot begin
    /// any dictionary word — the mirror of `looksLikeCurrentWordTypo` for the still-open case (which
    /// the typo net deliberately never judges). Same conservative eligibility, the same heal-aware
    /// reconstruction, and the same already-used-term exemption; silent unless a recogniser is wired.
    private func currentWordIsDeadEnd(
        candidate: CompletionCandidate,
        request: CompletionRequest
    ) -> Bool {
        guard let wordRecognizer else { return false }
        guard request.mode == .prose || request.mode == .correction else { return false }

        let stem = CurrentWordTypoGuard.trailingWord(of: request.context.beforeCursor)
        guard !stem.isEmpty else { return false } // model started a fresh word — leave it

        let judged = request.requiredPrefixBytes.isEmpty
            ? candidate.text
            : MidWordHealing.strip(candidate.text, heal: String(decoding: request.requiredPrefixBytes, as: UTF8.self))

        let lead = CurrentWordTypoGuard.leadingWord(of: judged)
        guard !lead.isEmpty else { return false } // completion opened on a boundary — not our word
        guard lead.count == judged.count else { return false } // word already closed → typo net's job

        let word = stem + lead
        guard CurrentWordTypoGuard.isEligible(word) else { return false }

        let contextWords = CurrentWordTypoGuard.words(in: request.context.beforeCursor)
            .union(CurrentWordTypoGuard.words(in: request.context.afterCursor))
        if contextWords.contains(word.lowercased()) { return false } // already-used term, keep

        return !wordRecognizer.canCompleteWord(prefix: word, language: request.context.detectedLanguage)
    }
}
