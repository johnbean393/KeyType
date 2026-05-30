import AutocompleteCore
import XCTest

final class CaretBoundaryTests: XCTestCase {
    func testStripsLeadingSpaceWhenPrefixEndsWithSpace() {
        // "The capital of France is " + " Paris." would double the space.
        XCTAssertEqual(
            CaretBoundary.reconcile(" Paris.", beforeCursor: "The capital of France is "),
            "Paris."
        )
    }

    func testKeepsLeadingSpaceWhenPrefixEndsWithWord() {
        // "…France is" + " Paris." is correct — the space is the word separator.
        XCTAssertEqual(
            CaretBoundary.reconcile(" Paris.", beforeCursor: "The capital of France is"),
            " Paris."
        )
    }

    func testStripsLeadingTabAfterWhitespacePrefix() {
        XCTAssertEqual(
            CaretBoundary.reconcile("\t\tvalue", beforeCursor: "let x ="),
            "\t\tvalue",
            "prefix ends with a word, so leading tabs are preserved"
        )
        XCTAssertEqual(
            CaretBoundary.reconcile("\tvalue", beforeCursor: "let x = "),
            "value"
        )
    }

    func testStripsLeadingNewlineAlways() {
        // FIM tends to prepend a newline at the caret.
        XCTAssertEqual(
            CaretBoundary.reconcile("\nFrance.", beforeCursor: "The capital of "),
            "France."
        )
        XCTAssertEqual(
            CaretBoundary.reconcile("\n    a + b", beforeCursor: "def add(a, b):\n    return "),
            "a + b"
        )
    }

    func testNewlineThenSpaceCollapsesBoth() {
        XCTAssertEqual(
            CaretBoundary.reconcile("\n Paris.", beforeCursor: "The capital of France is "),
            "Paris."
        )
    }

    func testNoChangeForCleanCandidate() {
        XCTAssertEqual(
            CaretBoundary.reconcile("orrow.", beforeCursor: "I will see you tom"),
            "orrow."
        )
    }

    func testCanReduceToEmpty() {
        XCTAssertEqual(CaretBoundary.reconcile("\n", beforeCursor: "hello"), "")
        XCTAssertEqual(CaretBoundary.reconcile("  ", beforeCursor: "hello "), "")
    }

    func testStripsNonBreakingAndMultipleSpacesAfterWhitespacePrefix() {
        // A non-breaking space (U+00A0) separator after an existing space would still double up.
        XCTAssertEqual(
            CaretBoundary.reconcile("\u{00A0}Paris.", beforeCursor: "The capital of France is "),
            "Paris."
        )
        // Several leading spaces collapse away entirely when the prefix already ends in whitespace.
        XCTAssertEqual(
            CaretBoundary.reconcile("   Paris.", beforeCursor: "The capital of France is "),
            "Paris."
        )
    }
}
