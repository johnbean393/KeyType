import Foundation

/// One model in KeyType's downloadable catalog.
///
/// A model is fully described by the GGUF it downloads plus the tokenizer family its ACPF
/// profile is stamped with. Weights are never bundled with the app (see `ModelContainer`); they
/// are fetched on demand into the per-user Models directory.
public struct DownloadableRuntimeModel: Identifiable, Equatable, Sendable {

    /// Whether this catalog entry can actually be downloaded yet.
    ///
    /// The catalog deliberately lists the product-chosen models even before their concrete
    /// Hugging Face GGUF URL / size / SHA-256 have been pinned. Such entries are surfaced in the
    /// UI but cannot be downloaded — we never invent a URL or checksum.
    public enum Availability: Equatable, Sendable {
        case available
        case unverified(reason: String)
    }

    public let id: String
    public let displayName: String
    public let detail: String
    /// On-disk GGUF filename inside the Models directory.
    public let filename: String
    /// Tokenizer family stamped into the model's ACPF profile (`<family>.acpf.bin`). Models that
    /// share a tokenizer share a family (e.g. every Qwen3.5 base size).
    public let tokenizerFamily: String
    public let approximateSizeLabel: String
    /// Expected byte size of the downloaded GGUF, used for a sanity check after download.
    public let expectedSizeBytes: Int64?
    /// Lowercase hex SHA-256 of the downloaded GGUF, verified before the file is committed.
    public let sha256: String?
    public let downloadURL: URL?
    public let availability: Availability
    /// Minimum physical memory required for this model to appear in the guided catalog.
    public let minimumPhysicalMemoryBytes: UInt64?

    public init(
        displayName: String,
        detail: String,
        filename: String,
        tokenizerFamily: String,
        approximateSizeLabel: String,
        expectedSizeBytes: Int64?,
        sha256: String?,
        downloadURL: URL?,
        availability: Availability,
        minimumPhysicalMemoryBytes: UInt64? = nil
    ) {
        self.id = filename
        self.displayName = displayName
        self.detail = detail
        self.filename = filename
        self.tokenizerFamily = tokenizerFamily
        self.approximateSizeLabel = approximateSizeLabel
        self.expectedSizeBytes = expectedSizeBytes
        self.sha256 = sha256
        self.downloadURL = downloadURL
        self.availability = availability
        self.minimumPhysicalMemoryBytes = minimumPhysicalMemoryBytes
    }

    /// `true` only when the entry has a real download URL and has been marked available.
    public var isDownloadable: Bool {
        downloadURL != nil && availability == .available
    }

    /// A human-readable reason the entry can't be downloaded, or `nil` when it can.
    public var unavailableReason: String? {
        switch availability {
        case .available:
            return downloadURL == nil ? "Download URL not configured yet." : nil
        case let .unverified(reason):
            return reason
        }
    }
}
