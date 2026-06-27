import Foundation
import ModelRuntime

/// The fixed set of base models KeyType offers in onboarding + Settings.
///
/// KeyType is a base-model continuation product (see `docs/00-overview.md`), so every entry here
/// is an un-instruct-tuned base model. Each entry now pins a concrete Hugging Face download URL and
/// is `.available`; byte size and SHA-256 are pinned where known (`nil` skips that post-download
/// check). The `.unverified` case stays in `Availability` for any future entry whose artifact has
/// not been located — we never fabricate a URL or checksum.
public enum RuntimeModelCatalog {

    /// Builds a Hugging Face direct-download URL from a `repo` and `file`. The catalog is authored
    /// with `huggingface.co`; `ModelDownloadManager` transparently retries against `hf-mirror.com`
    /// when that host is unreachable.
    private static func huggingFaceURL(repo: String, file: String) -> URL? {
        URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)?download=true")
    }

    /// Qwen3.5 base models share the Qwen3 tokenizer (vocab 151936). Keeping this family string
    /// equal to the value the pipeline historically hardcoded means any ACPF profile already on disk
    /// for the default 2B model keeps loading without a rebuild.
    public static let qwenFamily = "qwen3-v151936"
    /// Gemma "E2B/E4B" share the Gemma tokenizer. The vocab-size suffix is a label only; the ACPF
    /// builder stamps whatever family string we pass, so consistency (not the exact number) is what
    /// the runtime validates.
    public static let gemmaFamily = "gemma-v262144"
    /// LFM2.5 models use the LiquidAI LFM tokenizer. The upstream base config declares a 128k vocab.
    public static let lfm25Family = "lfm2.5-v128000"
    /// The LFM2.5 8B MoE GGUF is only offered on Macs with at least 24 GiB of physical memory.
    public static let lfm25MinimumPhysicalMemoryBytes: UInt64 = 24 * 1_073_741_824

    /// Every curated model, including entries that may be hidden on the current hardware.
    public static let allModels: [DownloadableRuntimeModel] = [
        DownloadableRuntimeModel(
            displayName: "Qwen3.5 0.8B Base",
            detail: "Smallest and fastest. Good on any Apple silicon Mac.",
            filename: "Qwen3.5-0.8B-Base.i1-Q6_K.gguf",
            tokenizerFamily: qwenFamily,
            approximateSizeLabel: "~0.8 GB",
            expectedSizeBytes: nil,
            sha256: nil,
            downloadURL: huggingFaceURL(
                repo: "mradermacher/Qwen3.5-0.8B-Base-i1-GGUF",
                file: "Qwen3.5-0.8B-Base.i1-Q6_K.gguf"
            ),
            availability: .available
        ),
        DownloadableRuntimeModel(
            displayName: "Qwen3.5 2B Base",
            detail: "Balanced quality and speed. The recommended default.",
            // Matches `ModelContainer.defaultModelFilename`, so the default model is detected as
            // already-installed by this catalog entry.
            filename: ModelContainer.defaultModelFilename,
            tokenizerFamily: qwenFamily,
            approximateSizeLabel: "~1.4 GB",
            expectedSizeBytes: nil,
            sha256: nil,
            downloadURL: huggingFaceURL(
                repo: "mradermacher/Qwen3.5-2B-Base-i1-GGUF",
                file: "Qwen3.5-2B-Base.i1-Q4_K_M.gguf"
            ),
            availability: .available
        ),
        DownloadableRuntimeModel(
            displayName: "Qwen3.5 4B Base",
            detail: "Higher quality completions. Needs more memory and is slower per token.",
            filename: "Qwen3.5-4B-Base.i1-Q4_K_M.gguf",
            tokenizerFamily: qwenFamily,
            approximateSizeLabel: "~2.6 GB",
            expectedSizeBytes: nil,
            sha256: nil,
            downloadURL: huggingFaceURL(
                repo: "mradermacher/Qwen3.5-4B-Base-i1-GGUF",
                file: "Qwen3.5-4B-Base.i1-Q4_K_M.gguf"
            ),
            availability: .available
        ),
        DownloadableRuntimeModel(
            displayName: "Gemma 4 E2B",
            detail: "Google Gemma base model, compact effective-2B variant.",
            filename: "gemma-4-E2B.i1-Q6_K.gguf",
            tokenizerFamily: gemmaFamily,
            approximateSizeLabel: "~4.5 GB",
            expectedSizeBytes: nil,
            sha256: nil,
            downloadURL: huggingFaceURL(
                repo: "mradermacher/gemma-4-E2B-i1-GGUF",
                file: "gemma-4-E2B.i1-Q6_K.gguf"
            ),
            availability: .available
        ),
        DownloadableRuntimeModel(
            displayName: "Gemma 4 E4B",
            detail: "Largest option. Best quality, highest memory and latency cost.",
            filename: "gemma-4-E4B.i1-Q4_K_M.gguf",
            tokenizerFamily: gemmaFamily,
            approximateSizeLabel: "~5.0 GB",
            expectedSizeBytes: nil,
            sha256: nil,
            downloadURL: huggingFaceURL(
                repo: "mradermacher/gemma-4-E4B-i1-GGUF",
                file: "gemma-4-E4B.i1-Q4_K_M.gguf"
            ),
            availability: .available
        ),
        DownloadableRuntimeModel(
            displayName: "LFM2.5 8B A1B Base",
            detail: "Liquid AI MoE base model for Macs with 24 GB RAM or more.",
            filename: "LFM2.5-8B-A1B-Base-Q4_K_M.gguf",
            tokenizerFamily: lfm25Family,
            approximateSizeLabel: "~5.2 GB",
            expectedSizeBytes: 5_155_564_416,
            sha256: "304496159b83de5b300daa94283f8f1c145d69785aaa1994a4957ec734f653ec",
            downloadURL: huggingFaceURL(
                repo: "johnbean393/LFM2.5-8B-A1B-Base-GGUF",
                file: "LFM2.5-8B-A1B-Base-Q4_K_M.gguf"
            ),
            availability: .available,
            minimumPhysicalMemoryBytes: lfm25MinimumPhysicalMemoryBytes
        )
    ]

    /// Models offered on this Mac.
    public static var models: [DownloadableRuntimeModel] {
        models(forPhysicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
    }

    /// Models offered for a specific physical-memory amount. Exposed for deterministic tests.
    public static func models(forPhysicalMemoryBytes physicalMemoryBytes: UInt64) -> [DownloadableRuntimeModel] {
        allModels.filter { model in
            guard let minimum = model.minimumPhysicalMemoryBytes else { return true }
            return physicalMemoryBytes >= minimum
        }
    }

    /// Catalog entry whose GGUF filename matches `filename`, if any.
    public static func model(forFilename filename: String) -> DownloadableRuntimeModel? {
        allModels.first { $0.filename == filename }
    }

    /// The recommended default selection in onboarding.
    public static var recommended: DownloadableRuntimeModel {
        model(forFilename: ModelContainer.defaultModelFilename) ?? models[0]
    }
}
