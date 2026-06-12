import AutocompleteCore
import XCTest
@testable import TokenProfiles

/// Drives `TokenClassifier.classify(_:)` directly: every case asserts the expected
/// `TokenProfileFlags` set on a hand-picked probe so misclassification trips a specific
/// failure name.
final class ClassifierFlagTests: XCTestCase {

    private func classify(_ bytes: [UInt8],
                          attr: TokenAttr = .normal,
                          role: TokenRole? = nil,
                          isControl: Bool = false,
                          isEOG: Bool = false) -> TokenProfileClassification {
        let probe = TokenizerProbe(
            tokenID: 0,
            bytes: bytes,
            attr: attr,
            role: role,
            isControl: isControl,
            isEOG: isEOG
        )
        return TokenClassifier.classify(probe)
    }

    private func u8(_ s: String) -> [UInt8] { Array(s.utf8) }

    // MARK: - Whitespace / Newline

    func testWhitespaceOnlyTokenGetsWhitespaceFlag() {
        let cls = classify([0x20, 0x20, 0x20])
        XCTAssertTrue(cls.flags.contains(.whitespace))
        XCTAssertFalse(cls.flags.contains(.newline))
    }

    func testRawNewlineFlagsBothNewlineAndWhitespace() {
        let cls = classify([0x0A])
        XCTAssertTrue(cls.flags.contains(.newline))
        XCTAssertTrue(cls.flags.contains(.whitespace))
    }

    func testCaretCharNewlineMarker() {
        let cls = classify(u8("\u{010A}")) // Ċ alone
        XCTAssertTrue(cls.flags.contains(.newline))
        XCTAssertTrue(cls.flags.contains(.whitespace))
    }

    func testGSpaceMarkerStandalone() {
        let cls = classify(u8("\u{0120}")) // Ġ alone
        XCTAssertTrue(cls.flags.contains(.whitespace))
        XCTAssertFalse(cls.flags.contains(.newline))
    }

    // MARK: - Word start / continuation

    func testQwenStyleSpacePrefixWordStart() {
        let cls = classify(u8("\u{0120}word"))
        XCTAssertTrue(cls.flags.contains(.wordStart))
        XCTAssertTrue(cls.flags.contains(.whitespace))
        XCTAssertFalse(cls.flags.contains(.wordContinuation))
    }

    func testSentencePieceUnderscoreWordStart() {
        let cls = classify(u8("\u{2581}word"))
        XCTAssertTrue(cls.flags.contains(.wordStart))
        XCTAssertTrue(cls.flags.contains(.whitespace))
    }

    func testBareAlphabeticTokenIsContinuation() {
        let cls = classify(u8("ing"))
        XCTAssertTrue(cls.flags.contains(.wordContinuation))
        XCTAssertFalse(cls.flags.contains(.wordStart))
    }

    func testDigitsAreWordContinuationByDefault() {
        let cls = classify(u8("123"))
        XCTAssertTrue(cls.flags.contains(.wordContinuation))
    }

    func testSpacePrefixedDigitsAreWordStart() {
        let cls = classify(u8("\u{0120}123"))
        XCTAssertTrue(cls.flags.contains(.wordStart))
    }

    // MARK: - Punctuation / Sentence end

    func testCommaIsPunctuation() {
        let cls = classify(u8(","))
        XCTAssertTrue(cls.flags.contains(.punctuation))
        XCTAssertFalse(cls.flags.contains(.sentenceEnd))
    }

    func testColonIsPunctuationNotSentenceEnd() {
        let cls = classify(u8(":"))
        XCTAssertTrue(cls.flags.contains(.punctuation))
        XCTAssertFalse(cls.flags.contains(.sentenceEnd))
    }

    func testPeriodIsSentenceEnd() {
        let cls = classify(u8("."))
        XCTAssertTrue(cls.flags.contains(.punctuation))
        XCTAssertTrue(cls.flags.contains(.sentenceEnd))
    }

