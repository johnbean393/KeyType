import Foundation
import GRDB
import Prompting

/// A writing-history store that can be both queried (for `previousUserInputs`) and written to (by
/// the recorder), and cleared in one action. Sendable so the app can record off the main actor.
public protocol WritingHistoryStoring: WritingHistoryProviding, Sendable {
    func record(_ sample: WritingHistorySample)
    func clearAll()
    func count() -> Int
}

/// No-op store used as a graceful fallback when the encrypted database can't be opened. Keeps the
/// completion pipeline alive (it just never has any personalization samples).
public struct NullWritingHistoryStore: WritingHistoryStoring {
    public init() {}
    public func samples(for query: WritingHistoryQuery) -> [String] { [] }
    public func record(_ sample: WritingHistorySample) {}
    public func clearAll() {}
    public func count() -> Int { 0 }
}

/// One row in the encrypted writing-history database. Mirrors `WritingHistorySample`
/// (`Prompting`) plus a denormalized `charCount` used for cheap longest/budget selection.
struct StoredWritingSample: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var text: String
    var appBundleIdentifier: String?
    var domain: String?
    var typingContext: String?
    var language: String?
    var createdAt: Date
    var updatedAt: Date
    var hasAcceptedCompletion: Bool
    var charCount: Int

    static let databaseTableName = "writingSample"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    init(sample: WritingHistorySample) {
        self.id = nil
        self.text = sample.text
        self.appBundleIdentifier = sample.appBundleIdentifier
        self.domain = sample.domain
        self.typingContext = sample.typingContext
        self.language = sample.language
        self.createdAt = sample.createdAt
        self.updatedAt = sample.updatedAt
        self.hasAcceptedCompletion = sample.hasAcceptedCompletion
        self.charCount = sample.text.count
    }

    var asSample: WritingHistorySample {
        WritingHistorySample(
            text: text,
            appBundleIdentifier: appBundleIdentifier,
            domain: domain,
            typingContext: typingContext,
            language: language,
            createdAt: createdAt,
            updatedAt: updatedAt,
            hasAcceptedCompletion: hasAcceptedCompletion
        )
    }
}

/// On-device, opt-in writing-history store, encrypted at rest with SQLCipher. Conforms to
/// `WritingHistoryProviding` so it drops straight into the prompt builder in place of the M3
/// in-memory stub.
///
/// - Encryption: the database is opened with a Keychain-held passphrase
///   (`KeychainPassphrase`); the file on disk is unreadable without it.
/// - Privacy: all data stays in `~/Library/Application Support/KeyType/History/` and is removed in
///   one action via `clearAll()` (the app also wipes the Keychain passphrase).
/// - Resilience: `record(_:)`/`samples(for:)` never throw out to the live completion path — they
///   swallow database errors and degrade to a no-op / empty result so a storage hiccup can't break
///   typing. Construction *can* throw; the app falls back to the in-memory store in that case.
///
/// See ADR-023.
///
/// `@unchecked Sendable`: the only stored state is a GRDB `DatabaseQueue` (thread-safe; it
/// serializes access internally) and an immutable URL, so concurrent `record`/`samples` calls from
/// different actors are safe.
public final class PersistentWritingHistoryStore: WritingHistoryStoring, @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    private let databaseURL: URL

    /// Default location of the encrypted database inside Application Support.
    public static func defaultDatabaseURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support
            .appendingPathComponent("KeyType/History", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("history.sqlcipher", isDirectory: false)
    }

    /// Opens (creating if needed) the encrypted database at `databaseURL`, using `passphrase` as
    /// the SQLCipher key. Defaults resolve the standard on-device location and the Keychain
    /// passphrase. Throws if the directory, keychain, or database can't be opened.
    public init(
        databaseURL: URL? = nil,
        passphrase: String? = nil
    ) throws {
        let url = try databaseURL ?? Self.defaultDatabaseURL()
        let key = try passphrase ?? KeychainPassphrase.loadOrCreate()

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.usePassphrase(key)
        }
        self.databaseURL = url
        self.dbQueue = try DatabaseQueue(path: url.path, configuration: configuration)
        try Self.migrator.migrate(dbQueue)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-create-writingSample") { db in
            try db.create(table: StoredWritingSample.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("text", .text).notNull()
                t.column("appBundleIdentifier", .text)
                t.column("domain", .text)
                t.column("typingContext", .text)
                t.column("language", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("hasAcceptedCompletion", .boolean).notNull().defaults(to: false)
                t.column("charCount", .integer).notNull().defaults(to: 0)
            }
            try db.create(
                index: "idx_sample_bundle_updated",
                on: StoredWritingSample.databaseTableName,
                columns: ["appBundleIdentifier", "updatedAt"]
            )
        }
        return migrator
    }

    // MARK: - Recording

    /// Persists one writing sample, deduping against a recent identical capture from the same app
    /// (when the same text was last seen, only its `updatedAt`/acceptance is refreshed). Errors are
    /// swallowed so a storage failure can't interrupt typing.
    public func record(_ sample: WritingHistorySample) {
        let trimmed = sample.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try dbQueue.write { db in
                let existing = try StoredWritingSample
                    .filter(Column("text") == sample.text)
                    .filter(Column("appBundleIdentifier") == sample.appBundleIdentifier)
                    .fetchOne(db)
                if var existing {
                    existing.updatedAt = sample.updatedAt
                    existing.hasAcceptedCompletion = existing.hasAcceptedCompletion || sample.hasAcceptedCompletion
                    try existing.update(db)
                } else {
                    var row = StoredWritingSample(sample: sample)
                    try row.insert(db)
                }
            }
        } catch {
            // Intentionally ignored: history is best-effort and must never break the typing path.
        }
    }

    /// Total stored samples (for diagnostics / Settings stats).
    public func count() -> Int {
        (try? dbQueue.read { db in try StoredWritingSample.fetchCount(db) }) ?? 0
    }

    // MARK: - Clearing

    /// Deletes every stored sample in one action. Used by the Settings "Clear all personal data"
    /// control. Errors are swallowed.
    public func clearAll() {
        do {
            try dbQueue.write { db in
                _ = try StoredWritingSample.deleteAll(db)
            }
        } catch {
            // Best-effort; the app also wipes the Keychain passphrase as a hard backstop.
        }
    }

    // MARK: - WritingHistoryProviding

    public func samples(for query: WritingHistoryQuery) -> [String] {
        let candidates: [StoredWritingSample]
        do {
            candidates = try dbQueue.read { db -> [StoredWritingSample] in
                var request = StoredWritingSample
                    .filter(Column("charCount") >= query.minimumCharacters)
                if let bundle = query.bundleIdentifier, query.sameAppOnly {
                    request = request.filter(Column("appBundleIdentifier") == bundle)
                    // Web fields: keep only the focused domain's rows so a different tab in the same
                    // browser can't fill the row budget (and the in-memory selection then drops any
                    // that slip through). Native apps have a nil domain and are unaffected.
                    if let domain = query.domain, !domain.isEmpty {
                        request = request.filter(Column("domain") == domain)
                    }
                }
                if let language = query.language {
                    // Keep rows whose language matches or is unknown (conservative).
                    request = request.filter(
                        Column("language") == language || Column("language") == nil
                    )
                }
                // Hard upper bound on rows pulled into memory before mixing.
                return try request
                    .order(Column("updatedAt").desc)
                    .limit(200)
                    .fetchAll(db)
            }
        } catch {
            return []
        }

        return WritingHistorySelection.select(from: candidates.map { $0.asSample }, query: query)
    }
}

