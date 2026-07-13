import AutocompleteCore
import Foundation
import ModelRuntime

/// All word-vs-word comparisons are in **joint (summed) log-probability** — the log of the actual
/// probability of the text (ADR-120). The previous per-token *mean* systematically favoured
/// multi-token strings (their trailing pieces are near-deterministic), to the point of ranking a
/// misspelling above its correction: measured on the live model, " definitely" (1 token) scored
/// mean −8.09 vs " definately" (2 tokens) mean −6.56, while the joint scores are −8.09 vs −13.12
/// — the correction wins by 5 nats once the maths stops lying.
public struct CorrectionValidationThresholds: Equatable, Sendable {
    /// A replacement must beat the *original* — what the user actually typed — by at least this
    /// many nats of joint log-probability. 0 means "the model must not prefer the original at
    /// all": deliberate spellings, slang, and proper nouns the model knows keep their veto, and
    /// this single gate replaces both the old absolute floor (which asked the wrong question —
    /// "is this word a likely continuation?" — and suppressed valid corrections like an adverb
    /// after "I") and the old original-is-much-better check. Dictionary flagging already
    /// guarantees the replacement is a real word.
    public var minimumAdvantageOverOriginal: Double
    /// Runner-up separation (joint nats) for ordinary candidates.
    public var minimumMargin: Double
    public var minimumSuffixMeanLogProbability: Double
    public var priorPredictionConfidence: Double
    /// Relaxed runner-up separation for *clear-cut* spellcheck corrections (dictionary-flagged
    /// word, edit distance ≤ `clearCutMaximumEditDistance`, model-top guess). Common typos
    /// attract look-alike checker guesses that compress the margin (definately → definitely vs
    /// defiantly measured at 5.97 joint nats, but mean-scale margins sat at 0.15); genuinely
    /// ambiguous near-ties stay suppressed, and the advantage-over-original gate is never
    /// relaxed. See ADR-119/120.
    public var clearCutMargin: Double
    public var clearCutMaximumEditDistance: Int

    public init(
        minimumAdvantageOverOriginal: Double = 0.0,
        minimumMargin: Double = 2.0,
        minimumSuffixMeanLogProbability: Double = -7.0,
        priorPredictionConfidence: Double = 0.97,
        clearCutMargin: Double = 0.5,
        clearCutMaximumEditDistance: Int = 2
    ) {
        self.minimumAdvantageOverOriginal = minimumAdvantageOverOriginal
        self.minimumMargin = minimumMargin
        self.minimumSuffixMeanLogProbability = minimumSuffixMeanLogProbability
        self.priorPredictionConfidence = priorPredictionConfidence
        self.clearCutMargin = clearCutMargin
        self.clearCutMaximumEditDistance = clearCutMaximumEditDistance
    }
}

public final class CorrectionValidationScorer {
    private let runtime: LocalModelRuntime
    private let thresholds: CorrectionValidationThresholds

    public init(
        runtime: LocalModelRuntime,
        thresholds: CorrectionValidationThresholds = CorrectionValidationThresholds()
    ) {
        self.runtime = runtime
        self.thresholds = thresholds
    }

