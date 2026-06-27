import Foundation

/// Why a generated completion was not shown. Mirrors the controller's suppression taxonomy as a
/// stable string so telemetry stays decoupled from `AutocompleteCore.SuppressionReason`.
public typealias TelemetrySuppressionReason = String

/// One sample of the wall-clock latency the user actually perceives, broken into the main phases:
/// AX→prompt main-actor work, the intentional debounce/presentation gate, off-main model decode,
/// and the present-on-screen handoff. Generation may overlap the debounce gate, so phase values are
/// diagnostic columns and do not necessarily sum to `total`. Recorded only for completions that were
/// shown (`outcome == "shown"`) so the rollup describes the visible latency budget, not the cost of
/// suppressed/cancelled work. See ADR-070/080.
public struct CompletionLatencySample: Codable, Equatable, Sendable {
    /// Trace start (AX snapshot received) → suggestion painted.
    public var totalMillis: Double
    /// AX snapshot → `eventPromptBuilt` (main-actor prompt assembly, side-context fetch, policy).
    public var promptBuildMillis: Double
    /// `eventDebounceScheduled` → `eventDebounceElapsed` (the adaptive coalescing/presentation gate
    /// wait — not work). This can overlap `generationMillis`.
    public var debounceMillis: Double
    /// `eventGenerationBegin` → `eventGenerationEnd` (off-main constrained decode, the big one).
    public var generationMillis: Double
    /// `eventPresentBegin` → `finish("shown")` (filter + anchor + overlay paint on the main actor).
    public var presentMillis: Double

    public init(
        totalMillis: Double,
        promptBuildMillis: Double,
        debounceMillis: Double,
        generationMillis: Double,
        presentMillis: Double
    ) {
        self.totalMillis = totalMillis
        self.promptBuildMillis = promptBuildMillis
        self.debounceMillis = debounceMillis
        self.generationMillis = generationMillis
        self.presentMillis = presentMillis
    }
}

/// p50 / p95 / mean rollup for a single latency phase. Values are milliseconds.
public struct LatencyPhaseStats: Codable, Equatable, Sendable {
    public var p50: Double
    public var p95: Double
    public var mean: Double

    public init(p50: Double = 0, p95: Double = 0, mean: Double = 0) {
        self.p50 = p50
        self.p95 = p95
        self.mean = mean
    }
}

/// End-to-end latency rollup over the bounded sample reservoir. Per-phase percentiles are computed
/// independently (sorting each phase column on its own) so each row answers "how slow is *this*
/// stage at its tail?" rather than "what was this stage on the worst end-to-end trace?".
public struct EndToEndLatencyStats: Codable, Equatable, Sendable {
    public var sampleCount: Int
    public var total: LatencyPhaseStats
    public var promptBuild: LatencyPhaseStats
    public var debounce: LatencyPhaseStats
    public var generation: LatencyPhaseStats
    public var present: LatencyPhaseStats
    /// Raw end-to-end milliseconds for the bounded reservoir, ordered newest-last. Exposed so the
    /// Statistics pane can bucket them into a distribution histogram with Swift Charts.
    public var totalSamples: [Double]

    public init(
        sampleCount: Int = 0,
        total: LatencyPhaseStats = LatencyPhaseStats(),
        promptBuild: LatencyPhaseStats = LatencyPhaseStats(),
        debounce: LatencyPhaseStats = LatencyPhaseStats(),
        generation: LatencyPhaseStats = LatencyPhaseStats(),
        present: LatencyPhaseStats = LatencyPhaseStats(),
        totalSamples: [Double] = []
    ) {
        self.sampleCount = sampleCount
        self.total = total
        self.promptBuild = promptBuild
        self.debounce = debounce
        self.generation = generation
        self.present = present
        self.totalSamples = totalSamples
    }
}

/// A read-only rollup of local completion telemetry. All counts are device-local; nothing here ever
/// leaves the machine. See ADR-023.
public struct TelemetrySnapshot: Codable, Equatable, Sendable {
    /// Completions that finished generation and were considered for display (`shown + suppressed`).
    public var generatedCount: Int
    /// Completions actually shown as ghost text.
    public var shownCount: Int
    /// Completions suppressed (filtered out or no candidate).
    public var suppressedCount: Int
    /// Shown completions the user accepted (word or full).
    public var acceptedCount: Int
    /// Decoder-only latency rollup. Retained so `ThresholdTuner` and developer tooling can still
    /// reason about pure generation cost; the user-facing Statistics pane shows `endToEnd` instead.
    public var latencyMillisP50: Double
    public var latencyMillisP95: Double
    /// Number of latency samples behind the decoder-only percentiles.
    public var latencySampleCount: Int
    /// End-to-end (AX-snapshot → on-screen) latency, with per-phase breakdown plus raw samples for
    /// the Statistics histogram. Recorded only for completions that were shown. See ADR-070.
    public var endToEnd: EndToEndLatencyStats
    public var correctionsDetectedCount: Int
    public var correctionsShownCount: Int
    public var correctionsAcceptedCount: Int
    public var correctionsDismissedCount: Int
    public var correctionsReplacementFailureCount: Int
    public var correctionSuppressionReasons: [String: Int]
    public var correctionValidationLatencyMillisP50: Double
    public var correctionValidationLatencyMillisP95: Double

