import AutocompleteCore
import Foundation

/// Bounded, string-only history of recently generated candidate anchors.
///
/// The history intentionally stores no logits, token branches, or KV state. It exists only to keep
/// already-generated, filter-approved strings available across ordinary append typing and small
/// rollback edits such as deleting a typo.
struct CompletionReuseHistory: Equatable {
    static let defaultMaxEntries = 150
    static let defaultMinimumEntriesPerKindFraction = 0.1

    enum ReuseKind: String, Equatable {
        case append
        case rollback
    }

    enum MissReason: String, Equatable {
        case empty
        case noTypedDelta
        case contextChanged
        case noMatch
        case matchingBranchesTooShort
    }

    struct Reuse: Equatable {
        var kind: ReuseKind
        var snapshotID: UInt64
        var anchorContext: TextFieldContext
        var anchorText: String
        var remainingText: String
        var sourceRank: Int
        var logProbability: Double
    }

    enum Decision: Equatable {
        case reuse(Reuse)
        case miss(kind: ReuseKind, reason: MissReason)
    }

    struct Eviction: Equatable {
        var removedEntries: Int
        var remainingEntries: Int
    }

    private struct Snapshot: Equatable {
        var id: UInt64
        var cache: CompletionPromotionCache
    }

    private var snapshots: [Snapshot] = []
    private var nextSnapshotID: UInt64 = 1
    let maxEntries: Int
    let minimumEntriesPerKind: Int

    init(
        maxEntries: Int = Self.defaultMaxEntries,
        minimumEntriesPerKindFraction: Double = Self.defaultMinimumEntriesPerKindFraction
    ) {
        self.maxEntries = max(1, maxEntries)
        self.minimumEntriesPerKind = max(1, Int(ceil(Double(max(1, maxEntries)) * minimumEntriesPerKindFraction)))
    }

    var isEmpty: Bool { snapshots.isEmpty }

    var entryCount: Int {
        snapshots.reduce(0) { $0 + $1.cache.entries.count }
    }

    var appendEntryCount: Int {
        snapshots.last?.cache.entries.count ?? 0
    }

    var rollbackEntryCount: Int {
        max(0, entryCount - appendEntryCount)
    }

    @discardableResult
    mutating func record(_ cache: CompletionPromotionCache) -> Eviction? {
        guard !cache.entries.isEmpty else { return nil }

        let limitedEntries = Array(cache.entries.prefix(maxEntries))
        let limitedCache = CompletionPromotionCache(
            anchorContext: cache.anchorContext,
            entries: limitedEntries,
            minimumRemainingCharacters: cache.minimumRemainingCharacters
        )

        snapshots.removeAll { snapshot in
            snapshot.cache.anchorContext.target == limitedCache.anchorContext.target
                && snapshot.cache.anchorContext.beforeCursor == limitedCache.anchorContext.beforeCursor
                && snapshot.cache.anchorContext.afterCursor == limitedCache.anchorContext.afterCursor
                && snapshot.cache.anchorContext.traits == limitedCache.anchorContext.traits
        }
        snapshots.append(Snapshot(id: nextSnapshotID, cache: limitedCache))
        nextSnapshotID += 1

        let removed = evictToCapacity()
        guard removed > 0 else { return nil }
        return Eviction(removedEntries: removed, remainingEntries: entryCount)
    }

    mutating func removeAll() {
        snapshots.removeAll()
    }

    func decision(
        for liveContext: TextFieldContext,
        preferredKind: ReuseKind? = nil
    ) -> Decision {
        guard !snapshots.isEmpty else {
            return .miss(kind: preferredKind ?? .append, reason: .empty)
        }

        var sawCompatibleContext = false
        var sawNoTypedDelta = false
        var sawShortMatch = false
        let kindOrder: [ReuseKind] = preferredKind.map { [$0] } ?? [.append, .rollback]

        for snapshot in snapshots.reversed() {
            guard Self.contextCanReuse(anchor: snapshot.cache.anchorContext, live: liveContext) else {
                continue
            }
            sawCompatibleContext = true

            for kind in kindOrder {
                switch decision(in: snapshot, for: liveContext, kind: kind) {
                case let .reuse(reuse):
                    return .reuse(reuse)
                case .miss(_, .noTypedDelta):
                    sawNoTypedDelta = true
                case .miss(_, .matchingBranchesTooShort):
                    sawShortMatch = true
                case .miss:
                    break
                }
            }
        }

        let fallbackKind = preferredKind ?? .append
        if sawShortMatch {
            return .miss(kind: fallbackKind, reason: .matchingBranchesTooShort)
        }
        if sawNoTypedDelta {
            return .miss(kind: fallbackKind, reason: .noTypedDelta)
        }
        if sawCompatibleContext {
            return .miss(kind: fallbackKind, reason: .noMatch)
        }
        return .miss(kind: fallbackKind, reason: .contextChanged)
    }

