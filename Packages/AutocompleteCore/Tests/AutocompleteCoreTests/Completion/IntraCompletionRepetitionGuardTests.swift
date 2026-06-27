import XCTest
@testable import AutocompleteCore

final class IntraCompletionRepetitionGuardTests: XCTestCase {

    // MARK: - Degenerate cases (should suppress)

    func testDigitTripleSpaceSeparated_isDegenerate() {
        XCTAssertTrue(IntraCompletionRepetitionGuard.isDegenerate(" text 1 1 1"))
    }

    func testDigitTripleWithLeadWord_isDegenerate() {
        XCTAssertTrue(IntraCompletionRepetitionGuard.isDegenerate(" since 1 1 1"))
    }

    func testDigitTripleWithMultipleLeadWords_isDegenerate() {
        XCTAssertTrue(IntraCompletionRepetitionGuard.isDegenerate(" apartment or my 1 1 1"))
    }

    func testWordTriple_isDegenerate() {
        XCTAssertTrue(IntraCompletionRepetitionGuard.isDegenerate(" the the the best option"))
    }

    /// Punctuation-separated repetitions: "1, 1, 1" must be caught even though
    /// whitespace-splitting gives ["1,", "1,", "1"] — the guard uses alphanumeric runs.
    func testPunctuationSeparated_isDegenerate() {
        XCTAssertTrue(IntraCompletionRepetitionGuard.isDegenerate("1, 1, 1"))
    }

    func testHyphenSeparated_isDegenerate() {
        XCTAssertTrue(IntraCompletionRepetitionGuard.isDegenerate("go-go-go now"))
    }

    // MARK: - Normal completions (must not suppress)

    func testNormalProseSentence_notDegenerate() {
        XCTAssertFalse(IntraCompletionRepetitionGuard.isDegenerate(" is a company for the industrial floor."))
    }

    func testSingleWord_notDegenerate() {
        XCTAssertFalse(IntraCompletionRepetitionGuard.isDegenerate(" hello"))
    }

    func testTwoWords_notDegenerate() {
        XCTAssertFalse(IntraCompletionRepetitionGuard.isDegenerate(" good morning"))
    }

    /// Two occurrences is below the threshold of three.
    func testDoubleRepeat_notDegenerate() {
        XCTAssertFalse(IntraCompletionRepetitionGuard.isDegenerate(" apartment or my 1 1"))
    }

    func testDoubleRepeatAlt_notDegenerate() {
        XCTAssertFalse(IntraCompletionRepetitionGuard.isDegenerate(" text 1 1"))
    }

    func testEmptyString_notDegenerate() {
        XCTAssertFalse(IntraCompletionRepetitionGuard.isDegenerate(""))
    }

    func testOnlyPunctuation_notDegenerate() {
        XCTAssertFalse(IntraCompletionRepetitionGuard.isDegenerate(". . ."))
    }

    // MARK: - contentWords helper

    func testContentWords_stripsSpacesAndPunctuation() {
        XCTAssertEqual(
            IntraCompletionRepetitionGuard.contentWords(" text 1 1 1").map(String.init),
            ["text", "1", "1", "1"]
        )
    }

    func testContentWords_commaSeparated() {
        XCTAssertEqual(
            IntraCompletionRepetitionGuard.contentWords("1, 1, 1").map(String.init),
            ["1", "1", "1"]
        )
    }

    func testContentWords_emptyString() {
        XCTAssertTrue(IntraCompletionRepetitionGuard.contentWords("").isEmpty)
    }

    func testContentWords_onlyPunctuation() {
        XCTAssertTrue(IntraCompletionRepetitionGuard.contentWords(". . .").isEmpty)
    }
}
