//
//  StatisticsSettingsView.swift
//  KeyType
//
//  The "Statistics" Settings pane: read-only local telemetry (acceptance/suppression and the
//  end-to-end latency the user actually perceives, broken down by phase + a distribution chart).
//  Split out of SettingsView so each sidebar category lives in its own file.
//

import Charts
import Personalization
import SwiftUI
import UniformTypeIdentifiers

struct StatisticsSettingsView: View {
    let telemetry: CompletionTelemetryStore
    /// Closure that snapshots telemetry + collects device/engine info and returns the JSON payload
    /// the "Export data" button should write to disk. Injected so this view stays decoupled from
    /// `SettingsStore` and from `LatencyExportContext`'s `sysctl`/`Bundle` lookups (which would
    /// pull AppKit/system imports into a pane that's otherwise pure SwiftUI). Returning `nil`
    /// surfaces an inline error in the file picker rather than silently writing an empty file.
    let makeLatencyExport: () -> Data?

    @State private var snapshot: TelemetrySnapshot = TelemetrySnapshot()
    @State private var snapshots: [CompletionTelemetrySnapshotFile] = []
    @State private var selectedSnapshotIDs: Set<String> = []
    @State private var exportDocument: LatencyExportDocument?
    @State private var isExportPresented = false
    @State private var exportError: String?
    @State private var snapshotError: String?
    @State private var snapshotStatus: String?

