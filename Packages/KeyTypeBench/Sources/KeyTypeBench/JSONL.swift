import Foundation

public enum BenchmarkJSONLError: Error, CustomStringConvertible {
    case unreadable(URL, Error)
    case invalidLine(url: URL, line: Int, Error)
    case writeFailed(URL, Error)
    case missingResource(String)

    public var description: String {
        switch self {
        case let .unreadable(url, error):
            return "Could not read \(url.path): \(error)"
        case let .invalidLine(url, line, error):
            return "Invalid JSONL in \(url.path) at line \(line): \(error)"
        case let .writeFailed(url, error):
            return "Could not write \(url.path): \(error)"
        case let .missingResource(name):
            return "Missing bundled benchmark resource: \(name)"
        }
    }
}

public enum BenchmarkJSONL {
    public static func loadCases(from url: URL) throws -> [KeyTypeBenchCase] {
        try load(KeyTypeBenchCase.self, from: url)
    }

    public static func writeCases(_ cases: [KeyTypeBenchCase], to url: URL) throws {
        try write(cases, to: url)
    }

    public static func loadSourceDocuments(from url: URL) throws -> [BenchmarkSourceDocument] {
        try load(BenchmarkSourceDocument.self, from: url)
    }

    public static func writeRows(_ rows: [BenchmarkRowResult], to url: URL) throws {
        try write(rows, to: url)
    }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> [T] {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw BenchmarkJSONLError.unreadable(url, error)
        }

        let decoder = JSONDecoder()
        var values: [T] = []
        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            guard let data = line.data(using: .utf8) else {
                continue
            }
            do {
                values.append(try decoder.decode(T.self, from: data))
            } catch {
                throw BenchmarkJSONLError.invalidLine(url: url, line: offset + 1, error)
            }
        }
        return values
    }

    private static func write<T: Encodable>(_ values: [T], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var lines: [String] = []
        lines.reserveCapacity(values.count)
        do {
            for value in values {
                let data = try encoder.encode(value)
                lines.append(String(decoding: data, as: UTF8.self))
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw BenchmarkJSONLError.writeFailed(url, error)
        }
    }
}

public enum BenchmarkDatasetResources {
    public static func smokeSuiteURL() throws -> URL {
        guard let url = Bundle.module.url(
            forResource: "smoke",
            withExtension: "jsonl",
            subdirectory: "Datasets"
        ) else {
            throw BenchmarkJSONLError.missingResource("Datasets/smoke.jsonl")
        }
        return url
    }

    public static func bundledURL(for suite: BenchmarkSuite) throws -> URL? {
        switch suite {
        case .smoke:
            return try smokeSuiteURL()
        case .core, .edge, .policy, .humanCalibration, .latency:
            return nil
        }
    }
}

public enum BenchmarkSuiteResolver {
    public static func resolveCaseURLs(
        suite: BenchmarkSuite,
        explicitCasePaths: [String],
        workingDirectory: URL
    ) throws -> [URL] {
        if !explicitCasePaths.isEmpty {
            return explicitCasePaths.map { URL(fileURLWithPath: $0.expandingTilde(), relativeTo: workingDirectory).standardizedFileURL }
        }

        let localCandidates = [
            workingDirectory
                .appendingPathComponent("KeyTypeBench-20260603", isDirectory: true)
                .appendingPathComponent("Datasets", isDirectory: true)
                .appendingPathComponent("\(suite.rawValue).jsonl"),
            workingDirectory
                .appendingPathComponent("KeyTypeBench-20260603", isDirectory: true)
                .appendingPathComponent("Private", isDirectory: true)
                .appendingPathComponent("\(suite.rawValue).jsonl")
        ]
        let localURLs = localCandidates.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !localURLs.isEmpty {
            return localURLs
        }

        if let bundled = try BenchmarkDatasetResources.bundledURL(for: suite) {
            return [bundled]
        }
        return []
    }
}

extension String {
    func expandingTilde() -> String {
        (self as NSString).expandingTildeInPath
    }
}
