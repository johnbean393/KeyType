//
//  KeyTypeTests.swift
//  KeyTypeTests
//
//  Created by John Bean on 5/29/26.
//

import AutocompleteCore
import AppKit
import CompletionUI
import MacContextCapture
import Testing
@testable import KeyType

struct KeyTypeTests {
    private static let target = AppTarget(bundleIdentifier: "com.test.app", appName: "Test")

    private static func temporaryDefaults() -> (UserDefaults, String) {
        let suiteName = "KeyTypeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Unable to create temporary defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private static func promotionCache(
        candidates: [String],
        beforeCursor: String = "I will ",
        minimumRemainingCharacters: Int = CompletionPromotionCache.defaultMinimumRemainingCharacters
    ) -> CompletionPromotionCache {
        CompletionPromotionCache(
            anchorContext: TextFieldContext(beforeCursor: beforeCursor, target: target),
            entries: candidates.enumerated().map { index, text in
                CompletionPromotionCache.Entry(anchorText: text, sourceRank: index)
            },
            minimumRemainingCharacters: minimumRemainingCharacters
        )
    }

    private static func candidateTexts(prefix: String, count: Int) -> [String] {
        (0..<count).map { "\(prefix) branch \($0) continuation" }
    }

    private static func liveContext(
        typed typedSinceAnchor: String,
        beforeCursor: String = "I will "
    ) -> TextFieldContext {
        TextFieldContext(beforeCursor: beforeCursor + typedSinceAnchor, target: target)
    }

    @Test func adaptiveDebounceUsesFastPathAfterResponsiveGeneration() {
        #expect(CompletionController.adaptiveDebounceNanoseconds(lastGenerationLatencyMs: 35) == 15_000_000)
    }

    @Test func adaptiveDebounceKeepsConservativeDelayAfterSlowGeneration() {
        #expect(CompletionController.adaptiveDebounceNanoseconds(lastGenerationLatencyMs: 180) == 55_000_000)
    }

    @Test func adaptiveDebounceStartsAtModerateDelayBeforeTelemetry() {
        #expect(CompletionController.adaptiveDebounceNanoseconds(lastGenerationLatencyMs: nil) == 25_000_000)
    }

    @Test @MainActor func caretDebugOverlaySnapshotUsesCapturedFieldGeometry() {
        let caret = CGRect(x: 42, y: 20, width: 2, height: 18)
        let field = CGRect(x: 10, y: 10, width: 100, height: 36)
        let context = TextFieldContext(
            beforeCursor: "hello",
            geometry: TextFieldGeometry(
                cursorRect: caret,
                fieldRect: field,
                isRightToLeft: false
            ),
            target: Self.target
        )
        let snapshot = FocusedFieldSnapshot(
            context: context,
            caretRect: caret,
            caretSource: "test",
            caretQuality: "exact"
        )

        let overlaySnapshot = ContextCaptureController.debugOverlaySnapshot(for: snapshot)

        #expect(overlaySnapshot?.caretRect == caret)
        #expect(overlaySnapshot?.fieldRect == field)
        #expect(overlaySnapshot?.availableTextRect == CGRect(x: 44, y: 20, width: 66, height: 18))
    }

    @Test @MainActor func manualAppEntriesPersistWithPerAppDisable() {
        let (defaults, suiteName) = Self.temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        store.addManualApp(bundleIdentifier: " com.example.MenuBar ", name: " MenuBar ")
        store.setApp("com.example.MenuBar", enabled: false)

        let reloaded = SettingsStore(defaults: defaults)

        #expect(reloaded.manualPerAppDisplayNames["com.example.MenuBar"] == "MenuBar")
        #expect(!reloaded.isAppEnabled("com.example.MenuBar"))
    }

    @Test @MainActor func promptCustomInstructionsAppendOSDerivedBritishEnglishAfterAppInstructions() {
        let (defaults, suiteName) = Self.temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)

        let instructions = store.promptCustomInstructions(
            appInstructions: ["Continue the current message only."],
            systemLocaleIdentifier: "en_US",
            preferredLanguages: ["en-GB"]
        )

