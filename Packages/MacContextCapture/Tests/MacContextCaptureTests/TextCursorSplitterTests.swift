//
//  TextCursorSplitterTests.swift
//  MacContextCaptureTests
//

import XCTest
@testable import MacContextCapture

final class TextCursorSplitterTests: XCTestCase {
    func testCaretAtStart() {
        let split = TextCursorSplitter.split(text: "hello world", axRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(split.beforeCursor, "")
        XCTAssertEqual(split.afterCursor, "hello world")
        XCTAssertEqual(split.selectedText, "")
        XCTAssertFalse(split.isAtEndOfLine)
    }

    func testCaretInMiddle() {
        let split = TextCursorSplitter.split(text: "hello world", axRange: NSRange(location: 5, length: 0))
        XCTAssertEqual(split.beforeCursor, "hello")
        XCTAssertEqual(split.afterCursor, " world")
        XCTAssertFalse(split.isAtEndOfLine)
    }

    func testCaretAtEndOfLine() {
        let split = TextCursorSplitter.split(text: "hello", axRange: NSRange(location: 5, length: 0))
        XCTAssertEqual(split.beforeCursor, "hello")
        XCTAssertEqual(split.afterCursor, "")
        XCTAssertTrue(split.isAtEndOfLine)
    }

    func testCaretBeforeNewlineIsAtEndOfLine() {
        let split = TextCursorSplitter.split(
            text: "first\nsecond",
            axRange: NSRange(location: 5, length: 0)
        )
        XCTAssertEqual(split.beforeCursor, "first")
        XCTAssertEqual(split.afterCursor, "\nsecond")
        XCTAssertTrue(split.isAtEndOfLine)
    }

    func testSelectionRangePopulated() {
        let split = TextCursorSplitter.split(text: "hello world", axRange: NSRange(location: 6, length: 5))
        XCTAssertEqual(split.beforeCursor, "hello ")
        XCTAssertEqual(split.afterCursor, "")
        XCTAssertEqual(split.selectedText, "world")
        XCTAssertNotNil(split.range)
    }

    func testEmojiTextSplitsOnUtf16Boundary() {
        // "a😀b" has UTF-16 length 4 (emoji is 2 code units). AX returns UTF-16 offsets, so a
        // location of 3 sits *after* the emoji, before "b".
        let text = "a😀b"
        let split = TextCursorSplitter.split(text: text, axRange: NSRange(location: 3, length: 0))
        XCTAssertEqual(split.beforeCursor, "a😀")
        XCTAssertEqual(split.afterCursor, "b")
        XCTAssertFalse(split.isAtEndOfLine)
    }

    func testOutOfBoundsLocationClampsToEnd() {
        let split = TextCursorSplitter.split(text: "abc", axRange: NSRange(location: 999, length: 5))
        XCTAssertEqual(split.beforeCursor, "abc")
        XCTAssertEqual(split.afterCursor, "")
        XCTAssertEqual(split.selectedText, "")
        XCTAssertTrue(split.isAtEndOfLine)
    }

    func testNilRangeTreatedAsCaretAtEnd() {
        let split = TextCursorSplitter.split(text: "abc", axRange: nil)
        XCTAssertEqual(split.beforeCursor, "abc")
        XCTAssertEqual(split.afterCursor, "")
        XCTAssertTrue(split.isAtEndOfLine)
    }
}