    public func validate(
        candidates: [CorrectionCandidate],
        prefixBeforeWord: String,
        suffixWindow: String = "",
        priorPredictionReplacement: String? = nil
    ) async throws -> [CorrectionCandidate] {
        guard !candidates.isEmpty else { return [] }

        if let priorPredictionReplacement,
           let prior = candidates.first(where: {
               $0.replacement.caseInsensitiveCompare(priorPredictionReplacement) == .orderedSame
           }) {
            var candidate = prior
            candidate.source = .priorPrediction
            candidate.confidence = max(candidate.confidence, thresholds.priorPredictionConfidence)
            candidate.validation = CorrectionValidation(
                method: .priorPrediction,
                absoluteScore: nil,
                margin: nil,
                suffixJoinScore: nil,
                boostedByPriorPrediction: true
            )
            return [candidate]
        }

        // Score across the word boundary the way the model actually tokenizes it (ADR-120, the
        // correction-lane analogue of ADR-017's caret-boundary sanitization): an anchor ending in
        // whitespace forces the word to tokenize standalone, a split BPE models essentially never
        // produce after a space token, which floors every candidate's mean log-probability. Trim
        // the trailing whitespace off the anchor and carry it as the words' leading separator so
        // "I " + "definitely" is scored as "I" + " definitely" (one space-prefixed token).
        let boundary = Self.splitTrailingWhitespace(of: prefixBeforeWord)
        let prefixTokens = try runtime.tokenizer.tokenize(boundary.head)
        let original = candidates.first?.original ?? ""
        let originalScore = try await jointLogProbability(
            of: boundary.separator + original,
            anchor: prefixTokens
        )

        var scored: [(candidate: CorrectionCandidate, score: Double, suffixScore: Double?)] = []
        for candidate in candidates {
            try Task.checkCancellation()
            let score = try await jointLogProbability(
                of: boundary.separator + candidate.replacement,
                anchor: prefixTokens
            )
            // Whitespace-only windows carry no join signal (defensive twin of the controller's
            // producer-side check — probing a bare space token is tokenization noise, ADR-120).
            let suffixScore = suffixWindow.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : try await meanLogProbability(
                    of: suffixWindow,
                    anchor: prefixTokens + runtime.tokenizer.tokenize(boundary.separator + candidate.replacement)
                )
            scored.append((candidate, score, suffixScore))
        }

        let rankedScores = scored.map(\.score).sorted(by: >)
        let runnerUp = rankedScores.dropFirst().first

        return scored.compactMap { entry in
            let margin = runnerUp.map { entry.score - $0 } ?? .infinity
            let advantage = entry.score - originalScore
            let suffixPass = entry.suffixScore.map { $0 >= thresholds.minimumSuffixMeanLogProbability } ?? true
            let passesValidation: Bool
            if entry.candidate.source == .systemGrammarOnly {
                // Grammar edits rewrite phrases the checker already vetted; the model only vetoes
                // when it clearly prefers the user's phrasing (more than the standard margin).
                passesValidation = entry.score.isFinite
                    && advantage >= -thresholds.minimumMargin
                    && suffixPass
            } else {
                passesValidation = Self.spellcheckValidationPasses(
                    advantage: advantage,
                    margin: margin,
                    suffixPass: suffixPass,
                    isClearCut: entry.candidate.source == .spellcheckOnly
                        && Self.boundedEditDistance(
                            entry.candidate.original.lowercased(),
                            entry.candidate.replacement.lowercased(),
                            cap: thresholds.clearCutMaximumEditDistance
                        ) != nil,
                    thresholds: thresholds
                )
            }

            guard passesValidation else {
                return nil
            }

            var candidate = entry.candidate
            switch candidate.source {
            case .systemGrammarOnly:
                candidate.source = .systemGrammarValidatedByModel
            case .spellcheckThenSystemGrammar:
                candidate.source = .spellcheckThenSystemGrammar
            default:
                candidate.source = .spellcheckValidatedByModel
            }
            candidate.confidence = min(0.96, max(candidate.confidence, 0.5 + min(0.45, margin / 3.0)))
            candidate.validation = CorrectionValidation(
                method: .modelScore,
                absoluteScore: entry.score,
                margin: margin.isFinite ? margin : nil,
                suffixJoinScore: entry.suffixScore,
                boostedByPriorPrediction: false
            )
            return candidate
        }
        .sorted {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            return $0.replacement < $1.replacement
        }
    }

    /// The pass/fail decision for a model-validated spellcheck candidate, extracted pure so tests
    /// can assert real logged cases without a model. All quantities are joint log-probability
    /// nats (ADR-120).
    ///
    /// `advantage` (replacement − original) is the primary gate: the correction must be at least
    /// as plausible as what the user actually typed, which both admits valid-but-unlikely
    /// continuations (an adverb after "I") and vetoes deliberate spellings the model knows. A
    /// clear-cut candidate (dictionary-flagged + edit distance within the cap) only needs to beat
    /// the runner-up by `clearCutMargin` — dominance, not the full separation bar — because
    /// common typos systematically attract look-alike checker guesses.
    static func spellcheckValidationPasses(
        advantage: Double,
        margin: Double,
        suffixPass: Bool,
        isClearCut: Bool,
        thresholds: CorrectionValidationThresholds
    ) -> Bool {
        let requiredMargin = isClearCut ? thresholds.clearCutMargin : thresholds.minimumMargin
        return advantage >= thresholds.minimumAdvantageOverOriginal
            && margin >= requiredMargin
            && suffixPass
    }