    func testQuestionMarkAndExclamationAreSentenceEnd() {
        XCTAssertTrue(classify(u8("?")).flags.contains(.sentenceEnd))
        XCTAssertTrue(classify(u8("!")).flags.contains(.sentenceEnd))
        XCTAssertTrue(classify(u8("?!")).flags.contains(.sentenceEnd))
    }

    func testNonLatinTerminatorsAreSentenceEnd() {
        // Sentence-end stop must fire beyond Latin scripts.
        for terminator in ["。", "！", "？", "।", "॥", "۔", "؟", "։", "።"] {
            XCTAssertTrue(
                classify(u8(terminator)).flags.contains(.sentenceEnd),
                "expected sentenceEnd for '\(terminator)'"
            )
        }
    }

    func testNonTerminalCJKPunctuationIsNotSentenceEnd() {
        // The ideographic comma 、 separates clauses but does not end a sentence.
        XCTAssertFalse(classify(u8("、")).flags.contains(.sentenceEnd))
    }

    // MARK: - Chat markers

    func testIMStartChatMarker() {
        let cls = classify(u8("<|im_start|>"), attr: .userDefined, isControl: true)
        XCTAssertTrue(cls.flags.contains(.chatMarker))
        XCTAssertTrue(cls.flags.contains(.excluded))
        XCTAssertTrue(cls.flags.contains(.special))
    }

    func testStartOfTurnChatMarker() {
        let cls = classify(u8("<start_of_turn>"), attr: .userDefined, isControl: true)
        XCTAssertTrue(cls.flags.contains(.chatMarker))
        XCTAssertTrue(cls.flags.contains(.excluded))
    }

    func testEndOfTextChatMarker() {
        let cls = classify(u8("<|endoftext|>"), attr: .userDefined, isControl: true, isEOG: true)
        XCTAssertTrue(cls.flags.contains(.chatMarker))
        XCTAssertTrue(cls.flags.contains(.excluded))
        XCTAssertTrue(cls.flags.contains(.stop), "EOG chat markers also count as stop")
    }

    func testInstructionMarkdownHeader() {
        let cls = classify(u8("### Response:"))
        XCTAssertTrue(cls.flags.contains(.chatMarker))
        XCTAssertTrue(cls.flags.contains(.excluded))
    }

    // MARK: - Emoji

    func testSmileyIsEmoji() {
        let cls = classify(u8("🙂"))
        XCTAssertTrue(cls.flags.contains(.emoji))
    }

    func testZWJFamilyIsEmoji() {
        let cls = classify(u8("👨‍👩‍👧"))
        XCTAssertTrue(cls.flags.contains(.emoji))
    }

    // MARK: - Invalid UTF-8

    func testStandaloneContinuationByteIsInvalidUTF8AndExcluded() {
        let cls = classify([0x9A], attr: .byte)
        XCTAssertTrue(cls.flags.contains(.invalidUTF8))
        XCTAssertTrue(cls.flags.contains(.excluded))
    }

    func testStandalonePrefixByteIsInvalidUTF8() {
        let cls = classify([0xC3], attr: .byte)
        XCTAssertTrue(cls.flags.contains(.invalidUTF8))
        XCTAssertTrue(cls.flags.contains(.excluded))
    }

    // MARK: - Specials / EOG

    func testBOSExcluded() {
        let cls = classify(u8("<bos>"), attr: .control, role: .bos, isControl: true)
        XCTAssertTrue(cls.flags.contains(.special))
        XCTAssertTrue(cls.flags.contains(.excluded))
        XCTAssertFalse(cls.flags.contains(.stop))
    }

    func testEOSStopAndSpecial() {
        let cls = classify(u8("<eos>"), attr: .control, role: .eos, isControl: true, isEOG: true)
        XCTAssertTrue(cls.flags.contains(.special))
        XCTAssertTrue(cls.flags.contains(.stop))
        XCTAssertFalse(cls.flags.contains(.excluded), "stop tokens are runtime-only, not excluded outright")
    }

