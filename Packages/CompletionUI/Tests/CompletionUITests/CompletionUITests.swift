import AppCompatibility
import AppKit
import AutocompleteCore
import CoreGraphics
import XCTest
@testable import CompletionUI

final class CompletionUITests: XCTestCase {
    private static let target = AppTarget(bundleIdentifier: "com.test.app", appName: "Test")

    private func context(cursorRect: CGRect?, fieldRect: CGRect? = nil, isRTL: Bool = false) -> TextFieldContext {
        TextFieldContext(
            beforeCursor: "hello",
            geometry: TextFieldGeometry(
                cursorRect: cursorRect,
                fieldRect: fieldRect,
                isAtEndOfLine: true,
                isRightToLeft: isRTL
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
            TargetOverride(bundleIdentifier: Self.target.bundleIdentifier, verticalAlignmentOffset: { _ in 3 })
        ]))
        let rect = CGRect(x: 10, y: 20, width: 1, height: 16)
        let fieldRect = CGRect(x: 0, y: 20, width: 120, height: 40)
        let placement = resolver.placement(for: context(cursorRect: rect, fieldRect: fieldRect, isRTL: true))
        XCTAssertEqual(placement?.cursorRect, rect)
        XCTAssertEqual(placement?.fieldRect, fieldRect)
        XCTAssertEqual(placement?.isRightToLeft, true)
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

    func testPlacementNilForHiddenOverlayPolicy() {
        let resolver = OverlayPlacementResolver(compatibilityStore: AppCompatibilityStore(overrides: [
            TargetOverride(bundleIdentifier: Self.target.bundleIdentifier, overlayPreference: .hidden)
        ]))
        let rect = CGRect(x: 10, y: 20, width: 1, height: 16)
        XCTAssertNil(resolver.placement(for: context(cursorRect: rect)))
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
    func testTrailingEdgeInlineCompletionWrapsInsteadOfUsingCapsule() {
        let font = NSFont.systemFont(ofSize: 24)
        let placement = OverlayPlacement(
            cursorRect: CGRect(x: 1221, y: 512, width: 2, height: 37),
            fieldRect: CGRect(x: 524, y: 506, width: 704, height: 45)
        )

        let layout = GhostTextOverlayWindow.layout(for: "Chinese.", font: font, placement: placement)

        XCTAssertEqual(layout.frame.minX, 524)
        XCTAssertEqual(layout.frame.width, 704)
        XCTAssertEqual(layout.lines.map(\.text), ["", "Chinese."])
    }

    @MainActor
    func testInlineCompletionKeepsSingleLineWhenFirstVisibleTokenFits() {
        let font = NSFont.systemFont(ofSize: 14)
        let placement = OverlayPlacement(
            cursorRect: CGRect(x: 200, y: 100, width: 2, height: 18),
            fieldRect: CGRect(x: 20, y: 80, width: 500, height: 44)
        )

        let layout = GhostTextOverlayWindow.layout(for: " continuation", font: font, placement: placement)

        XCTAssertEqual(layout.lines.map(\.text), [" continuation"])
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
        // Estimated from caret height (20 * 0.83 ≈ 16.6), clamped into [8, 96].
        XCTAssertGreaterThanOrEqual(resolved.pointSize, 8)
        XCTAssertLessThanOrEqual(resolved.pointSize, 96)
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
