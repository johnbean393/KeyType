import AutocompleteCore
import XCTest

final class MidWordHealingTests: XCTestCase {
    private static let target = AppTarget(bundleIdentifier: "com.test.app", appName: "Test")

    private func context(before: String, after: String = "") -> TextFieldContext {
        TextFieldContext(beforeCursor: before, afterCursor: after, target: Self.target)
    }

    // MARK: - plan

    func testSplitsAtLastWhitespaceMidWord() {
        let plan = MidWordHealing.plan(for: context(before: "The weather is gre"))
        XCTAssertEqual(plan?.head, "The weather is")
        XCTAssertEqual(plan?.heal, " gre") // separating space folded into the heal text
    }

    func testHealsTwoLetterStem() {
        let plan = MidWordHealing.plan(for: context(before: "Let's go to the be"))
        XCTAssertEqual(plan?.head, "Let's go to the")
        XCTAssertEqual(plan?.heal, " be")
    }

    func testHealsCapitalisedProperNounStem() {
        // Capitalisation is preserved — the byte-exact constraint regenerates " Wat…".
        let plan = MidWordHealing.plan(for: context(before: "I study at Wat"))
        XCTAssertEqual(plan?.head, "I study at")
        XCTAssertEqual(plan?.heal, " Wat")
    }

    func testHealsStemEndingInDigit() {
        let plan = MidWordHealing.plan(for: context(before: "Meet me at gate 12"))
        XCTAssertEqual(plan?.head, "Meet me at gate")
        XCTAssertEqual(plan?.heal, " 12")
    }

    func testNoHealAtWordBoundary() {
        // Prefix ends on a space → between words → ordinary next-token continuation, no healing.
        XCTAssertNil(MidWordHealing.plan(for: context(before: "The weather is ")))
    }

    func testNoHealAfterPunctuation() {
        // Completed word + punctuation → not mid-word.
        XCTAssertNil(MidWordHealing.plan(for: context(before: "The weather is great.")))
    }

    func testNoHealWhenNothingPrecedesTheWord() {
        // The word is the entire prefix → no clean head to prompt from → fall back to normal path.
        XCTAssertNil(MidWordHealing.plan(for: context(before: "gre")))
        XCTAssertNil(MidWordHealing.plan(for: context(before: "   gre")))
    }

    func testNoHealMidLine() {
        // Text after the cursor → native fill-in-the-middle territory, not healing.
        XCTAssertNil(MidWordHealing.plan(for: context(before: "The weather is gre", after: "at place")))
    }

    func testReconstructsOriginalPrefix() {
        let before = "I will see you tom"
        let plan = MidWordHealing.plan(for: context(before: before))
        XCTAssertEqual((plan?.head ?? "") + (plan?.heal ?? ""), before)
    }

    // MARK: - strip

    func testStripRemovesHealPrefix() {
        XCTAssertEqual(MidWordHealing.strip(" great today.", heal: " gre"), "at today.")
        XCTAssertEqual(MidWordHealing.strip(" tomorrow.", heal: " tom"), "orrow.")
    }

    func testStripIsDefensiveWhenPrefixMissing() {
        // Should never happen for a finalised candidate, but never mangle a non-matching string.
        XCTAssertEqual(MidWordHealing.strip("something else", heal: " gre"), "something else")
    }

    func testStripCanEmptyTheCompletion() {
        // Model re-emitted only the stem with no continuation → nothing new to show.
        XCTAssertEqual(MidWordHealing.strip(" gre", heal: " gre"), "")
    }

    func testStripDropsWordBreakAfterStem() {
        // The model satisfied the forced stem then started a *new* word — the leading separator must
        // not survive, or it inserts as a stray space mid-word ("aft" + " ernoon" → "aft ernoon").
        // See ADR-055.
        XCTAssertEqual(MidWordHealing.strip(" aft ernoon", heal: " aft"), "ernoon")
        XCTAssertEqual(MidWordHealing.strip(" gre at", heal: " gre"), "at")
    }

    func testStripKeepsInternalWhitespaceAfterRealContinuation() {
        // A clean sub-word continuation has no leading space; only the genuine word break is dropped,
        // so spaces *between* later words are preserved.
        XCTAssertEqual(MidWordHealing.strip(" afternoon nap", heal: " aft"), "ernoon nap")
    }
}
