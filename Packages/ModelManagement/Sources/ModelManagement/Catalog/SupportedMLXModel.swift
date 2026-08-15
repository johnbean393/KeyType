import Foundation
import ModelRuntime

/// One immutable file in a curated MLX bundle. A catalog entry is intentionally closed over this
/// exact list: extra files are harmless, but a missing or changed required file never becomes ready.
public struct VerifiedModelBundleFile: Equatable, Hashable, Sendable {
    public let relativePath: String
    public let expectedSizeBytes: Int64
    public let sha256: String

    public init(relativePath: String, expectedSizeBytes: Int64, sha256: String) {
        self.relativePath = relativePath
        self.expectedSizeBytes = expectedSizeBytes
        self.sha256 = sha256
    }
}

/// Decoder launch baseline. It preserves KeyType's existing decoder behavior; it is deliberately
/// not presented as a per-model optimization. MTP is absent because it is not a supported path.
public struct ModelTuningPreset: Equatable, Sendable {
    public let maxPromptTokens: Int
    public let topK: Int
    public let topP: Float
    public let temperature: Float
    public let branchWidth: Int
    public let relativeCutoff: Float
    public let minimumBranchProbability: Float
    public let enableFillInMiddle: Bool
    public let fimMaxPrefixTokens: Int
    public let fimMaxSuffixTokens: Int

    public init(
        maxPromptTokens: Int,
        topK: Int,
        topP: Float,
        temperature: Float,
        branchWidth: Int,
        relativeCutoff: Float,
        minimumBranchProbability: Float,
        enableFillInMiddle: Bool,
        fimMaxPrefixTokens: Int,
        fimMaxSuffixTokens: Int
    ) {
        self.maxPromptTokens = maxPromptTokens
        self.topK = topK
        self.topP = topP
        self.temperature = temperature
        self.branchWidth = branchWidth
        self.relativeCutoff = relativeCutoff
        self.minimumBranchProbability = minimumBranchProbability
        self.enableFillInMiddle = enableFillInMiddle
        self.fimMaxPrefixTokens = fimMaxPrefixTokens
        self.fimMaxSuffixTokens = fimMaxSuffixTokens
    }
}

public struct SupportedMLXModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let onboardingLabel: String
    public let detail: String
    public let approximateDownloadSizeLabel: String
    public let minimumPhysicalMemoryBytes: UInt64
    public let sourceRepository: String
    public let immutableRevision: String
    /// The Qwen model card named by the MLX conversion's own model card.
    public let sourceModelRepository: String
    public let requiredFiles: [VerifiedModelBundleFile]
    public let expectedTokenizerDigest: String
    public let tokenizerFamily: String
    public let quantization: String
    public let tuningPreset: ModelTuningPreset
    public let validationVersion: Int

    public init(
        id: String,
        displayName: String,
        onboardingLabel: String,
        detail: String,
        approximateDownloadSizeLabel: String,
        minimumPhysicalMemoryBytes: UInt64,
        sourceRepository: String,
        immutableRevision: String,
        sourceModelRepository: String,
        requiredFiles: [VerifiedModelBundleFile],
        expectedTokenizerDigest: String,
        tokenizerFamily: String,
        quantization: String,
        tuningPreset: ModelTuningPreset,
        validationVersion: Int
    ) {
        self.id = id
        self.displayName = displayName
        self.onboardingLabel = onboardingLabel
        self.detail = detail
        self.approximateDownloadSizeLabel = approximateDownloadSizeLabel
        self.minimumPhysicalMemoryBytes = minimumPhysicalMemoryBytes
        self.sourceRepository = sourceRepository
        self.immutableRevision = immutableRevision
        self.sourceModelRepository = sourceModelRepository
        self.requiredFiles = requiredFiles
        self.expectedTokenizerDigest = expectedTokenizerDigest.lowercased()
        self.tokenizerFamily = tokenizerFamily
        self.quantization = quantization
        self.tuningPreset = tuningPreset
        self.validationVersion = validationVersion
    }

    public var directoryURL: URL? {
        try? ModelContainer.mlxModelDirectoryURL(identifier: id)
    }

    public var minimumMemoryLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(minimumPhysicalMemoryBytes), countStyle: .memory)
    }

    public var downloadURLs: [(VerifiedModelBundleFile, URL)] {
        requiredFiles.compactMap { file in
            URL(string: "https://huggingface.co/\(sourceRepository)/resolve/\(immutableRevision)/\(file.relativePath)?download=true")
                .map { (file, $0) }
        }
    }
}
