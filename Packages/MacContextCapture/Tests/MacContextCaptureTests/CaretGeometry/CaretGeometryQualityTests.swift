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