    public init(
        generatedCount: Int = 0,
        shownCount: Int = 0,
        suppressedCount: Int = 0,
        acceptedCount: Int = 0,
        latencyMillisP50: Double = 0,
        latencyMillisP95: Double = 0,
        latencySampleCount: Int = 0,
        endToEnd: EndToEndLatencyStats = EndToEndLatencyStats(),
        correctionsDetectedCount: Int = 0,
        correctionsShownCount: Int = 0,
        correctionsAcceptedCount: Int = 0,
        correctionsDismissedCount: Int = 0,
        correctionsReplacementFailureCount: Int = 0,
        correctionSuppressionReasons: [String: Int] = [:],
        correctionValidationLatencyMillisP50: Double = 0,
        correctionValidationLatencyMillisP95: Double = 0
    ) {
        self.generatedCount = generatedCount
        self.shownCount = shownCount
        self.suppressedCount = suppressedCount
        self.acceptedCount = acceptedCount
        self.latencyMillisP50 = latencyMillisP50
        self.latencyMillisP95 = latencyMillisP95
        self.latencySampleCount = latencySampleCount
        self.endToEnd = endToEnd
        self.correctionsDetectedCount = correctionsDetectedCount
        self.correctionsShownCount = correctionsShownCount
        self.correctionsAcceptedCount = correctionsAcceptedCount
        self.correctionsDismissedCount = correctionsDismissedCount
        self.correctionsReplacementFailureCount = correctionsReplacementFailureCount
        self.correctionSuppressionReasons = correctionSuppressionReasons
        self.correctionValidationLatencyMillisP50 = correctionValidationLatencyMillisP50
        self.correctionValidationLatencyMillisP95 = correctionValidationLatencyMillisP95
    }

    /// Accepted / shown. 0 when nothing has been shown yet.
    public var acceptanceRate: Double {
        shownCount > 0 ? Double(acceptedCount) / Double(shownCount) : 0
    }

    /// Suppressed / generated. 0 when nothing has been generated yet. High is expected and fine —
    /// KeyType prefers suppression to a wrong suggestion.
    public var suppressionRate: Double {
        generatedCount > 0 ? Double(suppressedCount) / Double(generatedCount) : 0
    }
}

public struct CompletionTelemetrySnapshotFile: Identifiable, Equatable {
    public var id: String { filename }
    public var url: URL
    public var filename: String
    public var createdAt: Date?
    public var snapshot: TelemetrySnapshot

    public init(
        url: URL,
        filename: String,
        createdAt: Date?,
        snapshot: TelemetrySnapshot
    ) {
        self.url = url
        self.filename = filename
        self.createdAt = createdAt
        self.snapshot = snapshot
    }
}

public enum CompletionTelemetrySnapshotError: Error, LocalizedError, Equatable {
    case persistentStoreUnavailable

    public var errorDescription: String? {
        switch self {
        case .persistentStoreUnavailable:
            return "Telemetry snapshots are unavailable because the telemetry store has no file URL."
        }
    }
}

/// Local-only telemetry for completion acceptance, suppression, and latency.
///
/// Aggregates are persisted as plain JSON in Application Support (they are non-PII counters and a
/// bounded reservoir of latency samples — no captured text). The app feeds the snapshot into
/// `ThresholdTuner` to nudge the decoder, and surfaces it read-only in Settings. Cleared in one
/// action by `clearAll()`.
public final class CompletionTelemetryStore: @unchecked Sendable {
    private struct State: Codable {
        var generatedCount = 0
        var shownCount = 0
        var suppressedCount = 0
        var acceptedCount = 0
        var suppressionReasons: [String: Int] = [:]
        var latenciesMillis: [Double] = []
        var endToEndSamples: [CompletionLatencySample] = []
        var correctionsDetectedCount = 0
        var correctionsShownCount = 0
        var correctionsAcceptedCount = 0
        var correctionsDismissedCount = 0
        var correctionsReplacementFailureCount = 0
        var correctionSuppressionReasons: [String: Int] = [:]
        var correctionValidationLatenciesMillis: [Double] = []

