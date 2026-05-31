import XCTest
@testable import AutocompleteCore

final class SuffixOverlapGuardTests: XCTestCase {
    private func duplicates(_ completion: String, before: String = "", after: String) -> Bool {
        SuffixOverlapGuard.duplicatesSuffix(completion: completion, beforeCursor: before, afterCursor: after)
    }

    // MARK: - Boundary-aligned duplication (caret at a word boundary)

    func testSuppressesCompletionThatReproducesTheSuffixHead() {
        // Caret after "…similar level of " — the model regurgitates the existing downstream text.
        XCTAssertTrue(duplicates(
            "performance to the RTX 5070, so it's",
            before: "This GPU has a similar level of ",
            after: "performance to the RTX 5070, so it's close to a mid-range GPU."
        ))
    }

    func testSuppressesWhenCompletionHasLeadingSeparatorSpace() {
        XCTAssertTrue(duplicates(
            " performance to the RTX 5070, so it's",
            before: "This GPU has a similar level of",
            after: " performance to the RTX 5070, so it's close to a mid-range GPU."
        ))
    }

    // MARK: - Suffix-contained duplication (completion re-types the suffix)

    func testSuppressesCompletionContainingTheWholeSuffix() {
        // Caret after "…create a Git"; afterCursor = "hub repo for KeyType.". The (stale) completion
        // finishes the word and re-types the rest, so it contains the suffix verbatim.
        XCTAssertTrue(duplicates(
            "ithub repo for KeyType.",
            before: "Assume I will create a Git",
            after: "hub repo for KeyType."
        ))
    }

    func testSuppressesCompletionContainingSuffixAtWordBoundary() {
        // Field "…create a Git repo for KeyType." with the caret after the word "Git".
        XCTAssertTrue(duplicates(
            "ithub repo for KeyType.",
            before: "Assume I will create a Git",
            after: " repo for KeyType."
        ))
    }

    func testKeepsCompletionThatContainsOnlyAShortSharedRun() {
        // Suffix " to me" is below the contained-overlap floor, so a completion that happens to
        // include it is not suppressed on that basis.
        XCTAssertFalse(duplicates("send it to me", before: "Please ", after: " to me"))
    }

    // MARK: - Mid-word duplication (caret inside a word)

    func testSuppressesMidWordCopyWithGarbagePrefix() {
        // Caret after "…level of p"; afterCursor opens with the rest of "performance". The model
        // emits a stray "**" then copies the suffix — still a duplicate after normalisation.
        XCTAssertTrue(duplicates(
            "**formance to the RTX 5070, so it's",
            before: "This GPU has a similar level of p",
            after: "erformance to the RTX 5070, so it's close to a mid-range GPU."
        ))
    }

    func testSuppressesMidWordCopyWhenCaretSplitsWord() {
        // Caret after "…similar lev"; afterCursor = "el of performance…".
        XCTAssertTrue(duplicates(
            " of performance to the RTX 5070, so it's",
            before: "This GPU has a similar lev",
            after: "el of performance to the RTX 5070, so it's close to a mid-range GPU."
        ))
    }

    // MARK: - Legitimate completions are kept

    func testKeepsGenuineMidLineInsertion() {
        // "I really |this idea" → "like" does not duplicate the suffix.
        XCTAssertFalse(duplicates("like", before: "I really ", after: "this idea is great"))
    }

    func testKeepsEndOfLineContinuation() {
        XCTAssertFalse(duplicates(" world", before: "hello", after: ""))
    }

    func testKeepsWhenSuffixIsOnlyPunctuationOrWhitespace() {
        XCTAssertFalse(duplicates("store", before: "I went to the ", after: " ."))
        XCTAssertFalse(duplicates("store", before: "I went to the ", after: "."))
    }

    func testKeepsCompletionThatMerelySharesAFewLetters() {
        // Suffix begins with "the" but the completion is a different, longer continuation.
        XCTAssertFalse(duplicates("themed party tonight", before: "We are throwing a ", after: "the venue is booked"))
    }

    func testShortCompletionsBelowMinimumOverlapAreKept() {
        // Two normalised characters — below the floor, so not judged.
        XCTAssertFalse(duplicates("hi", before: "say ", after: "hi there"))
    }
}
