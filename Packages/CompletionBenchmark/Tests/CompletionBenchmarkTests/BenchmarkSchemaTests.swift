import CompletionBenchmark
import XCTest

final class BenchmarkSchemaTests: XCTestCase {
    func testSmokeFixtureLoads() throws {
        let url = try BenchmarkDatasetResources.smokeSuiteURL()
        let cases = try BenchmarkJSONL.loadCases(from: url)

        XCTAssertGreaterThanOrEqual(cases.count, 6)
        XCTAssertTrue(cases.allSatisfy { $0.suites.contains(.smoke) })
        XCTAssertTrue(cases.contains { $0.expected.kind == .suppress })
        XCTAssertTrue(cases.contains { $0.contextSources.fieldText == .real })
    }

    func testContextDefaultsDecode() throws {
        let json = """
        {"id":"x","sourceGroup":"g","contextSources":{"fieldText":"real"},"context":{"beforeCursor":"hello","target":{"bundleIdentifier":"com.apple.TextEdit","appName":"TextEdit"}},"expected":{"kind":"insert","modelTarget":" world"}}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(CompletionBenchmarkCase.self, from: data)

        XCTAssertEqual(decoded.split, .eval)
        XCTAssertEqual(decoded.context.afterCursor, "")
        XCTAssertEqual(decoded.context.labels, [])
        XCTAssertEqual(decoded.expected.shownAcceptable, [])
    }
}
