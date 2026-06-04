import KeyTypeBench
import ModelRuntime
import TokenProfiles
import XCTest

final class EvaluationPipelineTests: XCTestCase {
    func testNumericMidWordStemSuppressesBeforeGeneration() async throws {
        let runtime = StubModelRuntime()
        let profile = InMemoryAutocompleteProfile(vocabularySize: 256, records: [])
        let evaluator = ProductionCompletionEvaluator(
            runtime: runtime,
            profile: profile,
            modelInfo: BenchmarkModelInfo(identifier: "stub", filename: "stub.gguf")
        )
        let benchmarkCase = KeyTypeBenchCase(
            id: "numeric-midword",
            split: .eval,
            sourceGroup: "test",
            suites: [.edge],
            tags: ["mid-word"],
            contextSources: BenchmarkContextSources(fieldText: .real),
            context: BenchmarkTextFieldContext(
                beforeCursor: "Congress ID H00",
                target: BenchmarkAppTarget(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit")
            ),
            expected: BenchmarkExpected(kind: .insert, modelTarget: "0357")
        )

        let row = try await evaluator.evaluate(benchmarkCase)

        XCTAssertEqual(row.outcome, .acceptableSuppressionOnPositive)
        XCTAssertEqual(row.suppressionReason, "numericMidWordStem")
        XCTAssertFalse(row.generationAttempted)
        XCTAssertEqual(row.promptBuildMs, 0)
        XCTAssertEqual(row.generationMs, 0)
    }
}
