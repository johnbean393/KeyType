import Foundation
import TokenProfiles

/// Friendly logger used by the CLI to surface pipeline progress + final summary. Pulled
/// out so the orchestrator stays focused on the pipeline and tests can supply a quiet
/// (no-op) reporter.
public final class ConsoleReporter {
    public var isQuiet: Bool

    public init(isQuiet: Bool = false) {
        self.isQuiet = isQuiet
    }

    public func start(gguf: URL, output: URL, family: String, dryRun: Bool) {
        start(source: gguf, sourceLabel: "gguf", output: output, family: family, dryRun: dryRun)
    }

    public func start(source: URL, sourceLabel: String, output: URL, family: String, dryRun: Bool) {
        log("acpf-build: family=\(family)")
        log("  \(sourceLabel):   \(source.path)")
        log("  output: \(dryRun ? "[dry-run]" : output.path)")
    }

    public func classifying(vocabSize: Int) {
        log("classifying \(vocabSize) tokens…")
    }

    public func classifyProgress(done: Int, total: Int) {
        guard total > 0 else { return }
        let pct = Int(Double(done) / Double(total) * 100)
        log("  \(done) / \(total) (\(pct)%)")
    }

    public func computingTokenizerDigest() {
        log("hashing tokenizer vocabulary…")
    }

    public func encoding() {
        log("building trie + sections + encoding…")
    }

    public func encoded(bytes: Int) {
        log("  encoded \(bytes) bytes")
    }

    public func wrote(at url: URL, bytes: Int) {
        log("wrote \(bytes) bytes to \(url.path)")
    }

    public func selfChecking() {
        log("running ProfileSelfCheck…")
    }

    public func selfCheckCompleted(report: ProfileSelfCheck.Report) {
        if report.isSuccess {
            log("  self-check OK (\(report.checksRun.count) checks)")
        } else {
            log("  self-check FAILED (\(report.failures.count) of \(report.checksRun.count) checks)")
            for f in report.failures {
                log("    \(f)")
            }
        }
    }

    public func wroteReport(at url: URL) {
        log("wrote summary JSON to \(url.path)")
    }

    public func finish(summary: BuildSummary) {
        log("done.")
        log("  vocab:           \(summary.vocabSize)")
        log("  bytes blob:      \(summary.bytesBlobSize)")
        log("  trie nodes:      \(summary.trieNodeCount)")
        log("  trie edges:      \(summary.trieEdgeCount)")
        log("  file size:       \(summary.fileSize)")
        log("  tokenizer hash:  \(summary.tokenizerDigestHexPrefix)")
        if summary.ggufMetadataDigest.isEmpty {
            log("  source meta hash: unavailable for this backend")
        } else {
            log("  gguf meta hash:  \(summary.ggufMetadataDigest.prefix(16))")
        }
        log("  flag histogram:")
        for (name, count) in summary.flagHistogram.sorted(by: { $0.key < $1.key }) {
            log("    \(name): \(count)")
        }
        log("  bias overrides:")
        for (name, count) in summary.biasOverrideCounts.sorted(by: { $0.key < $1.key }) {
            log("    \(name): \(count)")
        }
    }

    private func log(_ message: String) {
        if !isQuiet { print(message) }
    }
}