    /// Splits `text` into everything before its trailing whitespace run and that run itself,
    /// so the whitespace can lead the scored word instead of dangling off the anchor (ADR-120).
    static func splitTrailingWhitespace(of text: String) -> (head: String, separator: String) {
        var head = Substring(text)
        var separator = ""
        while let last = head.last, last.isWhitespace {
            separator = String(last) + separator
            head = head.dropLast()
        }
        return (String(head), separator)
    }

    /// Levenshtein distance capped at `cap`: returns the distance when ≤ cap, else `nil`.
    /// Early-outs on length difference and abandons rows whose minimum already exceeds the cap,
    /// so pathological inputs stay cheap.
    static func boundedEditDistance(_ a: String, _ b: String, cap: Int) -> Int? {
        let s = Array(a), t = Array(b)
        if abs(s.count - t.count) > cap { return nil }
        if s.isEmpty { return t.count <= cap ? t.count : nil }
        if t.isEmpty { return s.count <= cap ? s.count : nil }

        var previous = Array(0...t.count)
        var current = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            current[0] = i
            var rowMinimum = i
            for j in 1...t.count {
                let substitution = previous[j - 1] + (s[i - 1] == t[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
                rowMinimum = min(rowMinimum, current[j])
            }
            if rowMinimum > cap { return nil }
            swap(&previous, &current)
        }
        return previous[t.count] <= cap ? previous[t.count] : nil
    }

    /// Joint log-probability of `text` after `anchor` — the log of the actual probability of the
    /// string, used for all word-vs-word comparisons (ADR-120).
    private func jointLogProbability(of text: String, anchor: [TokenID]) async throws -> Double {
        try await totalLogProbability(of: text, anchor: anchor).total
    }

    /// Per-token mean, kept for the suffix-join probe where the window text is identical across
    /// candidates (so length normalisation can't distort a comparison) and the existing
    /// `minimumSuffixMeanLogProbability` calibration still applies.
    private func meanLogProbability(of text: String, anchor: [TokenID]) async throws -> Double {
        let (total, count) = try await totalLogProbability(of: text, anchor: anchor)
        guard count > 0, total.isFinite else { return total }
        return total / Double(count)
    }

    private func totalLogProbability(of text: String, anchor: [TokenID]) async throws -> (total: Double, count: Int) {
        let tokens = try runtime.tokenizer.tokenize(text)
        guard !tokens.isEmpty else { return (-.infinity, 0) }

        var suffix: [TokenID] = []
        var total = 0.0
        for token in tokens {
            try Task.checkCancellation()
            let logits = try await runtime.anchoredLogits(anchor: anchor, suffix: suffix)
            guard let logProbability = Self.logProbability(of: token, in: logits) else {
                return (-.infinity, tokens.count)
            }
            total += logProbability
            suffix.append(token)
        }
        return (total, tokens.count)
    }

    private static func logProbability(of token: TokenID, in logits: [TokenLogit]) -> Double? {
        guard !logits.isEmpty else { return nil }
        var maxLogit = -Float.infinity
        var targetLogit: Float?
        for entry in logits {
            maxLogit = max(maxLogit, entry.logit)
            if entry.tokenID == token {
                targetLogit = entry.logit
            }
        }
        guard let targetLogit else { return nil }
        var sumExp: Float = 0
        for entry in logits {
            sumExp += expf(entry.logit - maxLogit)
        }
        guard sumExp > 0 else { return nil }
        return Double(targetLogit - maxLogit - logf(sumExp))
    }
}