    var body: some View {
        Form {
            Section("Total latency distribution") {
                LatencyDistributionChart(series: chartSeries)
                    .frame(minHeight: 180)
                snapshotMenu
            }
            
            Section("Local stats") {
                statRow(
                    "Acceptance rate",
                    detail: "\(snapshot.acceptedCount) accepted / \(snapshot.shownCount) shown",
                    value: { percent($0.acceptanceRate) }
                )
                statRow(
                    "Suppression rate",
                    detail: "\(snapshot.suppressedCount) of \(snapshot.generatedCount) generated",
                    value: { percent($0.suppressionRate) }
                )
            }

            Section("End-to-end latency") {
                let e2e = snapshot.endToEnd
                let totalsDetail = e2e.sampleCount > 0
                    ? "\(e2e.sampleCount) shown samples · mean \(ms(e2e.total.mean))"
                    : "No shown completions yet — start typing in a supported app to populate."
                statRow(
                    "Total (AX → on-screen)",
                    detail: totalsDetail,
                    value: { percentilePair($0.endToEnd.total, sampleCount: $0.endToEnd.sampleCount) }
                )
                statRow(
                    "Prompt build",
                    detail: "AX snapshot → prompt built (main actor)",
                    value: { percentilePair($0.endToEnd.promptBuild, sampleCount: $0.endToEnd.sampleCount) }
                )
                statRow(
                    "Debounce wait",
                    detail: "Intentional coalescing delay before decode",
                    value: { percentilePair($0.endToEnd.debounce, sampleCount: $0.endToEnd.sampleCount) }
                )
                statRow(
                    "Model generation",
                    detail: "Constrained decode (off main)",
                    value: { percentilePair($0.endToEnd.generation, sampleCount: $0.endToEnd.sampleCount) }
                )
                statRow(
                    "Overlay present",
                    detail: "Filter + anchor + paint ghost text",
                    value: { percentilePair($0.endToEnd.present, sampleCount: $0.endToEnd.sampleCount) }
                )

                HStack {
                    Button("Refresh stats") { refreshStats() }
                    Button("Export data…") { beginExport() }
                        .help("Save raw latency samples + device info as JSON to share with the KeyType maintainers.")
                    Button("Snapshot stats") { snapshotStats() }
                        .help("Save current telemetry as a local comparison snapshot, then clear current stats.")
                    Spacer()
                }
                .font(.footnote)

                if let exportError {
                    Text(exportError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if let snapshotError {
                    Text(snapshotError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if let snapshotStatus {
                    Text(snapshotStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { refreshStats() }
        .fileExporter(
            isPresented: $isExportPresented,
            document: exportDocument,
            contentType: .json,
            defaultFilename: LatencyExporter.suggestedFilename()
        ) { result in
            switch result {
            case .success:
                exportError = nil
            case let .failure(error):
                exportError = "Couldn't save export: \(error.localizedDescription)"
            }
            exportDocument = nil
        }
    }

    private var selectedSnapshots: [CompletionTelemetrySnapshotFile] {
        snapshots.filter { selectedSnapshotIDs.contains($0.id) }
    }

    private var metricSeries: [LatencyMetricSeries] {
        var series = [
            LatencyMetricSeries(
                id: "current",
                label: "Current",
                color: .orange,
                snapshot: snapshot
            )
        ]
        for (index, archive) in selectedSnapshots.enumerated() {
            series.append(
                LatencyMetricSeries(
                    id: archive.id,
                    label: snapshotLabel(for: archive),
                    color: Self.snapshotColors[index % Self.snapshotColors.count],
                    snapshot: archive.snapshot
                )
            )
        }
        return series
    }

    private var chartSeries: [LatencyDistributionSeries] {
        metricSeries.map {
            LatencyDistributionSeries(
                id: $0.id,
                label: $0.label,
                color: $0.color,
                samples: $0.snapshot.endToEnd.totalSamples
            )
        }
    }

    private var snapshotSelectionSummary: String {
        if snapshots.isEmpty { return "No snapshots saved" }
        return "\(selectedSnapshotIDs.count) of 2 selected"
    }

    private var snapshotMenu: some View {
        HStack {
            Menu {
                if snapshots.isEmpty {
                    Text("No snapshots")
                } else {
                    ForEach(snapshots) { archive in
                        Toggle(isOn: snapshotSelectionBinding(for: archive)) {
                            Text(snapshotLabel(for: archive))
                        }
                        .disabled(!selectedSnapshotIDs.contains(archive.id) && selectedSnapshotIDs.count >= 2)
                    }
                    Divider()
                }
                Button("Refresh snapshots") { reloadSnapshots() }
            } label: {
                Label("Compare snapshots", systemImage: "chart.bar.xaxis")
            }
            Text(snapshotSelectionSummary)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.footnote)
    }

    private static let snapshotColors: [Color] = [.blue, .purple]

    private static let snapshotLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private func refreshStats() {
        snapshot = telemetry.snapshot()
        reloadSnapshots()
    }

    private func reloadSnapshots() {
        snapshots = telemetry.archivedSnapshots()
        let validIDs = Set(snapshots.map(\.id))
        selectedSnapshotIDs.formIntersection(validIDs)
    }

    private func snapshotSelectionBinding(for archive: CompletionTelemetrySnapshotFile) -> Binding<Bool> {
        Binding(
            get: { selectedSnapshotIDs.contains(archive.id) },
            set: { isSelected in
                if isSelected {
                    guard selectedSnapshotIDs.count < 2 || selectedSnapshotIDs.contains(archive.id) else {
                        return
                    }
                    selectedSnapshotIDs.insert(archive.id)
                } else {
                    selectedSnapshotIDs.remove(archive.id)
                }
            }
        )
    }

    private func snapshotLabel(for archive: CompletionTelemetrySnapshotFile) -> String {
        if let createdAt = archive.createdAt {
            return Self.snapshotLabelFormatter.string(from: createdAt)
        }
        return archive.filename
    }

    /// Build the JSON payload, refresh the on-screen snapshot so the percentile rows match the
    /// file the user just produced, then trigger the save panel. Doing the encode synchronously
    /// up-front means the panel only opens when there's something real to write.
    private func beginExport() {
        guard let data = makeLatencyExport() else {
            exportError = "Couldn't encode latency data for export."
            return
        }
        snapshot = telemetry.snapshot()
        exportError = nil
        exportDocument = LatencyExportDocument(data: data)
        isExportPresented = true
    }

    private func snapshotStats() {
        do {
            let archive = try telemetry.snapshotCurrentStats()
            snapshot = telemetry.snapshot()
            reloadSnapshots()
            var selected = selectedSnapshotIDs
            selected.insert(archive.id)
            if selected.count > 2 {
                let ordered = [archive.id] + snapshots.map(\.id).filter {
                    $0 != archive.id && selected.contains($0)
                }
                selected = Set(ordered.prefix(2))
            }
            selectedSnapshotIDs = selected
            snapshotError = nil
            snapshotStatus = "Saved \(archive.filename) and cleared current stats."
        } catch {
            snapshotStatus = nil
            snapshotError = "Couldn't snapshot stats: \(error.localizedDescription)"
        }
    }

    private func statRow(
        _ title: String,
        detail: String,
        value: @escaping (TelemetrySnapshot) -> String
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            metricValues(value)
        }
    }

    @ViewBuilder
    private func metricValues(_ value: @escaping (TelemetrySnapshot) -> String) -> some View {
        let series = metricSeries
        if series.count == 1, let current = series.first {
            Text(value(current.snapshot))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(series) { item in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(item.color)
                            .frame(width: 7, height: 7)
                        Text(item.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(value(item.snapshot))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 82, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    private func ms(_ value: Double) -> String {
        // Sub-millisecond figures (prompt build / present on a fast machine) round to "0 ms" with a
        // bare `%.0f`, which reads as "nothing happened". Keep one decimal under 10 ms so the row
        // still shows that the phase exists and ran in well under a millisecond.
        value < 10 ? String(format: "%.1f ms", value) : String(format: "%.0f ms", value)
    }

    private func percentilePair(_ stats: LatencyPhaseStats, sampleCount: Int) -> String {
        guard sampleCount > 0 else { return "—" }
        return "\(ms(stats.p50)) / \(ms(stats.p95))"
    }
}

private struct LatencyMetricSeries: Identifiable {
    let id: String
    let label: String
    let color: Color
    let snapshot: TelemetrySnapshot
}

// MARK: - Distribution chart

private struct LatencyDistributionSeries: Identifiable {
    let id: String
    let label: String
    let color: Color
    let samples: [Double]
}

/// Bar histogram of recent end-to-end latency samples. Designed to surface skew and the long tail
/// the percentile rows above hide — if the bulk of bars sit far left of `p95`, the slowness is rare
/// rather than typical, which is the most common KeyType latency shape.
private struct LatencyDistributionChart: View {
    let series: [LatencyDistributionSeries]

    var body: some View {
        if series.allSatisfy({ $0.samples.isEmpty }) {
            ContentUnavailableView(
                "No latency samples yet",
                systemImage: "chart.bar.xaxis",
                description: Text("Once KeyType has shown a few completions, their end-to-end latency will be plotted here.")
            )
            .frame(maxWidth: .infinity, alignment: .center)
        } else {
            chart
        }
    }

    private var chart: some View {
        let activeSeries = series.filter { !$0.samples.isEmpty }
        let bins = LatencyHistogram.bins(for: activeSeries)
        let currentBins = bins.filter(\.isCurrent)
        let outlinePoints = LatencyHistogram.outlinePoints(for: bins, comparesSeries: activeSeries.count > 1)
        let domain = LatencyHistogram.domain(for: bins)
        let comparesSeries = activeSeries.count > 1
        // Use RectangleMark, not BarMark, for a fixed-bin histogram. BarMark's three-bound form
        // `(xStart:xEnd:y:)` reads the numeric `y` as a *position* and draws a thin horizontal
        // stripe at that height (the "floating pills" bug). BarMark has no 4-bound form; the
        // canonical primitive for a histogram with explicit bin boundaries is a rectangle from
        // (lowerBound, 0) to (upperBound, count).
        return Chart {
            ForEach(currentBins) { bin in
                RectangleMark(
                    xStart: .value("From", bin.lowerBound),
                    xEnd: .value("To", bin.upperBound),
                    yStart: .value("Zero", 0),
                    yEnd: .value(comparesSeries ? "Share" : "Count", bin.yValue(comparesSeries: comparesSeries))
                )
                .foregroundStyle(by: .value("Series", bin.seriesLabel))
                .opacity(0.82)
            }

            ForEach(outlinePoints) { point in
                LineMark(
                    x: .value("Latency", point.x),
                    y: .value(comparesSeries ? "Share" : "Count", point.y),
                    series: .value("Series", point.seriesLabel)
                )
                .foregroundStyle(by: .value("Series", point.seriesLabel))
                .lineStyle(StrokeStyle(lineWidth: 2.25, lineCap: .butt, lineJoin: .round))
                .interpolationMethod(.linear)
            }
        }
        .chartXScale(domain: domain)
        .chartForegroundStyleScale(
            domain: activeSeries.map(\.label),
            range: activeSeries.map(\.color)
        )
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let ms = value.as(Double.self) {
                        Text(LatencyHistogram.axisLabel(forMilliseconds: ms))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if comparesSeries, let share = value.as(Double.self) {
                        Text("\(Int(share))%")
                    } else if let count = value.as(Double.self) {
                        Text("\(Int(count))")
                    }
                }
            }
        }
        .chartXAxisLabel("Latency (ms)")
        .chartYAxisLabel(comparesSeries ? "Share of samples" : "Completions")
    }
}

// MARK: - Histogram bucketing

private struct LatencyHistogramBin: Identifiable {
    let seriesID: String
    let seriesLabel: String
    let lowerBound: Double
    let upperBound: Double
    let count: Int
    let sampleCount: Int
    let isCurrent: Bool

    var id: String { "\(seriesID)-\(lowerBound)" }
    var sharePercent: Double {
        sampleCount > 0 ? Double(count) / Double(sampleCount) * 100 : 0
    }
    func yValue(comparesSeries: Bool) -> Double {
        comparesSeries ? sharePercent : Double(count)
    }
}

private struct LatencyHistogramOutlinePoint: Identifiable {
    let seriesID: String
    let seriesLabel: String
    let index: Int
    let x: Double
    let y: Double

    var id: String { "\(seriesID)-\(index)" }
}

private struct LatencyHistogramSeriesKey: Hashable {
    let id: String
    let label: String

    init(_ bin: LatencyHistogramBin) {
        self.id = bin.seriesID
        self.label = bin.seriesLabel
    }
}

private enum LatencyHistogram {
    /// Bucket latency samples into roughly `desiredBinCount` equal-width bins between the observed
    /// min and max. Falls back to a single bin when the samples are degenerate (all equal, or one
    /// sample) so the chart still renders meaningfully instead of dividing by zero.
    static func bins(for samples: [Double], desiredBinCount: Int = 18) -> [LatencyHistogramBin] {
        bins(
            for: [
                LatencyDistributionSeries(
                    id: "current",
                    label: "Current",
                    color: .accentColor,
                    samples: samples
                )
            ],
            desiredBinCount: desiredBinCount
        )
    }

    static func bins(
        for series: [LatencyDistributionSeries],
        desiredBinCount: Int = 18
    ) -> [LatencyHistogramBin] {
        let allSamples = series.flatMap(\.samples)
        guard !allSamples.isEmpty else { return [] }
        let lo = allSamples.min() ?? 0
        let hi = allSamples.max() ?? lo
        let span = hi - lo
        let maxSampleCount = series.map(\.samples.count).max() ?? allSamples.count
        guard span > .ulpOfOne else {
            return series.flatMap { item in
                guard !item.samples.isEmpty else { return [LatencyHistogramBin]() }
                return [
                    LatencyHistogramBin(
                        seriesID: item.id,
                        seriesLabel: item.label,
                        lowerBound: lo,
                        upperBound: lo + 1,
                        count: item.samples.count,
                        sampleCount: item.samples.count,
                        isCurrent: item.id == "current"
                    )
                ]
            }
        }
        let binCount = max(1, min(desiredBinCount, maxSampleCount))
        let width = span / Double(binCount)
        return series.flatMap { item in
            guard !item.samples.isEmpty else { return [LatencyHistogramBin]() }
            var counts = Array(repeating: 0, count: binCount)
            for sample in item.samples {
                // The last bin is inclusive on the upper bound so the observed max isn't dropped.
                let raw = Int(((sample - lo) / width).rounded(.down))
                let index = min(max(raw, 0), binCount - 1)
                counts[index] += 1
            }
            return (0..<binCount).map { i in
                LatencyHistogramBin(
                    seriesID: item.id,
                    seriesLabel: item.label,
                    lowerBound: lo + Double(i) * width,
                    upperBound: lo + Double(i + 1) * width,
                    count: counts[i],
                    sampleCount: item.samples.count,
                    isCurrent: item.id == "current"
                )
            }
        }
    }

    static func outlinePoints(
        for bins: [LatencyHistogramBin],
        comparesSeries: Bool
    ) -> [LatencyHistogramOutlinePoint] {
        let snapshotBins = bins.filter { !$0.isCurrent }
        let grouped = Dictionary(grouping: snapshotBins, by: LatencyHistogramSeriesKey.init)
        return grouped.keys.sorted { $0.label < $1.label }.flatMap { key in
            let sortedBins = (grouped[key] ?? []).sorted {
                if $0.lowerBound == $1.lowerBound {
                    return $0.upperBound < $1.upperBound
                }
                return $0.lowerBound < $1.lowerBound
            }
            guard let first = sortedBins.first, let last = sortedBins.last else {
                return [LatencyHistogramOutlinePoint]()
            }

            var points: [LatencyHistogramOutlinePoint] = [
                LatencyHistogramOutlinePoint(
                    seriesID: key.id,
                    seriesLabel: key.label,
                    index: 0,
                    x: first.lowerBound,
                    y: 0
                )
            ]
            var index = 1
            for bin in sortedBins {
                let y = bin.yValue(comparesSeries: comparesSeries)
                points.append(
                    LatencyHistogramOutlinePoint(
                        seriesID: key.id,
                        seriesLabel: key.label,
                        index: index,
                        x: bin.lowerBound,
                        y: y
                    )
                )
                index += 1
                points.append(
                    LatencyHistogramOutlinePoint(
                        seriesID: key.id,
                        seriesLabel: key.label,
                        index: index,
                        x: bin.upperBound,
                        y: y
                    )
                )
                index += 1
            }
            points.append(
                LatencyHistogramOutlinePoint(
                    seriesID: key.id,
                    seriesLabel: key.label,
                    index: index,
                    x: last.upperBound,
                    y: 0
                )
            )
            return points
        }
    }

    /// Axis label that switches to seconds once the value crosses 1 s so two- and three-digit
    /// millisecond labels don't crowd the axis on slow-machine outliers.
    static func axisLabel(forMilliseconds value: Double) -> String {
        if value >= 1_000 {
            return String(format: "%.1fs", value / 1_000)
        }
        return String(format: "%.0f", value)
    }

    /// X-axis domain that hugs the observed range. Without this, Swift Charts anchors the
    /// continuous x scale at 0, which produces an empty 0–lo stretch on the left of the chart
    /// (KeyType's `total` is never near zero — there's always at least the debounce wait). The
    /// padding term keeps the leftmost / rightmost bars from sitting flush against the axis.
    static func domain(for bins: [LatencyHistogramBin]) -> ClosedRange<Double> {
        guard let first = bins.first, let last = bins.last else { return 0...1 }
        let span = max(last.upperBound - first.lowerBound, 1)
        let pad = span * 0.02
        return (first.lowerBound - pad)...(last.upperBound + pad)
    }
}

// MARK: - Export document

/// Trivial `FileDocument` wrapper that hands the pre-encoded latency JSON to SwiftUI's
/// `.fileExporter` save panel. Read-side decoding is implemented for completeness so the type
/// satisfies `FileDocument`'s symmetry contract, but KeyType never opens its own exports — the
/// data is intended to flow outward to the maintainers, not back into the app.
struct LatencyExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
