import AutocompleteCore
import CoreGraphics
import XCTest
@testable import MacContextCapture

final class MessagesRichPreviewCaretGeometryFallbackTests: XCTestCase {
    func testCapturedRichPreviewHeightOffsetsCaretWhileKeepingX() {
        let field = CGRect(x: 528, y: 96, width: 782, height: 270)
        let current = CGRect(x: 601, y: 327, width: 2, height: 18)

        let corrected = MessagesRichPreviewCaretGeometryFallback.correctedCaretRect(
            current,
            fieldRect: field,
            lineHeight: 18,
            mediaStackHeight: 128
        )

        XCTAssertEqual(corrected?.source, "MessagesAttachmentStackOffset")
        XCTAssertEqual(corrected?.rect.minX, current.minX)
        XCTAssertEqual(corrected?.rect.minY ?? -1, 199, accuracy: 0.001)
        XCTAssertEqual(corrected?.rect.height, current.height)
    }

    func testCapturedImageAttachmentHeightUsesSameOffsetPath() {
        let field = CGRect(x: 70, y: 88, width: 920, height: 300)
        let current = CGRect(x: 160, y: 330, width: 2, height: 22)

        let corrected = MessagesRichPreviewCaretGeometryFallback.correctedCaretRect(
            current,
            fieldRect: field,
            lineHeight: 22,
            mediaStackHeight: 210
        )

        XCTAssertEqual(corrected?.source, "MessagesAttachmentStackOffset")
        XCTAssertEqual(corrected?.rect.minX, current.minX)
        XCTAssertEqual(corrected?.rect.minY ?? -1, 120, accuracy: 0.001)
    }

    func testNormalMessagesComposeFieldKeepsNativeCaret() {
        let field = CGRect(x: 520, y: 141, width: 712, height: 44)
        let current = CapturedCaretGeometry(
            rect: CGRect(x: 542, y: 167, width: 2, height: 16),
            source: "AXBoundsForRange",
            quality: .exact
        )

        let repaired = MessagesRichPreviewCaretGeometryFallback.caretGeometry(
            target: AppTarget(bundleIdentifier: "com.apple.MobileSMS", appName: "Messages"),
            beforeCursor: "Do ",
            afterCursor: "",
            element: nil,
            fieldRect: field,
            current: current
        )

        XCTAssertNil(repaired)
    }

    func testDoesNotMoveCaretWhenEditingBeforeExistingText() {
        let field = CGRect(x: 528, y: 96, width: 782, height: 270)
        let current = CapturedCaretGeometry(
            rect: CGRect(x: 601, y: 327, width: 2, height: 18),
            source: "AXBoundsForRange",
            quality: .exact
        )

        let repaired = MessagesRichPreviewCaretGeometryFallback.caretGeometry(
            target: AppTarget(bundleIdentifier: "com.apple.MobileSMS", appName: "Messages"),
            beforeCursor: "Let's",
            afterCursor: " see if",
            element: nil,
            fieldRect: field,
            current: current
        )

        XCTAssertNil(repaired)
    }

    func testDoesNotMoveMultiLineMessageCaret() {
        let field = CGRect(x: 528, y: 96, width: 782, height: 270)
        let current = CapturedCaretGeometry(
            rect: CGRect(x: 601, y: 327, width: 2, height: 18),
            source: "AXBoundsForRange",
            quality: .exact
        )

        let repaired = MessagesRichPreviewCaretGeometryFallback.caretGeometry(
            target: AppTarget(bundleIdentifier: "com.apple.MobileSMS", appName: "Messages"),
            beforeCursor: "First line\nLet's see if",
            afterCursor: "",
            element: nil,
            fieldRect: field,
            current: current
        )

        XCTAssertNil(repaired)
    }

    func testAllowsLeadingAttachmentMarkerLineBeforeTypedText() {
        let field = CGRect(x: 528, y: 96, width: 782.5, height: 294.5)
        let current = CapturedCaretGeometry(
            rect: CGRect(x: 565.28759765625, y: 351.52734375, width: 2, height: 18.486328125),
            source: "AXFrameEstimate",
            quality: .estimated
        )

        let repaired = MessagesRichPreviewCaretGeometryFallback.caretGeometry(
            target: AppTarget(bundleIdentifier: "com.apple.MobileSMS", appName: "Messages"),
            beforeCursor: "\u{FFFC}\nLet's ",
            afterCursor: "",
            element: nil,
            fieldRect: field,
            current: current
        )

        XCTAssertEqual(repaired?.quality, .estimated)
        XCTAssertEqual(repaired?.source, "MessagesAttachmentBottomLineEstimate(AXFrameEstimate)")
        XCTAssertEqual(repaired?.rect?.minX, current.rect?.minX)
        XCTAssertEqual(repaired?.rect?.minY ?? -1, 96, accuracy: 0.001)
    }

    func testAllowsParagraphsAfterAttachmentMarkerBeforeCurrentLine() {
        let field = CGRect(x: 528, y: 96, width: 782, height: 195)
        let current = CapturedCaretGeometry(
            rect: CGRect(x: 652, y: 215, width: 2, height: 18),
            source: "AXBoundsForRange",
            quality: .exact
        )

        let repaired = MessagesRichPreviewCaretGeometryFallback.caretGeometry(
            target: AppTarget(bundleIdentifier: "com.apple.MobileSMS", appName: "Messages"),
            beforeCursor: "\u{FFFC}\nThis is the first line after the attachment.\n\nThis is the second",
            afterCursor: "",
            element: nil,
            fieldRect: field,
            current: current
        )

        XCTAssertEqual(repaired?.quality, .estimated)
        XCTAssertEqual(repaired?.source, "MessagesAttachmentBottomLineEstimate(AXBoundsForRange)")
        XCTAssertEqual(repaired?.rect?.minX, current.rect?.minX)
        XCTAssertEqual(repaired?.rect?.minY ?? -1, 96, accuracy: 0.001)
    }

    func testFallsBackToBottomLineEstimateWithoutCapturedAttachmentFrame() {
        let field = CGRect(x: 528, y: 96, width: 782, height: 270)
        let current = CapturedCaretGeometry(
            rect: CGRect(x: 601, y: 327, width: 2, height: 18),
            source: "AXBoundsForRange",
            quality: .exact
        )

        let repaired = MessagesRichPreviewCaretGeometryFallback.caretGeometry(
            target: AppTarget(bundleIdentifier: "com.apple.MobileSMS", appName: "Messages"),
            beforeCursor: "\u{FFFC}\nLet's see if",
            afterCursor: "",
            element: nil,
            fieldRect: field,
            current: current
        )

        XCTAssertEqual(repaired?.quality, .estimated)
        XCTAssertEqual(repaired?.source, "MessagesAttachmentBottomLineEstimate(AXBoundsForRange)")
        XCTAssertEqual(repaired?.rect?.minX, current.rect?.minX)
        XCTAssertEqual(repaired?.rect?.minY ?? -1, 96, accuracy: 0.001)
        XCTAssertEqual(repaired?.rect?.height, current.rect?.height)
    }
}
