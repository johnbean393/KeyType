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

    private func midLineEnabledFilter() -> DefaultCandidateFilter {
        DefaultCandidateFilter(compatibilityStore: AppCompatibilityStore(overrides: [
            TargetOverride(bundleIdentifier: Self.target.bundleIdentifier, midLineCompletionsEnabled: true)
        ]))
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
        let filter = DefaultCandidateFilter()
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

    func testSuppressesLatinLeadingCompletionAfterCJKText() {
        let filter = DefaultCandidateFilter()
        XCTAssertEqual(
            filter.suppressionReason(
                for: candidate(", weishenme2, we"),
                request: request(beforeCursor: "为什么")
            ),
            .scriptMismatch
        )
        XCTAssertEqual(
            filter.suppressionReason(
                for: candidate(" app。"),
                request: request(beforeCursor: "我现在在测试这个")
            ),
            .scriptMismatch
        )
    }

    func testKeepsCJKCompletionAfterCJKText() {
        let filter = DefaultCandidateFilter()
        XCTAssertNil(
            filter.suppressionReason(
                for: candidate("不敢相信"),
                request: request(beforeCursor: "我真")
            )
        )
    }

    func testScriptMismatchSkippedAfterExplicitWordBoundary() {
        let filter = DefaultCandidateFilter()
        XCTAssertNil(
            filter.suppressionReason(
                for: candidate("app"),
                request: request(beforeCursor: "我想打开 ")
            )
        )
    }

    // MARK: - Suffix-duplication net

    func testSuppressesCompletionDuplicatingAfterCursor() {
        let filter = midLineEnabledFilter()
        // Mid-line caret: the model copies the text already after the cursor.
        XCTAssertEqual(
            filter.suppressionReason(
                for: candidate("performance to the RTX 5070, so it's"),
                request: request(
                    beforeCursor: "This GPU has a similar level of ",
                    afterCursor: "performance to the RTX 5070, so it's close to a mid-range GPU."
                )
            ),
            .duplicatesAfterCursor
        )
    }

    func testSuppressesMidWordSuffixCopyWithGarbagePrefix() {
        let filter = midLineEnabledFilter()
        XCTAssertEqual(
            filter.suppressionReason(
                for: candidate("**formance to the RTX 5070, so it's"),
                request: request(
                    beforeCursor: "This GPU has a similar level of p",
                    afterCursor: "erformance to the RTX 5070, so it's close to a mid-range GPU."
                )
            ),
            .duplicatesAfterCursor
        )
    }

    func testKeepsGenuineMidLineCompletion() {
        let filter = midLineEnabledFilter()
        XCTAssertNil(
            filter.suppressionReason(
                for: candidate("like"),
                request: request(beforeCursor: "I really ", afterCursor: "this idea is great")
            )
        )
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

    func testHealedMidWordTypoIsSuppressed() {
        // Mid-word healing (ADR-019): the user typed "coll", the heal re-emits " coll", and the
        // candidate closes the word into the non-word "collvm". The net must see *through* the heal.
        let filter = DefaultCandidateFilter(wordRecognizer: StubRecognizer(known: ["collaboration"]))
        XCTAssertEqual(
            filter.suppressionReason(
                for: candidate(" collvm based SoC"),
                request: request(beforeCursor: "This is a coll", requiredPrefixBytes: Array(" coll".utf8))
            ),
            .currentWordLooksLikeTypo
        )
    }

    func testHealedMidWordRealWordIsKept() {
        let filter = DefaultCandidateFilter(wordRecognizer: StubRecognizer(known: ["collaboration"]))
        XCTAssertNil(
            filter.suppressionReason(
                for: candidate(" collaboration between"),
                request: request(beforeCursor: "This is a coll", requiredPrefixBytes: Array(" coll".utf8))
            )
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

    // MARK: - Dead-end mid-word net (ADR-052)

    /// A recogniser whose `canCompleteWord` only accepts an explicit set of viable prefixes.
    private struct PrefixRecognizer: SynchronousWordRecognizing {
        let viablePrefixes: Set<String>
        func recognizes(_ word: String, language: String?) -> Bool { true }
        func canCompleteWord(prefix: String, language: String?) -> Bool {
            viablePrefixes.contains(prefix.lowercased())
        }
    }

    func testOpenWordOnDeadEndStemIsSuppressed() {
        // User typed "th"; the model leaves the word open as "thx" — no English word starts "thx".
        let filter = DefaultCandidateFilter(wordRecognizer: PrefixRecognizer(viablePrefixes: ["thr"]))
        XCTAssertEqual(
            filter.suppressionReason(for: candidate("x"), request: request(beforeCursor: "go th")),
            .currentWordHasNoValidCompletion
        )
    }

    func testOpenWordOnViablePrefixIsKept() {
        // "thr" can begin "through"/"three" — a budget-truncated open word must NOT be suppressed.
        let filter = DefaultCandidateFilter(wordRecognizer: PrefixRecognizer(viablePrefixes: ["thr"]))
        XCTAssertNil(
            filter.suppressionReason(for: candidate("r"), request: request(beforeCursor: "go th"))
        )
    }

    func testClosedWordIsLeftToTheTypoNetNotTheDeadEndNet() {
        // A closed word is the typo net's job; the dead-end net (canCompleteWord) must not fire on it.
        let filter = DefaultCandidateFilter(wordRecognizer: PrefixRecognizer(viablePrefixes: []))
        // "tom" + "orrow." closes the word; recognizes() returns true here, so it is accepted.
        XCTAssertNil(
            filter.suppressionReason(for: candidate("orrow."), request: request(beforeCursor: "see you tom"))
        )
    }

    func testDeadEndNetInertWithoutRecognizer() {
        let filter = DefaultCandidateFilter()
        XCTAssertNil(
            filter.suppressionReason(for: candidate("x"), request: request(beforeCursor: "see you th"))
        )
    }

    // MARK: - Mid-word charset net (ADR-052)

    func testSuppressesJunkSymbolClosingTheCurrentWord() {
        let filter = DefaultCandidateFilter()
        // User typed "gre"; the model closes the word with a stray "$".
        XCTAssertEqual(
            filter.suppressionReason(for: candidate("at$ stuff"), request: request(beforeCursor: "this is gre")),
            .insertionUnsafe
        )
    }

    func testSuppressesExcessivePunctuationRun() {
        let filter = DefaultCandidateFilter()
        XCTAssertEqual(
            filter.suppressionReason(for: candidate("at...."), request: request(beforeCursor: "this is gre")),
            .insertionUnsafe
        )
    }

    func testKeepsCleanWordCloserPunctuation() {
        let filter = DefaultCandidateFilter()
        // A normal sentence-ending period (or ellipsis) closing the word is fine.
        XCTAssertNil(filter.suppressionReason(for: candidate("at."), request: request(beforeCursor: "this is gre")))
        XCTAssertNil(filter.suppressionReason(for: candidate("at..."), request: request(beforeCursor: "this is gre")))
    }

    func testCharsetNetIgnoresSymbolStartingAFreshWord() {
        // beforeCursor ends on a complete word + space → no open word → "$5" is a legit fresh token.
        let filter = DefaultCandidateFilter()
        XCTAssertNil(filter.suppressionReason(for: candidate("$5 today"), request: request(beforeCursor: "it costs ")))
    }

    func testCharsetNetSkippedInCodeMode() {
        let filter = DefaultCandidateFilter()
        XCTAssertNil(
            filter.suppressionReason(for: candidate("at$ stuff"), request: request(beforeCursor: "let gre", mode: .code))
        )
    }

    func testHealedJunkCloserIsSuppressed() {
        // Healed request: the heal " gre" is re-emitted, then the model glues a "$".
        let filter = DefaultCandidateFilter()
        XCTAssertEqual(
            filter.suppressionReason(
                for: candidate(" great$ idea"),
                request: request(beforeCursor: "this is gre", requiredPrefixBytes: Array(" gre".utf8))
            ),
            .insertionUnsafe
        )
    }

    // MARK: - Mid-word boundary net

    func testHealedProperNounBoundaryIsSuppressed() {
        let filter = DefaultCandidateFilter()
        XCTAssertEqual(
            filter.suppressionReason(
                for: candidate(" Aga Khan"),
                request: request(beforeCursor: "Count Fleet ran against Aga", requiredPrefixBytes: Array(" Aga".utf8))
            ),
            .insertionUnsafe
        )
    }

    func testHealedLowercaseTokenSplitIsKept() {
        let filter = DefaultCandidateFilter()
        XCTAssertNil(
            filter.suppressionReason(
                for: candidate(" gre at"),
                request: request(beforeCursor: "this is gre", requiredPrefixBytes: Array(" gre".utf8))
            )
        )
    }

    func testHealedBoundaryNetSkippedInCodeMode() {
        let filter = DefaultCandidateFilter()
        XCTAssertNil(
            filter.suppressionReason(
                for: candidate(" Aga Khan"),
                request: request(
                    beforeCursor: "let value = Aga",
                    requiredPrefixBytes: Array(" Aga".utf8),
                    mode: .code
                )
            )
        )
    }
}
