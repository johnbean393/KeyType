import AutocompleteCore
import CoreGraphics
import XCTest
@testable import MacContextCapture

final class DiscordComposeTextContextTests: XCTestCase {
    func testEstimatesWrappedCaretOnCurrentVisualLine() {
        let field = CGRect(x: 590, y: 94, width: 226, height: 78)
        let caret = DiscordComposeTextContext.estimatedCursorRect(
            beforeCursor: "Looks like you're having some issues.",
            in: field
        )

        XCTAssertEqual(caret.width, 2)
        XCTAssertEqual(caret.height, 22)
        XCTAssertEqual(caret.minY, 111, accuracy: 2)
        XCTAssertEqual(caret.minX, 642, accuracy: 8)
    }

    func testDoesNotOverrideExactCaretGeometry() {
        let target = AppTarget(bundleIdentifier: "com.hnc.Discord", appName: "Discord")

        XCTAssertNil(
            DiscordComposeTextContext.caretGeometry(
                target: target,
                beforeCursor: "Looks like you're having some issues.",
                fieldRect: CGRect(x: 590, y: 94, width: 226, height: 78),
                current: CapturedCaretGeometry(
                    rect: CGRect(x: 793, y: 111, width: 2, height: 44),
                    source: "AXBoundsForPreviousCharacter",
                    quality: .exact
                )
            )
        )
    }

    func testOnlyAppliesToDiscord() {
        let target = AppTarget(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit")

        XCTAssertNil(
            DiscordComposeTextContext.caretGeometry(
                target: target,
                beforeCursor: "Looks like you're having some issues.",
                fieldRect: CGRect(x: 590, y: 94, width: 226, height: 78),
                current: CapturedCaretGeometry(
                    rect: CGRect(x: 793, y: 111, width: 2, height: 44),
                    source: "AXBoundsForPreviousCharacter",
                    quality: .derived
                )
            )
        )
    }
}
