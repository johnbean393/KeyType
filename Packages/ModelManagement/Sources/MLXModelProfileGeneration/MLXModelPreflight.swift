import AutocompleteCore
import Foundation
import MLXModelRuntime
import ModelManagement
import ModelRuntime
import ProfileBuilderCore
import TokenProfiles

/// The live, validated assets needed by the constrained decoder. Keeping the runtime alive here
/// transfers ownership to the engine; callers must not create a second runtime for the same bundle.
public struct PreparedMLXModel {
    public let runtime: MLXLocalModelRuntime
    public let profile: MmapAutocompleteProfile
    public let family: String

    init(runtime: MLXLocalModelRuntime, profile: MmapAutocompleteProfile, family: String) {
        self.runtime = runtime
        self.profile = profile
        self.family = family
    }
}

/// Validates a catalog bundle against the live MLX tokenizer and produces the ACPF profile used by
/// KeyType's hot decoder. It is intentionally the last setup gate: a downloaded directory is never
/// selectable until hashes, tokenizer identity, FIM markers, profile, and a small inference run pass.
public enum MLXModelPreflight {
    public enum PreflightError: Error, Equatable, CustomStringConvertible {
        case tokenizerDigestMismatch(expected: String, found: String)
        case missingFIMMarker(String)

        public var description: String {
            switch self {
            case let .tokenizerDigestMismatch(expected, found):
                return "MLX tokenizer identity changed (expected \(expected), found \(found))."
            case let .missingFIMMarker(marker):
                return "MLX model does not expose required FIM marker \(marker)."
            }
        }
    }

    public static func prepare(
        _ model: SupportedMLXModel,
        directory: URL? = nil
    ) async throws -> PreparedMLXModel {
        let directory = try directory ?? ModelContainer.mlxModelDirectoryURL(identifier: model.id)
        try ModelBundleValidator.validate(directory: directory, manifest: model)

        let runtime = try await MLXModelLoader.load(modelDirectory: directory, family: model.tokenizerFamily)
        do {
            let digest = try runtime.mlxTokenizer.tokenizerDigest().hex
            guard digest == model.expectedTokenizerDigest else {
                throw PreflightError.tokenizerDigestMismatch(expected: model.expectedTokenizerDigest, found: digest)
            }
            try validateFIMMarkers(runtime)
            let profile = try buildOrOpenProfile(runtime: runtime, model: model)

            // A small actual inference catches invalid weights/configuration that a tokenizer-only
            // validation cannot. It is not a quality benchmark.
            let probe = try runtime.tokenizer.tokenize("KeyType")
            try await runtime.prepare(promptTokens: probe)
            guard !(try await runtime.logitsForNextToken()).isEmpty else {
                throw MLXRuntimeError.emptyPrepareResult
            }
            await runtime.resetKVCache()
            return PreparedMLXModel(runtime: runtime, profile: profile, family: model.tokenizerFamily)
        } catch {
            await runtime.shutdown()
            throw error
        }
    }

    public static func shutdown(_ prepared: PreparedMLXModel) async {
        await prepared.runtime.shutdown()
    }

    private static func validateFIMMarkers(_ runtime: MLXLocalModelRuntime) throws {
        for marker in ["<|fim_prefix|>", "<|fim_middle|>", "<|fim_suffix|>"] {
            let tokenIDs = try runtime.mlxTokenizer.tokenizeAllowingSpecial(marker)
            guard tokenIDs.count == 1, runtime.mlxTokenizer.isSpecialToken(tokenIDs[0]) else {
                throw PreflightError.missingFIMMarker(marker)
            }
        }
    }

    private static func buildOrOpenProfile(
        runtime: MLXLocalModelRuntime,
        model: SupportedMLXModel
    ) throws -> MmapAutocompleteProfile {
        let outputURL = try ModelContainer.profileURL(family: model.tokenizerFamily, create: true)
        let introspector = MLXVocabIntrospector(runtime: runtime)
        if let profile = try? MmapAutocompleteProfile.open(
            at: outputURL,
            tokenizerVocabSize: runtime.metadata.vocabularySize,
            tokenizerBytes: { try introspector.bytes(for: $0) },
            expectedModelFamily: model.tokenizerFamily
        ) {
            return profile
        }

        let temporaryURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).mlx-building-\(UUID().uuidString)")
        do {
            try BuildProfile.run(
                introspector: introspector,
                family: model.tokenizerFamily,
                output: temporaryURL,
                reporter: ConsoleReporter(isQuiet: true)
            )
            let profile = try MmapAutocompleteProfile.open(
                at: temporaryURL,
                tokenizerVocabSize: runtime.metadata.vocabularySize,
                tokenizerBytes: { try introspector.bytes(for: $0) },
                expectedModelFamily: model.tokenizerFamily
            )
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
            return profile
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }
}
