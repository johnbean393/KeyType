import AutocompleteCore
import XCTest

final class SuggestionAnchorTests: XCTestCase {
    private static let target = AppTarget(bundleIdentifier: "com.test.app", appName: "Test")

    private func context(before: String, after: String = "") -> TextFieldContext {
        TextFieldContext(beforeCursor: before, afterCursor: after, target: Self.target)
    }

    private func remaining(_ anchorText: String, anchorBefore: String, liveBefore: String, after: String = "") -> String? {
        SuggestionAnchor.remaining(
            anchorText: anchorText,
            anchor: context(before: anchorBefore, after: after),
            live: context(before: liveBefore, after: after)
        )
    }

    func testUnchangedCaretReturnsWholeCompletion() {
        XCTAssertEqual(
            remaining("excited.", anchorBefore: "I couldn't be more ", liveBefore: "I couldn't be more "),
            "excited."
        )
    }

    func testTypingSuggestedCharactersShrinksTheCompletion() {
        // The bug: suggestion "excited." for "…be more ", then the user types "e" — the remainder
        // shown/inserted must be "xcited.", never the full "excited." (which produced "eexcited.").
        XCTAssertEqual(
            remaining("excited.", anchorBefore: "I couldn't be more ", liveBefore: "I couldn't be more e"),
            "xcited."
        )
        XCTAssertEqual(
            remaining("excited.", anchorBefore: "I couldn't be more ", liveBefore: "I couldn't be more exc"),
            "ited."
        )
    }

    func testTypingTheWholeWordConsumesIt() {
        XCTAssertEqual(
            remaining("excited.", anchorBefore: "be more ", liveBefore: "be more excited."),
            ""
        )
    }

    func testTypingALeadingSpaceConsumesTheSeparator() {
        // Suggestion carries a leading separator (" Paris.") because it was anchored at a word; once
        // the user types the space the remainder drops it, so we never double the space.
        XCTAssertEqual(
            remaining(" Paris.", anchorBefore: "The capital is", liveBefore: "The capital is "),
            "Paris."
        )
    }

    func testDivergentKeystrokeInvalidates() {
        // User typed a character the suggestion did not predict → drop it.
        XCTAssertNil(remaining("excited.", anchorBefore: "be more ", liveBefore: "be more a"))
    }

    func testBackspaceOrCaretJumpInvalidates() {
        // Live prefix no longer extends the anchor prefix (deletion / moved caret).
        XCTAssertNil(remaining("excited.", anchorBefore: "be more ", liveBefore: "be mor"))
        XCTAssertNil(remaining("excited.", anchorBefore: "be more ", liveBefore: "completely different"))
    }

    func testChangeAfterCursorInvalidates() {
        XCTAssertNil(
            SuggestionAnchor.remaining(
                anchorText: "excited.",
                anchor: context(before: "be more ", after: " today"),
                live: context(before: "be more ", after: " tomorrow")
            )
        )
    }
}
