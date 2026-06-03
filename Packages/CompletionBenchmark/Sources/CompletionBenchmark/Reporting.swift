import Foundation

public struct BenchmarkReportManifest: Codable, Equatable {
    public var schemaVersion: Int
    public var suite: BenchmarkSuite
    public var generatedAt: String
    public var rowResultsPath: String
    public var aggregateJSONPath: String
    public var aggregateCSVPath: String
    public var releaseBuildRequiredForLatency: Bool
    public var aggregates: [AggregateBenchmarkResult]

    public init(
        schemaVersion: Int = 1,
        suite: BenchmarkSuite,
        generatedAt: String,
        rowResultsPath: String,
        aggregateJSONPath: String,
        aggregateCSVPath: String,
        releaseBuildRequiredForLatency: Bool = true,
        aggregates: [AggregateBenchmarkResult]
    ) {
        self.schemaVersion = schemaVersion
        self.suite = suite
        self.generatedAt = generatedAt
        self.rowResultsPath = rowResultsPath
        self.aggregateJSONPath = aggregateJSONPath
        self.aggregateCSVPath = aggregateCSVPath
        self.releaseBuildRequiredForLatency = releaseBuildRequiredForLatency
        self.aggregates = aggregates
    }
}

public enum BenchmarkReportWriter {
    public static func write(
        rows: [BenchmarkRowResult],
        aggregates: [AggregateBenchmarkResult],
        suite: BenchmarkSuite,
        outputDirectory: URL
    ) throws -> BenchmarkReportManifest {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let rowsURL = outputDirectory.appendingPathComponent("rows.jsonl")
        let aggregateJSONURL = outputDirectory.appendingPathComponent("aggregate.json")
        let aggregateCSVURL = outputDirectory.appendingPathComponent("aggregate.csv")

        try BenchmarkJSONL.writeRows(rows, to: rowsURL)
        try writeJSON(aggregates, to: aggregateJSONURL)
        try writeCSV(aggregates, to: aggregateCSVURL)

        let manifest = BenchmarkReportManifest(
            suite: suite,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            rowResultsPath: rowsURL.path,
            aggregateJSONPath: aggregateJSONURL.path,
            aggregateCSVPath: aggregateCSVURL.path,
            aggregates: aggregates
        )
        try writeJSON(manifest, to: outputDirectory.appendingPathComponent("manifest.json"))
        return manifest
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url)
    }

    private static func writeCSV(_ aggregates: [AggregateBenchmarkResult], to url: URL) throws {
        let header = [
            "suite",
            "model_identifier",
            "model_filename",
            "model_family",
            "quantization",
            "row_count",
            "precision_when_shown",
            "positive_coverage",
            "wrong_show_rate",
            "suppression_accuracy",
            "quality_score",
            "quality_score_total",
            "p50_generation_ms",
            "p95_generation_ms",
            "p50_total_ms",
            "p95_total_ms"
        ]
        var lines = [header.joined(separator: ",")]
        lines += aggregates.map { aggregate in
            [
                aggregate.suite.rawValue,
                aggregate.modelIdentifier,
                aggregate.modelFilename,
                aggregate.modelFamily ?? "",
                aggregate.quantization ?? "",
                String(aggregate.rowCount),
                csvNumber(aggregate.precisionWhenShown),
                csvNumber(aggregate.positiveCoverage),
                csvNumber(aggregate.wrongShowRate),
                csvNumber(aggregate.suppressionAccuracy),
                csvNumber(aggregate.qualityScore),
                csvNumber(aggregate.qualityScoreTotal),
                csvNumber(aggregate.p50GenerationMs),
                csvNumber(aggregate.p95GenerationMs),
                csvNumber(aggregate.p50TotalMs),
                csvNumber(aggregate.p95TotalMs)
            ].map(csvEscape).joined(separator: ",")
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func csvNumber(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}
