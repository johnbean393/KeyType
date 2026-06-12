import KeyTypeBench
import XCTest

final class CommittedDatasetTests: XCTestCase {
    func testCommittedDatasetsMatchV1CountsAndMetadata() throws {
        let expectations: [(BenchmarkSuite, Int)] = [
            (.smoke, 36),
            (.core, 700),
            (.edge, 300),
            (.policy, 72),
            (.latency, 100)
        ]

        for (suite, expectedCount) in expectations {
            let cases = try loadCases(suite)
            XCTAssertEqual(cases.count, expectedCount, suite.rawValue)
            XCTAssertTrue(cases.allSatisfy { $0.suites.contains(suite) }, suite.rawValue)
            XCTAssertTrue(cases.allSatisfy { !$0.sourceGroup.isEmpty }, suite.rawValue)
            XCTAssertTrue(
                cases.allSatisfy { row in
                    guard let path = row.source?.path else { return true }
                    return !path.hasPrefix("/")
                },
                "\(suite.rawValue) contains an absolute source path"
            )
        }
    }

    func testGeneratedSuitesKeepSourceGroupSplitsInRange() throws {
        for suite in [BenchmarkSuite.core, .edge, .latency] {
            let cases = try loadCases(suite)
            let counts = Dictionary(grouping: cases, by: \.split).mapValues(\.count)
            assertShare(counts[.dev, default: 0], of: cases.count, atLeast: 0.10, atMost: 0.15, "\(suite.rawValue) dev")
            assertShare(counts[.eval, default: 0], of: cases.count, atLeast: 0.70, atMost: 0.80, "\(suite.rawValue) eval")
            assertShare(counts[.holdout, default: 0], of: cases.count, atLeast: 0.10, atMost: 0.15, "\(suite.rawValue) holdout")

            let splitsByGroup = Dictionary(grouping: cases, by: \.sourceGroup)
                .mapValues { Set($0.map(\.split)) }
            XCTAssertTrue(
                splitsByGroup.values.allSatisfy { $0.count == 1 },
                "\(suite.rawValue) has a source group split across multiple splits"
            )
        }
    }

    func testPublicSourceManifestIsAuditable() throws {
        let url = repositoryRoot()
            .appendingPathComponent("KeyTypeBench-20260603", isDirectory: true)
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("public-source-documents.jsonl")
        let documents = try BenchmarkJSONL.loadSourceDocuments(from: url)
        XCTAssertEqual(documents.count, 1_133)
        XCTAssertGreaterThanOrEqual(Set(documents.map(\.sourceGroup)).count, 60)
        XCTAssertTrue(documents.allSatisfy { $0.contextSources.fieldText == .real })
        XCTAssertTrue(documents.contains { $0.tags.contains("wikipedia") })
        XCTAssertFalse(documents.contains { $0.source.license?.localizedCaseInsensitiveContains("gutenberg") == true })
    }

    func testCommittedDatasetsDoNotContainRejectedSourcesOrInlineSourceURLs() throws {
        for suite in BenchmarkSuite.allCases where suite != .humanCalibration {
            let cases = try loadCases(suite)
            for row in cases {
                let searchable = [
                    row.context.beforeCursor,
                    row.context.afterCursor,
                    row.expected.modelTarget,
                    row.source?.title,
                    row.source?.url,
                    row.source?.license
                ]
                .compactMap { $0 }
                .joined(separator: "\n")

                XCTAssertFalse(searchable.localizedCaseInsensitiveContains("gutenberg"), row.id)
                XCTAssertFalse(searchable.localizedCaseInsensitiveContains("stack exchange"), row.id)
                XCTAssertFalse(row.context.beforeCursor.contains("Source: https://"), row.id)
                XCTAssertFalse(row.context.afterCursor.contains("Source: https://"), row.id)
            }
        }
    }

    /// The history-echo diagnostic fixture (stale/unrelated writing history) is measurement-only — it
    /// has no behavioural CI assertion because the right fix layer was upstream selection, not an output
    /// guard. This guards the *dataset* itself from rot: every line must decode, the stale-history cases
    /// must carry topically-unrelated `previousUserInputs`, and the control case's reuse string must
    /// actually appear in its history so the "legitimate reuse is not over-suppressed" check stays valid.
    func testHistoryEchoFixtureIsWellFormed() throws {
        let url = repositoryRoot()
            .appendingPathComponent("Packages/KeyTypeBench/Sources/KeyTypeBench/Datasets/history-echo.jsonl")
        let cases = try BenchmarkJSONL.loadCases(from: url)
        XCTAssertEqual(cases.count, 4)

        for row in cases {
            XCTAssertFalse(row.context.beforeCursor.isEmpty, row.id)
            XCTAssertFalse(row.context.previousUserInputs.isEmpty, "\(row.id) must carry writing history")
            XCTAssertEqual(row.expected.kind, .insert, row.id)
            XCTAssertTrue(row.tags.contains("history-echo"), row.id)
        }

        let control = try XCTUnwrap(cases.first { $0.tags.contains("control") })
        let history = control.context.previousUserInputs.joined(separator: "\n")
        XCTAssertTrue(
            control.expected.shownAcceptable.contains { history.contains($0) },
            "control reuse string must appear in its own writing history"
        )

        let staleCases = cases.filter { $0.tags.contains("stale-history") }
        XCTAssertEqual(staleCases.count, 3, "three stale-unrelated-history cases")
    }

    private func assertShare(
        _ count: Int,
        of total: Int,
        atLeast minimum: Double,
        atMost maximum: Double,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let share = Double(count) / Double(total)
        XCTAssertGreaterThanOrEqual(share, minimum, label, file: file, line: line)
        XCTAssertLessThanOrEqual(share, maximum, label, file: file, line: line)
    }

    private func loadCases(_ suite: BenchmarkSuite) throws -> [KeyTypeBenchCase] {
        let url = repositoryRoot()
            .appendingPathComponent("KeyTypeBench-20260603", isDirectory: true)
            .appendingPathComponent("Datasets", isDirectory: true)
            .appendingPathComponent("\(suite.rawValue).jsonl")
        return try BenchmarkJSONL.loadCases(from: url)
    }

    private func repositoryRoot(
        file: StaticString = #filePath
    ) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent() // KeyTypeBenchTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // KeyTypeBench
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
    }
}
