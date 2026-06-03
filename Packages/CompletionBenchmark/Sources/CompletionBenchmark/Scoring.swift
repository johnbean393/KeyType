import Foundation

public struct BenchmarkRowScore: Equatable {
    public var outcome: BenchmarkCompletionOutcome
    public var contribution: Double

    public init(outcome: BenchmarkCompletionOutcome, contribution: Double) {
        self.outcome = outcome
        self.contribution = contribution
    }
}

public enum BenchmarkScorer {
    public static func score(
        expected: BenchmarkExpected,
        shownText: String?,
        suppressionReason: String?
    ) -> BenchmarkRowScore {
        switch expected.kind {
        case .insert:
            if let shownText {
                return isAcceptable(shownText, expected: expected)
                    ? BenchmarkRowScore(outcome: .correctInsert, contribution: 1.0)
                    : BenchmarkRowScore(outcome: .wrongShown, contribution: -2.0)
            }
            return BenchmarkRowScore(outcome: .acceptableSuppressionOnPositive, contribution: 0.3)
        case .suppress:
            if shownText != nil {
                return BenchmarkRowScore(outcome: .wrongShown, contribution: -2.0)
            }
            if expected.allowedReasons.isEmpty {
                return BenchmarkRowScore(outcome: .correctSuppression, contribution: 1.0)
            }
            if let suppressionReason, expected.allowedReasons.contains(suppressionReason) {
                return BenchmarkRowScore(outcome: .correctSuppression, contribution: 1.0)
            }
            return BenchmarkRowScore(outcome: .incorrectSuppression, contribution: 0.0)
        }
    }

    private static func isAcceptable(_ shownText: String, expected: BenchmarkExpected) -> Bool {
        let shown = canonical(shownText)
        return expected.acceptableShownTexts.contains { acceptable in
            let target = canonical(acceptable)
            return shown == target || (!target.isEmpty && shown.hasPrefix(target))
        }
    }

    private static func canonical(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}

public struct AggregateBenchmarkResult: Codable, Equatable {
    public var schemaVersion: Int
    public var suite: BenchmarkSuite
    public var modelIdentifier: String
    public var modelFilename: String
    public var modelFamily: String?
    public var quantization: String?
    public var rowCount: Int
    public var positiveCount: Int
    public var negativeCount: Int
    public var shownCount: Int
    public var correctInsertCount: Int
    public var correctSuppressionCount: Int
    public var wrongShownCount: Int
    public var positiveSuppressionCount: Int
    public var precisionWhenShown: Double
    public var positiveCoverage: Double
    public var wrongShowRate: Double
    public var suppressionAccuracy: Double
    public var qualityScore: Double
    public var qualityScoreTotal: Double
    public var p50GenerationMs: Double
    public var p95GenerationMs: Double
    public var p50TotalMs: Double
    public var p95TotalMs: Double
    public var suppressionReasonHistogram: [String: Int]
    public var byTag: [String: AggregateBreakdown]

    public init(
        schemaVersion: Int = 1,
        suite: BenchmarkSuite,
        modelIdentifier: String,
        modelFilename: String,
        modelFamily: String?,
        quantization: String?,
        rowCount: Int,
        positiveCount: Int,
        negativeCount: Int,
        shownCount: Int,
        correctInsertCount: Int,
        correctSuppressionCount: Int,
        wrongShownCount: Int,
        positiveSuppressionCount: Int,
        precisionWhenShown: Double,
        positiveCoverage: Double,
        wrongShowRate: Double,
        suppressionAccuracy: Double,
        qualityScore: Double,
        qualityScoreTotal: Double,
        p50GenerationMs: Double,
        p95GenerationMs: Double,
        p50TotalMs: Double,
        p95TotalMs: Double,
        suppressionReasonHistogram: [String: Int],
        byTag: [String: AggregateBreakdown]
    ) {
        self.schemaVersion = schemaVersion
        self.suite = suite
        self.modelIdentifier = modelIdentifier
        self.modelFilename = modelFilename
        self.modelFamily = modelFamily
        self.quantization = quantization
        self.rowCount = rowCount
        self.positiveCount = positiveCount
        self.negativeCount = negativeCount
        self.shownCount = shownCount
        self.correctInsertCount = correctInsertCount
        self.correctSuppressionCount = correctSuppressionCount
        self.wrongShownCount = wrongShownCount
        self.positiveSuppressionCount = positiveSuppressionCount
        self.precisionWhenShown = precisionWhenShown
        self.positiveCoverage = positiveCoverage
        self.wrongShowRate = wrongShowRate
        self.suppressionAccuracy = suppressionAccuracy
        self.qualityScore = qualityScore
        self.qualityScoreTotal = qualityScoreTotal
        self.p50GenerationMs = p50GenerationMs
        self.p95GenerationMs = p95GenerationMs
        self.p50TotalMs = p50TotalMs
        self.p95TotalMs = p95TotalMs
        self.suppressionReasonHistogram = suppressionReasonHistogram
        self.byTag = byTag
    }
}

public struct AggregateBreakdown: Codable, Equatable {
    public var rowCount: Int
    public var precisionWhenShown: Double
    public var positiveCoverage: Double
    public var wrongShowRate: Double
    public var qualityScore: Double
    public var p95TotalMs: Double
}

public enum BenchmarkAggregator {
    public static func aggregate(
        rows: [BenchmarkRowResult],
        cases: [CompletionBenchmarkCase],
        suite: BenchmarkSuite
    ) -> AggregateBenchmarkResult? {
        guard let first = rows.first else { return nil }
        let caseByID = Dictionary(uniqueKeysWithValues: cases.map { ($0.id, $0) })
        return aggregateRows(rows, casesByID: caseByID, suite: suite, first: first)
    }

