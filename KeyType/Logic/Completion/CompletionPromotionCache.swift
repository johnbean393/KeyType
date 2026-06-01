import AutocompleteCore
import Foundation

/// String-only snapshot of one generated candidate set.
///
/// It lets the controller keep using a lower-ranked branch when the user types into it, without
/// retaining model logits or KV branch state. `CompletionReuseHistory` keeps a bounded set of these
/// snapshots so append and small rollback edits can reuse generated strings before decoding again.
struct CompletionPromotionCache: Equatable {
    static let defaultMinimumRemainingCharacters = 3

    struct Entry: Equatable {
        var anchorText: String
        var sourceRank: Int
        var logProbability: Double

        init(anchorText: String, sourceRank: Int, logProbability: Double = 0) {
            self.anchorText = anchorText
            self.sourceRank = sourceRank
            self.logProbability = logProbability
        }
    }

    struct Promotion: Equatable {
        var anchorText: String
        var remainingText: String
        var sourceRank: Int
        var logProbability: Double
    }

    enum RecomputeReason: Equatable {
        case noTypedDelta
        case contextChanged
        case noMatch
        case matchingBranchesTooShort
    }

    enum Decision: Equatable {
        case promote(Promotion)
        case recompute(RecomputeReason)
    }

    var anchorContext: TextFieldContext
    var entries: [Entry]
    var minimumRemainingCharacters: Int

    init(
        anchorContext: TextFieldContext,
        entries: [Entry],
        minimumRemainingCharacters: Int = Self.defaultMinimumRemainingCharacters
    ) {
        self.anchorContext = anchorContext
        self.entries = entries.sorted {
            if $0.sourceRank != $1.sourceRank { return $0.sourceRank < $1.sourceRank }
            if $0.logProbability != $1.logProbability { return $0.logProbability > $1.logProbability }
            return $0.anchorText < $1.anchorText
        }
        self.minimumRemainingCharacters = max(1, minimumRemainingCharacters)
    }

    func decision(for liveContext: TextFieldContext) -> Decision {
        guard stableContextMatches(liveContext) else {
            return .recompute(.contextChanged)
        }

        let typedSinceAnchor = String(liveContext.beforeCursor.dropFirst(anchorContext.beforeCursor.count))
        guard !typedSinceAnchor.isEmpty else {
            return .recompute(.noTypedDelta)
        }

        var sawShortMatch = false
        for entry in entries {
            guard let remaining = SuggestionAnchor.remaining(
                anchorText: entry.anchorText,
                anchor: anchorContext,
                live: liveContext
            ) else {
                continue
            }
            if remaining.count < minimumRemainingCharacters {
                sawShortMatch = true
                continue
            }
            return .promote(
                Promotion(
                    anchorText: entry.anchorText,
                    remainingText: remaining,
                    sourceRank: entry.sourceRank,
                    logProbability: entry.logProbability
                )
            )
        }

        return .recompute(sawShortMatch ? .matchingBranchesTooShort : .noMatch)
    }

    private func stableContextMatches(_ liveContext: TextFieldContext) -> Bool {
        let anchorHasSelection = !(anchorContext.selection.selectedText ?? "").isEmpty
        let liveHasSelection = !(liveContext.selection.selectedText ?? "").isEmpty
        return liveContext.target == anchorContext.target
            && liveContext.afterCursor == anchorContext.afterCursor
            && liveContext.traits == anchorContext.traits
            && liveContext.beforeCursor.hasPrefix(anchorContext.beforeCursor)
            && !anchorHasSelection
            && !liveHasSelection
    }
}
