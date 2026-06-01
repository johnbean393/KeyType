//
//  KeyTypeTests.swift
//  KeyTypeTests
//
//  Created by John Bean on 5/29/26.
//

import AutocompleteCore
import Testing
@testable import KeyType

struct KeyTypeTests {
    private static let target = AppTarget(bundleIdentifier: "com.test.app", appName: "Test")

    private static func promotionCache(
        candidates: [String],
        beforeCursor: String = "I will "
    ) -> CompletionPromotionCache {
        CompletionPromotionCache(
            anchorContext: TextFieldContext(beforeCursor: beforeCursor, target: target),
            entries: candidates.enumerated().map { index, text in
                CompletionPromotionCache.Entry(anchorText: text, sourceRank: index)
            }
        )
    }

    private static func liveContext(
        typed typedSinceAnchor: String,
        beforeCursor: String = "I will "
    ) -> TextFieldContext {
        TextFieldContext(beforeCursor: beforeCursor + typedSinceAnchor, target: target)
    }

    @Test func adaptiveDebounceUsesFastPathAfterResponsiveGeneration() {
        #expect(CompletionController.adaptiveDebounceNanoseconds(lastGenerationLatencyMs: 35) == 35_000_000)
    }

    @Test func adaptiveDebounceKeepsConservativeDelayAfterSlowGeneration() {
        #expect(CompletionController.adaptiveDebounceNanoseconds(lastGenerationLatencyMs: 180) == 90_000_000)
    }

    @Test func adaptiveDebounceStartsAtModerateDelayBeforeTelemetry() {
        #expect(CompletionController.adaptiveDebounceNanoseconds(lastGenerationLatencyMs: nil) == 50_000_000)
    }

    @Test func typeThroughAdvanceConsumesTypedPrefixBeforeAXSnapshot() {
        let anchor = TextFieldContext(beforeCursor: "with a 20-core Media", target: Self.target)
        let advanced = CompletionController.typeThroughAdvance(
            anchorText: "Tek designed GPU, and a 10",
            anchorContext: anchor,
            liveContext: anchor,
            typedCharacters: "T"
        )

        #expect(advanced?.context.beforeCursor == "with a 20-core MediaT")
        #expect(advanced?.remainingText == "ek designed GPU, and a 10")
    }

    @Test func typeThroughAdvanceStacksWithoutWaitingForAXSnapshot() {
        let anchor = TextFieldContext(beforeCursor: "with a 20-core Media", target: Self.target)
        let first = CompletionController.typeThroughAdvance(
            anchorText: "Tek designed GPU",
            anchorContext: anchor,
            liveContext: anchor,
            typedCharacters: "T"
        )
        let second = first.flatMap {
            CompletionController.typeThroughAdvance(
                anchorText: "Tek designed GPU",
                anchorContext: anchor,
                liveContext: $0.context,
                typedCharacters: "e"
            )
        }

        #expect(second?.context.beforeCursor == "with a 20-core MediaTe")
        #expect(second?.remainingText == "k designed GPU")
    }

    @Test func typeThroughAdvanceRejectsDivergentTypedText() {
        let anchor = TextFieldContext(beforeCursor: "with a 20-core Media", target: Self.target)
        let advanced = CompletionController.typeThroughAdvance(
            anchorText: "Tek designed GPU",
            anchorContext: anchor,
            liveContext: anchor,
            typedCharacters: "X"
        )

        #expect(advanced == nil)
    }

    @Test func promotionCachePromotesLowerRankedBranchWhenTopIsInvalidated() {
        let cache = Self.promotionCache(candidates: [
            "ship it today",
            "review the patch",
            "send the update"
        ])

        let decision = cache.decision(for: Self.liveContext(typed: "r"))

        guard case let .promote(promotion) = decision else {
            Issue.record("Expected lower-ranked branch promotion, got \(decision)")
            return
        }
        #expect(promotion.sourceRank == 1)
        #expect(promotion.anchorText == "review the patch")
        #expect(promotion.remainingText == "eview the patch")
    }

    @Test func promotionCacheRecomputesWhenOnlyMatchesAreTooShort() {
        let cache = Self.promotionCache(candidates: ["there"])

        let decision = cache.decision(for: Self.liveContext(typed: "the"))

        guard case .recompute(.matchingBranchesTooShort) = decision else {
            Issue.record("Expected short-match recompute, got \(decision)")
            return
        }
    }

    @Test func promotionCacheRecomputesWhenNoBranchMatchesTypedText() {
        let cache = Self.promotionCache(candidates: [
            "ship it today",
            "review the patch"
        ])

        let decision = cache.decision(for: Self.liveContext(typed: "z"))

        guard case .recompute(.noMatch) = decision else {
            Issue.record("Expected no-match recompute, got \(decision)")
            return
        }
    }

