//
//  CaretGeometryQualityTests.swift
//  MacContextCaptureTests
//

import AppKit
import AutocompleteCore
import XCTest
@testable import MacContextCapture

final class CaretGeometryQualityTests: XCTestCase {
    func testQualityOrdering() {
        XCTAssertLessThan(AXCaretGeometryQuality.estimated, AXCaretGeometryQuality.derived)
        XCTAssertLessThan(AXCaretGeometryQuality.derived, AXCaretGeometryQuality.exact)
    }

    func testQualityLabels() {
        XCTAssertEqual(AXCaretGeometryQuality.exact.label, "exact")
        XCTAssertEqual(AXCaretGeometryQuality.derived.label, "derived")
        XCTAssertEqual(AXCaretGeometryQuality.estimated.label, "estimated")
    }

    func testGeometryStrategyNamesTheNonInvasivePath() {
        XCTAssertEqual(AXCaretGeometryStrategy.full, .full)
        XCTAssertEqual(AXCaretGeometryStrategy.primary, .primary)
        XCTAssertEqual(AXCaretGeometryStrategy.nonInvasive, .nonInvasive)
    }

    func testNativeMultilineTextUsesPrimaryGeometryForAlignment() {
        XCTAssertEqual(FocusedFieldReader.caretGeometryStrategy(
            isWebField: false,
            role: kAXTextAreaRole as String,
            subrole: nil
        ), .primary)
        XCTAssertEqual(FocusedFieldReader.caretGeometryStrategy(
            isWebField: false,
            role: "AXDocument",
            subrole: nil
        ), .primary)
    }

    func testNativeSingleLineTextUsesNonInvasiveGeometry() {
        XCTAssertEqual(FocusedFieldReader.caretGeometryStrategy(
            isWebField: false,
            role: kAXTextFieldRole as String,
            subrole: nil
        ), .nonInvasive)
    }

    func testWebFieldsKeepFullGeometry() {
        XCTAssertEqual(FocusedFieldReader.caretGeometryStrategy(
            isWebField: true,
            role: kAXTextAreaRole as String,
            subrole: nil
        ), .full)
    }

    func testNativeNonTextFocusedElementsDoNotTriggerDescendantSearch() {
        XCTAssertFalse(FocusedFieldReader.shouldSearchDescendantTextElement(
            rootIsUsable: false,
            rootIsWebContainer: false,
            preferDescendantTextElement: false
        ))
    }

    func testKnownWebBackedFocusedElementsCanSearchForEditableDescendants() {
        XCTAssertTrue(FocusedFieldReader.shouldSearchDescendantTextElement(
            rootIsUsable: false,
            rootIsWebContainer: false,
            preferDescendantTextElement: true
        ))
        XCTAssertTrue(FocusedFieldReader.shouldSearchDescendantTextElement(
            rootIsUsable: true,
            rootIsWebContainer: true,
            preferDescendantTextElement: true
        ))
    }

    func testFieldSizedBoundsAreNotTrustedAsCaretRects() {
        let field = CGRect(x: 80, y: 100, width: 900, height: 120)
        let bogusCaret = field

        XCTAssertTrue(AXCaretGeometryResolver.rectLooksLikeTextContainer(bogusCaret, anchor: field))
    }

    func testLineSizedBoundsAreTrustedAsCaretRects() {
        let field = CGRect(x: 80, y: 100, width: 900, height: 120)
        let lineCaret = CGRect(x: 220, y: 158, width: 2, height: 20)

        XCTAssertFalse(AXCaretGeometryResolver.rectLooksLikeTextContainer(lineCaret, anchor: field))
    }

