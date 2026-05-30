import AppCompatibility
import AutocompleteCore
import ConstrainedGeneration
import XCTest

/// Covers the full `SuppressionReason` taxonomy through `DefaultCandidateFilter` (M6). Pure and
/// deterministic — no model, profile, or AppKit.
final class CandidateFilterTests: XCTestCase {
    private static let target = AppTarget(bundleIdentifier: "com.test.app", appName: "Test")

    private func request(
        beforeCursor: String = "",
        afterCursor: String = "",
        requiredPrefixBytes: [UInt8] = [],
        mode: CompletionMode = .prose,
        maxCompletionTokens: Int = 4,
        maxDisplayWidth: Int = 80,
        language: String? = nil,
        target: AppTarget = CandidateFilterTests.target,
        placeholder: String? = nil,
        labels: [String] = [],
        traits: TextFieldTraits = TextFieldTraits()
    ) -> CompletionRequest {
        let context = TextFieldContext(
            beforeCursor: beforeCursor,
            afterCursor: afterCursor,
            target: target,
            placeholder: placeholder,
            labels: labels,
            detectedLanguage: language,
            traits: traits
        )
        return CompletionRequest(
            context: context,
            prompt: beforeCursor,
            requiredPrefixBytes: requiredPrefixBytes,
            mode: mode,
            maxCompletionTokens: maxCompletionTokens,
            maxDisplayWidth: maxDisplayWidth
        )
    }

    private func candidate(
        _ text: String,
        tokenIDs: [TokenID] = [0],
        displayWidth: Int? = nil
    ) -> CompletionCandidate {
        CompletionCandidate(text: text, tokenIDs: tokenIDs, displayWidth: displayWidth)
    }

    // MARK: - Pass-through

    func testAcceptsAValidCandidate() {
        let filter = DefaultCandidateFilter()
        XCTAssertNil(filter.suppressionReason(for: candidate(" world"), request: request(beforeCursor: "hello")))
    }

    // MARK: - App / policy gates

    func testCompletionsDisabled() {
        let store = AppCompatibilityStore(overrides: [
            TargetOverride(bundleIdentifier: Self.target.bundleIdentifier, completionsDisabled: true)
        ])
        let filter = DefaultCandidateFilter(compatibilityStore: store)
        XCTAssertEqual(filter.suppressionReason(for: candidate(" world"), request: request()), .completionsDisabled)
    }

    func testMidLineCompletionDisabledWhenTextFollowsCursor() {
        let store = AppCompatibilityStore(overrides: [
            TargetOverride(bundleIdentifier: Self.target.bundleIdentifier, midLineCompletionsDisabled: true)
        ])
        let filter = DefaultCandidateFilter(compatibilityStore: store)
        // Text after the cursor → mid-line → suppressed.
        XCTAssertEqual(
            filter.suppressionReason(for: candidate(" world"), request: request(afterCursor: "tail")),
            .midLineCompletionDisabled
        )
        // No text after the cursor → end-of-line → allowed.
        XCTAssertNil(filter.suppressionReason(for: candidate(" world"), request: request(afterCursor: "")))
    }

    func testTabShortcutsDisabled() {
        let store = AppCompatibilityStore(overrides: [
            TargetOverride(bundleIdentifier: Self.target.bundleIdentifier, tabShortcutsDisabled: true)
        ])
        let filter = DefaultCandidateFilter(compatibilityStore: store)
        XCTAssertEqual(filter.suppressionReason(for: candidate(" world"), request: request()), .tabShortcutsDisabled)
    }

    func testSecureFieldExcluded() {
        let filter = DefaultCandidateFilter(compatibilityStore: AppCompatibilityStore(overrides: []))
        XCTAssertEqual(
            filter.suppressionReason(
                for: candidate(" word"),
                request: request(placeholder: "Password", traits: TextFieldTraits(isSecureTextEntry: true))
            ),
            .secureFieldExcluded
        )
    }

    // MARK: - Content gates

    func testNoCandidateForEmptyText() {
        let filter = DefaultCandidateFilter()
        XCTAssertEqual(filter.suppressionReason(for: candidate(""), request: request()), .noCandidate)
    }

    func testInvalidUTF8OnReplacementScalar() {
        let filter = DefaultCandidateFilter()
        XCTAssertEqual(
            filter.suppressionReason(for: candidate("wor\u{FFFD}ld"), request: request()),
            .invalidUTF8
        )
    }

