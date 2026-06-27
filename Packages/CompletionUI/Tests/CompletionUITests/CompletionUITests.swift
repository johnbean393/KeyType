import AppCompatibility
import AppKit
import AutocompleteCore
import CoreGraphics
import XCTest
@testable import CompletionUI

final class CompletionUITests: XCTestCase {
    private static let target = AppTarget(bundleIdentifier: "com.test.app", appName: "Test")

    private func context(
        cursorRect: CGRect?,
        fieldRect: CGRect? = nil,
        isRTL: Bool = false,
        cursorRectQuality: CaretGeometryQuality = .unknown
    ) -> TextFieldContext {
        TextFieldContext(
            beforeCursor: "hello",
            geometry: TextFieldGeometry(
                cursorRect: cursorRect,
                fieldRect: fieldRect,
                isAtEndOfLine: true,
                isRightToLeft: isRTL,
                cursorRectQuality: cursorRectQuality
            ),
            target: Self.target
        )
    }

    // MARK: - Placement resolver

    func testPlacementNilWhenNoCaretRect() {
        let resolver = OverlayPlacementResolver()
        XCTAssertNil(resolver.placement(for: context(cursorRect: nil)))
    }

    func testPlacementCarriesGeometryAndPolicy() {
        let resolver = OverlayPlacementResolver(compatibilityStore: AppCompatibilityStore(overrides: [
            TargetOverride(
                bundleIdentifier: Self.target.bundleIdentifier,
                horizontalAlignmentOffset: 4,
                verticalAlignmentOffset: { _ in 3 }
            )
        ]))
        let rect = CGRect(x: 10, y: 20, width: 1, height: 16)
        let fieldRect = CGRect(x: 0, y: 20, width: 120, height: 40)
        let placement = resolver.placement(
            for: context(
                cursorRect: rect,
                fieldRect: fieldRect,
                isRTL: true,
                cursorRectQuality: .derived
            )
        )
        XCTAssertEqual(placement?.cursorRect, rect)
        XCTAssertEqual(placement?.fieldRect, fieldRect)
        XCTAssertEqual(placement?.isRightToLeft, true)
        XCTAssertEqual(placement?.cursorRectQuality, .derived)
        XCTAssertEqual(placement?.horizontalOffset, 4)
        XCTAssertEqual(placement?.verticalOffset(18), 3)
    }

    func testPlacementKeepsEstimatedWebCaretInline() {
        let resolver = OverlayPlacementResolver(compatibilityStore: AppCompatibilityStore(overrides: []))
        let rect = CGRect(x: 10, y: 20, width: 1, height: 16)
        let context = TextFieldContext(
            beforeCursor: "hello",
            geometry: TextFieldGeometry(cursorRect: rect, cursorRectQuality: .estimated),
            target: Self.target,
            traits: TextFieldTraits(isWebField: true)
        )

        XCTAssertEqual(resolver.placement(for: context)?.mode, .inline)
    }

    @MainActor
    func testCorrectionBadgeLayoutPlacesBesideCaretAndClampsToField() {
        let font = NSFont.systemFont(ofSize: 14)
        let placement = OverlayPlacement(
            cursorRect: CGRect(x: 190, y: 100, width: 2, height: 18),
            fieldRect: CGRect(x: 0, y: 80, width: 220, height: 60),
            mode: .correction
        )

        let layout = GhostTextOverlayWindow.correctionBadgeLayout(
            original: "mdidle",
            replacement: "middle",
            font: font,
            placement: placement
        )

        XCTAssertLessThanOrEqual(layout.frame.maxX, 220)
        XCTAssertLessThan(layout.frame.minY, placement.cursorRect.minY)
    }

    @MainActor
    func testCorrectionBadgeLayoutPlacesRTLToLeft() {
        let font = NSFont.systemFont(ofSize: 14)
        let placement = OverlayPlacement(
            cursorRect: CGRect(x: 160, y: 100, width: 2, height: 18),
            fieldRect: CGRect(x: 0, y: 80, width: 300, height: 60),
            mode: .correction,
            isRightToLeft: true
        )

        let layout = GhostTextOverlayWindow.correctionBadgeLayout(
            original: "mdidle",
            replacement: "middle",
            font: font,
            placement: placement
        )

        XCTAssertLessThanOrEqual(layout.frame.maxX, placement.cursorRect.minX)
    }

    @MainActor
    func testAnchoredCorrectionPlacesReplacementBesideWord() {
        let font = NSFont.systemFont(ofSize: 14)
        let word = CGRect(x: 80, y: 100, width: 46, height: 18)
        let placement = OverlayPlacement(
            cursorRect: CGRect(x: 140, y: 100, width: 2, height: 18),
            fieldRect: CGRect(x: 40, y: 80, width: 360, height: 80),
            mode: .correction
        )

        let layout = GhostTextOverlayWindow.anchoredCorrectionLayout(
            replacement: "middle",
            wordRect: word,
            font: font,
            placement: placement
        )

        XCTAssertEqual(layout.lineRect.minX + layout.frame.minX, word.minX, accuracy: 0.5)
        XCTAssertGreaterThan(layout.replacementRect.minX + layout.frame.minX, word.maxX)
    }