    func testEstimatedCaretLayoutAccountsForSoftWrappedLines() {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let characterWidth = ("a" as NSString).size(withAttributes: [.font: font]).width
        let text = "aaaa aaaa aaaa"

        let layout = AXCaretGeometryResolver.estimatedSoftWrappedCaretLayout(
            in: text,
            selection: NSRange(location: (text as NSString).length, length: 0),
            availableWidth: characterWidth * 10.5,
            font: font,
            widthBias: 1
        )

        XCTAssertEqual(layout.lineIndex, 1)
        XCTAssertEqual(layout.xOffset, characterWidth * 4, accuracy: 0.5)
    }

    func testEstimatedCaretLayoutSupportsPointOffsetBias() {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let text = "aaaa"
        let selection = NSRange(location: (text as NSString).length, length: 0)
        let baseline = AXCaretGeometryResolver.estimatedSoftWrappedCaretLayout(
            in: text,
            selection: selection,
            availableWidth: 1_000,
            font: font,
            widthBias: 1,
            widthPointOffsetBias: 0
        )

        let shifted = AXCaretGeometryResolver.estimatedSoftWrappedCaretLayout(
            in: text,
            selection: selection,
            availableWidth: 1_000,
            font: font,
            widthBias: 1,
            widthPointOffsetBias: 7
        )

        XCTAssertEqual(shifted.lineIndex, baseline.lineIndex)
        XCTAssertEqual(shifted.xOffset, baseline.xOffset + 7, accuracy: 0.5)
    }

    func testEstimatedCaretRectSupportsBlankLineHeightBias() {
        let field = CGRect(x: 520, y: 142, width: 712, height: 160)
        let beforeCursor = """
        First passage.

        Second passage.

        Third passage
        """
        let selection = NSRange(location: (beforeCursor as NSString).length, length: 0)
        let baseline = AXCaretGeometryResolver.conservativeEstimatedCaretRect(
            in: field,
            text: beforeCursor,
            selection: selection,
            blankLineHeightBias: 0
        )

        let shifted = AXCaretGeometryResolver.conservativeEstimatedCaretRect(
            in: field,
            text: beforeCursor,
            selection: selection,
            blankLineHeightBias: 1
        )

        XCTAssertEqual(baseline.minY - shifted.minY, baseline.height * 2, accuracy: 0.001)
    }

    func testEstimatedCaretRectUsesNeutralMeasuredWidthForCurrentLine() {
        let field = CGRect(x: 511, y: 155, width: 832, height: 82)
        let firstLine = "Let's see what the bounding box is on the first line."
        let currentLine = "On the second line, the bounding box is too far to the left"
        let beforeCursor = "\(firstLine)\n\(currentLine)"
        let selection = NSRange(location: (beforeCursor as NSString).length, length: 0)
        let rect = AXCaretGeometryResolver.conservativeEstimatedCaretRect(
            in: field,
            text: beforeCursor,
            selection: selection,
            paragraphBreakSpacingLineHeightMultiplier: 1.5
        )
        let font = NSFont.systemFont(ofSize: 15)
        let measuredCurrentLineWidth = (currentLine as NSString).size(withAttributes: [.font: font]).width

        XCTAssertEqual(rect.minX, field.minX + measuredCurrentLineWidth, accuracy: 0.001)
    }

    func testWrappedLineTrailingEdgeCaretIsRepairedFromFieldEstimate() {
        let field = CGRect(x: 520, y: 142, width: 712, height: 44)
        let beforeCursor = """
        This is a test of the new KeyType feature, screenshot aware calibration and alignment of the suggestion. I hope at the end of each line
        """
        let badCaret = CGRect(x: 1226, y: 148, width: 2, height: 36)
        let current = CapturedCaretGeometry(
            rect: badCaret,
            source: "AXBoundsForRange",
            quality: CaretGeometryQuality.exact
        )

        let repaired = FocusedFieldReader.repairedCaretGeometry(
            beforeCursor: beforeCursor,
            fieldRect: field,
            current: current
        )
        let selection = NSRange(location: (beforeCursor as NSString).length, length: 0)
        let expected = AXCaretGeometryResolver.conservativeEstimatedCaretRect(
            in: field,
            text: beforeCursor,
            selection: selection
        )

        XCTAssertEqual(repaired.quality, .estimated)
        XCTAssertEqual(repaired.source, "AXFrameEstimateAfterInvalidCaret(AXBoundsForRange)")
        XCTAssertEqual(repaired.rect?.minX ?? 0, expected.minX, accuracy: 0.001)
        XCTAssertLessThan(repaired.rect?.minX ?? .greatestFiniteMagnitude, badCaret.minX - 80)
    }

