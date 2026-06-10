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

        // 6·: Reserved model-internal markers (Gemma `<unused56>`, chat/FIM scaffolding). These are
        //     masked at sample time once the profile is rebuilt (see TokenClassifier); this net is the
        //     belt-and-suspenders for stale profiles / cross-token concatenations / other models, with
        //     a distinct reason so telemetry can confirm the masking landed.
        if Self.containsReservedMarker(candidate.text) { return .reservedMarker }

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
        ) || SuffixOverlapGuard.duplicatesExactSuffixPrefix(
            completion: candidate.text,
            afterCursor: request.context.afterCursor
        ) {
            return .duplicatesAfterCursor
        }

        // The content-overlap nets below judge the text that will actually be inserted. When the
        // prompt was healed (ADR-019) the candidate re-emits the already-typed stem (" coll…"); strip
        // it so the comparison is against the genuinely-new continuation, not the stem the user typed.
        let insertedText = Self.healStripped(candidate.text, request: request)

        // 7b. Prefix-repetition net: the completion reproduces a phrase already in the recent
        //     preceding text, so accepting it would create a verbatim repetition loop.
        //     Typical failure: small model predicts "i want to write about" after "…AI meetup."
        //     because that exact phrase appeared earlier in the text. See PrefixRepetitionGuard.
        if PrefixRepetitionGuard.repeatsPrefix(
            completion: insertedText,
            beforeCursor: request.context.beforeCursor
        ) {
            return .repeatsRecentPrefix
        }

        // 7b'. Intra-completion repetition: the same word appears ≥ 3 times within the candidate
        //     itself ("text 1 1 1", "since 1 1 1") — model degeneration unrelated to side context.
        //     Distinct from the prefix-repetition loop above (which checks against already-typed text).
        if IntraCompletionRepetitionGuard.isDegenerate(insertedText) {
            return .intraCompletionRepetition
        }

        // 7b''. Markup-tag net: the candidate is nothing but HTML tags in a prose context with no
        //     markup in the surrounding text — Gemma's single-token tag block (`</code>` = 215)
        //     surfacing in ordinary writing. Sample-time demotion (`BiasPolicy.markupTagStaticPenalty`)
        //     is the primary defence; this context-aware net covers stale profiles and beam paths.
        //     Code/terminal modes are untouched, and a field already containing markup is exempt.
        if request.mode == .prose || request.mode == .correction,
           MarkupTagGuard.violates(
               completion: insertedText,
               beforeCursor: request.context.beforeCursor,
               afterCursor: request.context.afterCursor
           ) {
            return .markupTagOutsideMarkupContext
        }

        // 7c. Context-echo net: the completion verbatim-reproduces injected side context the user did
        //     not type (clipboard / on-screen OCR). The small model parrots such context instead of
        //     using it as background — e.g. text copied from one app surfacing in another's compose
        //     field. Writing-history samples are excluded upstream (see `CompletionRequest`).
        if ContextEchoGuard.echoesInjectedContext(
            completion: insertedText,
            injectedContext: request.injectedContext
        ) {
            return .echoesInjectedContext
        }

        // 8. Mid-line confidence net. Native FIM is useful only when it is both short and highly
        //    likely; longer middle spans have been low-precision in edge data. Keep this deliberately
        //    conservative so re-enabled mid-line favors suppression over wrong visible text.
        if Self.hasLowConfidenceMidLineCandidate(candidate, request: request) {
            return .lowConfidenceMidLine
        }

        // 9. Final typo net (the in-beam guard of ADR-015 is the primary defence).
        if looksLikeCurrentWordTypo(candidate: candidate, request: request) {
            return .currentWordLooksLikeTypo
        }

        // 10. Dead-end mid-word net: the word is still *open* on a stem that can't begin any
        //    dictionary word, so it could never resolve to a real word (e.g. a lone "x" after
        //    "th"). Catches the small-model failure of completing mid-word with a useless single
        //    letter. See ADR-052.
        if currentWordIsDeadEnd(candidate: candidate, request: request) {
            return .currentWordHasNoValidCompletion
        }

        return nil
    }

    private static let maxVisibleMidLineTokenCount = 2
    private static let minimumMidLineMeanLogProbability = -0.5

    static func hasLowConfidenceMidLineCandidate(
        _ candidate: CompletionCandidate,
        request: CompletionRequest
    ) -> Bool {
        guard !request.context.afterCursor.isEmpty else { return false }
        guard !candidate.tokenIDs.isEmpty else { return true }
        guard candidate.tokenIDs.count <= maxVisibleMidLineTokenCount else { return true }
        let meanLogProbability = candidate.logProbability / Double(candidate.tokenIDs.count)
        return meanLogProbability < minimumMidLineMeanLogProbability
    }

    // MARK: - Heal-aware text

    /// The text that will actually be inserted: for a healed request (ADR-019) the candidate re-emits
    /// the already-typed stem, so strip it back off; otherwise the candidate text is inserted as-is.
    static func healStripped(_ text: String, request: CompletionRequest) -> String {
        guard !request.requiredPrefixBytes.isEmpty else { return text }
        return MidWordHealing.strip(text, heal: String(decoding: request.requiredPrefixBytes, as: UTF8.self))
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
    /// all. The alphanumeric rule drops noise-only suggestions (`"..."`, `"…"`, `"—"`); alphanumerics
    /// span every script, so CJK/Thai pass. (Reserved markers get their own gate — see `suppressionReason`.)
    static func isInsertionSafe(_ text: String) -> Bool {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        for scalar in text.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F { return false }
        }
        if text.rangeOfCharacter(from: .alphanumerics) == nil { return false }
        return true
    }

    /// Regexes for model-internal markers that must never appear in a shown completion: reserved
    /// placeholders (`<unused56>`, `<reserved_…>`, `<extra_id_…>`, `<pad>`, `<mask>`) and chat /
    /// FIM scaffolding (`<|…|>`, `<start_of_turn>`, …). Matched as substrings since a candidate may
    /// embed one mid-text. Kept narrow so ordinary `<tag>` text the user types is unaffected.
    private static let reservedMarkerRegexes: [NSRegularExpression] = {
        let patterns = [
            #"<unused\d+>"#,
            #"<reserved[_ ]?\d+>"#,
            #"<extra_id_\d+>"#,
            #"<pad>"#, #"<mask>"#,
            #"<\|[^|>]+\|>"#,
            #"<start_of_turn>"#, #"<end_of_turn>"#
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    static func containsReservedMarker(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for regex in reservedMarkerRegexes where regex.firstMatch(in: text, options: [], range: range) != nil {
            return true
        }
        return false
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
        let judged = Self.healStripped(candidate.text, request: request)

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

        let judged = Self.healStripped(candidate.text, request: request)

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
