import AutocompleteCore
import XCTest

final class CorrectionTargetingTests: XCTestCase {
    private let target = AppTarget(bundleIdentifier: "com.test.app", appName: "Test")

    func testExtractsLastClosedWordBeforeCaretAndLeavesPunctuationOutsideRange() throws {
        let context = TextFieldContext(beforeCursor: "in the mdidle, ", target: target)
        let correction = try CorrectionTargeting.closedWordBeforeCaret(in: context).get()

        XCTAssertEqual(correction.original, "mdidle")
        XCTAssertEqual(correction.prefixBeforeWord, "in the ")
        XCTAssertEqual(correction.suffixAfterWord, ", ")
        XCTAssertEqual(correction.range, TextRangeDescriptor(container: .beforeCursor, startOffset: 7, endOffset: 13))
        XCTAssertEqual(correction.range.range(in: context.beforeCursor).map { String(context.beforeCursor[$0]) }, "mdidle")
    }

    func testOpenCurrentWordIsNotEligible() {
        let context = TextFieldContext(beforeCursor: "in the mdidle", target: target)

        XCTAssertEqual(failure(in: context), .noClosedWord)
    }

    func testCurrentWordBeforeCaretIsEligibleWhenCaretIsAtWordEnd() throws {
        let context = TextFieldContext(beforeCursor: "in the mdidle", target: target)
        let correction = try CorrectionTargeting.currentWordBeforeCaret(in: context).get()

        XCTAssertEqual(correction.original, "mdidle")
        XCTAssertEqual(correction.prefixBeforeWord, "in the ")
        XCTAssertEqual(correction.suffixAfterWord, "")
        XCTAssertEqual(correction.range, TextRangeDescriptor(container: .beforeCursor, startOffset: 7, endOffset: 13))
    }

    func testCurrentWordBeforeCaretRequiresCaretAtWordBoundary() {
        let context = TextFieldContext(beforeCursor: "in the mdi", afterCursor: "dle of the room", target: target)

        guard case let .failure(reason) = CorrectionTargeting.currentWordBeforeCaret(in: context) else {
            return XCTFail("Expected current word in the middle of a larger word to be ineligible")
        }
        XCTAssertEqual(reason, .noClosedWord)
    }

    func testSelectionIsNotEligible() {
        let context = TextFieldContext(
            beforeCursor: "in the mdidle ",
            selection: TextSelection(selectedText: "mdidle"),
            target: target
        )

        XCTAssertEqual(failure(in: context), .selectionActive)
    }

    func testUnsafeFieldsAreNotEligible() {
        let context = TextFieldContext(
            beforeCursor: "in the mdidle ",
            target: target,
            traits: TextFieldTraits(isTerminalLike: true)
        )

        XCTAssertEqual(failure(in: context), .unsafeField)
    }

    func testSkipsURLsAndEmails() {
        XCTAssertEqual(failure(in: TextFieldContext(beforeCursor: "go to https://exmaple.com ", target: target)), .urlOrEmail)
        XCTAssertEqual(failure(in: TextFieldContext(beforeCursor: "email me@example ", target: target)), .urlOrEmail)
    }

    func testSkipsNumbersAcronymsCamelCaseAndCodeIdentifiers() {
        XCTAssertEqual(failure(in: TextFieldContext(beforeCursor: "see mdidle2 ", target: target)), .number)
        XCTAssertEqual(failure(in: TextFieldContext(beforeCursor: "see NASA ", target: target)), .acronym)
        XCTAssertEqual(failure(in: TextFieldContext(beforeCursor: "see myVariable ", target: target)), .camelCase)
        XCTAssertEqual(failure(in: TextFieldContext(beforeCursor: "config.mdidle ", target: target)), .codeIdentifier)
    }

    func testSkipsCJKLatinAdjacency() {
        XCTAssertEqual(failure(in: TextFieldContext(beforeCursor: "在mdidle ", target: target)), .scriptMismatch)
    }

    func testCasePreservation() {
        XCTAssertEqual(CorrectionTargeting.preservesCase("middle", like: "Mdidle"), "Middle")
        XCTAssertEqual(CorrectionTargeting.preservesCase("middle", like: "MDIDLE"), "MIDDLE")
        XCTAssertEqual(CorrectionTargeting.preservesCase("middle", like: "mdidle"), "middle")
    }

    func testEditDistance() {
        XCTAssertEqual(CorrectionTargeting.editDistance("mdidle", "middle"), 2)
        XCTAssertGreaterThan(CorrectionTargeting.editDistance("abcdef", "middle", maxDistance: 2), 2)
    }

    private func failure(in context: TextFieldContext) -> CorrectionEligibilityFailure? {
        guard case let .failure(reason) = CorrectionTargeting.closedWordBeforeCaret(in: context) else {
            return nil
        }
        return reason
    }
}