    @MainActor
    func testAnchoredCorrectionFallsBelowWhenInlineWouldOverflow() {
        let font = NSFont.systemFont(ofSize: 14)
        let word = CGRect(x: 320, y: 120, width: 50, height: 18)
        let field = CGRect(x: 40, y: 80, width: 340, height: 90)
        let placement = OverlayPlacement(
            cursorRect: CGRect(x: 372, y: 120, width: 2, height: 18),
            fieldRect: field,
            mode: .correction
        )

        let layout = GhostTextOverlayWindow.anchoredCorrectionLayout(
            replacement: "replacement",
            wordRect: word,
            font: font,
            placement: placement
        )
        let replacement = layout.replacementRect.offsetBy(dx: layout.frame.minX, dy: layout.frame.minY)

        XCTAssertLessThan(replacement.maxY, word.minY)
        XCTAssertGreaterThanOrEqual(replacement.minX, field.minX)
        XCTAssertLessThanOrEqual(replacement.maxX, field.maxX)
    }

    func testPlacementUsesNativeBaselineForSingleLineWebField() throws {
        let resolver = OverlayPlacementResolver(compatibilityStore: AppCompatibilityStore())
        let context = TextFieldContext(
            beforeCursor: "search field",
            geometry: TextFieldGeometry(
                cursorRect: CGRect(x: 344, y: 816, width: 2, height: 17),
                fieldRect: CGRect(x: 269, y: 811, width: 964, height: 30),
                cursorRectQuality: .exact
            ),
            target: AppTarget(bundleIdentifier: "com.google.Chrome", appName: "Chrome", domain: "github.com"),
            traits: TextFieldTraits(isWebField: true)
        )

        let placement = try XCTUnwrap(resolver.placement(for: context))

        XCTAssertEqual(placement.verticalOffset(17), 0, accuracy: 0.001)
    }

    func testPlacementUsesNativeBaselineForCompactMultilineWebField() throws {
        let resolver = OverlayPlacementResolver(compatibilityStore: AppCompatibilityStore())
        let context = TextFieldContext(
            beforeCursor: "First line\nSecond line",
            geometry: TextFieldGeometry(
                cursorRect: CGRect(x: 466, y: 156, width: 2, height: 17),
                fieldRect: CGRect(x: 388, y: 154, width: 656, height: 42),
                cursorRectQuality: .exact
            ),
            target: AppTarget(bundleIdentifier: "com.google.Chrome", appName: "Chrome", domain: "aistudio.google.com"),
            traits: TextFieldTraits(isWebField: true)
        )

        let placement = try XCTUnwrap(resolver.placement(for: context))

        XCTAssertEqual(placement.verticalOffset(17), 0, accuracy: 0.001)
    }

    func testPlacementKeepsBrowserOffsetForTallSafariWebEditor() throws {
        let resolver = OverlayPlacementResolver(compatibilityStore: AppCompatibilityStore())
        let context = TextFieldContext(
            beforeCursor: "First paragraph is where the caret should",
            geometry: TextFieldGeometry(
                cursorRect: CGRect(x: 338, y: 570, width: 2, height: 18),
                fieldRect: CGRect(x: 32, y: 407, width: 810, height: 200),
                cursorRectQuality: .exact
            ),
            target: AppTarget(bundleIdentifier: "com.apple.Safari", appName: "Safari", domain: "example.com"),
            traits: TextFieldTraits(isWebField: true)
        )

        let placement = try XCTUnwrap(resolver.placement(for: context))

        XCTAssertEqual(placement.verticalOffset(18), 28, accuracy: 0.001)
    }

    func testPlacementUsesNativeBaselineForTallChromeWebEditor() throws {
        let resolver = OverlayPlacementResolver(compatibilityStore: AppCompatibilityStore())
        let context = TextFieldContext(
            beforeCursor: "First paragraph is where the caret should",
            geometry: TextFieldGeometry(
                cursorRect: CGRect(x: 338, y: 570, width: 2, height: 18),
                fieldRect: CGRect(x: 32, y: 407, width: 810, height: 200),
                cursorRectQuality: .exact
            ),
            target: AppTarget(bundleIdentifier: "com.google.Chrome", appName: "Chrome", domain: "example.com"),
            traits: TextFieldTraits(isWebField: true)
        )

        let placement = try XCTUnwrap(resolver.placement(for: context))

        XCTAssertEqual(placement.verticalOffset(18), 0, accuracy: 0.001)
    }

    func testPlacementKeepsChromeTallWebEditorAfterLineBreak() {
        let resolver = OverlayPlacementResolver(compatibilityStore: AppCompatibilityStore())
        let field = CGRect(x: 32, y: 407, width: 810, height: 200)
        let rect = CGRect(x: 338, y: 475, width: 2, height: 18)
        let context = TextFieldContext(
            beforeCursor: "First paragraph checks baseline alignment.\n\nSecond paragraph is where the caret should",
            geometry: TextFieldGeometry(
                cursorRect: rect,
                fieldRect: field,
                cursorRectQuality: .exact
            ),
            target: AppTarget(bundleIdentifier: "com.google.Chrome", appName: "Chrome", domain: "example.com"),
            traits: TextFieldTraits(isWebField: true)
        )

        XCTAssertNotNil(resolver.placement(for: context))
    }

