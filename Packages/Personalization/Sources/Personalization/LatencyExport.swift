import Foundation

/// Self-describing on-device latency export. Designed to be sent to the KeyType maintainers as a
/// single file so we can correlate the latency tail a user is seeing against their machine, OS,
/// model choice, and current telemetry counters — without ever leaving the device unless the user
/// explicitly chooses to share it. See ADR-070.
///
/// Privacy notes:
/// - Carries only non-text counters, the GGUF model filename, and timing samples. No captured user
///   text, no per-app identifiers, no clipboard or OCR content.
/// - Schema is versioned so an offline analyzer can route through the right decoder when fields are
///   added, renamed, or removed in future builds.
public struct LatencyExport: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var exportedAt: Date
    public var device: LatencyExportDeviceInfo
    public var engine: LatencyExportEngineInfo
    public var counters: LatencyExportCounters
    /// Raw end-to-end samples with the four phase deltas, ordered oldest-first within the bounded
    /// reservoir. Suitable for re-running `EndToEndLatencyStats` analysis offline or for plotting.
    public var endToEndSamples: [CompletionLatencySample]
    /// Raw decoder-only latencies (the `engine.completions(...)` segment), retained because
    /// `ThresholdTuner` and the adaptive debounce already use this number — useful when correlating
    /// a slow `total` against pure model time.
    public var decoderLatenciesMillis: [Double]

    public init(
        schemaVersion: Int,
        exportedAt: Date,
        device: LatencyExportDeviceInfo,
        engine: LatencyExportEngineInfo,
        counters: LatencyExportCounters,
        endToEndSamples: [CompletionLatencySample],
        decoderLatenciesMillis: [Double]
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.device = device
        self.engine = engine
        self.counters = counters
        self.endToEndSamples = endToEndSamples
        self.decoderLatenciesMillis = decoderLatenciesMillis
    }
}

/// Hardware + OS context behind a latency sample. Collected by the app target (which has access to
/// `ProcessInfo`, `sysctlbyname`, and `Bundle.main`) and passed in to `LatencyExporter`.
public struct LatencyExportDeviceInfo: Codable, Equatable, Sendable {
    public var osVersion: String
    public var machineModel: String?
    public var cpuBrand: String?
    public var physicalMemoryBytes: UInt64
    public var processorCount: Int
    public var appVersion: String?
    public var appBuild: String?

    public init(
        osVersion: String,
        machineModel: String? = nil,
        cpuBrand: String? = nil,
        physicalMemoryBytes: UInt64,
        processorCount: Int,
        appVersion: String? = nil,
        appBuild: String? = nil
    ) {
        self.osVersion = osVersion
        self.machineModel = machineModel
        self.cpuBrand = cpuBrand
        self.physicalMemoryBytes = physicalMemoryBytes
        self.processorCount = processorCount
        self.appVersion = appVersion
        self.appBuild = appBuild
    }
}

/// Engine/decoder context behind a latency sample — different models and length presets produce
/// very different `generation` percentiles, so analysing latency without this is misleading.
public struct LatencyExportEngineInfo: Codable, Equatable, Sendable {
    public var modelFilename: String?
    public var completionLengthLabel: String?

    public init(modelFilename: String? = nil, completionLengthLabel: String? = nil) {
        self.modelFilename = modelFilename
        self.completionLengthLabel = completionLengthLabel
    }
}

/// Aggregate counters mirrored from `TelemetrySnapshot`. Bundled into the export so analysis can
/// reason about latency in the context of acceptance/suppression at the time of capture (e.g. is a
/// high `present` cost correlated with a high suppression rate?).
public struct LatencyExportCounters: Codable, Equatable, Sendable {
    public var generatedCount: Int
    public var shownCount: Int
    public var suppressedCount: Int
    public var acceptedCount: Int
    public var suppressionReasons: [String: Int]

    public init(
        generatedCount: Int,
        shownCount: Int,
        suppressedCount: Int,
        acceptedCount: Int,
        suppressionReasons: [String: Int]
    ) {
        self.generatedCount = generatedCount
        self.shownCount = shownCount
        self.suppressedCount = suppressedCount
        self.acceptedCount = acceptedCount
        self.suppressionReasons = suppressionReasons
    }
}

/// Builds and serialises a `LatencyExport` from an in-memory telemetry store plus the device/engine
/// context the app target has collected. Lives in `Personalization` so the data model and the JSON
/// shape stay co-located with the telemetry type that produced them.
public enum LatencyExporter {
    /// Schema version. **Bump on every breaking change** (field rename, removal, or semantic shift)
    /// so an offline analyzer can route an old export through the right decoder. Additive,
    /// optional-only changes can keep the same number.
    public static let currentSchemaVersion = 1

    /// Snapshot the store and produce an export value. Reads `endToEnd` and decoder samples under
    /// the store's lock so the export is internally consistent (you won't get a count that doesn't
    /// line up with the sample array length).
    public static func makeExport(
        telemetry: CompletionTelemetryStore,
        device: LatencyExportDeviceInfo,
        engine: LatencyExportEngineInfo,
        now: Date = Date()
    ) -> LatencyExport {
        let snapshot = telemetry.snapshot()
        return LatencyExport(
            schemaVersion: currentSchemaVersion,
            exportedAt: now,
            device: device,
            engine: engine,
            counters: LatencyExportCounters(
                generatedCount: snapshot.generatedCount,
                shownCount: snapshot.shownCount,
                suppressedCount: snapshot.suppressedCount,
                acceptedCount: snapshot.acceptedCount,
                suppressionReasons: telemetry.suppressionReasons()
            ),
            endToEndSamples: telemetry.endToEndSamplesSnapshot(),
            decoderLatenciesMillis: telemetry.decoderLatenciesSnapshot()
        )
    }

    /// Pretty-printed, key-sorted JSON. The intent is that the file is human-skimmable (the reporter
    /// can eyeball values before sending it to us) without needing a separate viewer.
    public static func encodeJSON(_ export: LatencyExport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(export)
    }

    /// Filename suggestion for the save panel. Stable, sortable, machine-friendly; the timestamp
    /// uses UTC to avoid local-time ambiguity when comparing exports across users/sessions.
    public static func suggestedFilename(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "keytype-latency-\(formatter.string(from: date))Z.json"
    }
}
