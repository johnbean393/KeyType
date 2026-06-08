import Foundation

/// One stored writing sample. Mirrors the selection-dimension shape called out in
/// `docs/02-prompting.md` so the real on-disk store (M8) can drop in without changing
/// the consumer.
public struct WritingHistorySample: Equatable {
    public var text: String
    public var appBundleIdentifier: String?
    public var domain: String?
    public var typingContext: String?
    public var language: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var hasAcceptedCompletion: Bool

    public init(
        text: String,
        appBundleIdentifier: String? = nil,
        domain: String? = nil,
        typingContext: String? = nil,
        language: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        hasAcceptedCompletion: Bool = false
    ) {
        self.text = text
        self.appBundleIdentifier = appBundleIdentifier
        self.domain = domain
        self.typingContext = typingContext
        self.language = language
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.hasAcceptedCompletion = hasAcceptedCompletion
    }
}

/// Selection knobs for `WritingHistoryProviding.samples(for:)`. The defaults are
/// reasonable for a small in-memory stub; M8 will tune them off real telemetry.
public struct WritingHistoryQuery: Equatable {
    public var bundleIdentifier: String?
    public var domain: String?
    public var typingContext: String?
    public var language: String?
    public var fetchSize: Int
    public var minimumCharacters: Int
    public var longestCount: Int
    public var mostRecentCount: Int
    public var crossAppRecentCount: Int
    public var tokenBudget: Int
    public var sameAppOnly: Bool

    public init(
        bundleIdentifier: String? = nil,
        domain: String? = nil,
        typingContext: String? = nil,
        language: String? = nil,
        fetchSize: Int = 8,
        minimumCharacters: Int = 12,
        longestCount: Int = 2,
        mostRecentCount: Int = 4,
        crossAppRecentCount: Int = 2,
        tokenBudget: Int = 256,
        sameAppOnly: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.domain = domain
        self.typingContext = typingContext
        self.language = language
        self.fetchSize = fetchSize
        self.minimumCharacters = minimumCharacters
        self.longestCount = longestCount
        self.mostRecentCount = mostRecentCount
        self.crossAppRecentCount = crossAppRecentCount
        self.tokenBudget = tokenBudget
        self.sameAppOnly = sameAppOnly
    }
}

/// Source of `previousUserInputs` for the prompt builder. Kept as a protocol so the
/// app target can swap in a persistent store (M8) without touching `Prompting`.
public protocol WritingHistoryProviding {
    func samples(for query: WritingHistoryQuery) -> [String]
}

/// Trivial in-memory implementation used during M3. Real persistence + smarter
/// recency/longest mixing lands in M8 (`docs/04-roadmap.md`). Selection mirrors the
/// "recent + long + same-context" guidance from `docs/02-prompting.md`.
public struct InMemoryWritingHistoryStore: WritingHistoryProviding {
    public var entries: [WritingHistorySample]

    public init(entries: [WritingHistorySample] = []) {
        self.entries = entries
    }

    public func samples(for query: WritingHistoryQuery) -> [String] {
        let candidates = entries.filter { entry in
            guard entry.text.count >= query.minimumCharacters else { return false }
            if query.sameAppOnly, let bundle = query.bundleIdentifier,
               entry.appBundleIdentifier != bundle {
                return false
            }
            if let language = query.language, let entryLanguage = entry.language,
               entryLanguage != language {
                return false
            }
            return true
        }

        let sameApp = candidates.filter { entry in
            guard let bundle = query.bundleIdentifier else { return true }
            guard entry.appBundleIdentifier == bundle else { return false }
            // For web fields the bundle is the browser, shared across sites; require a matching domain
            // so a different tab's content can't be treated as same-context. Native apps have no
            // domain, so this is inert for them. Mirrors `WritingHistorySelection` in Personalization.
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

        let recentSameApp = sameApp.sorted { $0.updatedAt > $1.updatedAt }
        take(recentSameApp, upTo: query.mostRecentCount)

        let longestSameApp = sameApp.sorted { $0.text.count > $1.text.count }
        take(longestSameApp, upTo: query.longestCount)

        if !query.sameAppOnly {
            let recentCrossApp = crossApp.sorted { $0.updatedAt > $1.updatedAt }
            take(recentCrossApp, upTo: query.crossAppRecentCount)
        }

        return Array(picked.prefix(query.fetchSize)).map { $0.text }
    }
}