    func testPlacementKeepsChromeTallWebEditorWithTextBelowCaret() {
        let resolver = OverlayPlacementResolver(compatibilityStore: AppCompatibilityStore())
        let field = CGRect(x: 199, y: 529, width: 786, height: 206)
        let rect = CGRect(x: 501, y: 699, width: 2, height: 21)
        let context = TextFieldContext(
            beforeCursor: "First line checks baseline alignment.",
            afterCursor: "\nSecond line is where the caret should sit",
            geometry: TextFieldGeometry(
                cursorRect: rect,
                fieldRect: field,
                cursorRectQuality: .exact
            ),
            target: AppTarget(bundleIdentifier: "com.google.Chrome", appName: "Chrome", domain: "example.com"),
            traits: TextFieldTraits(isWebField: true)
        )

        XCTAssertNotNil(resolver.placement(for: context))
    }

    func testPlacementKeepsTallWebEditorWhenTextSnapshotOmitsPreviousParagraphs() {
        let resolver = OverlayPlacementResolver(compatibilityStore: AppCompatibilityStore(overrides: []))
        let field = CGRect(x: 32, y: 407, width: 810, height: 200)
        let rect = CGRect(x: 338, y: 475, width: 2, height: 18)
        let context = TextFieldContext(
            beforeCursor: "Second paragraph is where the caret should",
            geometry: TextFieldGeometry(
                cursorRect: rect,
                fieldRect: field,
                cursorRectQuality: .exact
            ),
            target: Self.target,
            traits: TextFieldTraits(isWebField: true)
        )

        XCTAssertNotNil(resolver.placement(for: context))
    }

    func testPlacementKeepsTallWebEditorAfterLineBreak() {
        let resolver = OverlayPlacementResolver(compatibilityStore: AppCompatibilityStore(overrides: []))
        let field = CGRect(x: 32, y: 407, width: 810, height: 200)
        let rect = CGRect(x: 338, y: 475, width: 2, height: 18)
        let context = TextFieldContext(
            beforeCursor: "First paragraph checks baseline alignment.\n\nSecond paragraph is where the caret should",
            geometry: TextFieldGeometry(
                cursorRect: rect,
                fieldRect: field,
                cursorRectQuality: .exact
            ),
            target: Self.target,
            traits: TextFieldTraits(isWebField: true)
        )

        XCTAssertNotNil(resolver.placement(for: context))
    }

    func testPlacementKeepsTallWebEditorWithTextBelowCaret() {
        let resolver = OverlayPlacementResolver(compatibilityStore: AppCompatibilityStore(overrides: []))
        let field = CGRect(x: 199, y: 529, width: 786, height: 206)
        let rect = CGRect(x: 501, y: 699, width: 2, height: 21)
        let context = TextFieldContext(
            beforeCursor: "First line checks baseline alignment.",
            afterCursor: "\nSecond line is where the caret should sit",
            geometry: TextFieldGeometry(
                cursorRect: rect,
                fieldRect: field,
                cursorRectQuality: .exact
            ),
            target: AppTarget(bundleIdentifier: "com.test.browser", appName: "Browser"),
            traits: TextFieldTraits(isWebField: true)
        )

        XCTAssertNotNil(resolver.placement(for: context))
    }

    func testPlacementKeepsTopLineWebEditorSnapshot() {
        let resolver = OverlayPlacementResolver(compatibilityStore: AppCompatibilityStore(overrides: []))
        let field = CGRect(x: 32, y: 407, width: 810, height: 200)
        let rect = CGRect(x: 338, y: 570, width: 2, height: 18)
        let context = TextFieldContext(
            beforeCursor: "First paragraph is where the caret should",
            geometry: TextFieldGeometry(
                cursorRect: rect,
                fieldRect: field,
                cursorRectQuality: .exact
            ),
            target: Self.target,
            traits: TextFieldTraits(isWebField: true)
        )

        XCTAssertNotNil(resolver.placement(for: context))
    }

    func testPlacementSuppressesCodeEditorLineOriginCaret() {
        let resolver = OverlayPlacementResolver(compatibilityStore: AppCompatibilityStore(overrides: []))
        let field = CGRect(x: 277, y: 802, width: 975, height: 27)
        let context = TextFieldContext(
            beforeCursor: "",
            geometry: TextFieldGeometry(
                cursorRect: CGRect(x: 277, y: 802, width: 2, height: 27),
                fieldRect: field,
                cursorRectQuality: .exact
            ),
            target: AppTarget(bundleIdentifier: "com.microsoft.VSCode", appName: "Code")
        )

        XCTAssertNil(resolver.placement(for: context))
    }

