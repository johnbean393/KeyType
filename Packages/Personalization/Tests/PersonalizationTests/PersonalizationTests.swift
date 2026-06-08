import Prompting
import XCTest
@testable import Personalization

final class PersonalizationTests: XCTestCase {

    // MARK: - Encrypted store

    private func makeTempStore() throws -> (PersistentWritingHistoryStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keytype-history-\(UUID().uuidString).sqlcipher")
        let store = try PersistentWritingHistoryStore(databaseURL: url, passphrase: "test-passphrase-abcdef")
        return (store, url)
    }

    func testPersistentStoreRecordsQueriesAndClears() throws {
        let (store, url) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: url) }

        store.record(WritingHistorySample(
            text: "The quarterly report is due on Friday afternoon.",
            appBundleIdentifier: "com.app.mail"
        ))
        store.record(WritingHistorySample(text: "short", appBundleIdentifier: "com.app.mail"))
        store.record(WritingHistorySample(
            text: "Remember to water the plants every morning.",
            appBundleIdentifier: "com.app.notes"
        ))

        XCTAssertEqual(store.count(), 3)

        let mail = store.samples(for: WritingHistoryQuery(
            bundleIdentifier: "com.app.mail",
            minimumCharacters: 12
        ))
        XCTAssertTrue(mail.contains("The quarterly report is due on Friday afternoon."))
        XCTAssertFalse(mail.contains("short"), "below minimumCharacters should be excluded")

        store.clearAll()
        XCTAssertEqual(store.count(), 0)
        XCTAssertTrue(store.samples(for: WritingHistoryQuery(bundleIdentifier: "com.app.mail")).isEmpty)
    }

    func testPersistentStoreDomainScopingExcludesOtherTabs() throws {
        // DB-level coverage for the domain filter (the production path): two sites in the same browser
        // bundle must not share context, and a nil-domain row must not leak into a domain-scoped query.
        let (store, url) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: url) }

        store.record(WritingHistorySample(text: "Draft about quarterly revenue numbers here.", appBundleIdentifier: "com.browser", domain: "mail.google.com"))
        store.record(WritingHistorySample(text: "you can use it to access the OpenAI API key.", appBundleIdentifier: "com.browser", domain: "platform.openai.com"))
        store.record(WritingHistorySample(text: "Some unknown-domain text from this browser.", appBundleIdentifier: "com.browser", domain: nil))

        let result = store.samples(for: WritingHistoryQuery(
            bundleIdentifier: "com.browser",
            domain: "mail.google.com",
            minimumCharacters: 1,
            sameAppOnly: true
        ))
        XCTAssertEqual(result, ["Draft about quarterly revenue numbers here."])
    }

    func testPersistentStoreDedupesIdenticalSample() throws {
        let (store, url) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let sample = WritingHistorySample(
            text: "Thanks so much for the thoughtful feedback.",
            appBundleIdentifier: "com.app.mail"
        )
        store.record(sample)
        store.record(sample)
        XCTAssertEqual(store.count(), 1, "identical text in the same app should not duplicate")
    }

    func testEncryptedFileIsNotReadableAsPlainText() throws {
        let (store, url) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.record(WritingHistorySample(
            text: "SECRET-MARKER-1234567890 confidential note",
            appBundleIdentifier: "com.app.notes"
        ))
        let data = try Data(contentsOf: url)
        XCTAssertFalse(
            data.range(of: Data("SECRET-MARKER".utf8)) != nil,
            "stored text must not appear in plaintext on disk"
        )
    }

    // MARK: - Selection / budget

    func testSelectionRespectsTokenBudget() {
        let entries = (0..<10).map { i in
            WritingHistorySample(
                text: "Sample number \(i): " + String(repeating: "x", count: 90),
                appBundleIdentifier: "com.app",
                updatedAt: Date().addingTimeInterval(Double(i))
            )
        }
        // Each text is ~100 chars (~26 tokens); a 30-token budget fits only one.
        let query = WritingHistoryQuery(
            bundleIdentifier: "com.app",
            minimumCharacters: 1,
            longestCount: 0,
            mostRecentCount: 10,
            crossAppRecentCount: 0,
            tokenBudget: 30
        )
        let result = WritingHistorySelection.select(from: entries, query: query)
        XCTAssertEqual(result.count, 1, "token budget should cap the number of samples")
    }

    func testSelectionPrefersSameAppRecent() {
        let now = Date()
        let entries = [
            WritingHistorySample(text: "Older note from this same app here.", appBundleIdentifier: "com.app", updatedAt: now.addingTimeInterval(-100)),
            WritingHistorySample(text: "Newer note from this same app here.", appBundleIdentifier: "com.app", updatedAt: now),
            WritingHistorySample(text: "A note from a different app entirely.", appBundleIdentifier: "com.other", updatedAt: now)
        ]
        let result = WritingHistorySelection.select(from: entries, query: WritingHistoryQuery(
            bundleIdentifier: "com.app",
            minimumCharacters: 1,
            longestCount: 0,
            mostRecentCount: 1,
            crossAppRecentCount: 0
        ))
        XCTAssertEqual(result, ["Newer note from this same app here."])
    }

    func testSameAppOnlyExcludesCrossAppContent() {
        // Regression: a recent sample from another app must never be injected when the query is
        // same-app-scoped — otherwise unrelated content (e.g. a Notes draft) bleeds into another
        // app's prompt and the model parrots it verbatim.
        let now = Date()
        let entries = [
            WritingHistorySample(text: "you can use it to access the OpenAI API.", appBundleIdentifier: "com.app.notes", updatedAt: now),
            WritingHistorySample(text: "Hi Molly, hope you are doing well today.", appBundleIdentifier: "com.app.mail", updatedAt: now.addingTimeInterval(-100))
        ]
        let result = WritingHistorySelection.select(from: entries, query: WritingHistoryQuery(
            bundleIdentifier: "com.app.mail",
            minimumCharacters: 1,
            sameAppOnly: true
        ))
        XCTAssertEqual(result, ["Hi Molly, hope you are doing well today."])
        XCTAssertFalse(result.contains { $0.contains("OpenAI") }, "cross-app content must not leak")
    }

    func testSameAppScopingExcludesOtherWebDomains() {
        // Two tabs in the same browser (same bundle) must not share context: a sample from another
        // site, or one with no recorded domain, must not be injected into the focused domain's prompt.
        let now = Date()
        let entries = [
            WritingHistorySample(text: "Draft about quarterly revenue numbers.", appBundleIdentifier: "com.browser", domain: "mail.google.com", updatedAt: now),
            WritingHistorySample(text: "you can use it to access the OpenAI API.", appBundleIdentifier: "com.browser", domain: "platform.openai.com", updatedAt: now),
            WritingHistorySample(text: "Some unknown-domain text from this browser.", appBundleIdentifier: "com.browser", domain: nil, updatedAt: now)
        ]
        let result = WritingHistorySelection.select(from: entries, query: WritingHistoryQuery(
            bundleIdentifier: "com.browser",
            domain: "mail.google.com",
            minimumCharacters: 1,
            sameAppOnly: true
        ))
        XCTAssertEqual(result, ["Draft about quarterly revenue numbers."])
    }

    func testNativeAppScopingIsUnaffectedByDomain() {
        // A native app has no domain; same-app scoping must still return its samples.
        let now = Date()
        let entries = [
            WritingHistorySample(text: "A note typed in the native app here.", appBundleIdentifier: "com.app.notes", domain: nil, updatedAt: now)
        ]
        let result = WritingHistorySelection.select(from: entries, query: WritingHistoryQuery(
            bundleIdentifier: "com.app.notes",
            minimumCharacters: 1,
            sameAppOnly: true
        ))
        XCTAssertEqual(result, ["A note typed in the native app here."])
    }

    // MARK: - Telemetry

    func testTelemetryRatesAndPercentiles() {
        let telemetry = CompletionTelemetryStore(url: nil)
        (0..<4).forEach { _ in telemetry.recordShown() }
        telemetry.recordSuppressed(reason: "displayWidthExceeded")
        telemetry.recordSuppressed(reason: "noCandidate")
        telemetry.recordAccepted()
        telemetry.recordAccepted()
        for ms in stride(from: 10.0, through: 100.0, by: 10.0) {
            telemetry.recordLatency(milliseconds: ms)
        }

        let s = telemetry.snapshot()
        XCTAssertEqual(s.generatedCount, 6)
        XCTAssertEqual(s.shownCount, 4)
        XCTAssertEqual(s.suppressedCount, 2)
        XCTAssertEqual(s.acceptedCount, 2)
        XCTAssertEqual(s.acceptanceRate, 0.5, accuracy: 0.0001)
        XCTAssertEqual(s.suppressionRate, 2.0 / 6.0, accuracy: 0.0001)
        XCTAssertEqual(s.latencySampleCount, 10)
        XCTAssertGreaterThan(s.latencyMillisP95, s.latencyMillisP50)
    }

    func testTelemetryEndToEndSamplePercentilesAndBreakdown() {
        let telemetry = CompletionTelemetryStore(url: nil)
        // 10 samples whose total walks 50→500 ms. The phase contributions are kept distinct so the
        // per-phase percentiles must come from sorting that column on its own, not from the
        // worst-total sample.
        for i in 1...10 {
            let total = Double(i) * 50
            telemetry.recordEndToEndSample(
                CompletionLatencySample(
                    totalMillis: total,
                    promptBuildMillis: Double(i),
                    debounceMillis: 35,
                    generationMillis: total - Double(i) - 35 - 1,
                    presentMillis: 1
                )
            )
        }

        let e2e = telemetry.snapshot().endToEnd
        XCTAssertEqual(e2e.sampleCount, 10)
        XCTAssertEqual(e2e.total.p50, 275, accuracy: 0.001)
        XCTAssertEqual(e2e.total.p95, 477.5, accuracy: 0.001)
        XCTAssertEqual(e2e.total.mean, 275, accuracy: 0.001)
        XCTAssertEqual(e2e.debounce.p50, 35, accuracy: 0.001)
        XCTAssertEqual(e2e.debounce.p95, 35, accuracy: 0.001)
        XCTAssertEqual(e2e.promptBuild.p50, 5.5, accuracy: 0.001)
        XCTAssertEqual(e2e.present.p95, 1, accuracy: 0.001)
        XCTAssertGreaterThan(e2e.generation.p95, e2e.generation.p50)
        XCTAssertEqual(e2e.totalSamples.count, 10)
        XCTAssertEqual(e2e.totalSamples.first, 50)
        XCTAssertEqual(e2e.totalSamples.last, 500)
    }

    func testTelemetryEndToEndSampleReservoirIsBounded() {
        let telemetry = CompletionTelemetryStore(url: nil)
        for i in 0..<600 {
            telemetry.recordEndToEndSample(
                CompletionLatencySample(
                    totalMillis: Double(i),
                    promptBuildMillis: 1,
                    debounceMillis: 1,
                    generationMillis: Double(max(i - 3, 0)),
                    presentMillis: 1
                )
            )
        }
        let e2e = telemetry.snapshot().endToEnd
        XCTAssertEqual(e2e.sampleCount, 500, "reservoir must cap to maxEndToEndSamples")
        XCTAssertEqual(e2e.totalSamples.first, 100, "oldest samples should have been dropped first")
        XCTAssertEqual(e2e.totalSamples.last, 599)
    }

    func testTelemetryEndToEndSampleRejectsBadValues() {
        let telemetry = CompletionTelemetryStore(url: nil)
        telemetry.recordEndToEndSample(
            CompletionLatencySample(totalMillis: .nan, promptBuildMillis: 1, debounceMillis: 1, generationMillis: 1, presentMillis: 1)
        )
        telemetry.recordEndToEndSample(
            CompletionLatencySample(totalMillis: 10, promptBuildMillis: -1, debounceMillis: 1, generationMillis: 1, presentMillis: 1)
        )
        telemetry.recordEndToEndSample(
            CompletionLatencySample(totalMillis: 10, promptBuildMillis: 1, debounceMillis: 1, generationMillis: 1, presentMillis: 1)
        )
        XCTAssertEqual(telemetry.snapshot().endToEnd.sampleCount, 1)
    }

    func testTelemetryClearResets() {
        let telemetry = CompletionTelemetryStore(url: nil)
        telemetry.recordShown()
        telemetry.recordAccepted()
        telemetry.recordEndToEndSample(
            CompletionLatencySample(totalMillis: 100, promptBuildMillis: 1, debounceMillis: 35, generationMillis: 63, presentMillis: 1)
        )
        telemetry.clearAll()
        let s = telemetry.snapshot()
        XCTAssertEqual(s.generatedCount, 0)
        XCTAssertEqual(s.shownCount, 0)
        XCTAssertEqual(s.acceptedCount, 0)
        XCTAssertEqual(s.endToEnd.sampleCount, 0)
        XCTAssertTrue(s.endToEnd.totalSamples.isEmpty)
    }

    func testTelemetryPersistsAcrossInstances() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keytype-telemetry-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = CompletionTelemetryStore(url: url)
        first.recordShown()
        first.recordAccepted()
        first.recordEndToEndSample(
            CompletionLatencySample(totalMillis: 120, promptBuildMillis: 2, debounceMillis: 35, generationMillis: 82, presentMillis: 1)
        )

        let second = CompletionTelemetryStore(url: url)
        let s = second.snapshot()
        XCTAssertEqual(s.shownCount, 1)
        XCTAssertEqual(s.acceptedCount, 1)
        XCTAssertEqual(s.endToEnd.sampleCount, 1)
        XCTAssertEqual(s.endToEnd.totalSamples.first, 120)
    }

    func testTelemetrySnapshotCurrentStatsCopiesAndClearsCurrentStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keytype-telemetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("telemetry.json")
        let telemetry = CompletionTelemetryStore(url: url)
        telemetry.recordShown()
        telemetry.recordAccepted()
        telemetry.recordLatency(milliseconds: 87)
        telemetry.recordEndToEndSample(
            CompletionLatencySample(totalMillis: 120, promptBuildMillis: 2, debounceMillis: 35, generationMillis: 82, presentMillis: 1)
        )

        let archived = try telemetry.snapshotCurrentStats(now: Date(timeIntervalSince1970: 1_780_000_000))

        XCTAssertEqual(archived.filename, "keytype-latency-20260528-202640Z.json")
        XCTAssertEqual(archived.url.deletingLastPathComponent(), directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "current telemetry file should be cleared")
        XCTAssertEqual(archived.snapshot.shownCount, 1)
        XCTAssertEqual(archived.snapshot.acceptedCount, 1)
        XCTAssertEqual(archived.snapshot.endToEnd.sampleCount, 1)

        let current = telemetry.snapshot()
        XCTAssertEqual(current.shownCount, 0)
        XCTAssertEqual(current.acceptedCount, 0)
        XCTAssertEqual(current.endToEnd.sampleCount, 0)

        let archives = telemetry.archivedSnapshots()
        XCTAssertEqual(archives.map(\.filename), [archived.filename])
        XCTAssertEqual(archives.first?.snapshot.endToEnd.totalSamples, [120])
    }

    func testTelemetrySnapshotCurrentStatsUsesUniqueFilenamesWithinSameSecond() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keytype-telemetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("telemetry.json")
        let telemetry = CompletionTelemetryStore(url: url)
        let now = Date(timeIntervalSince1970: 1_780_000_000)

        telemetry.recordShown()
        let first = try telemetry.snapshotCurrentStats(now: now)
        telemetry.recordShown()
        let second = try telemetry.snapshotCurrentStats(now: now)

        XCTAssertEqual(first.filename, "keytype-latency-20260528-202640Z.json")
        XCTAssertEqual(second.filename, "keytype-latency-20260528-202640Z-2.json")
        XCTAssertEqual(telemetry.archivedSnapshots().count, 2)
    }

    func testTelemetryArchivedSnapshotsIgnoreLatencyExportFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keytype-telemetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("telemetry.json")
        let telemetry = CompletionTelemetryStore(url: url)

        let export = LatencyExport(
            schemaVersion: LatencyExporter.currentSchemaVersion,
            exportedAt: Date(timeIntervalSince1970: 1_780_000_000),
            device: LatencyExportDeviceInfo(osVersion: "26.4.0", physicalMemoryBytes: 1, processorCount: 1),
            engine: LatencyExportEngineInfo(),
            counters: LatencyExportCounters(
                generatedCount: 1,
                shownCount: 1,
                suppressedCount: 0,
                acceptedCount: 0,
                suppressionReasons: [:]
            ),
            endToEndSamples: [
                CompletionLatencySample(totalMillis: 120, promptBuildMillis: 2, debounceMillis: 35, generationMillis: 82, presentMillis: 1)
            ],
            decoderLatenciesMillis: [82]
        )
        let exportURL = directory.appendingPathComponent("keytype-latency-20260529-084640Z.json")
        try LatencyExporter.encodeJSON(export).write(to: exportURL)

        XCTAssertTrue(telemetry.archivedSnapshots().isEmpty)
    }

    func testTelemetryClearAllRemovesArchivedSnapshots() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keytype-telemetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("telemetry.json")
        let telemetry = CompletionTelemetryStore(url: url)

        telemetry.recordShown()
        let archived = try telemetry.snapshotCurrentStats(now: Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived.url.path))

        telemetry.clearAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: archived.url.path))
        XCTAssertTrue(telemetry.archivedSnapshots().isEmpty)
    }

    // MARK: - Latency export

    func testLatencyExporterPackagesAllSamplesAndContext() throws {
        let telemetry = CompletionTelemetryStore(url: nil)
        telemetry.recordShown()
        telemetry.recordShown()
        telemetry.recordSuppressed(reason: "noCandidate")
        telemetry.recordAccepted()
        telemetry.recordLatency(milliseconds: 87)
        telemetry.recordLatency(milliseconds: 142)
        telemetry.recordEndToEndSample(
            CompletionLatencySample(totalMillis: 110, promptBuildMillis: 2, debounceMillis: 35, generationMillis: 71, presentMillis: 2)
        )
        telemetry.recordEndToEndSample(
            CompletionLatencySample(totalMillis: 240, promptBuildMillis: 3, debounceMillis: 50, generationMillis: 184, presentMillis: 3)
        )

        let device = LatencyExportDeviceInfo(
            osVersion: "26.4.0",
            machineModel: "Mac15,7",
            cpuBrand: "Apple M3 Pro",
            physicalMemoryBytes: 36 * 1024 * 1024 * 1024,
            processorCount: 12,
            appVersion: "1.2.3",
            appBuild: "456"
        )
        let engine = LatencyExportEngineInfo(
            modelFilename: "qwen3-1.7b-q4_K_M.gguf",
            completionLengthLabel: "medium"
        )
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let export = LatencyExporter.makeExport(telemetry: telemetry, device: device, engine: engine, now: now)

        XCTAssertEqual(export.schemaVersion, LatencyExporter.currentSchemaVersion)
        XCTAssertEqual(export.exportedAt, now)
        XCTAssertEqual(export.device, device)
        XCTAssertEqual(export.engine, engine)
        XCTAssertEqual(export.counters.generatedCount, 3)
        XCTAssertEqual(export.counters.shownCount, 2)
        XCTAssertEqual(export.counters.suppressedCount, 1)
        XCTAssertEqual(export.counters.acceptedCount, 1)
        XCTAssertEqual(export.counters.suppressionReasons, ["noCandidate": 1])
        XCTAssertEqual(export.decoderLatenciesMillis, [87, 142])
        XCTAssertEqual(export.endToEndSamples.count, 2)
        XCTAssertEqual(export.endToEndSamples.first?.totalMillis, 110)
        XCTAssertEqual(export.endToEndSamples.last?.generationMillis, 184)
    }

    func testLatencyExporterJSONRoundTrips() throws {
        let telemetry = CompletionTelemetryStore(url: nil)
        telemetry.recordEndToEndSample(
            CompletionLatencySample(totalMillis: 95, promptBuildMillis: 1, debounceMillis: 35, generationMillis: 58, presentMillis: 1)
        )
        let device = LatencyExportDeviceInfo(
            osVersion: "26.4.0",
            machineModel: nil,
            cpuBrand: nil,
            physicalMemoryBytes: 16 * 1024 * 1024 * 1024,
            processorCount: 8
        )
        let engine = LatencyExportEngineInfo()
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let original = LatencyExporter.makeExport(telemetry: telemetry, device: device, engine: engine, now: now)

        let data = try LatencyExporter.encodeJSON(original)

        // Pretty-printed output is much easier for a human reporter to skim before sending.
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"schemaVersion\" : 1"), "expected pretty-printed schema header")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LatencyExport.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testLatencyExporterSuggestedFilenameIsStableAndSortable() {
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        let name = LatencyExporter.suggestedFilename(at: date)
        XCTAssertTrue(name.hasPrefix("keytype-latency-"))
        XCTAssertTrue(name.hasSuffix("Z.json"))
        // 15-character "yyyyMMdd-HHmmss" timestamp between the prefix and the trailing "Z.json".
        let middle = name
            .replacingOccurrences(of: "keytype-latency-", with: "")
            .replacingOccurrences(of: "Z.json", with: "")
        XCTAssertEqual(middle.count, 15)
    }

    func testTelemetryToleratesPersistedStateWithoutEndToEndField() throws {
        // Simulates an older JSON file written by a previous KeyType build that had no
        // `endToEndSamples` key. The store must keep the counters that *are* present rather than
        // zeroing everything out because one new field can't be decoded.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keytype-telemetry-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let legacy: [String: Any] = [
            "generatedCount": 7,
            "shownCount": 5,
            "suppressedCount": 2,
            "acceptedCount": 3,
            "suppressionReasons": ["noCandidate": 2],
            "latenciesMillis": [40.0, 60.0, 80.0]
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy, options: [])
        try data.write(to: url)

        let store = CompletionTelemetryStore(url: url)
        let s = store.snapshot()
        XCTAssertEqual(s.generatedCount, 7)
        XCTAssertEqual(s.shownCount, 5)
        XCTAssertEqual(s.acceptedCount, 3)
        XCTAssertEqual(s.latencySampleCount, 3)
        XCTAssertEqual(s.endToEnd.sampleCount, 0)
    }

    // MARK: - Threshold tuner

    func testTunerNeutralBelowMinimumSamples() {
        let snapshot = TelemetrySnapshot(generatedCount: 5, shownCount: 1, suppressedCount: 4, acceptedCount: 0)
        XCTAssertEqual(ThresholdTuner.adjustments(for: snapshot), .neutral)
    }

    func testTunerRelaxesWhenSuppressionHighAcceptanceLow() {
        let snapshot = TelemetrySnapshot(generatedCount: 100, shownCount: 10, suppressedCount: 90, acceptedCount: 1)
        let a = ThresholdTuner.adjustments(for: snapshot)
        XCTAssertGreaterThan(a.relativeCutoffDelta, 0, "should widen the search")
        XCTAssertLessThan(a.minBranchProbabilityScale, 1, "should lower the probability floor")
    }

    func testTunerTightensWhenAcceptanceHigh() {
        let snapshot = TelemetrySnapshot(generatedCount: 100, shownCount: 80, suppressedCount: 20, acceptedCount: 64)
        let a = ThresholdTuner.adjustments(for: snapshot)
        XCTAssertLessThan(a.relativeCutoffDelta, 0)
        XCTAssertGreaterThan(a.minBranchProbabilityScale, 1)
    }

    func testTunerClampsWithinBounds() {
        let snapshot = TelemetrySnapshot(generatedCount: 1000, shownCount: 10, suppressedCount: 990, acceptedCount: 0)
        let a = ThresholdTuner.adjustments(for: snapshot)
        XCTAssertLessThanOrEqual(abs(a.relativeCutoffDelta), ThresholdTuner.maxCutoffDelta)
        XCTAssertGreaterThanOrEqual(a.minBranchProbabilityScale, ThresholdTuner.minProbabilityScale)
        XCTAssertLessThanOrEqual(a.minBranchProbabilityScale, ThresholdTuner.maxProbabilityScale)
    }

    // MARK: - Keychain

    func testKeychainPassphraseRoundTripIfAvailable() throws {
        let service = "com.pattonium.KeyType.tests.\(UUID().uuidString)"
        let account = "test"
        do {
            let first = try KeychainPassphrase.loadOrCreate(service: service, account: account)
            let second = try KeychainPassphrase.loadOrCreate(service: service, account: account)
            XCTAssertEqual(first, second, "passphrase must be stable across calls")
            XCTAssertEqual(first.count, 64, "32 random bytes hex-encoded")
            try KeychainPassphrase.delete(service: service, account: account)
            XCTAssertNil(try KeychainPassphrase.load(service: service, account: account))
        } catch {
            throw XCTSkip("Keychain unavailable in this environment: \(error)")
        }
    }
}
