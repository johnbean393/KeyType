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
            TargetOverride(bundleIdentifier: Self.target.bundleIdentifier, verticalAlignmentOffset: 3)
        ]))
        let rect = CGRect(x: 10, y: 20, width: 1, height: 16)
        let fieldRect = CGRect(x: 0, y: 20, width: 120, height: 40)
        let placement = resolver.placement(for: context(cursorRect: rect, fieldRect: fieldRect, isRTL: true))
        XCTAssertEqual(placement?.cursorRect, rect)
        XCTAssertEqual(placement?.fieldRect, fieldRect)
        XCTAssertEqual(placement?.isRightToLeft, true)
        XCTAssertEqual(placement?.verticalOffset, 3)
    }

    func testPlacementUsesMirrorForEstimatedWebCaret() {
        let resolver = OverlayPlacementResolver(compatibilityStore: AppCompatibilityStore(overrides: []))
        let rect = CGRect(x: 10, y: 20, width: 1, height: 16)
        let context = TextFieldContext(
            beforeCursor: "hello",
            geometry: TextFieldGeometry(cursorRect: rect, cursorRectQuality: .estimated),
            target: Self.target,
            traits: TextFieldTraits(isWebField: true)
        )

        XCTAssertEqual(resolver.placement(for: context)?.mode, .mirror)
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
}