/// Pure recency/longest/cross-app mixing + token-budget capping, factored out so it is unit-testable
/// without a database. Mirrors the "recent + long + same-context" guidance in `docs/02-prompting.md`
/// and the shape of the M3 `InMemoryWritingHistoryStore`.
enum WritingHistorySelection {
    static func select(from entries: [WritingHistorySample], query: WritingHistoryQuery) -> [String] {
        let candidates = entries.filter { $0.text.count >= query.minimumCharacters }

        let sameApp = candidates.filter { entry in
            guard let bundle = query.bundleIdentifier else { return true }
            guard entry.appBundleIdentifier == bundle else { return false }
            // For web fields the bundle is the browser, so several sites share it. Require a matching
            // domain so content from a different tab (or an unknown-domain sample) can't be treated as
            // same-context and bleed in. Native apps have no domain, so this is inert for them.
            if let queryDomain = query.domain, !queryDomain.isEmpty {
                return entry.domain == queryDomain
            }
            return true
        }
        let crossApp = candidates.filter { entry in
            guard let bundle = query.bundleIdentifier else { return false }
            return entry.appBundleIdentifier != bundle
        }

        var picked: [WritingHistorySample] = []
        var seen = Set<String>()

        func take(_ samples: [WritingHistorySample], upTo limit: Int) {
            for s in samples.prefix(limit) where seen.insert(s.text).inserted {
                picked.append(s)
            }
        }

        take(sameApp.sorted { $0.updatedAt > $1.updatedAt }, upTo: query.mostRecentCount)
        take(sameApp.sorted { $0.text.count > $1.text.count }, upTo: query.longestCount)
        if !query.sameAppOnly {
            take(crossApp.sorted { $0.updatedAt > $1.updatedAt }, upTo: query.crossAppRecentCount)
        }

        // Cap by both fetch size and an approximate token budget (~4 chars/token), keeping the
        // earliest-selected (highest-priority) samples.
        var result: [String] = []
        var tokens = 0
        for sample in picked.prefix(query.fetchSize) {
            let cost = max(1, Int((Double(sample.text.count) / 4.0).rounded(.up)))
            if tokens + cost > query.tokenBudget, !result.isEmpty { break }
            result.append(sample.text)
            tokens += cost
        }
        return result
    }
}
