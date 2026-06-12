import AppCompatibility
import ArgumentParser
import ConstrainedGeneration
import KeyTypeBench
import Foundation
import LlamaModelRuntime
import ModelManagement
import ModelRuntime
import TokenProfiles

@main
struct KeyTypeBenchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "KeyTypeBench",
        abstract: "Evaluate KeyType completion quality and latency against GGUF models.",
        discussion: """
            Latency numbers are meaningful only in release builds. Use:

              swift run -c release --package-path Packages/KeyTypeBench KeyTypeBench run --suite smoke
            """,
        subcommands: [
            Run.self,
            Compile.self,
            Validate.self
        ],
        defaultSubcommand: Run.self
    )
}

extension BenchmarkSuite: ExpressibleByArgument {}
extension BenchmarkSplit: ExpressibleByArgument {}
extension CompilerCaseType: ExpressibleByArgument {}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a named benchmark suite against one or more GGUF models."
    )

    @Option(name: .long, help: "Suite to run: smoke, core, edge, policy, human-calibration, latency.")
    var suite: BenchmarkSuite = .smoke

    @Option(name: .customLong("cases"), help: "JSONL case file. Can be passed more than once.")
    var casePaths: [String] = []

    @Option(name: .customLong("model"), help: "GGUF model path. Can be passed more than once. Defaults to KeyType's default model path.")
    var modelPaths: [String] = []

    @Option(name: .long, help: "ACPF profile path for all models. If omitted, the profile is resolved from the model family.")
    var profile: String?

    @Option(name: .long, help: "Directory containing <family>.acpf.bin profiles. Defaults to KeyType's model container.")
    var profileDirectory: String?

    @Option(name: .long, help: "Output directory. Defaults to KeyTypeBench-20260603/Results/<suite>-<timestamp>.")
    var output: String?

    @Option(name: .long, help: "Only run rows in this split.")
    var split: BenchmarkSplit?

    @Option(name: .long, help: "Only run rows containing this tag. Can be passed more than once.")
    var tags: [String] = []

    @Option(name: .long, help: "Default max completion tokens for rows without limits.")
    var maxCompletionTokens: Int = 4

    @Option(name: .long, help: "Default max display width for rows without limits.")
    var maxDisplayWidth: Int = 80

    @Option(name: .long, help: "Llama context length.")
    var contextLength: Int = 4096

    @Flag(name: .long, help: "Opt benchmark targets with same-line after-cursor text into mid-line/FIM generation.")
    var enableMidLine: Bool = false

    @Option(name: .long, help: "Decoder beam width.")
    var branchWidth: Int = DecodingConfiguration().branchWidth

    @Option(name: .long, help: "Maximum returned candidates.")
    var maxCandidates: Int = DecodingConfiguration().maxCandidates

    @Option(name: .long, help: "FIM prefix token window nearest the caret; <= 0 disables the cap.")
    var fimMaxPrefixTokens: Int = DecodingConfiguration().fimMaxPrefixTokens

    @Option(name: .long, help: "FIM suffix token window nearest the caret; <= 0 disables the cap.")
    var fimMaxSuffixTokens: Int = DecodingConfiguration().fimMaxSuffixTokens

    @Option(name: .long, help: "Leading suffix tokens scored for FIM reranking; <= 0 disables rerank.")
    var suffixRerankTokenCount: Int = DecodingConfiguration().suffixRerankTokenCount

    @Option(name: .long, help: "Weight applied to FIM suffix-rerank score.")
    var suffixRerankWeight: Float = DecodingConfiguration().suffixRerankWeight

    @Option(name: .long, help: "Decode-time presence penalty: subtracted once from any token already emitted on the branch. Sweep knob for the repetition-penalty default.")
    var presencePenalty: Float = DecodingConfiguration().presencePenalty

    @Option(name: .long, help: "Decode-time frequency penalty: subtracted per prior occurrence of a token on the branch.")
    var frequencyPenalty: Float = DecodingConfiguration().frequencyPenalty

    @Flag(name: .customLong("no-history"), help: "Drop writing-history (previousUserInputs) side context from prompts. A/B knob for the history-on/off experiment.")
    var noHistory: Bool = false

    @Flag(name: .long, help: "Skip missing model/profile inputs instead of failing.")
    var skipMissing: Bool = false

    @Flag(name: .long, help: "Allow a debug build run. Do not use its latency numbers for decisions.")
    var allowDebugLatency: Bool = false

    func run() async throws {
        #if DEBUG
        guard allowDebugLatency else {
            throw ValidationError("Run with `swift run -c release --package-path Packages/KeyTypeBench KeyTypeBench run ...` for latency. Pass --allow-debug-latency only for plumbing checks.")
        }
        #endif

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let caseURLs = try BenchmarkSuiteResolver.resolveCaseURLs(
            suite: suite,
            explicitCasePaths: casePaths,
            workingDirectory: cwd
        )
        guard !caseURLs.isEmpty else {
            throw ValidationError("No dataset found for suite '\(suite.rawValue)'. Add KeyTypeBench-20260603/Datasets/\(suite.rawValue).jsonl, KeyTypeBench-20260603/Private/\(suite.rawValue).jsonl, or pass --cases.")
        }

        var cases = try caseURLs.flatMap { try BenchmarkJSONL.loadCases(from: $0) }
        cases = cases.filter { $0.suites.contains(suite) }
        if let split {
            cases = cases.filter { $0.split == split }
        }
        for tag in tags {
            cases = cases.filter { $0.tags.contains(tag) }
        }
        guard !cases.isEmpty else {
            let splitMessage = split.map { " and split '\($0.rawValue)'" } ?? ""
            let tagMessage = tags.isEmpty ? "" : " and tags \(tags.map { "'\($0)'" }.joined(separator: ", "))"
            throw ValidationError("Loaded dataset files, but no rows matched suite '\(suite.rawValue)'\(splitMessage)\(tagMessage).")
        }

        let models = try resolveModelURLs(cwd: cwd)
        var allRows: [BenchmarkRowResult] = []

        for modelURL in models {
            if !ModelContainer.modelExists(at: modelURL) {
                if skipMissing {
                    print("Skipping missing model: \(modelURL.path)")
                    continue
                }
                throw ValidationError("Model file is missing or empty: \(modelURL.path)")
            }

            let runtime = try LlamaModelRuntime(modelURL: modelURL, contextLength: contextLength)
            let family = ModelFamilyResolver.family(
                forFilename: modelURL.lastPathComponent,
                vocabSize: runtime.metadata.vocabularySize
            )
            let profileURL = try resolveProfileURL(family: family, cwd: cwd)
            guard FileManager.default.fileExists(atPath: profileURL.path) else {
                await runtime.shutdown()
                if skipMissing {
                    print("Skipping \(modelURL.lastPathComponent); profile missing: \(profileURL.path)")
                    continue
                }
                throw ValidationError("ACPF profile missing for \(modelURL.lastPathComponent): \(profileURL.path)")
            }

            let acpf = try MmapAutocompleteProfile.open(
                at: profileURL,
                tokenizerVocabSize: runtime.metadata.vocabularySize,
                tokenizerBytes: { try runtime.tokenizer.rawBytes(for: $0) },
                expectedModelFamily: family
            )
            let info = BenchmarkModelInfo(
                identifier: modelURL.deletingPathExtension().lastPathComponent,
                filename: modelURL.lastPathComponent,
                path: modelURL.path,
                family: family,
                quantization: BenchmarkModelInfoFactory.quantization(from: modelURL.lastPathComponent)
            )
            let compatibilityStore = makeCompatibilityStore(for: cases)
            let decodingConfiguration = DecodingConfiguration(
                branchWidth: branchWidth,
                maxCandidates: maxCandidates,
                enableFillInMiddle: true,
                fimMaxPrefixTokens: fimMaxPrefixTokens,
                fimMaxSuffixTokens: fimMaxSuffixTokens,
                suffixRerankTokenCount: suffixRerankTokenCount,
                suffixRerankWeight: suffixRerankWeight,
                presencePenalty: presencePenalty,
                frequencyPenalty: frequencyPenalty
            )
            let evaluator = ProductionCompletionEvaluator(
                runtime: runtime,
                profile: acpf,
                modelInfo: info,
                compatibilityStore: compatibilityStore,
                decodingConfiguration: decodingConfiguration,
                defaultMaxCompletionTokens: maxCompletionTokens,
                defaultMaxDisplayWidth: maxDisplayWidth,
                includeWritingHistory: !noHistory
            )

            do {
                for benchmarkCase in cases {
                    allRows.append(try await evaluator.evaluate(benchmarkCase))
                }
                await evaluator.shutdown()
            } catch {
                await evaluator.shutdown()
                throw error
            }
        }

        guard !allRows.isEmpty else {
            if skipMissing {
                print("No rows evaluated; every requested model/profile was missing or skipped.")
                return
            }
            throw ValidationError("No rows were evaluated. Check --model inputs or remove --skip-missing.")
        }

        let aggregates = BenchmarkAggregator.aggregateByModel(rows: allRows, cases: cases, suite: suite)
        let out = outputURL(cwd: cwd)
        let manifest = try BenchmarkReportWriter.write(
            rows: allRows,
            aggregates: aggregates,
            suite: suite,
            outputDirectory: out
        )
        print("Rows: \(manifest.rowResultsPath)")
        print("Aggregate JSON: \(manifest.aggregateJSONPath)")
        print("Aggregate CSV: \(manifest.aggregateCSVPath)")
    }

    private func resolveModelURLs(cwd: URL) throws -> [URL] {
        if modelPaths.isEmpty {
            return [try ModelContainer.modelURL()]
        }
        return modelPaths.map {
            URL(fileURLWithPath: $0.expandingTilde(), relativeTo: cwd).standardizedFileURL
        }
    }

    private func resolveProfileURL(family: String, cwd: URL) throws -> URL {
        if let profile {
            return URL(fileURLWithPath: profile.expandingTilde(), relativeTo: cwd).standardizedFileURL
        }
        if let profileDirectory {
            return URL(fileURLWithPath: profileDirectory.expandingTilde(), relativeTo: cwd)
                .standardizedFileURL
                .appendingPathComponent(ModelContainer.profileFilename(family: family))
        }
        return try ModelContainer.profileURL(family: family)
    }

    private func outputURL(cwd: URL) -> URL {
        if let output {
            return URL(fileURLWithPath: output.expandingTilde(), relativeTo: cwd).standardizedFileURL
        }
        let stamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        return cwd
            .appendingPathComponent("KeyTypeBench-20260603", isDirectory: true)
            .appendingPathComponent("Results", isDirectory: true)
            .appendingPathComponent("\(suite.rawValue)-\(stamp)", isDirectory: true)
    }

    private func makeCompatibilityStore(for cases: [KeyTypeBenchCase]) -> AppCompatibilityStore {
        guard enableMidLine else { return AppCompatibilityStore() }

        var overrides = AppCompatibilityStore.defaultOverrides
        var seen = Set<BenchmarkTargetKey>()
        for benchmarkCase in cases {
            let context = benchmarkCase.context
            let sameLineSuffix = context.afterCursor.prefix { !$0.isNewline }
            guard !context.afterCursor.isEmpty,
                  sameLineSuffix.contains(where: { !$0.isWhitespace }),
                  !context.traits.isTerminalLike
            else { continue }

            let key = BenchmarkTargetKey(
                bundleIdentifier: context.target.bundleIdentifier,
                domain: context.target.domain
            )
            guard seen.insert(key).inserted else { continue }
            overrides.append(
                TargetOverride(
                    bundleIdentifier: key.bundleIdentifier,
                    domain: key.domain,
                    midLineCompletionsEnabled: true
                )
            )
        }
        return AppCompatibilityStore(overrides: overrides)
    }
}