    public static func aggregateByModel(
        rows: [BenchmarkRowResult],
        cases: [CompletionBenchmarkCase],
        suite: BenchmarkSuite
    ) -> [AggregateBenchmarkResult] {
        let grouped = Dictionary(grouping: rows) { $0.modelIdentifier }
        return grouped.keys.sorted().compactMap { model in
            aggregate(rows: grouped[model] ?? [], cases: cases, suite: suite)
        }
    }

    private static func aggregateRows(
        _ rows: [BenchmarkRowResult],
        casesByID: [String: CompletionBenchmarkCase],
        suite: BenchmarkSuite,
        first: BenchmarkRowResult
    ) -> AggregateBenchmarkResult {
        let positive = rows.filter { casesByID[$0.caseID]?.expected.kind == .insert }
        let negative = rows.filter { casesByID[$0.caseID]?.expected.kind == .suppress }
        let shown = rows.filter { $0.shownText != nil }
        let correctInsert = rows.filter { $0.outcome == .correctInsert }
        let correctSuppression = rows.filter { $0.outcome == .correctSuppression }
        let wrongShown = rows.filter { $0.outcome == .wrongShown }
        let positiveSuppression = rows.filter { $0.outcome == .acceptableSuppressionOnPositive }
        let generated = rows.filter(\.generationAttempted)
        let totalScore = rows.reduce(0) { $0 + $1.scoreContribution }
        let reasonHistogram = Dictionary(
            grouping: rows.compactMap(\.suppressionReason),
            by: { $0 }
        ).mapValues(\.count)

        let tags = Set(rows.flatMap(\.tags)).sorted()
        var byTag: [String: AggregateBreakdown] = [:]
        for tag in tags {
            let tagRows = rows.filter { $0.tags.contains(tag) }
            byTag[tag] = breakdown(rows: tagRows, casesByID: casesByID)
        }

        return AggregateBenchmarkResult(
            suite: suite,
            modelIdentifier: first.modelIdentifier,
            modelFilename: first.modelFilename,
            modelFamily: first.modelFamily,
            quantization: first.quantization,
            rowCount: rows.count,
            positiveCount: positive.count,
            negativeCount: negative.count,
            shownCount: shown.count,
            correctInsertCount: correctInsert.count,
            correctSuppressionCount: correctSuppression.count,
            wrongShownCount: wrongShown.count,
            positiveSuppressionCount: positiveSuppression.count,
            precisionWhenShown: ratio(correctInsert.count, shown.count),
            positiveCoverage: ratio(correctInsert.count, positive.count),
            wrongShowRate: ratio(wrongShown.count, rows.count),
            suppressionAccuracy: ratio(correctSuppression.count, negative.count),
            qualityScore: rows.isEmpty ? 0 : totalScore / Double(rows.count),
            qualityScoreTotal: totalScore,
            p50GenerationMs: percentile(generated.map(\.generationMs), 0.50),
            p95GenerationMs: percentile(generated.map(\.generationMs), 0.95),
            p50TotalMs: percentile(rows.map(\.totalMs), 0.50),
            p95TotalMs: percentile(rows.map(\.totalMs), 0.95),
            suppressionReasonHistogram: reasonHistogram,
            byTag: byTag
        )
    }

    private static func breakdown(
        rows: [BenchmarkRowResult],
        casesByID: [String: CompletionBenchmarkCase]
    ) -> AggregateBreakdown {
        let positive = rows.filter { casesByID[$0.caseID]?.expected.kind == .insert }
        let shown = rows.filter { $0.shownText != nil }
        let correct = rows.filter { $0.outcome == .correctInsert }
        let wrong = rows.filter { $0.outcome == .wrongShown }
        let score = rows.reduce(0) { $0 + $1.scoreContribution }
        return AggregateBreakdown(
            rowCount: rows.count,
            precisionWhenShown: ratio(correct.count, shown.count),
            positiveCoverage: ratio(correct.count, positive.count),
            wrongShowRate: ratio(wrong.count, rows.count),
            qualityScore: rows.isEmpty ? 0 : score / Double(rows.count),
            p95TotalMs: percentile(rows.map(\.totalMs), 0.95)
        )
    }

    private static func ratio(_ numerator: Int, _ denominator: Int) -> Double {
        denominator == 0 ? 0 : Double(numerator) / Double(denominator)
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = max(0, min(sorted.count - 1, Int(ceil(p * Double(sorted.count))) - 1))
        return sorted[rank]
    }
}