    func testRequiredPrefixNotSatisfied() {
        let filter = DefaultCandidateFilter()
        // Candidate diverges from the demanded prefix.
        XCTAssertEqual(
            filter.suppressionReason(
                for: candidate("xyz"),
                request: request(requiredPrefixBytes: Array("orrow".utf8))
            ),
            .requiredPrefixNotSatisfied
        )
    }

    func testRequiredPrefixSatisfiedExtendingAndPartial() {
        let filter = DefaultCandidateFilter()
        // Extends the prefix.
        XCTAssertNil(filter.suppressionReason(
            for: candidate("orrow night"),
            request: request(requiredPrefixBytes: Array("orrow".utf8))
        ))
        // Partial step toward the prefix.
        XCTAssertNil(filter.suppressionReason(
            for: candidate("orr"),
            request: request(requiredPrefixBytes: Array("orrow".utf8))
        ))
    }

    func testDisplayWidthExceeded() {
        let filter = DefaultCandidateFilter()
        XCTAssertEqual(
            filter.suppressionReason(
                for: candidate("hello there", displayWidth: 11),
                request: request(maxDisplayWidth: 5)
            ),
            .displayWidthExceeded
        )
    }

    func testMaxCompletionLengthExceeded() {
        let filter = DefaultCandidateFilter()
        XCTAssertEqual(
            filter.suppressionReason(
                for: candidate(" a b c", tokenIDs: [1, 2, 3, 4, 5]),
                request: request(maxCompletionTokens: 4)
            ),
            .maxCompletionLengthExceeded
        )
    }

    func testInsertionUnsafeForWhitespaceOnly() {
        let filter = DefaultCandidateFilter()
        XCTAssertEqual(filter.suppressionReason(for: candidate("   "), request: request()), .insertionUnsafe)
    }

    func testInsertionUnsafeForControlCharacters() {
        let filter = DefaultCandidateFilter()
        XCTAssertEqual(filter.suppressionReason(for: candidate("a\tb"), request: request()), .insertionUnsafe)
        XCTAssertEqual(filter.suppressionReason(for: candidate("a\nb"), request: request()), .insertionUnsafe)
    }

    func testInsertionUnsafeForPunctuationOnly() {
        let filter = DefaultCandidateFilter()
        XCTAssertEqual(filter.suppressionReason(for: candidate("..."), request: request()), .insertionUnsafe)
        XCTAssertEqual(filter.suppressionReason(for: candidate("…"), request: request()), .insertionUnsafe)
        // Has letters → fine.
        XCTAssertNil(filter.suppressionReason(for: candidate(" cell."), request: request()))
    }

    // MARK: - Typo net

    /// A recogniser that only accepts an explicit allow-list, mirroring the conservative
    /// `NSSpellChecker`-backed seam.
    private struct StubRecognizer: SynchronousWordRecognizing {
        let known: Set<String>
        func recognizes(_ word: String, language: String?) -> Bool { known.contains(word.lowercased()) }
    }

    func testCurrentWordLooksLikeTypo() {
        let filter = DefaultCandidateFilter(wordRecognizer: StubRecognizer(known: ["tomorrow"]))
        // User typed "tom"; candidate closes the word as "tomorow." (a misspelling) then continues.
        XCTAssertEqual(
            filter.suppressionReason(for: candidate("orow."), request: request(beforeCursor: "see you tom")),
            .currentWordLooksLikeTypo
        )
    }

    func testCorrectlySpelledCurrentWordIsAccepted() {
        let filter = DefaultCandidateFilter(wordRecognizer: StubRecognizer(known: ["tomorrow"]))
        XCTAssertNil(
            filter.suppressionReason(for: candidate("orrow."), request: request(beforeCursor: "see you tom"))
        )
    }

    func testOpenCurrentWordIsNeverJudged() {
        // No boundary in the candidate → the word is still open → never flagged even if unknown.
        let filter = DefaultCandidateFilter(wordRecognizer: StubRecognizer(known: []))
        XCTAssertNil(
            filter.suppressionReason(for: candidate("orrow"), request: request(beforeCursor: "see you tom"))
        )
    }

    func testTypoNetSkippedInCodeMode() {
        let filter = DefaultCandidateFilter(wordRecognizer: StubRecognizer(known: []))
        XCTAssertNil(
            filter.suppressionReason(
                for: candidate("efghi ", tokenIDs: [1]),
                request: request(beforeCursor: "abcd", mode: .code)
            )
        )
    }

    func testTypoNetInertWithoutRecognizer() {
        let filter = DefaultCandidateFilter()
        XCTAssertNil(
            filter.suppressionReason(for: candidate("orow.", tokenIDs: [1]), request: request(beforeCursor: "see you tom"))
        )
    }
}