private struct BenchmarkTargetKey: Hashable {
    var bundleIdentifier: String
    var domain: String?
}

struct Compile: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compile",
        abstract: "Compile human-written source documents into benchmark JSONL cases."
    )

    @Option(name: .long, help: "Source JSONL file or directory of .txt/.md/.swift files.")
    var sources: String

    @Option(name: .long, help: "Output JSONL case file.")
    var output: String

    @Option(name: .long, help: "Suite tag to stamp on compiled rows.")
    var suite: BenchmarkSuite = .core

    @Option(name: .long, help: "Split to stamp on compiled rows. Split at source document/source group level.")
    var split: BenchmarkSplit = .eval

    @Option(name: .long, help: "Case type to generate. Can be passed more than once.")
    var caseTypes: [CompilerCaseType] = []

    @Flag(name: .long, inversion: .prefixedNo, help: "Include handcrafted policy/secure suppression cases.")
    var includePolicyCases: Bool = true

    func run() throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let sourceURL = URL(fileURLWithPath: sources.expandingTilde(), relativeTo: cwd).standardizedFileURL
        let outputURL = URL(fileURLWithPath: output.expandingTilde(), relativeTo: cwd).standardizedFileURL

        let loadedDocs: [BenchmarkSourceDocument]
        if sourceURL.pathExtension.lowercased() == "jsonl" {
            loadedDocs = try BenchmarkJSONL.loadSourceDocuments(from: sourceURL)
        } else {
            loadedDocs = try BenchmarkDatasetCompiler.sourceDocuments(fromTextFilesAt: sourceURL, suite: suite, split: split)
        }
        let docs = loadedDocs.map { doc in
            var copy = doc
            copy.suites = [suite]
            copy.split = split
            copy.source.path = normalizedSourcePath(copy.source.path, cwd: cwd)
            return copy
        }
        let config = BenchmarkDatasetCompilerConfiguration(
            defaultCaseTypes: caseTypes.isEmpty ? BenchmarkDatasetCompilerConfiguration().defaultCaseTypes : caseTypes,
            includePolicyCases: includePolicyCases
        )
        let cases = BenchmarkDatasetCompiler.compile(documents: docs, configuration: config)
        try BenchmarkJSONL.writeCases(cases, to: outputURL)
        print("Wrote \(cases.count) cases to \(outputURL.path)")
    }

    private func normalizedSourcePath(_ path: String?, cwd: URL) -> String? {
        guard let path else { return nil }
        let cwdPath = cwd.standardizedFileURL.path
        let absolute = URL(fileURLWithPath: path.expandingTilde()).standardizedFileURL.path
        if absolute == cwdPath {
            return "."
        }
        if absolute.hasPrefix(cwdPath + "/") {
            return String(absolute.dropFirst(cwdPath.count + 1))
        }
        return path
    }
}

struct Validate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Load and validate benchmark case JSONL without running a model."
    )

    @Option(name: .long, help: "Suite to validate.")
    var suite: BenchmarkSuite = .smoke

    @Option(name: .customLong("cases"), help: "JSONL case file. Can be passed more than once.")
    var casePaths: [String] = []

    func run() throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let urls = try BenchmarkSuiteResolver.resolveCaseURLs(
            suite: suite,
            explicitCasePaths: casePaths,
            workingDirectory: cwd
        )
        guard !urls.isEmpty else {
            throw ValidationError("No dataset found for suite '\(suite.rawValue)'.")
        }
        let cases = try urls.flatMap { try BenchmarkJSONL.loadCases(from: $0) }
            .filter { $0.suites.contains(suite) }
        guard !cases.isEmpty else {
            throw ValidationError("Dataset loaded but no rows matched suite '\(suite.rawValue)'.")
        }
        let sourceGroups = Set(cases.map(\.sourceGroup)).count
        print("Validated \(cases.count) cases across \(sourceGroups) source groups for suite \(suite.rawValue).")
    }
}

private extension String {
    func expandingTilde() -> String {
        (self as NSString).expandingTildeInPath
    }
}