    func testEOTStop() {
        let cls = classify(u8("<eot>"), attr: .control, role: .eot, isControl: true, isEOG: true)
        XCTAssertTrue(cls.flags.contains(.stop))
    }

    func testUNKExcluded() {
        let cls = classify(u8("<unk>"), attr: [.control, .unknown], role: .unk, isControl: true)
        XCTAssertTrue(cls.flags.contains(.excluded))
    }

    // MARK: - Reserved placeholders flagged by byte content (GGUF attribute missing)

    func testGemmaUnusedPlaceholderExcludedByByteContent() {
        // The real failure: Gemma's <unusedN> arrive as NORMAL (no .unused attr) and leaked as
        // literal text. They must be classified special + excluded purely from their rendered bytes.
        let cls = classify(u8("<unused56>"), attr: .normal)
        XCTAssertTrue(cls.flags.contains(.special), "reserved placeholder must be special")
        XCTAssertTrue(cls.flags.contains(.excluded), "reserved placeholder must be excluded from sampling")
    }

    func testOtherReservedPlaceholderFormsExcluded() {
        for s in ["<unused0>", "<reserved_12>", "<extra_id_3>", "<pad>", "<mask>"] {
            XCTAssertTrue(classify(u8(s), attr: .normal).flags.contains(.excluded), "\(s) should be excluded")
        }
    }

    func testGenuineAngleBracketTextIsNotExcluded() {
        // Don't over-reach: ordinary markup/text the user might type stays sampleable.
        for s in ["<h2>", "</code>", "<div>", "<3"] {
            XCTAssertFalse(classify(u8(s), attr: .normal).flags.contains(.excluded), "\(s) should NOT be excluded")
        }
    }

    // MARK: - Markup-tag tokens (Gemma's single-token HTML-tag block, ids 168–237)

    func testWholeTagTokensGetMarkupTagFlag() {
        // The `</code>`-shown-in-prose failure: these arrive as NORMAL single tokens. They are
        // flagged (for the prose bias penalty) but stay sampleable for code/terminal modes.
        for s in ["<b>", "</code>", "<table>", "</blockquote>", "<br/>"] {
            let cls = classify(u8(s), attr: .normal)
            XCTAssertTrue(cls.flags.contains(.markupTag), "\(s) should be flagged markupTag")
            XCTAssertFalse(cls.flags.contains(.excluded), "\(s) must NOT be excluded")
        }
    }

    func testSentencePieceSpacePrefixedTagGetsMarkupTagFlag() {
        XCTAssertTrue(classify(u8("\u{2581}<b>"), attr: .normal).flags.contains(.markupTag))
    }

    func testNonTagAngleBracketTextIsNotMarkupTag() {
        for s in ["<3", "a<b", "code>", #"<a href="x">"#, "hello", "<", ">"] {
            XCTAssertFalse(classify(u8(s), attr: .normal).flags.contains(.markupTag), "\(s) should NOT be markupTag")
        }
    }

    func testReservedPlaceholderIsNotMarkupTag() {
        // `<unused56>` matches the tag shape but is special/excluded — keep the flags disjoint so
        // bias accounting stays single-purpose.
        let cls = classify(u8("<unused56>"), attr: .normal)
        XCTAssertTrue(cls.flags.contains(.excluded))
        XCTAssertFalse(cls.flags.contains(.markupTag))
    }

    // MARK: - Display width

    func testDisplayWidthOfASCII() {
        XCTAssertEqual(classify(u8("hello")).displayWidth, 5)
    }

    func testDisplayWidthOfMultibyteIsGraphemes() {
        XCTAssertEqual(classify(u8("日本語")).displayWidth, 3)
        XCTAssertEqual(classify(u8("é")).displayWidth, 1)
    }

    func testDisplayWidthOfInvalidUTF8FallsBackToBytes() {
        XCTAssertEqual(classify([0xC3], attr: .byte).displayWidth, 1)
    }
}