    /// Backspace can mean either "return to an older anchor" (rollback reuse) or "shrink an already
    /// reused append branch" (append reuse from the original snapshot). Prefer rollback, then fall
    /// back to append before forcing a decode.
    func decisionAfterDeleteBackward(for liveContext: TextFieldContext) -> Decision {
        let rollback = decision(for: liveContext, preferredKind: .rollback)
        if case .reuse = rollback {
            return rollback
        }

        let append = decision(for: liveContext, preferredKind: .append)
        if case .reuse = append {
            return append
        }
        if case .miss(_, .matchingBranchesTooShort) = append {
            return append
        }
        return rollback
    }

    private func decision(
        in snapshot: Snapshot,
        for liveContext: TextFieldContext,
        kind: ReuseKind
    ) -> Decision {
        switch kind {
        case .append:
            return appendDecision(in: snapshot, for: liveContext)
        case .rollback:
            return rollbackDecision(in: snapshot, for: liveContext)
        }
    }

    private func appendDecision(in snapshot: Snapshot, for liveContext: TextFieldContext) -> Decision {
        let anchor = snapshot.cache.anchorContext
        guard liveContext.beforeCursor.hasPrefix(anchor.beforeCursor) else {
            return .miss(kind: .append, reason: .noMatch)
        }

        let typedSinceAnchor = String(liveContext.beforeCursor.dropFirst(anchor.beforeCursor.count))
        guard !typedSinceAnchor.isEmpty else {
            return .miss(kind: .append, reason: .noTypedDelta)
        }

        var sawShortMatch = false
        for entry in snapshot.cache.entries {
            guard let remaining = SuggestionAnchor.remaining(
                anchorText: entry.anchorText,
                anchor: anchor,
                live: liveContext
            ) else {
                continue
            }
            if remaining.count < snapshot.cache.minimumRemainingCharacters {
                sawShortMatch = true
                continue
            }
            return .reuse(
                Reuse(
                    kind: .append,
                    snapshotID: snapshot.id,
                    anchorContext: liveContext,
                    anchorText: remaining,
                    remainingText: remaining,
                    sourceRank: entry.sourceRank,
                    logProbability: entry.logProbability
                )
            )
        }

        return .miss(kind: .append, reason: sawShortMatch ? .matchingBranchesTooShort : .noMatch)
    }

    private func rollbackDecision(in snapshot: Snapshot, for liveContext: TextFieldContext) -> Decision {
        let anchor = snapshot.cache.anchorContext
        guard anchor.beforeCursor.hasPrefix(liveContext.beforeCursor) else {
            return .miss(kind: .rollback, reason: .noMatch)
        }

        let rolledBackText = String(anchor.beforeCursor.dropFirst(liveContext.beforeCursor.count))
        var sawShortMatch = false
        for entry in snapshot.cache.entries {
            let remaining = rolledBackText + entry.anchorText
            if remaining.count < snapshot.cache.minimumRemainingCharacters {
                sawShortMatch = true
                continue
            }
            return .reuse(
                Reuse(
                    kind: .rollback,
                    snapshotID: snapshot.id,
                    anchorContext: liveContext,
                    anchorText: remaining,
                    remainingText: remaining,
                    sourceRank: entry.sourceRank,
                    logProbability: entry.logProbability
                )
            )
        }

        return .miss(kind: .rollback, reason: sawShortMatch ? .matchingBranchesTooShort : .noMatch)
    }

    private static func contextCanReuse(anchor: TextFieldContext, live: TextFieldContext) -> Bool {
        let anchorHasSelection = !(anchor.selection.selectedText ?? "").isEmpty
        let liveHasSelection = !(live.selection.selectedText ?? "").isEmpty
        return anchor.target == live.target
            && anchor.afterCursor == live.afterCursor
            && anchor.traits == live.traits
            && !anchorHasSelection
            && !liveHasSelection
    }

    private mutating func evictToCapacity() -> Int {
        var removed = 0
        while entryCount > maxEntries {
            let overflow = entryCount - maxEntries
            if let removal = plannedRemoval(maxCount: overflow, respectingBudgets: true)
                ?? plannedRemoval(maxCount: overflow, respectingBudgets: false) {
                snapshots[removal.snapshotIndex].cache.entries.removeLast(removal.count)
                removed += removal.count
                snapshots.removeAll { $0.cache.entries.isEmpty }
            } else {
                break
            }
        }
        return removed
    }

    private struct RemovalPlan {
        var snapshotIndex: Int
        var count: Int
    }

    private func plannedRemoval(maxCount: Int, respectingBudgets: Bool) -> RemovalPlan? {
        guard maxCount > 0 else { return nil }

        for index in snapshots.indices {
            let snapshotEntryCount = snapshots[index].cache.entries.count
            guard snapshotEntryCount > 0 else { continue }

            let bucketCount = index == snapshots.index(before: snapshots.endIndex)
                ? appendEntryCount
                : rollbackEntryCount
            let removableByBudget = respectingBudgets
                ? max(0, bucketCount - minimumEntriesPerKind)
                : bucketCount
            let removable = min(snapshotEntryCount, maxCount, removableByBudget)
            if removable > 0 {
                return RemovalPlan(snapshotIndex: index, count: removable)
            }
        }
        return nil
    }
}
