import CompletionBenchmark
import XCTest

final class BenchmarkScoringTests: XCTestCase {
    func testWrongShownIsStronglyPenalized() {
        let expected = BenchmarkExpected(kind: .insert, modelTarget: " looks good")

        let score = BenchmarkScorer.score(
            expected: expected,
            shownText: " is unrelated",
            suppressionReason: nil
        )

        XCTAssertEqual(score.outcome, .wrongShown)
        XCTAssertEqual(score.contribution, -2.0)
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
}