    func testRepairedChatGPTSoftWrapStartsCurrentWordNearLineOrigin() {
        let field = CGRect(x: 520, y: 142, width: 712, height: 44)
        let beforeCursor = "This is a test of the new KeyType improvements, where screenshots are now used to check if AX provided coordinates "
        let badCaret = CGRect(x: 1226, y: 148, width: 2, height: 36)
        let current = CapturedCaretGeometry(
            rect: badCaret,
            source: "AXBoundsForRange",
            quality: CaretGeometryQuality.exact
        )

        let repaired = FocusedFieldReader.repairedCaretGeometry(
            beforeCursor: beforeCursor,
            fieldRect: field,
            current: current
        )

        XCTAssertEqual(repaired.quality, .estimated)
        XCTAssertGreaterThan(repaired.rect?.minX ?? 0, field.minX + 60)
        XCTAssertLessThan(repaired.rect?.minX ?? .greatestFiniteMagnitude, field.minX + 120)
    }

    func testWebLineMismatchedCaretIsRepairedFromFieldEstimate() {
        let field = CGRect(x: 520, y: 142, width: 712, height: 160)
        let beforeCursor = """
        Per-app overrides are currently quite difficult to adjust in development.

        Since building KeyType from Xcode doesn't get the Accessibility permis
        """
        let lineMismatchedCaret = CGRect(x: 992, y: 263, width: 2, height: 18)
        let current = CapturedCaretGeometry(
            rect: lineMismatchedCaret,
            source: "AXBoundsForRange",
            quality: CaretGeometryQuality.exact
        )
        let selection = NSRange(location: (beforeCursor as NSString).length, length: 0)
        let expected = AXCaretGeometryResolver.conservativeEstimatedCaretRect(
            in: field,
            text: beforeCursor,
            selection: selection,
            blankLineHeightBias: 1,
            paragraphBreakSpacingLineHeightMultiplier: 1.5
        )

        let repaired = FocusedFieldReader.repairedCaretGeometry(
            beforeCursor: beforeCursor,
            fieldRect: field,
            current: current,
            repairLineMismatchedCaret: true
        )

        XCTAssertEqual(repaired.quality, .estimated)
        XCTAssertEqual(repaired.source, "AXFrameEstimateAfterInvalidCaret(AXBoundsForRange)")
        XCTAssertEqual(repaired.rect?.minY ?? 0, expected.minY, accuracy: 0.001)
        XCTAssertGreaterThan(abs(lineMismatchedCaret.midY - expected.midY), expected.height * 0.75)
    }

