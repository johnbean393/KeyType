import KeyTypeBench
import XCTest

final class BenchmarkScoringTests: XCTestCase {
    func testWrongShownHasNoUtilityContribution() {
        let expected = BenchmarkExpected(kind: .insert, modelTarget: " looks good")

        let score = BenchmarkScorer.score(
            expected: expected,
            shownText: " is unrelated",
            suppressionReason: nil
        )

        XCTAssertEqual(score.outcome, .wrongShown)
        XCTAssertEqual(score.contribution, 0.0)
    }

    func testWrongShownOnSuppressionHasNoUtilityContribution() {
        let expected = BenchmarkExpected(kind: .suppress, allowedReasons: ["secureFieldExcluded"])

        let score = BenchmarkScorer.score(
            expected: expected,
            shownText: " should not appear",
            suppressionReason: nil
        )

        XCTAssertEqual(score.outcome, .wrongShown)
        XCTAssertEqual(score.contribution, 0.0)
    }

    func testShorterPrefixAtWordBoundaryIsAccepted() {
        let expected = BenchmarkExpected(kind: .insert, modelTarget: " people per square mile (8.")

        let score = BenchmarkScorer.score(
            expected: expected,
            shownText: " people per square mile",
            suppressionReason: nil
        )

        XCTAssertEqual(score.outcome, .correctInsert)
        XCTAssertEqual(score.contribution, 1.0)
    }

    func testShorterPrefixInsideWordIsRejected() {
        let expected = BenchmarkExpected(kind: .insert, modelTarget: " people per square mile")

        let score = BenchmarkScorer.score(
            expected: expected,
            shownText: " peop",
            suppressionReason: nil
        )

        XCTAssertEqual(score.outcome, .wrongShown)
        XCTAssertEqual(score.contribution, 0.0)
    }

    func testShorterPrefixInsideNumberIsRejected() {
        let expected = BenchmarkExpected(kind: .insert, modelTarget: " 2014, and Donald J.")

        let score = BenchmarkScorer.score(
            expected: expected,
            shownText: " 201",
            suppressionReason: nil
        )

        XCTAssertEqual(score.outcome, .wrongShown)
        XCTAssertEqual(score.contribution, 0.0)
    }

    func testShorterPrefixWithoutCompletedTokenIsRejected() {
        let expected = BenchmarkExpected(kind: .insert, modelTarget: " ... and then")

        let score = BenchmarkScorer.score(
            expected: expected,
            shownText: " ...",
            suppressionReason: nil
        )

        XCTAssertEqual(score.outcome, .wrongShown)
        XCTAssertEqual(score.contribution, 0.0)
    }

    func testPositiveSuppressionGetsPartialCredit() {
        let expected = BenchmarkExpected(kind: .insert, modelTarget: " looks good")

        let score = BenchmarkScorer.score(
            expected: expected,
            shownText: nil,
            suppressionReason: "noCandidate"
        )

        XCTAssertEqual(score.outcome, .acceptableSuppressionOnPositive)
        XCTAssertEqual(score.contribution, 0.3)
    }

    func testSuppressionRequiresAllowedReasonWhenProvided() {
        let expected = BenchmarkExpected(kind: .suppress, allowedReasons: ["secureFieldExcluded"])

        let correct = BenchmarkScorer.score(
            expected: expected,
            shownText: nil,
            suppressionReason: "secureFieldExcluded"
        )
        let incorrect = BenchmarkScorer.score(
            expected: expected,
            shownText: nil,
            suppressionReason: "noCandidate"
        )

        XCTAssertEqual(correct.outcome, .correctSuppression)
        XCTAssertEqual(incorrect.outcome, .incorrectSuppression)
    }

    func testAggregateQualityUsesCurrentOutcomeContributions() throws {
        let cases = [
            makeCase(id: "correct", expected: BenchmarkExpected(kind: .insert, modelTarget: " useful")),
            makeCase(id: "wrong", expected: BenchmarkExpected(kind: .insert, modelTarget: " useful")),
            makeCase(id: "suppressed", expected: BenchmarkExpected(kind: .insert, modelTarget: " useful"))
        ]
        let rows = [
            makeRow(caseID: "correct", outcome: .correctInsert, storedContribution: 1.0),
            makeRow(caseID: "wrong", outcome: .wrongShown, storedContribution: -1.0),
            makeRow(caseID: "suppressed", outcome: .acceptableSuppressionOnPositive, storedContribution: 0.3)
        ]

        let aggregate = try XCTUnwrap(BenchmarkAggregator.aggregate(rows: rows, cases: cases, suite: .core))

        XCTAssertEqual(aggregate.qualityScoreTotal, 1.3, accuracy: 0.000001)
        XCTAssertEqual(aggregate.qualityScore, 1.3 / 3.0, accuracy: 0.000001)
        XCTAssertEqual(aggregate.wrongShownCount, 1)
        XCTAssertEqual(aggregate.wrongShowRate, 1.0 / 3.0, accuracy: 0.000001)
    }

    private func makeCase(id: String, expected: BenchmarkExpected) -> KeyTypeBenchCase {
        KeyTypeBenchCase(
            id: id,
            split: .eval,
            sourceGroup: "group",
            suites: [.core],
            tags: ["test"],
            contextSources: BenchmarkContextSources(fieldText: .real),
            context: BenchmarkTextFieldContext(
                beforeCursor: "hello",
                target: BenchmarkAppTarget(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit")
            ),
            expected: expected
        )
    }

    private func makeRow(
        caseID: String,
        outcome: BenchmarkCompletionOutcome,
        storedContribution: Double
    ) -> BenchmarkRowResult {
        BenchmarkRowResult(
            caseID: caseID,
            split: .eval,
            sourceGroup: "group",
            suites: [.core],
            tags: ["test"],
            expectedKind: .insert,
            outcome: outcome,
            scoreContribution: storedContribution,
            modelInfo: BenchmarkModelInfo(identifier: "model", filename: "model.gguf"),
            promptTokenCount: 10,
            candidateCount: outcome == .acceptableSuppressionOnPositive ? 0 : 1,
            topCandidateText: nil,
            topKCandidateTexts: [],
            shownText: outcome == .acceptableSuppressionOnPositive ? nil : "visible",
            suppressionReason: outcome == .acceptableSuppressionOnPositive ? "noCandidate" : nil,
            generationAttempted: true,
            promptBuildMs: 1,
            generationMs: 2,
            totalMs: 3
        )
    }
}