    @Test func promotionCacheRecomputesWhenContextChanged() {
        let cache = Self.promotionCache(candidates: ["review the patch"])
        let live = TextFieldContext(
            beforeCursor: "I will r",
            afterCursor: " later",
            target: Self.target
        )

        let decision = cache.decision(for: live)

        guard case .recompute(.contextChanged) = decision else {
            Issue.record("Expected context-change recompute, got \(decision)")
            return
        }
    }

    @Test func promotionCacheAllowsSelectionRangeAndFieldMetadataRefreshDuringAppend() {
        let cache = Self.promotionCache(candidates: ["review the patch"])
        let live = TextFieldContext(
            beforeCursor: "I will r",
            selection: TextSelection(range: "I will r".endIndex..<"I will r".endIndex),
            target: Self.target,
            typingContext: "email-subject"
        )

        let decision = cache.decision(for: live)

        guard case let .promote(promotion) = decision else {
            Issue.record("Expected metadata refresh to keep append promotion, got \(decision)")
            return
        }
        #expect(promotion.remainingText == "eview the patch")
    }

    @Test func promotionCacheRecomputesWhenSelectionIsActive() {
        let cache = Self.promotionCache(candidates: ["review the patch"])
        let live = TextFieldContext(
            beforeCursor: "I will r",
            selection: TextSelection(selectedText: "will"),
            target: Self.target
        )

        let decision = cache.decision(for: live)

        guard case .recompute(.contextChanged) = decision else {
            Issue.record("Expected active-selection recompute, got \(decision)")
            return
        }
    }

    @Test func heldAnchorCanKeepShortRemainderThatPromotionCacheWouldReject() {
        let anchor = TextFieldContext(beforeCursor: "I will ", target: Self.target)
        let liveAfterFirstAcceptedWord = TextFieldContext(beforeCursor: "I will say ", target: Self.target)
        let cache = CompletionPromotionCache(
            anchorContext: anchor,
            entries: [
                CompletionPromotionCache.Entry(anchorText: "say hi", sourceRank: 0)
            ]
        )

        guard case .recompute(.matchingBranchesTooShort) = cache.decision(for: liveAfterFirstAcceptedWord) else {
            Issue.record("Expected cache to reject the short remaining branch")
            return
        }
        #expect(
            SuggestionAnchor.remaining(
                anchorText: "say hi",
                anchor: anchor,
                live: liveAfterFirstAcceptedWord
            ) == "hi"
        )
    }

    @Test func heldAnchorCanKeepLongRemainderWhenPromotionCacheRejectedByActiveSelection() {
        let anchor = TextFieldContext(beforeCursor: "I will ", target: Self.target)
        let liveAfterFirstAcceptedWord = TextFieldContext(
            beforeCursor: "I will review ",
            selection: TextSelection(selectedText: "selected"),
            target: Self.target
        )
        let cache = CompletionPromotionCache(
            anchorContext: anchor,
            entries: [
                CompletionPromotionCache.Entry(anchorText: "review the patch tomorrow", sourceRank: 0)
            ]
        )

        guard case .recompute(.contextChanged) = cache.decision(for: liveAfterFirstAcceptedWord) else {
            Issue.record("Expected cache to reject the active-selection branch")
            return
        }
        #expect(
            SuggestionAnchor.remaining(
                anchorText: "review the patch tomorrow",
                anchor: anchor,
                live: liveAfterFirstAcceptedWord
            ) == "the patch tomorrow"
        )
    }

    @Test func promotionCacheQuantifiesAvoidedRegenerationCoverage() {
        let branches = [
            "alpha release",
            "bravo release",
            "charlie release",
            "delta release",
            "echo release"
        ]
        let typedChoices = ["a", "b", "c", "d", "e", "z"]
        let cache = Self.promotionCache(candidates: branches)

        let cacheReusable = typedChoices.filter { typed in
            if case .promote = cache.decision(for: Self.liveContext(typed: typed)) {
                return true
            }
            return false
        }.count
        let topOnlyReusable = typedChoices.filter { typed in
            guard branches[0].hasPrefix(typed) else { return false }
            return branches[0].dropFirst(typed.count).count >= CompletionPromotionCache.defaultMinimumRemainingCharacters
        }.count

        #expect(topOnlyReusable == 1)
        #expect(cacheReusable == 5)
        #expect(typedChoices.count - topOnlyReusable == 5)
        #expect(typedChoices.count - cacheReusable == 1)
    }

}
