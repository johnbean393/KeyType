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

        let prefixTokens = try runtime.tokenizer.tokenizePrompt(prefixBeforeWord)
        let original = candidates.first?.original ?? ""
        let replacementTokens = try ([original] + candidates.map(\.replacement)).map {
            try runtime.tokenizer.tokenize($0)
        }
        let replacementScores = try await meanLogProbabilities(
            tokenSequences: replacementTokens,
            anchors: Array(repeating: prefixTokens, count: replacementTokens.count)
        )
        let originalScore = replacementScores[0]

        let suffixScores: [Double?]
        if suffixWindow.isEmpty {
            suffixScores = Array(repeating: nil, count: candidates.count)
        } else {
            let suffixTokens = try runtime.tokenizer.tokenize(suffixWindow)
            let candidateTokens = Array(replacementTokens.dropFirst())
            let scores = try await meanLogProbabilities(
                tokenSequences: Array(repeating: suffixTokens, count: candidates.count),
                anchors: candidateTokens.map { prefixTokens + $0 }
            )
            suffixScores = scores.map(Optional.some)
        }

        var scored: [(candidate: CorrectionCandidate, score: Double, suffixScore: Double?)] = []
        for (index, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            scored.append((candidate, replacementScores[index + 1], suffixScores[index]))
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

    /// Score multiple target token sequences together, grouping every active path at the same
    /// target depth into one runtime frontier call. Anchors may differ (suffix-join validation), so
    /// their common prefix becomes the resident anchor and each remaining tail becomes a suffix.
    /// This is semantically the same autoregressive log-probability calculation as serial scoring.
    private func meanLogProbabilities(
        tokenSequences: [[TokenID]],
        anchors: [[TokenID]]
    ) async throws -> [Double] {
        guard tokenSequences.count == anchors.count else {
            return Array(repeating: -.infinity, count: tokenSequences.count)
        }
        guard !tokenSequences.isEmpty else { return [] }

        let sharedAnchor = Self.commonTokenPrefix(anchors)
        let anchorTails = anchors.map { Array($0.dropFirst(sharedAnchor.count)) }
        var totals = Array(repeating: 0.0, count: tokenSequences.count)
        var valid = tokenSequences.map { !$0.isEmpty }
        let maxDepth = tokenSequences.map(\.count).max() ?? 0

        for depth in 0..<maxDepth {
            try Task.checkCancellation()
            let active = tokenSequences.indices.filter {
                valid[$0] && depth < tokenSequences[$0].count
            }
            guard !active.isEmpty else { break }

            let suffixes = active.map { index in
                anchorTails[index] + Array(tokenSequences[index].prefix(depth))
            }
            let frontier = try await runtime.anchoredLogitsBatch(
                anchor: sharedAnchor,
                suffixes: suffixes
            )
            guard frontier.count == active.count else {
                for index in active { valid[index] = false }
                continue
            }

            for (index, logits) in zip(active, frontier) {
                guard let logProbability = Self.logProbability(
                    of: tokenSequences[index][depth],
                    in: logits
                ) else {
                    valid[index] = false
                    continue
                }
                totals[index] += logProbability
            }
        }

        return tokenSequences.indices.map { index in
            guard valid[index], !tokenSequences[index].isEmpty else { return -.infinity }
            return totals[index] / Double(tokenSequences[index].count)
        }
    }

    private static func commonTokenPrefix(_ sequences: [[TokenID]]) -> [TokenID] {
        guard var prefix = sequences.first else { return [] }
        for sequence in sequences.dropFirst() {
            let count = min(prefix.count, sequence.count)
            var index = 0
            while index < count, prefix[index] == sequence[index] {
                index += 1
            }
            if index < prefix.count {
                prefix.removeSubrange(index..<prefix.count)
            }
            if prefix.isEmpty { break }
        }
        return prefix
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
