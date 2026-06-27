import AutocompleteCore
import Foundation
import ModelRuntime

public struct CorrectionValidationThresholds: Equatable, Sendable {
    public var minimumMeanLogProbability: Double
    public var minimumMargin: Double
    public var minimumSuffixMeanLogProbability: Double
    public var priorPredictionConfidence: Double

    public init(
        minimumMeanLogProbability: Double = -6.0,
        minimumMargin: Double = 0.20,
        minimumSuffixMeanLogProbability: Double = -7.0,
        priorPredictionConfidence: Double = 0.97
    ) {
        self.minimumMeanLogProbability = minimumMeanLogProbability
        self.minimumMargin = minimumMargin
        self.minimumSuffixMeanLogProbability = minimumSuffixMeanLogProbability
        self.priorPredictionConfidence = priorPredictionConfidence
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

        let prefixTokens = try runtime.tokenizer.tokenize(prefixBeforeWord)
        let original = candidates.first?.original ?? ""
        let originalScore = try await meanLogProbability(
            of: original,
            anchor: prefixTokens
        )

        var scored: [(candidate: CorrectionCandidate, score: Double, suffixScore: Double?)] = []
        for candidate in candidates {
            try Task.checkCancellation()
            let score = try await meanLogProbability(of: candidate.replacement, anchor: prefixTokens)
            let suffixScore = suffixWindow.isEmpty
                ? nil
                : try await meanLogProbability(
                    of: suffixWindow,
                    anchor: prefixTokens + runtime.tokenizer.tokenize(candidate.replacement)
                )
            scored.append((candidate, score, suffixScore))
        }

        let rankedScores = scored.map(\.score).sorted(by: >)
        let runnerUp = rankedScores.dropFirst().first

        return scored.compactMap { entry in
            let margin = runnerUp.map { entry.score - $0 } ?? .infinity
            let originalIsMuchBetter = originalScore > entry.score + max(1.0, thresholds.minimumMargin * 2)
            let suffixPass = entry.suffixScore.map { $0 >= thresholds.minimumSuffixMeanLogProbability } ?? true
            let passesValidation: Bool
            if entry.candidate.source == .systemGrammarOnly {
                passesValidation = entry.score.isFinite
                    && !originalIsMuchBetter
                    && suffixPass
            } else {
                passesValidation = entry.score >= thresholds.minimumMeanLogProbability
                    && margin >= thresholds.minimumMargin
                    && !originalIsMuchBetter
                    && suffixPass
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

    private func meanLogProbability(of text: String, anchor: [TokenID]) async throws -> Double {
        let tokens = try runtime.tokenizer.tokenize(text)
        guard !tokens.isEmpty else { return -.infinity }

        var suffix: [TokenID] = []
        var total = 0.0
        for token in tokens {
            try Task.checkCancellation()
            let logits = try await runtime.anchoredLogits(anchor: anchor, suffix: suffix)
            guard let logProbability = Self.logProbability(of: token, in: logits) else {
                return -.infinity
            }
            total += logProbability
            suffix.append(token)
        }
        return total / Double(tokens.count)
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
