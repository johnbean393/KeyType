import AutocompleteCore
import Foundation
import ModelRuntime
import TokenProfiles

/// Summary metrics emitted at the end of a build. Surfaced both on the CLI report and as
/// a JSON file when `--report` is passed.
public struct BuildSummary: Codable, Equatable {
    public var family: String
    public var vocabSize: Int
    public var bytesBlobSize: Int
    public var trieNodeCount: Int
    public var trieEdgeCount: Int
    public var fileSize: Int
    public var tokenizerDigestHexPrefix: String
    public var ggufMetadataDigest: String
    public var flagHistogram: [String: Int]
    public var biasOverrideCounts: [String: Int]

    public func writeJSON(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: [.atomic])
    }
}

/// Pipeline orchestrator. Pure-ish — takes a `VocabIntrospecting`, a destination URL, and
/// a reporter; produces a `BuildSummary`. Unit tests can drive it with a synthetic
/// introspector if needed; the GGUF and MLX CLIs provide backend-specific implementations.
public enum BuildProfile {

    /// Build a profile and optionally write it to disk. Returns the summary, including
    /// post-write `ProfileSelfCheck` results.
    @discardableResult
    public static func run(
        introspector: any VocabIntrospecting,
        family: String,
        output: URL?,
        reporter: ConsoleReporter,
        buildTimestamp: Date = Date(),
        builderHost: String = Host.current().localizedName ?? ""
    ) throws -> BuildSummary {
        let n = introspector.vocabSize
        reporter.classifying(vocabSize: n)

        // 1. Classify every token + run the static-bias policy.
        var entries = [ACPFTokenEntry]()
        entries.reserveCapacity(n)
        var flagHistogram: [String: Int] = [:]
        for id in 0..<n {
            let tokenID = TokenID(id)
            let probe = try introspector.probe(for: tokenID)
            let cls = TokenClassifier.classify(probe)
            let staticBias = BiasPolicy.staticBias(flags: cls.flags, displayWidth: cls.displayWidth, bytes: probe.bytes)
            entries.append(ACPFTokenEntry(
                tokenID: tokenID,
                bytes: probe.bytes,
                flags: cls.flags,
                staticBias: staticBias,
                displayWidth: cls.displayWidth,
                tokenType: cls.tokenType
            ))
            for flag in TokenProfileFlagsReporting.named(cls.flags) {
                flagHistogram[flag, default: 0] += 1
            }
            if id % 5000 == 0 && id > 0 {
                reporter.classifyProgress(done: id, total: n)
            }
        }
        reporter.classifyProgress(done: n, total: n)

        // 2. Compute tokenizer digest.
        reporter.computingTokenizerDigest()
        let digest = try ACPFTokenizerDigest.digest(vocabSize: n) { id in
            try introspector.bytes(for: id)
        }

        // 3. Pack profile input.
        let ggufDigest = introspector.ggufMetadataDigest()
        let input = ACPFProfileInput(
            modelFamily: family,
            vocabSize: n,
            tokenizerDigest: digest,
            entries: entries,
            ggufMetadataDigest: ggufDigest,
            generatorVersion: ACPF.generatorVersion,
            builderHost: builderHost,
            buildTimestamp: buildTimestamp
        )

        // 4. Encode.
        reporter.encoding()
        let data = try ACPFWriter.encode(input)
        reporter.encoded(bytes: data.count)

        // 5. Optionally write and re-open for self-check.
        if let output = output {
            try data.write(to: output, options: [.atomic])
            reporter.wrote(at: output, bytes: data.count)
            let profile = try MmapAutocompleteProfile.open(
                at: output,
                expectedVocabSize: n,
                expectedModelFamily: family,
                expectedTokenizerDigest: digest
            )
            try runSelfCheck(profile: profile, introspector: introspector, reporter: reporter)
            // Build the summary from the on-disk profile so the reported counts match
            // what the runtime will actually see.
            return makeSummary(
                profile: profile,
                family: family,
                fileSize: data.count,
                ggufDigest: ggufDigest,
                flagHistogram: flagHistogram,
                input: input
            )
        }

        // Dry-run: build summary from in-memory data.
        let profile = try MmapAutocompleteProfile(data: data)
        try runSelfCheck(profile: profile, introspector: introspector, reporter: reporter)
        return makeSummary(
            profile: profile,
            family: family,
            fileSize: data.count,
            ggufDigest: ggufDigest,
            flagHistogram: flagHistogram,
            input: input
        )
    }

    // MARK: - Self-check

    private static func runSelfCheck(
        profile: MmapAutocompleteProfile,
        introspector: any VocabIntrospecting,
        reporter: ConsoleReporter
    ) throws {
        reporter.selfChecking()
        let report = ProfileSelfCheck.runAll(on: profile) { id in
            try introspector.bytes(for: id)
        }
        reporter.selfCheckCompleted(report: report)
        if !report.isSuccess {
            throw ACPFCLIError.selfCheckFailed(failures: report.failures)
        }
    }

    // MARK: - Summary builder

    private static func makeSummary(
        profile: MmapAutocompleteProfile,
        family: String,
        fileSize: Int,
        ggufDigest: String,
        flagHistogram: [String: Int],
        input: ACPFProfileInput
    ) -> BuildSummary {
        var biasOverrideCounts: [String: Int] = [:]
        for mode in BiasMode.allCases {
            var count = 0
            for entry in input.entries {
                let delta = BiasPolicy.delta(flags: entry.flags, mode: mode, bytes: entry.bytes)
                if delta != 0 { count += 1 }
            }
            biasOverrideCounts[String(describing: mode)] = count
        }
        return BuildSummary(
            family: family,
            vocabSize: profile.vocabularySize,
            bytesBlobSize: profile.bytesSectionLength,
            trieNodeCount: profile.trieNodeCountValue,
            trieEdgeCount: profile.trieEdgeCountValue,
            fileSize: fileSize,
            tokenizerDigestHexPrefix: profile.tokenizerDigest.hexPrefix,
            ggufMetadataDigest: ggufDigest,
            flagHistogram: flagHistogram,
            biasOverrideCounts: biasOverrideCounts
        )
    }
}

/// Maps `TokenProfileFlags` bits to human-readable names for the histogram.
enum TokenProfileFlagsReporting {
    static func named(_ flags: TokenProfileFlags) -> [String] {
        var out: [String] = []
        if flags.contains(.special) { out.append("special") }
        if flags.contains(.excluded) { out.append("excluded") }
        if flags.contains(.stop) { out.append("stop") }
        if flags.contains(.whitespace) { out.append("whitespace") }
        if flags.contains(.newline) { out.append("newline") }
        if flags.contains(.punctuation) { out.append("punctuation") }
        if flags.contains(.sentenceEnd) { out.append("sentenceEnd") }
        if flags.contains(.emoji) { out.append("emoji") }
        if flags.contains(.chatMarker) { out.append("chatMarker") }
        if flags.contains(.invalidUTF8) { out.append("invalidUTF8") }
        if flags.contains(.wordStart) { out.append("wordStart") }
        if flags.contains(.wordContinuation) { out.append("wordContinuation") }
        if out.isEmpty { out.append("none") }
        return out
    }
}