        init() {}

        // Tolerate persisted state from older versions that lack `endToEndSamples` — the synthesized
        // `Codable` would otherwise fail to decode and silently zero out *all* telemetry counters on
        // the first launch with this build.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            generatedCount = try container.decodeIfPresent(Int.self, forKey: .generatedCount) ?? 0
            shownCount = try container.decodeIfPresent(Int.self, forKey: .shownCount) ?? 0
            suppressedCount = try container.decodeIfPresent(Int.self, forKey: .suppressedCount) ?? 0
            acceptedCount = try container.decodeIfPresent(Int.self, forKey: .acceptedCount) ?? 0
            suppressionReasons = try container.decodeIfPresent([String: Int].self, forKey: .suppressionReasons) ?? [:]
            latenciesMillis = try container.decodeIfPresent([Double].self, forKey: .latenciesMillis) ?? []
            endToEndSamples = try container.decodeIfPresent([CompletionLatencySample].self, forKey: .endToEndSamples) ?? []
            correctionsDetectedCount = try container.decodeIfPresent(Int.self, forKey: .correctionsDetectedCount) ?? 0
            correctionsShownCount = try container.decodeIfPresent(Int.self, forKey: .correctionsShownCount) ?? 0
            correctionsAcceptedCount = try container.decodeIfPresent(Int.self, forKey: .correctionsAcceptedCount) ?? 0
            correctionsDismissedCount = try container.decodeIfPresent(Int.self, forKey: .correctionsDismissedCount) ?? 0
            correctionsReplacementFailureCount = try container.decodeIfPresent(Int.self, forKey: .correctionsReplacementFailureCount) ?? 0
            correctionSuppressionReasons = try container.decodeIfPresent([String: Int].self, forKey: .correctionSuppressionReasons) ?? [:]
            correctionValidationLatenciesMillis = try container.decodeIfPresent([Double].self, forKey: .correctionValidationLatenciesMillis) ?? []
        }
    }

    private static let snapshotFilenamePrefix = "keytype-latency-"
    private static let snapshotFilenameSuffix = ".json"
    private static let telemetryStateKeys: Set<String> = [
        "generatedCount",
        "shownCount",
        "suppressedCount",
        "acceptedCount",
        "suppressionReasons",
        "latenciesMillis",
        "correctionsDetectedCount",
        "correctionsShownCount",
        "correctionsAcceptedCount",
        "correctionsDismissedCount",
        "correctionsReplacementFailureCount",
        "correctionSuppressionReasons",
        "correctionValidationLatenciesMillis"
    ]

    private let url: URL?
    private let lock = NSLock()
    private var state: State
    /// Bounded reservoir so the file (and percentile cost) stays small over a long session.
    private let maxLatencySamples = 500
    /// Same bound as decoder-only samples — the Statistics histogram only needs a recent window and
    /// the per-phase percentile sort is O(n log n) on every snapshot read.
    private let maxEndToEndSamples = 500
    private let maxCorrectionValidationLatencySamples = 500

    public static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("KeyType/Telemetry", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("telemetry.json", isDirectory: false)
    }

    /// Loads persisted telemetry from `url` (defaulting to the standard location). A `nil` URL keeps
    /// telemetry purely in memory (used by tests and as a fallback when the path can't be resolved).
    public init(url: URL? = (try? CompletionTelemetryStore.defaultURL())) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(State.self, from: data) {
            self.state = decoded
        } else {
            self.state = State()
        }
    }

    // MARK: - Recording

    public func recordShown() {
        mutate {
            $0.generatedCount += 1
            $0.shownCount += 1
        }
    }

    public func recordSuppressed(reason: TelemetrySuppressionReason) {
        mutate {
            $0.generatedCount += 1
            $0.suppressedCount += 1
            $0.suppressionReasons[reason, default: 0] += 1
        }
    }

    public func recordAccepted() {
        mutate { $0.acceptedCount += 1 }
    }

    public func recordCorrectionDetected() {
        mutate { $0.correctionsDetectedCount += 1 }
    }

    public func recordCorrectionShown() {
        mutate { $0.correctionsShownCount += 1 }
    }

    public func recordCorrectionAccepted() {
        mutate { $0.correctionsAcceptedCount += 1 }
    }

    public func recordCorrectionDismissed() {
        mutate { $0.correctionsDismissedCount += 1 }
    }

    public func recordCorrectionSuppressed(reason: String) {
        mutate { $0.correctionSuppressionReasons[reason, default: 0] += 1 }
    }

    public func recordCorrectionValidationLatency(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        mutate {
            $0.correctionValidationLatenciesMillis.append(milliseconds)
            if $0.correctionValidationLatenciesMillis.count > maxCorrectionValidationLatencySamples {
                $0.correctionValidationLatenciesMillis.removeFirst($0.correctionValidationLatenciesMillis.count - maxCorrectionValidationLatencySamples)
            }
        }
    }

    public func recordCorrectionReplacementFailure() {
        mutate { $0.correctionsReplacementFailureCount += 1 }
    }

    public func recordLatency(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        mutate {
            $0.latenciesMillis.append(milliseconds)
            if $0.latenciesMillis.count > maxLatencySamples {
                $0.latenciesMillis.removeFirst($0.latenciesMillis.count - maxLatencySamples)
            }
        }
    }

    /// Persist one end-to-end latency sample (the trace that ran from "AX snapshot received" to
    /// "ghost text painted") plus its phase breakdown. Non-finite or negative phase values are
    /// dropped — the trace records `DispatchTime` deltas, so any bad value indicates a bug, not real
    /// latency. See ADR-070.
    public func recordEndToEndSample(_ sample: CompletionLatencySample) {
        guard sample.totalMillis.isFinite, sample.totalMillis >= 0,
              sample.promptBuildMillis.isFinite, sample.promptBuildMillis >= 0,
              sample.debounceMillis.isFinite, sample.debounceMillis >= 0,
              sample.generationMillis.isFinite, sample.generationMillis >= 0,
              sample.presentMillis.isFinite, sample.presentMillis >= 0
        else { return }
        mutate {
            $0.endToEndSamples.append(sample)
            if $0.endToEndSamples.count > maxEndToEndSamples {
                $0.endToEndSamples.removeFirst($0.endToEndSamples.count - maxEndToEndSamples)
            }
        }
    }

    // MARK: - Reading

    public func snapshot() -> TelemetrySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return Self.snapshot(from: state)
    }

    public func archivedSnapshots() -> [CompletionTelemetrySnapshotFile] {
        guard let url else { return [] }
        let directory = url.deletingLastPathComponent()
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls
            .filter { Self.isSnapshotFilename($0.lastPathComponent) }
            .compactMap { snapshotURL -> CompletionTelemetrySnapshotFile? in
                guard let data = try? Data(contentsOf: snapshotURL),
                      Self.looksLikeTelemetryState(data),
                      let state = try? JSONDecoder().decode(State.self, from: data)
                else { return nil }
                return CompletionTelemetrySnapshotFile(
                    url: snapshotURL,
                    filename: snapshotURL.lastPathComponent,
                    createdAt: Self.snapshotDate(from: snapshotURL.lastPathComponent),
                    snapshot: Self.snapshot(from: state)
                )
            }
            .sorted { lhs, rhs in
                switch (lhs.createdAt, rhs.createdAt) {
                case let (left?, right?) where left != right:
                    return left > right
                default:
                    return lhs.filename > rhs.filename
                }
            }
    }

    @discardableResult
    public func snapshotCurrentStats(now: Date = Date()) throws -> CompletionTelemetrySnapshotFile {
        guard let url else { throw CompletionTelemetrySnapshotError.persistentStoreUnavailable }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshotURL = Self.uniqueSnapshotURL(in: directory, at: now)

        lock.lock()
        defer { lock.unlock() }
        let snapshotState = state
        let data = try JSONEncoder().encode(snapshotState)
        try data.write(to: snapshotURL, options: .atomic)
        state = State()
        try? FileManager.default.removeItem(at: url)

        return CompletionTelemetrySnapshotFile(
            url: snapshotURL,
            filename: snapshotURL.lastPathComponent,
            createdAt: Self.snapshotDate(from: snapshotURL.lastPathComponent),
            snapshot: Self.snapshot(from: snapshotState)
        )
    }

    static func endToEndStats(from samples: [CompletionLatencySample]) -> EndToEndLatencyStats {
        guard !samples.isEmpty else { return EndToEndLatencyStats() }
        return EndToEndLatencyStats(
            sampleCount: samples.count,
            total: phaseStats(samples.map(\.totalMillis)),
            promptBuild: phaseStats(samples.map(\.promptBuildMillis)),
            debounce: phaseStats(samples.map(\.debounceMillis)),
            generation: phaseStats(samples.map(\.generationMillis)),
            present: phaseStats(samples.map(\.presentMillis)),
            totalSamples: samples.map(\.totalMillis)
        )
    }

    private static func phaseStats(_ values: [Double]) -> LatencyPhaseStats {
        guard !values.isEmpty else { return LatencyPhaseStats() }
        let mean = values.reduce(0, +) / Double(values.count)
        return LatencyPhaseStats(
            p50: percentile(values, 0.5),
            p95: percentile(values, 0.95),
            mean: mean
        )
    }

    /// Suppression-reason histogram (for diagnostics / Settings detail).
    public func suppressionReasons() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return state.suppressionReasons
    }

    /// Raw end-to-end samples in the bounded reservoir, ordered oldest-first. Used by
    /// `LatencyExporter` to ship the full per-phase trace alongside the percentile rollup; the
    /// Settings UI itself reads the snapshot's `endToEnd.totalSamples` for the histogram.
    public func endToEndSamplesSnapshot() -> [CompletionLatencySample] {
        lock.lock()
        defer { lock.unlock() }
        return state.endToEndSamples
    }

    /// Raw decoder-only latencies (the `engine.completions(...)` segment) in the bounded reservoir.
    /// Exposed for the latency export so we can cross-reference pure model time against the broader
    /// end-to-end sample even when the snapshot only carries the rollup.
    public func decoderLatenciesSnapshot() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        return state.latenciesMillis
    }

    // MARK: - Clearing

    public func clearAll() {
        lock.lock()
        state = State()
        lock.unlock()
        if let url { try? FileManager.default.removeItem(at: url) }
        removeArchivedSnapshots()
    }

    // MARK: - Helpers

    private static func snapshot(from state: State) -> TelemetrySnapshot {
        let latencies = state.latenciesMillis
        let endToEndSamples = state.endToEndSamples
        let correctionLatencies = state.correctionValidationLatenciesMillis
        return TelemetrySnapshot(
            generatedCount: state.generatedCount,
            shownCount: state.shownCount,
            suppressedCount: state.suppressedCount,
            acceptedCount: state.acceptedCount,
            latencyMillisP50: Self.percentile(latencies, 0.5),
            latencyMillisP95: Self.percentile(latencies, 0.95),
            latencySampleCount: latencies.count,
            endToEnd: Self.endToEndStats(from: endToEndSamples),
            correctionsDetectedCount: state.correctionsDetectedCount,
            correctionsShownCount: state.correctionsShownCount,
            correctionsAcceptedCount: state.correctionsAcceptedCount,
            correctionsDismissedCount: state.correctionsDismissedCount,
            correctionsReplacementFailureCount: state.correctionsReplacementFailureCount,
            correctionSuppressionReasons: state.correctionSuppressionReasons,
            correctionValidationLatencyMillisP50: Self.percentile(correctionLatencies, 0.5),
            correctionValidationLatencyMillisP95: Self.percentile(correctionLatencies, 0.95)
        )
    }

    private static func isSnapshotFilename(_ filename: String) -> Bool {
        filename.hasPrefix(snapshotFilenamePrefix) && filename.hasSuffix(snapshotFilenameSuffix)
    }

    private static func snapshotFilename(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss'Z'"
        return "\(snapshotFilenamePrefix)\(formatter.string(from: date))\(snapshotFilenameSuffix)"
    }

    private static func snapshotDate(from filename: String) -> Date? {
        guard isSnapshotFilename(filename) else { return nil }
        let stem = filename
            .dropFirst(snapshotFilenamePrefix.count)
            .dropLast(snapshotFilenameSuffix.count)
        guard stem.count >= 16 else { return nil }
        let timestamp = String(stem.prefix(16))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss'Z'"
        return formatter.date(from: timestamp)
    }

    private static func uniqueSnapshotURL(in directory: URL, at date: Date) -> URL {
        let filename = snapshotFilename(at: date)
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = directory.appendingPathComponent(filename, isDirectory: false)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(suffix).\(ext)", isDirectory: false)
            suffix += 1
        }
        return candidate
    }

    private static func looksLikeTelemetryState(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else { return false }
        return telemetryStateKeys.contains { dictionary[$0] != nil }
    }

    private func removeArchivedSnapshots() {
        guard let url else { return }
        let directory = url.deletingLastPathComponent()
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for snapshotURL in urls where Self.isSnapshotFilename(snapshotURL.lastPathComponent) {
            try? FileManager.default.removeItem(at: snapshotURL)
        }
    }

    private func mutate(_ body: (inout State) -> Void) {
        lock.lock()
        body(&state)
        let snapshot = state
        lock.unlock()
        persist(snapshot)
    }

    private func persist(_ state: State) {
        guard let url else { return }
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        guard sorted.count > 1 else { return sorted[0] }
        let rank = p * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        let weight = rank - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }
}
