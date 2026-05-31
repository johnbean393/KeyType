import XCTest
@testable import MacContextCapture

final class ScreenTextOCRTests: XCTestCase {
    func testDropsBlankAndWhitespaceLines() {
        let text = ScreenTextOCR.cleanedText(
            fromLines: ["  Subject: schedule ", "", "   ", "Agenda for Monday"],
            maxLines: 40,
            maxChars: 2000
        )
        XCTAssertEqual(text, "Subject: schedule\nAgenda for Monday")
    }

    func testCapsLineCount() {
        let lines = (1...100).map { "line \($0)" }
        let text = ScreenTextOCR.cleanedText(fromLines: lines, maxLines: 3, maxChars: 2000)
        XCTAssertEqual(text, "line 1\nline 2\nline 3")
    }

    func testCapsCharacterCount() {
        let text = ScreenTextOCR.cleanedText(
            fromLines: [String(repeating: "a", count: 50)],
            maxLines: 40,
            maxChars: 10
        )
        XCTAssertEqual(text.count, 10)
    }

    func testEmptyInputProducesEmptyString() {
        XCTAssertEqual(ScreenTextOCR.cleanedText(fromLines: [], maxLines: 40, maxChars: 2000), "")
    }

    // MARK: - Field-text stripping

    func testStripsLinesThatAreTheFieldText() {
        let lines = ["Inbox", "Hi team, here is the plan", "Sent 2m ago"]
        let result = ScreenTextOCR.linesExcludingFieldText(lines, fieldText: "Hi team, here is the plan for tomorrow")
        XCTAssertEqual(result, ["Inbox", "Sent 2m ago"])
    }

    func testStripsSoftWrappedFieldSegments() {
        // The field text has no newline (soft-wrapped on screen); each OCR visual line is still a
        // contiguous substring, so both should be dropped.
        let lines = ["the quick brown fox", "jumps over the lazy dog", "Toolbar"]
        let field = "the quick brown fox jumps over the lazy dog"
        let result = ScreenTextOCR.linesExcludingFieldText(lines, fieldText: field)
        XCTAssertEqual(result, ["Toolbar"])
    }

    func testMatchingIsWhitespaceAndCaseInsensitive() {
        let lines = ["  HELLO   World  "]
        let result = ScreenTextOCR.linesExcludingFieldText(lines, fieldText: "hello world")
        XCTAssertTrue(result.isEmpty)
    }

    func testKeepsShortLinesEvenIfPresentInField() {
        let lines = ["OK", "Surrounding context line"]
        let result = ScreenTextOCR.linesExcludingFieldText(lines, fieldText: "OK")
        XCTAssertEqual(result, ["OK", "Surrounding context line"])
    }

    func testEmptyFieldTextKeepsEverything() {
        let lines = ["one", "two"]
        XCTAssertEqual(ScreenTextOCR.linesExcludingFieldText(lines, fieldText: ""), ["one", "two"])
    }
}
