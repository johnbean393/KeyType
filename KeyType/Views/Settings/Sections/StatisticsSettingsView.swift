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
    @State private var exportDocument: LatencyExportDocument?
    @State private var isExportPresented = false
    @State private var exportError: String?

    var body: some View {
        Form {
            Section("Total latency distribution") {
                LatencyDistributionChart(samples: snapshot.endToEnd.totalSamples)
                    .frame(minHeight: 180)
            }
            
            Section("Local stats") {
                statRow("Acceptance rate", percent(snapshot.acceptanceRate),
                        detail: "\(snapshot.acceptedCount) accepted / \(snapshot.shownCount) shown")
                statRow("Suppression rate", percent(snapshot.suppressionRate),
                        detail: "\(snapshot.suppressedCount) of \(snapshot.generatedCount) generated")
            }

            Section("End-to-end latency") {
                let e2e = snapshot.endToEnd
                let totalsDetail = e2e.sampleCount > 0
                    ? "\(e2e.sampleCount) shown samples · mean \(ms(e2e.total.mean))"
                    : "No shown completions yet — start typing in a supported app to populate."
                statRow("Total (AX → on-screen)",
                        percentilePair(e2e.total),
                        detail: totalsDetail)
                statRow("Prompt build",
                        percentilePair(e2e.promptBuild),
                        detail: "AX snapshot → prompt built (main actor)")
                statRow("Debounce wait",
                        percentilePair(e2e.debounce),
                        detail: "Intentional coalescing delay before decode")
                statRow("Model generation",
                        percentilePair(e2e.generation),
                        detail: "Constrained decode (off main)")
                statRow("Overlay present",
                        percentilePair(e2e.present),
                        detail: "Filter + anchor + paint ghost text")

                HStack {
                    Button("Refresh stats") { snapshot = telemetry.snapshot() }
                    Button("Export data…") { beginExport() }
                        .help("Save raw latency samples + device info as JSON to share with the KeyType maintainers.")
                    Spacer()
                }
                .font(.footnote)

                if let exportError {
                    Text(exportError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .task { snapshot = telemetry.snapshot() }
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

    private func statRow(_ title: String, _ value: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Text(value).font(.body.monospacedDigit()).foregroundStyle(.secondary)
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

    private func percentilePair(_ stats: LatencyPhaseStats) -> String {
        "\(ms(stats.p50)) / \(ms(stats.p95))"
    }
}

// MARK: - Distribution chart

/// Bar histogram of recent end-to-end latency samples. Designed to surface skew and the long tail
/// the percentile rows above hide — if the bulk of bars sit far left of `p95`, the slowness is rare
/// rather than typical, which is the most common KeyType latency shape.
private struct LatencyDistributionChart: View {
    let samples: [Double]

    var body: some View {
        if samples.isEmpty {
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
        let bins = LatencyHistogram.bins(for: samples)
        let domain = LatencyHistogram.domain(for: bins)
        // Use RectangleMark, not BarMark, for a fixed-bin histogram. BarMark's three-bound form
        // `(xStart:xEnd:y:)` reads the numeric `y` as a *position* and draws a thin horizontal
        // stripe at that height (the "floating pills" bug). BarMark has no 4-bound form; the
        // canonical primitive for a histogram with explicit bin boundaries is a rectangle from
        // (lowerBound, 0) to (upperBound, count).
        return Chart(bins) { bin in
            RectangleMark(
                xStart: .value("From", bin.lowerBound),
                xEnd: .value("To", bin.upperBound),
                yStart: .value("Zero", 0),
                yEnd: .value("Count", bin.count)
            )
            .foregroundStyle(.tint)
        }
        .chartXScale(domain: domain)
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
            AxisMarks(values: .automatic(desiredCount: 4))
        }
        .chartXAxisLabel("Latency (ms)")
        .chartYAxisLabel("Completions")
    }
}

// MARK: - Histogram bucketing

struct LatencyHistogramBin: Identifiable {
    let lowerBound: Double
    let upperBound: Double
    let count: Int

    var id: Double { lowerBound }
}

enum LatencyHistogram {
    /// Bucket latency samples into roughly `desiredBinCount` equal-width bins between the observed
    /// min and max. Falls back to a single bin when the samples are degenerate (all equal, or one
    /// sample) so the chart still renders meaningfully instead of dividing by zero.
    static func bins(for samples: [Double], desiredBinCount: Int = 18) -> [LatencyHistogramBin] {
        guard !samples.isEmpty else { return [] }
        let lo = samples.min() ?? 0
        let hi = samples.max() ?? lo
        let span = hi - lo
        guard span > .ulpOfOne else {
            return [LatencyHistogramBin(lowerBound: lo, upperBound: lo + 1, count: samples.count)]
        }
        let binCount = max(1, min(desiredBinCount, samples.count))
        let width = span / Double(binCount)
        var counts = Array(repeating: 0, count: binCount)
        for sample in samples {
            // The last bin is inclusive on the upper bound so the observed max isn't dropped.
            let raw = Int(((sample - lo) / width).rounded(.down))
            let index = min(max(raw, 0), binCount - 1)
            counts[index] += 1
        }
        return (0..<binCount).map { i in
            LatencyHistogramBin(
                lowerBound: lo + Double(i) * width,
                upperBound: lo + Double(i + 1) * width,
                count: counts[i]
            )
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
