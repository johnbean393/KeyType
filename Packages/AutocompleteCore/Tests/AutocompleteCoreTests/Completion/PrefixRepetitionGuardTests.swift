import AutocompleteCore
import XCTest

final class PrefixRepetitionGuardTests: XCTestCase {

    // MARK: - Whole-completion repetition

    func testFiresWhenWholeCompletionRepeatsRecentPhrase() {
        let before = "This is the private key for the OpenAI API. You can use it to access the OpenAI. And"
        XCTAssertTrue(
            PrefixRepetitionGuard.repeatsPrefix(
                completion: " you can use it to access the OpenAI",
                beforeCursor: before
            )
        )
    }

    func testIgnoresPunctuationAndCaseDifferences() {
        let before = "I went to the AI meetup. I want to write about"
        XCTAssertTrue(
            PrefixRepetitionGuard.repeatsPrefix(
                completion: " i want to write about,",
                beforeCursor: before
            )
        )
    }

    // MARK: - Leading repetition that then diverges (the loop shape)

    func testFiresWhenCompletionLeadsWithRepeatThenDiverges() {
        // The repeated phrase is followed by genuinely new text, so the *whole* completion is no
        // longer a substring of the prefix — only the leading run is.
        let before = "This is the private key for the OpenAI API. You can use it to access the OpenAI. And"
        XCTAssertTrue(
            PrefixRepetitionGuard.repeatsPrefix(
                completion: " you can use it to access the OpenAI API to do whatever you want",
                beforeCursor: before
            )
        )
    }

    // MARK: - Negatives

    func testAllowsGenuineContinuation() {
        let before = "This is the private key for the OpenAI API. You can use it to access the OpenAI. And"
        XCTAssertFalse(
            PrefixRepetitionGuard.repeatsPrefix(
                completion: " keep it somewhere safe",
                beforeCursor: before
            )
        )
    }

    func testDoesNotFireOnShortCommonLeadingWord() {
        // A short leading collision ("the ") must not be enough to suppress a real continuation.
        let before = "I saw the dog run across the"
        XCTAssertFalse(
            PrefixRepetitionGuard.repeatsPrefix(
                completion: " street quickly",
                beforeCursor: before
            )
        )
    }

    func testDoesNotFireOnShortCompletion() {
        let before = "the quick brown fox jumps over the"
        XCTAssertFalse(
            PrefixRepetitionGuard.repeatsPrefix(
                completion: " lazy",
                beforeCursor: before
            )
        )
    }

    func testLeadingRepeatThresholdBoundary() {
        // The leading-divergence shape requires a repeated run of ≥16 normalized alphanumeric chars.
        // "abcdefghijklmno" is 15 → must NOT fire on leading-only; "abcdefghijklmnop" is 16 → fires.
        let before15 = "abcdefghijklmno was here earlier in the document somewhere"
        XCTAssertFalse(
            PrefixRepetitionGuard.repeatsPrefix(
                completion: "abcdefghijklmno then something new entirely",
                beforeCursor: before15
            ),
            "15-char leading run is below the threshold"
        )
        let before16 = "abcdefghijklmnop was here earlier in the document somewhere"
        XCTAssertTrue(
            PrefixRepetitionGuard.repeatsPrefix(
                completion: "abcdefghijklmnop then something new entirely",
                beforeCursor: before16
            ),
            "16-char leading run meets the threshold"
        )
    }

    func testWholeCompletionRepeatBoundaryIsEightChars() {
        // The whole-completion shape uses the lower ≥8 floor; "abcdefg" (7) must not fire.
        XCTAssertFalse(
            PrefixRepetitionGuard.repeatsPrefix(completion: " abcdefg", beforeCursor: "abcdefg earlier")
        )
        XCTAssertTrue(
            PrefixRepetitionGuard.repeatsPrefix(completion: " abcdefgh", beforeCursor: "abcdefgh earlier")
        )
    }

    func testRespectsLookbackWindow() {
        // The repeated phrase sits far outside the lookback window, so it should not be suppressed.
        let filler = String(repeating: "x ", count: 400)
        let before = "you can use it to access the OpenAI" + filler
        XCTAssertFalse(
            PrefixRepetitionGuard.repeatsPrefix(
                completion: " you can use it to access the OpenAI",
                beforeCursor: before
            )
        )
    }
}
