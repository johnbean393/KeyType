import ArgumentParser
import Foundation
import LlamaModelRuntime
import ModelRuntime
import ProfileBuilderCore
import TokenProfiles

/// `acpf-build` — offline builder that turns a GGUF tokenizer into an ACPF profile.
///
/// Slow build time is acceptable (we read every token, classify, build the trie); the
/// runtime read is fast because the file is memory-mapped.
@main
struct ACPFBuildCommand: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "acpf-build",
        abstract: "Produce a KeyType ACPF token-profile binary from a GGUF tokenizer.",
        discussion: """
            Reads the tokenizer from the GGUF at --gguf, classifies every token, builds the
            byte-prefix trie + first-byte buckets + bias tables, and writes a memory-mappable
            ACPF binary to --output (default: ~/Library/Application Support/KeyType/Models/
            <family>.acpf.bin). The output is gitignored by being outside the repo entirely.
            """
    )

    @Option(name: .long, help: "Path to the source GGUF. Defaults to ModelContainer.modelURL().")
    var gguf: String?

    @Option(name: .long, help: "Tokenizer family identifier stamped into the profile header.")
    var family: String = "qwen3-v151936"

    @Option(name: .long, help: "Output ACPF path. Defaults to ModelContainer.profileURL(family:).")
    var output: String?

    @Flag(name: .long, help: "Overwrite an existing profile if one is already at --output.")
    var force: Bool = false

    @Flag(name: .long, help: "Run the full pipeline without writing the output file.")
    var dryRun: Bool = false

    @Option(name: .long, help: "Optional JSON summary file with the flag histogram and stats.")
    var report: String?

    func run() async throws {
        let reporter = ConsoleReporter()
        let ggufURL = try resolveGGUFURL()
        let outputURL = try resolveOutputURL()

        if !force && FileManager.default.fileExists(atPath: outputURL.path) {
            throw ACPFCLIError.outputExists(path: outputURL.path)
        }

        reporter.start(gguf: ggufURL, output: outputURL, family: family, dryRun: dryRun)

        let runtime = try LlamaModelRuntime(modelURL: ggufURL, contextLength: 256, reuseThreshold: 0)
        let introspector = runtime.makeIntrospector()
        let summary = try BuildProfile.run(
            introspector: introspector,
            family: family,
            output: dryRun ? nil : outputURL,
            reporter: reporter
        )

        if let reportPath = report {
            let reportURL = URL(fileURLWithPath: reportPath)
            try summary.writeJSON(to: reportURL)
            reporter.wroteReport(at: reportURL)
        }

        reporter.finish(summary: summary)
    }

    private func resolveGGUFURL() throws -> URL {
        if let g = gguf { return URL(fileURLWithPath: g) }
        return try ModelContainer.modelURL()
    }

    private func resolveOutputURL() throws -> URL {
        if let o = output { return URL(fileURLWithPath: o) }
        return try ModelContainer.profileURL(family: family, create: true)
    }
}