    func testWebEstimatedFrameCaretWithParagraphBreaksIsRepairedFromFieldSpacing() {
        let field = CGRect(x: 511, y: 155, width: 832, height: 126)
        let beforeCursor = """
        I think we should try to see if we can reproduce the same issue herein Slack.
        Let's start with a new chat.
        The iss
        """
        let selection = NSRange(location: (beforeCursor as NSString).length, length: 0)
        let plainEstimate = AXCaretGeometryResolver.conservativeEstimatedCaretRect(
            in: field,
            text: beforeCursor,
            selection: selection,
            blankLineHeightBias: 1
        )
        let paragraphEstimate = AXCaretGeometryResolver.conservativeEstimatedCaretRect(
            in: field,
            text: beforeCursor,
            selection: selection,
            blankLineHeightBias: 1,
            paragraphBreakSpacingLineHeightMultiplier: 1.5
        )
        let current = CapturedCaretGeometry(
            rect: plainEstimate,
            source: "AXFrameEstimate",
            quality: CaretGeometryQuality.estimated
        )

        let repaired = FocusedFieldReader.repairedCaretGeometry(
            beforeCursor: beforeCursor,
            fieldRect: field,
            current: current,
            repairLineMismatchedCaret: true
        )

        XCTAssertEqual(repaired.quality, .estimated)
        XCTAssertEqual(repaired.source, "AXFrameEstimateAfterInvalidCaret(AXFrameEstimate)")
        XCTAssertEqual(repaired.rect?.minY ?? 0, paragraphEstimate.minY, accuracy: 0.001)
        XCTAssertLessThan(repaired.rect?.minY ?? .greatestFiniteMagnitude, plainEstimate.minY - 30)
    }

    func testLineMismatchedCaretIsNotRepairedByDefault() {
        let field = CGRect(x: 520, y: 142, width: 712, height: 160)
        let beforeCursor = """
        Per-app overrides are currently quite difficult to adjust in development.

        Since building KeyType from Xcode doesn't get the Accessibility permis
        """
        let lineMismatchedCaret = CGRect(x: 992, y: 263, width: 2, height: 18)
        let current = CapturedCaretGeometry(
            rect: lineMismatchedCaret,
            source: "AXBoundsForRange",
            quality: CaretGeometryQuality.exact
        )

        let repaired = FocusedFieldReader.repairedCaretGeometry(
            beforeCursor: beforeCursor,
            fieldRect: field,
            current: current
        )

        XCTAssertEqual(repaired, current)
    }

    func testLineMismatchedAppEstimatedCaretIsNotRepairedAgain() {
        let field = CGRect(x: 520, y: 142, width: 712, height: 160)
        let beforeCursor = """
        Per-app overrides are currently quite difficult to adjust in development.

        Since building KeyType from Xcode doesn't get the Accessibility permis
        """
        let estimatedCaret = CGRect(x: 992, y: 263, width: 2, height: 18)
        let current = CapturedCaretGeometry(
            rect: estimatedCaret,
            source: "appSoftWrapEstimate",
            quality: CaretGeometryQuality.estimated
        )

        let repaired = FocusedFieldReader.repairedCaretGeometry(
            beforeCursor: beforeCursor,
            fieldRect: field,
            current: current,
            repairLineMismatchedCaret: true
        )

        XCTAssertEqual(repaired, current)
    }

    func testSingleLineTallCaretIsNotRepairedWithoutWrapEvidence() {
        let field = CGRect(x: 520, y: 142, width: 712, height: 44)
        let caret = CGRect(x: 620, y: 148, width: 2, height: 36)
        let current = CapturedCaretGeometry(
            rect: caret,
            source: "AXBoundsForRange",
            quality: CaretGeometryQuality.exact
        )

        let repaired = FocusedFieldReader.repairedCaretGeometry(
            beforeCursor: "short text",
            fieldRect: field,
            current: current
        )

        XCTAssertEqual(repaired, current)
    }

    func testTopLineTrailingEdgeCaretIsNotRepairedAsContinuationLine() {
        let field = CGRect(x: 520, y: 142, width: 712, height: 44)
        let beforeCursor = """
        This is a test of the new KeyType feature, screenshot aware calibration and alignment of the suggestion. I hope at the end of each line
        """
        let topLineCaret = CGRect(x: 1226, y: 168, width: 2, height: 16)
        let current = CapturedCaretGeometry(
            rect: topLineCaret,
            source: "AXBoundsForRange",
            quality: CaretGeometryQuality.exact
        )

        let repaired = FocusedFieldReader.repairedCaretGeometry(
            beforeCursor: beforeCursor,
            fieldRect: field,
            current: current
        )

        XCTAssertEqual(repaired, current)
    }
}
