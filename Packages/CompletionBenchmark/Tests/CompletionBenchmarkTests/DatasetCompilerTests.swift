import CompletionBenchmark
import XCTest

final class DatasetCompilerTests: XCTestCase {
    func testCompilerPreservesSourceGroupSplitAndHumanFieldSource() {
        let source = BenchmarkSourceDocument(
            id: "doc-001",
            sourceGroup: "human-doc-001",
            split: .holdout,
            text: """
            Thanks for sending the notes over this morning. I read through the proposal and added a few comments near the timeline section. The main change is that we should leave more room for review before sharing the draft.
            """,
            tags: ["prose"],
            suites: [.core],
            source: BenchmarkSourceMetadata(kind: "document", title: "Test document", license: "test"),
            caseTypes: [.endOfLineAppend, .midWordCompletion, .fillInMiddle]
        )

        let cases = BenchmarkDatasetCompiler.compile(
            documents: [source],
            configuration: BenchmarkDatasetCompilerConfiguration(includePolicyCases: false)
        )

        XCTAssertEqual(cases.count, 3)
        XCTAssertTrue(cases.allSatisfy { $0.sourceGroup == "human-doc-001" })
        XCTAssertTrue(cases.allSatisfy { $0.split == .holdout })
        XCTAssertTrue(cases.allSatisfy { $0.contextSources.fieldText == .real })
        XCTAssertTrue(cases.contains { $0.tags.contains("mid-word") })
        XCTAssertTrue(cases.contains { !$0.context.afterCursor.isEmpty })
    }
}
