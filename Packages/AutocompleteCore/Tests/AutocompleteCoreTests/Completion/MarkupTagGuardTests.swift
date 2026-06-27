import XCTest
@testable import AutocompleteCore

/// `MarkupTagGuard` — the output net for Gemma's single-token HTML-tag leak (`"my name is"` →
/// `"</code>"` in a web chat box). Suppress only pure-markup candidates in markup-free contexts;
/// a user genuinely writing tags must keep their completions.
final class MarkupTagGuardTests: XCTestCase {

    // MARK: - Pure-markup detection

    func testSingleClosingTagIsPureMarkup() {
        XCTAssertTrue(MarkupTagGuard.isPureMarkup("</code>"))
    }

    func testLeadingSpaceTagIsPureMarkup() {
        // The observed leak: token 236743 (" ") + token 215 ("</code>").
        XCTAssertTrue(MarkupTagGuard.isPureMarkup(" </code>"))
    }

    func testMultipleTagsArePureMarkup() {
        XCTAssertTrue(MarkupTagGuard.isPureMarkup("</td></tr>"))
        XCTAssertTrue(MarkupTagGuard.isPureMarkup("<b> <i>"))
    }

    func testSelfClosingTagIsPureMarkup() {
        XCTAssertTrue(MarkupTagGuard.isPureMarkup("<br/>"))
        XCTAssertTrue(MarkupTagGuard.isPureMarkup("<br />"))
    }

    func testProseIsNotPureMarkup() {
        XCTAssertFalse(MarkupTagGuard.isPureMarkup("john smith"))
    }

    func testTagFollowedByProseIsNotPureMarkup() {
        // The tag may be continuing the user's own markup — other nets judge the rest.
        XCTAssertFalse(MarkupTagGuard.isPureMarkup("</b> and then some"))
    }

    func testPartialBracketTextIsNotPureMarkup() {
        XCTAssertFalse(MarkupTagGuard.isPureMarkup("code> to format"))
        XCTAssertFalse(MarkupTagGuard.isPureMarkup("<3"))
        XCTAssertFalse(MarkupTagGuard.isPureMarkup("a < b"))
    }

    func testAttributeBearingTagIsNotPureMarkup() {
        // Attribute tags are never single leaked tokens; leave them to context judgement.
        XCTAssertFalse(MarkupTagGuard.isPureMarkup(#"<a href="x">"#))
    }

    func testEmptyStringIsNotPureMarkup() {
        XCTAssertFalse(MarkupTagGuard.isPureMarkup(""))
    }

    // MARK: - Context exemption

    func testSuppressesPureTagInProseContext() {
        XCTAssertTrue(MarkupTagGuard.violates(
            completion: " </code>",
            beforeCursor: "my name is",
            afterCursor: ""
        ))
    }

    func testAllowsClosingTagWhenUserIsWritingMarkup() {
        XCTAssertFalse(MarkupTagGuard.violates(
            completion: "</b>",
            beforeCursor: "wrap it like <b>hello",
            afterCursor: ""
        ))
    }

    func testAllowsTagWhenMarkupFollowsCaret() {
        XCTAssertFalse(MarkupTagGuard.violates(
            completion: "<td>",
            beforeCursor: "add a cell: ",
            afterCursor: "</tr></table>"
        ))
    }

    func testAttributeBearingContextMarkupExempts() {
        XCTAssertFalse(MarkupTagGuard.violates(
            completion: "</a>",
            beforeCursor: #"see <a href="https://example.com">this link"#,
            afterCursor: ""
        ))
    }

    func testProseCompletionNeverViolates() {
        XCTAssertFalse(MarkupTagGuard.violates(
            completion: " john smith",
            beforeCursor: "my name is",
            afterCursor: ""
        ))
    }
}