        #expect(instructions.count == 2)
        #expect(instructions[0] == "Continue the current message only.")
        #expect(instructions[1].contains("British English"))
    }

    @Test func englishVariantUsesOnlyNonDefaultRegionalEnglishLocales() {
        let british = EnglishVariant.promptInstruction(
            systemLocaleIdentifier: "en_US",
            preferredLanguages: ["en-GB"]
        )
        let american = EnglishVariant.promptInstruction(
            systemLocaleIdentifier: "en_US",
            preferredLanguages: ["en-US"]
        )
        let nonEnglish = EnglishVariant.promptInstruction(
            systemLocaleIdentifier: "fr_FR",
            preferredLanguages: ["fr-FR"]
        )

        #expect(british?.contains("British English") == true)
        #expect(american == nil)
        #expect(nonEnglish == nil)
    }

    @Test @MainActor func unassignedAcceptanceShortcutsPersist() {
        let (defaults, suiteName) = Self.temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        store.acceptWordShortcut = .unassigned
        store.acceptFullShortcut = AcceptanceShortcut(keyCode: 48, modifiers: [], label: "\u{21E5}")

        let reloaded = SettingsStore(defaults: defaults)

        #expect(reloaded.acceptWordShortcut == .unassigned)
        #expect(!reloaded.acceptWordShortcut.matches(keyCode: 48, flags: CGEventFlags()))
        #expect(reloaded.acceptFullShortcut.matches(keyCode: 48, flags: CGEventFlags()))
    }

    @Test func capsulePresentationIsUsedForVisibleCurrentLineSuffix() {
        let context = TextFieldContext(
            beforeCursor: "This is ",
            afterCursor: "existing text",
            geometry: TextFieldGeometry(isAtEndOfLine: false),
            target: Self.target
        )

        #expect(CompletionController.shouldUseCapsule(for: context))
    }

    @Test func capsulePresentationTrustsEndOfLineGeometryOverStaleSuffix() {
        let context = TextFieldContext(
            beforeCursor: "Let's try",
            afterCursor: "stale AX suffix",
            geometry: TextFieldGeometry(isAtEndOfLine: true),
            target: AppTarget(bundleIdentifier: "md.obsidian", appName: "Obsidian"),
            traits: TextFieldTraits(isWebField: true)
        )

        #expect(!CompletionController.shouldUseCapsule(for: context))
    }

    @Test func obsidianIgnoresAXFontForOverlaySizing() {
        let style = ResolvedFieldStyle(
            font: NSFont.systemFont(ofSize: 48),
            color: .labelColor
        )
        let context = TextFieldContext(
            beforeCursor: "Notes are the core of Obsidian.",
            target: AppTarget(bundleIdentifier: "md.obsidian", appName: "Obsidian"),
            traits: TextFieldTraits(isWebField: true)
        )

        let effective = CompletionController.effectiveOverlayStyle(style, for: context)

        #expect(effective.font == nil)
        #expect(effective.color == .labelColor)
    }

    @Test func nonObsidianKeepsResolvedAXFont() {
        let font = NSFont.systemFont(ofSize: 18)
        let style = ResolvedFieldStyle(font: font, color: .labelColor)
        let context = TextFieldContext(
            beforeCursor: "This is a test",
            target: Self.target
        )

        let effective = CompletionController.effectiveOverlayStyle(style, for: context)

        #expect(effective.font?.pointSize == font.pointSize)
        #expect(effective.font?.familyName == font.familyName)
        #expect(effective.color == .labelColor)
    }

    @Test func screenshotCalibrationOffsetConvertsFromImageToAppKitCoordinates() {
        let font = NSFont.systemFont(ofSize: 16)
        let style = ResolvedFieldStyle(font: font, lineHeight: 18)
        let placement = OverlayPlacement(
            cursorRect: CGRect(x: 20, y: 100, width: 2, height: 18),
            fieldRect: CGRect(x: 10, y: 80, width: 240, height: 44)
        )
        let result = ScreenshotCalibrationResult(
            detectedFontSize: 16,
            bestSize: 17.6,
            rmse: 0.1,
            confidence: 0.9,
            fontSizeAdjustmentFactor: 1.1,
            verticalAlignmentOffset: -6,
            actualLineLength: 12,
            recognizedText: "hello world",
            usesInvertedLuminance: false,
            meetsQualityThresholds: true
        )

        let calibrated = CompletionController.applyOverlayCalibration(
            result,
            style: style,
            placement: placement
        )

        #expect(calibrated.placement.cursorRect.minY == 106)
        #expect(calibrated.style.font?.pointSize == 17.6)
        #expect(calibrated.style.lineHeight == 19.8)
    }

    @Test func capsulePresentationIsNotUsedAtEndOfLineForNewWordWrapping() {
        let context = TextFieldContext(
            beforeCursor: "This is a test ",
            afterCursor: "",
            target: Self.target
        )

        #expect(!CompletionController.shouldUseCapsule(for: context))
    }

    @Test func capsulePresentationIsNotUsedWhenSuffixStartsOnNextLine() {
        let context = TextFieldContext(
            beforeCursor: "This is a test ",
            afterCursor: "\nnext paragraph",
            target: Self.target
        )

        #expect(!CompletionController.shouldUseCapsule(for: context))
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

    @Test func promotionCacheRecomputesWhenLiveCaretSwitchesFromCJKToLatinComposition() {
        let cache = Self.promotionCache(candidates: ["z z z continuation"], beforeCursor: "我")
        let live = TextFieldContext(beforeCursor: "我z", target: Self.target)

        let decision = cache.decision(for: live)

        guard case .recompute(.contextChanged) = decision else {
            Issue.record("Expected script-change recompute, got \(decision)")
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

    @Test func reuseHistoryUsesOneHundredFiftyEntriesByDefaultWithTenPercentKindBudgets() {
        let history = CompletionReuseHistory()

        #expect(history.maxEntries == 150)
        #expect(history.minimumEntriesPerKind == 15)
    }

    @Test func reuseHistoryPromotesAppendBranchFromRecentSnapshot() {
        var history = CompletionReuseHistory()
        history.record(Self.promotionCache(candidates: [
            "ship it today",
            "review the patch",
            "send the update"
        ]))

        let decision = history.decision(for: Self.liveContext(typed: "r"), preferredKind: .append)

        guard case let .reuse(reuse) = decision else {
            Issue.record("Expected append reuse, got \(decision)")
            return
        }
        #expect(reuse.kind == .append)
        #expect(reuse.sourceRank == 1)
        #expect(reuse.anchorText == "eview the patch")
        #expect(reuse.remainingText == "eview the patch")
        #expect(reuse.anchorContext.beforeCursor == "I will r")
    }

    @Test func reuseHistoryRecoversRollbackAnchorAfterDeletingTypoStem() {
        var history = CompletionReuseHistory()
        history.record(
            Self.promotionCache(
                candidates: ["ew the patch"],
                beforeCursor: "I will revi"
            )
        )

        let liveAfterDelete = TextFieldContext(beforeCursor: "I will rev", target: Self.target)
        let decision = history.decision(for: liveAfterDelete, preferredKind: .rollback)

        guard case let .reuse(reuse) = decision else {
            Issue.record("Expected rollback reuse, got \(decision)")
            return
        }
        #expect(reuse.kind == .rollback)
        #expect(reuse.anchorText == "iew the patch")
        #expect(reuse.remainingText == "iew the patch")
        #expect(reuse.anchorContext.beforeCursor == "I will rev")
    }

    @Test func reuseHistoryFallsBackToAppendAfterDeleteBackwardWhenRollbackMisses() {
        var history = CompletionReuseHistory()
        history.record(
            Self.promotionCache(
                candidates: ["encent is about to launch their T1"],
                beforeCursor: "T"
            )
        )

        let liveAfterDelete = TextFieldContext(
            beforeCursor: "Tencent is about to launc",
            target: Self.target
        )
        guard case .miss(kind: .rollback, reason: .noMatch) =
                history.decision(for: liveAfterDelete, preferredKind: .rollback)
        else {
            Issue.record("Expected rollback alone to miss")
            return
        }

        let decision = history.decisionAfterDeleteBackward(for: liveAfterDelete)

        guard case let .reuse(reuse) = decision else {
            Issue.record("Expected delete-backward append fallback reuse, got \(decision)")
            return
        }
        #expect(reuse.kind == .append)
        #expect(reuse.sourceRank == 0)
        #expect(reuse.remainingText == "h their T1")
        #expect(reuse.anchorContext.beforeCursor == "Tencent is about to launc")
    }

    @Test func reuseHistoryRecomputesRollbackWhenOnlyMatchesAreTooShort() {
        var history = CompletionReuseHistory()
        history.record(
            Self.promotionCache(
                candidates: ["k"],
                beforeCursor: "I will ta"
            )
        )

        let liveAfterDelete = TextFieldContext(beforeCursor: "I will t", target: Self.target)
        let decision = history.decision(for: liveAfterDelete, preferredKind: .rollback)

        guard case .miss(kind: .rollback, reason: .matchingBranchesTooShort) = decision else {
            Issue.record("Expected short rollback miss, got \(decision)")
            return
        }
    }

    @Test func reuseHistoryQuantifiesRollbackAvoidedRegenerationCoverage() {
        let branches = [
            ("I will revi", "ew the patch"),
            ("Please sen", "d the update"),
            ("We can shi", "p it today"),
            ("Let's documen", "t the decision"),
            ("The model predi", "cts the suffix")
        ]
        var history = CompletionReuseHistory()
        for (beforeCursor, completion) in branches {
            history.record(Self.promotionCache(candidates: [completion], beforeCursor: beforeCursor))
        }

        let historyReusable = branches.filter { beforeCursor, _ in
            let liveAfterDelete = TextFieldContext(
                beforeCursor: String(beforeCursor.dropLast()),
                target: Self.target
            )
            if case .reuse = history.decision(for: liveAfterDelete, preferredKind: .rollback) {
                return true
            }
            return false
        }.count
        let flushedSingleCacheReusable = 0

        #expect(flushedSingleCacheReusable == 0)
        #expect(historyReusable == 5)
        #expect(branches.count - flushedSingleCacheReusable == 5)
        #expect(branches.count - historyReusable == 0)
    }

    @Test func reuseHistoryEvictsOldestEntriesAtCapacity() {
        var history = CompletionReuseHistory(maxEntries: 150)
        for index in 0..<40 {
            history.record(
                Self.promotionCache(
                    candidates: Self.candidateTexts(prefix: "snapshot \(index)", count: 5),
                    beforeCursor: "Prompt \(index) "
                )
            )
        }

        #expect(history.entryCount == 150)
        #expect(history.appendEntryCount == 5)
        #expect(history.rollbackEntryCount == 145)

        let oldestLive = TextFieldContext(beforeCursor: "Prompt 0 ", target: Self.target)
        guard case .miss(kind: _, reason: .noMatch) = history.decision(for: oldestLive, preferredKind: .rollback) else {
            Issue.record("Expected oldest snapshot to be evicted")
            return
        }

        let newestLive = TextFieldContext(beforeCursor: "Prompt 39 ", target: Self.target)
        guard case .reuse = history.decision(for: newestLive, preferredKind: .rollback) else {
            Issue.record("Expected newest snapshot to remain reusable")
            return
        }
    }

    @Test func reuseHistoryPreservesTenPercentBudgetForCurrentAndRollbackEntries() {
        var history = CompletionReuseHistory(maxEntries: 150)
        history.record(
            Self.promotionCache(
                candidates: Self.candidateTexts(prefix: "rollback", count: 20),
                beforeCursor: "Older "
            )
        )
        history.record(
            Self.promotionCache(
                candidates: Self.candidateTexts(prefix: "current", count: 140),
                beforeCursor: "Current "
            )
        )

        #expect(history.entryCount == 150)
        #expect(history.minimumEntriesPerKind == 15)
        #expect(history.rollbackEntryCount == 15)
        #expect(history.appendEntryCount == 135)
    }
}
