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

    // MARK: - Corruption guard

    func testDropsLinesWithReplacementCharacter() {
        let lines = ["A clean line of text", "garb\u{FFFD}led recognition here"]
        XCTAssertEqual(ScreenTextOCR.droppingCorruptedLines(lines), ["A clean line of text"])
    }

    func testDropsSymbolHeavyLines() {
        let lines = ["Subject: schedule", "▮▮ ◊◊ ╳╳ ¶¶ §§ ‡‡"]
        XCTAssertEqual(ScreenTextOCR.droppingCorruptedLines(lines), ["Subject: schedule"])
    }

    func testKeepsOrdinaryProse() {
        let lines = ["This GPU has a similar level of performance to the RTX 5070, so it's close."]
        XCTAssertEqual(ScreenTextOCR.droppingCorruptedLines(lines), lines)
    }

    func testKeepsTechnicalTextWithModelNamesAndNumbers() {
        // Model names, version numbers, hyphenation, and code-ish punctuation must NOT be flagged.
        let lines = [
            "Nvidia is about to launch their N1X SoC.",
            "a 20-core MediaTek GPU and a 10-core Nvidia GPU",
            "let x = foo(bar) + baz[0] // 50% done"
        ]
        XCTAssertEqual(ScreenTextOCR.droppingCorruptedLines(lines), lines)
    }

    func testKeepsBulletedListItems() {
        let lines = ["• First item", "• Second item"]
        XCTAssertEqual(ScreenTextOCR.droppingCorruptedLines(lines), lines)
    }

    func testDropsLinesWithDigitSubstitutedWords() {
        // OCR letter→digit confusion ("quality" → "qu81ity", "defect" → "defecti" stays, but the
        // garbled token is enough to drop the whole line).
        let lines = ["A clean sentence about quality", "wrongly classified as a mid-tsM qu81ity defecti."]
        XCTAssertEqual(ScreenTextOCR.droppingCorruptedLines(lines), ["A clean sentence about quality"])
    }

    func testDigitSubstitutionDoesNotFlagTechnicalTokens() {
        // Trailing/leading digits and ALL-CAPS model names must survive.
        let lines = [
            "Running k0 tests on the RTX 5070 and N1X SoC",
            "utf8 encoding, version v2, 20-core CPU, macOS15"
        ]
        XCTAssertEqual(ScreenTextOCR.droppingCorruptedLines(lines), lines)
    }
}
