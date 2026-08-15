import ArgumentParser
import Foundation
import MLXModelRuntime
import ModelRuntime
import ProfileBuilderCore

/// Offline ACPF builder for a local MLX safetensor model.
@main
struct MLXProfileBuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "acpf-build-mlx",
        abstract: "Produce a KeyType ACPF profile from a local MLX model."
    )

    @Option(name: .long, help: "Path to the local MLX safetensor model directory.")
    var modelDirectory: String

    @Option(name: .long, help: "Tokenizer family identifier stamped into the profile header.")
    var family: String = "qwen3-v151936"

    @Option(name: .long, help: "Output ACPF path. Defaults to KeyType's model profile directory.")
    var output: String?

    @Flag(name: .long, help: "Overwrite an existing profile.")
    var force = false

    @Flag(name: .long, help: "Run the full pipeline without writing the profile.")
    var dryRun = false

    @Option(name: .long, help: "Optional JSON summary path.")
    var report: String?

    func run() async throws {
        let sourceURL = URL(fileURLWithPath: modelDirectory)
        let outputURL = try resolveOutputURL()
        if !force && FileManager.default.fileExists(atPath: outputURL.path) {
            throw ValidationError("Output already exists: \(outputURL.path). Pass --force to replace it.")
        }

        let reporter = ConsoleReporter()
        reporter.start(
            source: sourceURL,
            sourceLabel: "mlx model",
            output: outputURL,
            family: family,
            dryRun: dryRun
        )

        let runtime = try await MLXModelLoader.load(modelDirectory: sourceURL, family: family)
        do {
            let summary = try BuildProfile.run(
                introspector: MLXVocabIntrospector(runtime: runtime),
                family: family,
                output: dryRun ? nil : outputURL,
                reporter: reporter
            )
            await runtime.shutdown()

            if let report {
                let reportURL = URL(fileURLWithPath: report)
                try summary.writeJSON(to: reportURL)
                reporter.wroteReport(at: reportURL)
            }
            reporter.finish(summary: summary)
        } catch {
            await runtime.shutdown()
            throw error
        }
    }

    func resolveOutputURL() throws -> URL {
        if let output { return URL(fileURLWithPath: output) }
        return try ModelContainer.profileURL(family: family, create: true)
    }
}
