import AutocompleteCore
import CoreGraphics
import XCTest
@testable import MacContextCapture

final class CodeEditorCaretGeometryFallbackTests: XCTestCase {
    func testVSCodeLineOriginCaretIsEstimatedFromCurrentLinePrefix() {
        let field = CGRect(x: 277, y: 802, width: 975, height: 27)
        let current = CapturedCaretGeometry(
            rect: CGRect(x: 277, y: 802, width: 2, height: 27),
            source: "AXBoundsForRange",
            quality: .exact
        )

        let repaired = CodeEditorCaretGeometryFallback.caretGeometry(
            target: AppTarget(bundleIdentifier: "com.microsoft.VSCode", appName: "Code"),
            beforeCursor: "First line checks baseline alignment.\nSecond line is where the caret should sit",
            afterCursor: "",
            element: nil,
            fieldRect: field,
            current: current
        )

        XCTAssertEqual(repaired?.quality, .estimated)
        XCTAssertEqual(repaired?.source, "CodeEditorLineOriginEstimate(AXBoundsForRange)")
        XCTAssertEqual(repaired?.rect?.minY, current.rect?.minY)
        XCTAssertGreaterThan(repaired?.rect?.minX ?? 0, field.minX + 280)
    }

    func testCursorUsesSameLineOriginRepair() {
        let field = CGRect(x: 277, y: 802, width: 975, height: 27)
        let current = CapturedCaretGeometry(
            rect: CGRect(x: 278, y: 802, width: 2, height: 24),
            source: "AXBoundsForRange",
            quality: .exact
        )

        let repaired = CodeEditorCaretGeometryFallback.caretGeometry(
            target: AppTarget(bundleIdentifier: "com.todesktop.230313mzl4w4u92", appName: "Cursor"),
            beforeCursor: "Second line is where the caret should sit",
            afterCursor: "",
            element: nil,
            fieldRect: field,
            current: current
        )

        XCTAssertEqual(repaired?.quality, .estimated)
        XCTAssertGreaterThan(repaired?.rect?.minX ?? 0, field.minX + 280)
    }

    func testLineOriginCaretIsKeptWhenCurrentLineIsEmpty() {
        let field = CGRect(x: 277, y: 802, width: 975, height: 27)
        let current = CapturedCaretGeometry(
            rect: CGRect(x: 277, y: 802, width: 2, height: 27),
            source: "AXBoundsForRange",
            quality: .exact
        )

        let repaired = CodeEditorCaretGeometryFallback.caretGeometry(
            target: AppTarget(bundleIdentifier: "com.microsoft.VSCode", appName: "Code"),
            beforeCursor: "First line checks baseline alignment.\n",
            afterCursor: "",
            element: nil,
            fieldRect: field,
            current: current
        )

        XCTAssertNil(repaired)
    }

    func testLineOriginCaretRepairDoesNotApplyToOtherApps() {
        let field = CGRect(x: 277, y: 802, width: 975, height: 27)
        let current = CapturedCaretGeometry(
            rect: CGRect(x: 277, y: 802, width: 2, height: 27),
            source: "AXBoundsForRange",
            quality: .exact
        )

        let repaired = CodeEditorCaretGeometryFallback.caretGeometry(
            target: AppTarget(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit"),
            beforeCursor: "Second line is where the caret should sit",
            afterCursor: "",
            element: nil,
            fieldRect: field,
            current: current
        )

        XCTAssertNil(repaired)
    }
}
