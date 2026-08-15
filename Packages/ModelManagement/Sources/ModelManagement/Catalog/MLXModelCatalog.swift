import Foundation

/// Narrow, maintained MLX catalog. Each entry is a curated MLX Community conversion of the
/// post-trained Qwen checkpoint named by its public model card; it is not a Qwen-published MLX
/// bundle or a Base checkpoint.
public enum MLXModelCatalog {
    /// Measured from each pinned bundle through the same MLX loader used by the app. The three
    /// launch manifests match exactly; setup still checks the live value before reusing ACPF.
    private static let qwenTokenizerDigest = "a5ef0db942b70a225a6ca8f8b4e5fe80"
    private static let qwenFamily = "qwen3-v151936"
    private static let gibibyte: UInt64 = 1_073_741_824
    private static let baseline = ModelTuningPreset(
        maxPromptTokens: 2_048,
        topK: 64,
        topP: 0.95,
        temperature: 0.8,
        branchWidth: 2,
        relativeCutoff: 6,
        minimumBranchProbability: 0.02,
        enableFillInMiddle: true,
        fimMaxPrefixTokens: 256,
        fimMaxSuffixTokens: 64
    )

    public static let models: [SupportedMLXModel] = [
        model(
            id: "Qwen3.5-0.8B-MLX-6bit",
            displayName: "Qwen 3.5 0.8B — MLX 6-bit",
            label: "Fastest",
            detail: "Smallest download and memory requirement.",
            size: "0.8 GB",
            memory: 8 * gibibyte,
            repository: "mlx-community/Qwen3.5-0.8B-6bit",
            revision: "779b383518183ae3af13b26a5cdc829a26f7c937",
            files: [
                file("config.json", 3_112, "8ac4ca37b3f5bd2fe8702031d4799ab924fe0e082b3fc3b359c252fe1220a7cf"),
                file("model.safetensors", 813_203_247, "24e8db49de3a266ff8d3a0aa7277244c44982ad9f78584923500de46b0bfb8fe"),
                file("model.safetensors.index.json", 71_473, "bd9776bff0f7aea1622aee7af20e4fc2b5e45d63ff0fd95709cdc571b2098a93")
            ] + tokenizerFiles
        ),
        model(
            id: "Qwen3.5-2B-MLX-4bit",
            displayName: "Qwen 3.5 2B — MLX 4-bit",
            label: "Recommended",
            detail: "Recommended for a 24 GB M5 Pro.",
            size: "1.7 GB",
            memory: 12 * gibibyte,
            repository: "mlx-community/Qwen3.5-2B-MLX-4bit",
            revision: "93760be4f1f69842a46bc13dbdc0f19e291392a3",
            files: [
                file("config.json", 3_113, "beb7fc5a6e0405fe332821cf1a8ef7b69bb390a8c8933171647de5579debf949"),
                file("model.safetensors", 1_722_271_785, "713fe7e5d3c3965f7106b0d0ee17615f7869c23c8d327996df8c1196fbcf07d5"),
                file("model.safetensors.index.json", 81_722, "8294c05cca7d53a6c33e3db2b379539bd296d054e0b689711b16b6ac93c7e49d")
            ] + tokenizerFiles
        ),
        model(
            id: "Qwen3.5-4B-MLX-4bit",
            displayName: "Qwen 3.5 4B — MLX 4-bit",
            label: "Higher capacity",
            detail: "Larger bundle; measured against the matching GGUF variant.",
            size: "3.1 GB",
            memory: 18 * gibibyte,
            repository: "mlx-community/Qwen3.5-4B-MLX-4bit",
            revision: "32f3e8ecf65426fc3306969496342d504bfa13f3",
            files: [
                file("config.json", 3_366, "f3efc81b2ea8d96a45301037d3ccccbcccdef44a961845c87f286aaddbc6eaaa"),
                file("model.safetensors", 3_034_300_695, "5fb9acd0246866381cf8c5c354c6db1019f6498eec4ccb4f5edcc71ffeacb2db"),
                file("model.safetensors.index.json", 101_944, "52e534c41f7b97708329c85f762e5882bf48bd5955a422c6ae74eba321e6048a")
            ] + tokenizerFiles
        )
    ]

    public static func model(id: String) -> SupportedMLXModel? {
        models.first { $0.id == id }
    }

    /// Hardware-filtered catalog for the UI. The full immutable manifest list remains available
    /// above for validation and tooling, while an undersized Mac is never invited to download a
    /// bundle that cannot meet its declared memory floor.
    public enum Architecture: Equatable, Sendable {
        case arm64
        case x86_64
    }

    public static var currentArchitecture: Architecture {
        #if arch(arm64)
        .arm64
        #else
        .x86_64
        #endif
    }

    public static func models(
        forPhysicalMemoryBytes memory: UInt64 = ProcessInfo.processInfo.physicalMemory,
        architecture: Architecture = currentArchitecture
    ) -> [SupportedMLXModel] {
        guard architecture == .arm64 else { return [] }
        return models.filter { memory >= $0.minimumPhysicalMemoryBytes }
    }

    public static func recommended(
        forPhysicalMemoryBytes memory: UInt64 = ProcessInfo.processInfo.physicalMemory,
        architecture: Architecture = currentArchitecture
    ) -> SupportedMLXModel? {
        let available = models(forPhysicalMemoryBytes: memory, architecture: architecture)
        return available.first { $0.onboardingLabel == "Recommended" } ?? available.first
    }

    private static let tokenizerFiles = [
        file("tokenizer.json", 19_989_343, "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
        file("tokenizer_config.json", 1_139, "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182"),
        file("vocab.json", 6_722_759, "ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003")
    ]

    private static func file(_ path: String, _ bytes: Int64, _ hash: String) -> VerifiedModelBundleFile {
        VerifiedModelBundleFile(relativePath: path, expectedSizeBytes: bytes, sha256: hash)
    }

    private static func model(
        id: String, displayName: String, label: String, detail: String, size: String, memory: UInt64,
        repository: String, revision: String, files: [VerifiedModelBundleFile]
    ) -> SupportedMLXModel {
        return SupportedMLXModel(
            id: id, displayName: displayName, onboardingLabel: label, detail: detail,
            approximateDownloadSizeLabel: size, minimumPhysicalMemoryBytes: memory,
            sourceRepository: repository, immutableRevision: revision,
            sourceModelRepository: "Qwen/Qwen3.5-\(id.contains("0.8B") ? "0.8B" : id.contains("2B") ? "2B" : "4B")",
            requiredFiles: files,
            expectedTokenizerDigest: qwenTokenizerDigest, tokenizerFamily: qwenFamily,
            quantization: id.contains("6bit") ? "6-bit" : "4-bit", tuningPreset: baseline,
            validationVersion: 1
        )
    }
}