    func testPlacementKeepsCodeEditorRepairedCaretAwayFromLineOrigin() {
        let resolver = OverlayPlacementResolver(compatibilityStore: AppCompatibilityStore(overrides: []))
        let field = CGRect(x: 277, y: 802, width: 975, height: 27)
        let context = TextFieldContext(
            beforeCursor: "Second line is where the caret should sit",
            geometry: TextFieldGeometry(
                cursorRect: CGRect(x: 650, y: 802, width: 2, height: 27),
                fieldRect: field,
                cursorRectQuality: .estimated
            ),
            target: AppTarget(bundleIdentifier: "com.microsoft.VSCode", appName: "Code")
        )

        XCTAssertNotNil(resolver.placement(for: context))
    }

    func testPlacementKeepsLineOriginCaretForOtherApps() {
        let resolver = OverlayPlacementResolver(compatibilityStore: AppCompatibilityStore(overrides: []))
        let field = CGRect(x: 277, y: 802, width: 975, height: 27)
        let context = TextFieldContext(
            beforeCursor: "",
            geometry: TextFieldGeometry(
                cursorRect: CGRect(x: 277, y: 802, width: 2, height: 27),
                fieldRect: field,
                cursorRectQuality: .exact
            ),
            target: AppTarget(bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode")
        )

        XCTAssertNotNil(resolver.placement(for: context))
    }

    func testPlacementNilForHiddenOverlayPolicy() {
        let resolver = OverlayPlacementResolver(compatibilityStore: AppCompatibilityStore(overrides: [
            TargetOverride(bundleIdentifier: Self.target.bundleIdentifier, overlayPreference: .hidden)
        ]))
        let rect = CGRect(x: 10, y: 20, width: 1, height: 16)
        XCTAssertNil(resolver.placement(for: context(cursorRect: rect)))
    }

    // MARK: - Caret debug overlay

    func testCaretDebugOverlaySnapshotComputesLTRAvailableTextRect() {
        let snapshot = CaretDebugOverlaySnapshot(
            caretRect: CGRect(x: 642, y: 111, width: 2, height: 22),
            fieldRect: CGRect(x: 590, y: 94, width: 226, height: 78)
        )

        XCTAssertEqual(snapshot.availableTextRect, CGRect(x: 644, y: 111, width: 172, height: 22))
    }

    func testCaretDebugOverlaySnapshotComputesRTLAvailableTextRect() {
        let snapshot = CaretDebugOverlaySnapshot(
            caretRect: CGRect(x: 642, y: 111, width: 2, height: 22),
            fieldRect: CGRect(x: 590, y: 94, width: 226, height: 78),
            isRightToLeft: true
        )

        XCTAssertEqual(snapshot.availableTextRect, CGRect(x: 590, y: 111, width: 52, height: 22))
    }

    func testCaretDebugOverlaySnapshotClampsAvailableRectInsideField() {
        let snapshot = CaretDebugOverlaySnapshot(
            caretRect: CGRect(x: 793, y: 150, width: 2, height: 44),
            fieldRect: CGRect(x: 590, y: 94, width: 226, height: 78)
        )

        XCTAssertEqual(snapshot.availableTextRect, CGRect(x: 795, y: 128, width: 21, height: 44))
    }

    // MARK: - Noop presenter visible state

    func testNoopPresenterTracksVisibleCandidate() {
        let presenter = NoopCompletionOverlayPresenter()
        XCTAssertNil(presenter.visibleCandidate)

        let candidate = CompletionCandidate(text: " world")
        presenter.show(candidate: candidate, placement: OverlayPlacement(cursorRect: .zero))
        XCTAssertEqual(presenter.visibleCandidate, candidate)

        presenter.hide()
        XCTAssertNil(presenter.visibleCandidate)
    }

    @MainActor
    func testGhostTextColorFallsBackFromNearWhiteAXColor() {
        let resolved = GhostTextView.visibleGhostColor(from: NSColor(calibratedWhite: 0.98, alpha: 1))
            .usingColorSpace(.sRGB)

        XCTAssertNotNil(resolved)
        XCTAssertLessThan(resolved?.redComponent ?? 1, 0.5)
        XCTAssertGreaterThan(resolved?.alphaComponent ?? 0, 0.8)
    }

    @MainActor
    func testGhostTextColorKeepsReadableGrayWhenAXColorIsMissing() {
        let resolved = GhostTextView.visibleGhostColor(from: nil)
            .usingColorSpace(.sRGB)

        XCTAssertNotNil(resolved)
        XCTAssertGreaterThan(resolved?.redComponent ?? 0, 0.35)
        XCTAssertLessThan(resolved?.redComponent ?? 1, 0.55)
        XCTAssertGreaterThan(resolved?.alphaComponent ?? 0, 0.8)
    }

    @MainActor
    func testGhostTextWidthIsCappedToRemainingFieldWidth() {
        let placement = OverlayPlacement(
            cursorRect: CGRect(x: 80, y: 10, width: 2, height: 20),
            fieldRect: CGRect(x: 10, y: 0, width: 100, height: 40)
        )

        XCTAssertEqual(
            GhostTextOverlayWindow.availableTextWidth(for: placement, singleLineWidth: 500),
            28
        )
    }

    @MainActor
    func testGhostTextWidthFallsBackToMeasuredWidthWithoutFieldRect() {
        let placement = OverlayPlacement(cursorRect: CGRect(x: 80, y: 10, width: 2, height: 20))
        XCTAssertEqual(
            GhostTextOverlayWindow.availableTextWidth(for: placement, singleLineWidth: 500),
            500
        )
    }

    @MainActor
    func testGhostTextWrapsOverflowingFirstWordToFieldLeadingEdge() {
        let font = NSFont.monospacedSystemFont(ofSize: 20, weight: .regular)
        let lineHeight: CGFloat = 24
        let lines = GhostTextOverlayWindow.wrappedLines(
            for: "Olympic.",
            font: font,
            firstLineWidth: 2,
            fullLineWidth: 300,
            firstLineInset: 120,
            lineHeight: lineHeight
        )

        XCTAssertEqual(lines, [
            GhostTextLine(text: "", leadingInset: 120, reservedHeight: lineHeight),
            GhostTextLine(text: "Olympic.", leadingInset: 0, reservedHeight: lineHeight)
        ])
    }

    @MainActor
    func testGhostTextWrapsAtWordBoundariesAfterCaretLine() {
        let font = NSFont.monospacedSystemFont(ofSize: 20, weight: .regular)
        let lineHeight: CGFloat = 24
        let wordWidth = ("current" as NSString).size(withAttributes: [.font: font]).width
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        let lines = GhostTextOverlayWindow.wrappedLines(
            for: "current text is:",
            font: font,
            firstLineWidth: wordWidth + spaceWidth + 1,
            fullLineWidth: 300,
            firstLineInset: 80,
            lineHeight: lineHeight
        )

        XCTAssertEqual(lines.map(\.text), ["current", "text is:"])
        XCTAssertEqual(lines.map(\.leadingInset), [80, 0])
    }

    @MainActor
    func testGhostTextPreservesLeadingSpaceOnFirstRenderedLine() {
        let font = NSFont.monospacedSystemFont(ofSize: 20, weight: .regular)
        let lineHeight: CGFloat = 24
        let lines = GhostTextOverlayWindow.wrappedLines(
            for: " It has 9",
            font: font,
            firstLineWidth: 300,
            fullLineWidth: 300,
            firstLineInset: 120,
            lineHeight: lineHeight
        )

        XCTAssertEqual(lines.map(\.text), [" It has 9"])
        XCTAssertEqual(lines.map(\.leadingInset), [120])
    }

    @MainActor
    func testGhostTextDropsLeadingSpaceAfterWrappingToFieldEdge() {
        let font = NSFont.monospacedSystemFont(ofSize: 20, weight: .regular)
        let lineHeight: CGFloat = 24
        let lines = GhostTextOverlayWindow.wrappedLines(
            for: " It has 9",
            font: font,
            firstLineWidth: 2,
            fullLineWidth: 300,
            firstLineInset: 120,
            lineHeight: lineHeight
        )

        XCTAssertEqual(lines.map(\.text), ["", "It has 9"])
        XCTAssertEqual(lines.map(\.leadingInset), [120, 0])
    }

    @MainActor
    func testGhostTextLayoutUsesFieldWidthForWrappedInlineText() {
        let font = NSFont.monospacedSystemFont(ofSize: 20, weight: .regular)
        let placement = OverlayPlacement(
            cursorRect: CGRect(x: 285, y: 100, width: 2, height: 24),
            fieldRect: CGRect(x: 20, y: 80, width: 300, height: 80)
        )
        let layout = GhostTextOverlayWindow.layout(for: "Olympic.", font: font, placement: placement)

        XCTAssertEqual(layout.frame.minX, 20)
        XCTAssertEqual(layout.frame.width, 300)
        XCTAssertEqual(layout.lines.map(\.text), ["", "Olympic."])
        XCTAssertEqual(layout.lines.map(\.leadingInset), [267, 0])
    }

    @MainActor
    func testGhostTextLayoutIgnoresFieldSizedCaretHeight() {
        let font = NSFont.systemFont(ofSize: 15)
        let placement = OverlayPlacement(
            cursorRect: CGRect(x: 200, y: 100, width: 2, height: 120),
            fieldRect: CGRect(x: 20, y: 90, width: 700, height: 130)
        )
        let layout = GhostTextOverlayWindow.layout(for: "firm that helps companies", font: font, placement: placement)

        XCTAssertLessThanOrEqual(layout.lines.first?.reservedHeight ?? 0, 24)
        XCTAssertLessThan(layout.frame.height, 40)
    }

    @MainActor
    func testTrailingEdgeSingleLineCompletionDoesNotWrapBelowField() {
        let font = NSFont.systemFont(ofSize: 24)
        let placement = OverlayPlacement(
            cursorRect: CGRect(x: 1221, y: 512, width: 2, height: 37),
            fieldRect: CGRect(x: 524, y: 506, width: 704, height: 45)
        )

        let layout = GhostTextOverlayWindow.layout(for: "Chinese.", font: font, placement: placement)

        XCTAssertEqual(layout.frame.minX, placement.cursorRect.maxX)
        XCTAssertEqual(layout.frame.width, placement.fieldRect!.maxX - placement.cursorRect.maxX)
        XCTAssertEqual(layout.lines.map(\.text), ["Chinese."])
    }

    @MainActor
    func testSingleLineFieldSuppressesOverflowingInlineGhostText() {
        let font = NSFont.systemFont(ofSize: 20)
        let placement = OverlayPlacement(
            cursorRect: CGRect(x: 714, y: 523, width: 2, height: 20),
            fieldRect: CGRect(x: 460, y: 508, width: 487, height: 50)
        )

        XCTAssertTrue(
            GhostTextOverlayWindow.shouldSuppressInlineSingleLineOverflow(
                text: " ghost text probe chrome google search after wrap fix sample",
                font: font,
                placement: placement
            )
        )
    }

    @MainActor
    func testSingleLineFieldKeepsFittingInlineGhostText() {
        let font = NSFont.systemFont(ofSize: 20)
        let placement = OverlayPlacement(
            cursorRect: CGRect(x: 714, y: 523, width: 2, height: 20),
            fieldRect: CGRect(x: 460, y: 508, width: 487, height: 50)
        )

        XCTAssertFalse(
            GhostTextOverlayWindow.shouldSuppressInlineSingleLineOverflow(
                text: " now",
                font: font,
                placement: placement
            )
        )
    }

    @MainActor
    func testMultilineFieldKeepsFittingCompletionSingleLineAtCaret() {
        let font = NSFont.systemFont(ofSize: 14)
        let placement = OverlayPlacement(
            cursorRect: CGRect(x: 200, y: 100, width: 2, height: 18),
            fieldRect: CGRect(x: 20, y: 80, width: 500, height: 44)
        )

        let layout = GhostTextOverlayWindow.layout(for: " continuation", font: font, placement: placement)

        XCTAssertEqual(layout.frame.minX, placement.cursorRect.maxX)
        XCTAssertLessThan(layout.frame.width, placement.fieldRect?.width ?? .infinity)
        XCTAssertEqual(layout.lines.map(\.text), [" continuation"])
        XCTAssertEqual(layout.lines.map(\.leadingInset), [0])
    }

    @MainActor
    func testMirrorLayoutSuppressesOverflowWithDerivedMultilineCaret() {
        let font = NSFont.systemFont(ofSize: 15)
        let placement = OverlayPlacement(
            cursorRect: CGRect(x: 786, y: 111, width: 2, height: 44),
            fieldRect: CGRect(x: 590, y: 94, width: 226, height: 78),
            mode: .mirror,
            cursorRectQuality: .derived
        )

        XCTAssertTrue(
            GhostTextOverlayWindow.shouldSuppressMirrorOverflow(
                text: "you.",
                font: font,
                placement: placement
            )
        )
    }

    @MainActor
    func testMirrorLayoutKeepsShortSuggestionOnCaretLine() {
        let font = NSFont.systemFont(ofSize: 15)
        let placement = OverlayPlacement(
            cursorRect: CGRect(x: 786, y: 111, width: 2, height: 44),
            fieldRect: CGRect(x: 590, y: 94, width: 226, height: 78),
            mode: .mirror,
            cursorRectQuality: .derived
        )

        let layout = GhostTextOverlayWindow.layout(for: "I'll", font: font, placement: placement)

        XCTAssertFalse(
            GhostTextOverlayWindow.shouldSuppressMirrorOverflow(
                text: "I'll",
                font: font,
                placement: placement
            )
        )
        XCTAssertEqual(layout.frame.minX, placement.cursorRect.maxX)
        XCTAssertLessThanOrEqual(layout.frame.maxX, placement.fieldRect?.maxX ?? 0)
        XCTAssertLessThanOrEqual(layout.lineHeight, 24)
        XCTAssertEqual(layout.lines.map(\.text), ["I'll"])
    }

    @MainActor
    func testMirrorLayoutSuppressesSingleLineToolbarCollision() {
        let font = NSFont.systemFont(ofSize: 15)
        let placement = OverlayPlacement(
            cursorRect: CGRect(x: 793, y: 111, width: 2, height: 44),
            fieldRect: CGRect(x: 590, y: 94, width: 226, height: 78),
            mode: .mirror,
            cursorRectQuality: .derived
        )

        XCTAssertTrue(
            GhostTextOverlayWindow.shouldSuppressMirrorOverflow(
                text: " Let's",
                font: font,
                placement: placement
            )
        )
    }

    @MainActor
    func testTextMirrorSnippetUsesCurrentParagraphOnly() {
        let snippet = TextMirrorSnippet.currentParagraph(
            beforeCursor: "Earlier paragraph\nCurrent paragraph prefix",
            afterCursor: " suffix\nNext paragraph"
        )

        XCTAssertEqual(snippet.before, "Current paragraph prefix")
        XCTAssertEqual(snippet.after, " suffix")
    }

    @MainActor
    func testTextMirrorCaretConvertsToFlippedFieldCoordinates() {
        let field = CGRect(x: 100, y: 200, width: 300, height: 80)
        let caret = CGRect(x: 160, y: 230, width: 2, height: 20)

        let local = TextMirrorGeometry.localCaretRect(cursorRect: caret, fieldRect: field)

        XCTAssertEqual(local.minX, 60)
        XCTAssertEqual(local.minY, 30)
        XCTAssertEqual(local.height, caret.height)
    }

    @MainActor
    func testTextMirrorLayoutUsesFieldFrame() {
        let font = NSFont.systemFont(ofSize: 15)
        let field = CGRect(x: 80, y: 90, width: 420, height: 120)
        let placement = OverlayPlacement(
            cursorRect: CGRect(x: 250, y: 140, width: 2, height: 20),
            fieldRect: field,
            mode: .mirror
        )
        let layout = GhostTextOverlayWindow.textMirrorLayout(
            for: OverlayTextStyle(font: font),
            placement: placement
        )

        XCTAssertEqual(layout.frame, field)
        XCTAssertGreaterThanOrEqual(layout.lineHeight, ceil(font.ascender - font.descender + font.leading))
    }

    @MainActor
    func testTextMirrorViewAlignsTextKitCaretToCapturedCaret() {
        let font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        let field = CGRect(x: 100, y: 200, width: 260, height: 90)
        let caret = CGRect(x: 174, y: 244, width: 2, height: 20)
        let placement = OverlayPlacement(
            cursorRect: caret,
            fieldRect: field,
            mode: .mirror
        )
        let view = TextMirrorCompletionNSView(
            frame: CGRect(origin: .zero, size: field.size)
        )
        view.configure(
            mirrorContext: TextMirrorOverlayContext(
                beforeCursor: "hello ",
                afterCursor: "world"
            ),
            completion: "there ",
            style: OverlayTextStyle(font: font),
            placement: placement
        )

        let origin = view.alignedDrawOrigin()
        let mirrorCaret = view.caretRect(utf16Location: ("hello " as NSString).length)
            .offsetBy(dx: origin.x, dy: origin.y)
        let targetCaret = TextMirrorGeometry.localCaretRect(cursorRect: caret, fieldRect: field)

        XCTAssertEqual(mirrorCaret.minX, targetCaret.minX, accuracy: 0.5)
        XCTAssertEqual(mirrorCaret.minY, targetCaret.minY, accuracy: 0.5)
    }

    @MainActor
    func testTextMirrorAlignsCapturedCaretInsideTallerLineBox() {
        let font = NSFont.systemFont(ofSize: 15)
        let lineHeight: CGFloat = 28
        let field = CGRect(x: 100, y: 200, width: 360, height: 90)
        let caret = CGRect(x: 174, y: 244, width: 2, height: 18)
        let placement = OverlayPlacement(
            cursorRect: caret,
            fieldRect: field,
            mode: .mirror
        )
        let view = TextMirrorCompletionNSView(
            frame: CGRect(origin: .zero, size: field.size)
        )
        view.configure(
            mirrorContext: TextMirrorOverlayContext(
                beforeCursor: "Let's",
                afterCursor: ""
            ),
            completion: " see what happens",
            style: OverlayTextStyle(font: font, lineHeight: lineHeight),
            placement: placement
        )

        let targetCaret = TextMirrorGeometry.localCaretRect(cursorRect: caret, fieldRect: field)
        let mirrorCaret = view.caretRect(utf16Location: ("Let's" as NSString).length)
        let origin = view.alignedDrawOrigin()

        XCTAssertEqual(mirrorCaret.minY, (lineHeight - caret.height) / 2, accuracy: 0.5)
        XCTAssertEqual(mirrorCaret.height, caret.height, accuracy: 0.5)
        XCTAssertEqual(origin.y, targetCaret.minY - mirrorCaret.minY, accuracy: 0.5)
        XCTAssertLessThan(origin.y, targetCaret.minY)
    }

    // MARK: - Advance past an accepted word

    @MainActor
    func testAdvancedPlacementShiftsCaretRightwardForLTR() {
        let placement = OverlayPlacement(cursorRect: CGRect(x: 40, y: 20, width: 2, height: 16))
        let advanced = GhostTextOverlayWindow.advanced(placement, byAcceptedWidth: 30)

        // LTR: the caret moves rightward by the accepted width, so the remainder draws where it
        // already sat (the old caret.maxX + headWidth).
        XCTAssertEqual(advanced.cursorRect.minX, 70)
        XCTAssertEqual(advanced.cursorRect.maxX, placement.cursorRect.maxX + 30)
        XCTAssertEqual(advanced.cursorRect.minY, placement.cursorRect.minY)
        XCTAssertEqual(advanced.cursorRect.height, placement.cursorRect.height)
    }

    @MainActor
    func testAdvancedPlacementShiftsCaretLeftwardForRTL() {
        let placement = OverlayPlacement(cursorRect: CGRect(x: 40, y: 20, width: 2, height: 16), isRightToLeft: true)
        let advanced = GhostTextOverlayWindow.advanced(placement, byAcceptedWidth: 30)

        XCTAssertEqual(advanced.cursorRect.minX, 10)
        XCTAssertTrue(advanced.isRightToLeft)
    }

    // MARK: - Capsule layout

    @MainActor
    func testCapsuleLayoutCentersBelowCaret() {
        let font = NSFont.systemFont(ofSize: 14)
        let caret = CGRect(x: 200, y: 100, width: 2, height: 18)
        let placement = OverlayPlacement(
            cursorRect: caret,
            fieldRect: CGRect(x: 0, y: 80, width: 600, height: 40),
            presentation: .capsule
        )
        let layout = GhostTextOverlayWindow.layout(for: " world", font: font, placement: placement)

        // Horizontally centered on the caret.
        XCTAssertEqual(layout.frame.midX, caret.midX, accuracy: 0.5)
        // Positioned strictly below the caret (AppKit bottom-left origin → smaller Y).
        XCTAssertLessThanOrEqual(layout.frame.maxY, caret.minY)
    }

    @MainActor
    func testCapsulePinsToTrailingEdgeNearTrailingEdge() {
        let font = NSFont.systemFont(ofSize: 14)
        let field = CGRect(x: 0, y: 80, width: 300, height: 40)
        let placement = OverlayPlacement(
            cursorRect: CGRect(x: 298, y: 100, width: 2, height: 18),
            fieldRect: field,
            presentation: .capsule
        )
        let layout = GhostTextOverlayWindow.layout(for: " continuation", font: font, placement: placement)

        XCTAssertEqual(layout.frame.maxX, field.maxX, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(layout.frame.minX, field.minX)
    }

    @MainActor
    func testCapsulePinsToLeadingEdgeNearLeadingEdge() {
        let font = NSFont.systemFont(ofSize: 14)
        let field = CGRect(x: 20, y: 80, width: 300, height: 40)
        let placement = OverlayPlacement(
            cursorRect: CGRect(x: 22, y: 100, width: 2, height: 18),
            fieldRect: field,
            presentation: .capsule
        )
        let layout = GhostTextOverlayWindow.layout(for: " continuation", font: font, placement: placement)

        XCTAssertEqual(layout.frame.minX, field.minX, accuracy: 0.5)
        XCTAssertLessThanOrEqual(layout.frame.maxX, field.maxX)
    }

    @MainActor
    func testCapsulePinsToLeadingEdgeWhenWiderThanField() {
        let font = NSFont.systemFont(ofSize: 14)
        let field = CGRect(x: 20, y: 80, width: 40, height: 40)
        let placement = OverlayPlacement(
            cursorRect: CGRect(x: 40, y: 100, width: 2, height: 18),
            fieldRect: field,
            presentation: .capsule
        )
        let layout = GhostTextOverlayWindow.layout(for: " a very long continuation indeed", font: font, placement: placement)

        XCTAssertGreaterThan(layout.frame.width, field.width)
        XCTAssertEqual(layout.frame.minX, field.minX, accuracy: 0.5)
    }

    // MARK: - Font resolution

    @MainActor
    func testResolveFontKeepsFamilyAndSizesFromCaretHeight() {
        // The field font's reported size is intentionally ignored; the typeface is sized from the
        // caret height via the font's metrics, so the ghost's glyph box ≈ caretHeight × factor.
        let field = NSFont.systemFont(ofSize: 12)
        let caretHeight: CGFloat = 20
        let factor: CGFloat = 2
        let placement = OverlayPlacement(cursorRect: CGRect(x: 0, y: 0, width: 1, height: caretHeight), fontSizeAdjustmentFactor: Double(factor))
        let resolved = InlineGhostTextPresenter.resolveFont(field, placement: placement)
        XCTAssertEqual(resolved.familyName, field.familyName)
        XCTAssertEqual(resolved.ascender - resolved.descender, caretHeight * factor, accuracy: 0.5)
    }

    @MainActor
    func testResolveFontIsStableWhenAXSizeAlreadyMatchesCaret() {
        // When AX's reported size is already consistent with the caret height, sizing from the
        // caret reproduces (close to) that size rather than changing it.
        let field = NSFont.systemFont(ofSize: 24)
        let caretHeight = field.ascender - field.descender // the caret a 24pt line would produce
        let placement = OverlayPlacement(cursorRect: CGRect(x: 0, y: 0, width: 1, height: caretHeight))
        let resolved = InlineGhostTextPresenter.resolveFont(field, placement: placement)
        XCTAssertEqual(resolved.pointSize, 24, accuracy: 0.5)
    }

    @MainActor
    func testResolveFontFallsBackToCaretHeight() {
        let placement = OverlayPlacement(cursorRect: CGRect(x: 0, y: 0, width: 1, height: 20))
        let resolved = InlineGhostTextPresenter.resolveFont(nil, placement: placement)
        // Estimated from caret height (20 * 0.83), then reduced by 15%, clamped into [8, 96].
        XCTAssertEqual(resolved.pointSize, 20 * 0.83 * 0.85, accuracy: 0.1)
    }

    @MainActor
    func testResolveFontIgnoresFieldSizedMultilineCaretHeight() {
        let field = NSFont.systemFont(ofSize: 15)
        let placement = OverlayPlacement(
            cursorRect: CGRect(x: 20, y: 90, width: 2, height: 130),
            fieldRect: CGRect(x: 20, y: 90, width: 700, height: 130)
        )

        let resolved = InlineGhostTextPresenter.resolveFont(field, placement: placement)

        XCTAssertEqual(resolved.familyName, field.familyName)
        XCTAssertEqual(resolved.pointSize, field.pointSize, accuracy: 1)
    }
}
