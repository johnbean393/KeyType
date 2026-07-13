import AutocompleteCore
@testable import ConstrainedGeneration
import ModelRuntime
import XCTest

final class CorrectionValidationScorerTests: XCTestCase {
    private let range = TextRangeDescriptor(container: .beforeCursor, startOffset: 7, endOffset: 13)

    func testPriorPredictionBoostPassesWithoutModelMargin() async throws {
        let runtime = Runtime(logitsByPath: [:])
        let scorer = CorrectionValidationScorer(runtime: runtime)
        let candidate = makeCandidate("middle")

        let result = try await scorer.validate(
            candidates: [candidate],
            prefixBeforeWord: "in the ",
            priorPredictionReplacement: "middle"
        )

        XCTAssertEqual(result.first?.source, .priorPrediction)
        XCTAssertEqual(result.first?.validation.boostedByPriorPrediction, true)
        XCTAssertGreaterThanOrEqual(result.first?.confidence ?? 0, 0.97)
        XCTAssertEqual(runtime.anchoredLogitsCallCount, 0)
    }

    func testModelScoreRequiresRunnerUpMargin() async throws {
        let scorer = CorrectionValidationScorer(runtime: Runtime(logitsByPath: [
            [1]: [makeLogit(10, 5), makeLogit(11, 1), makeLogit(12, 0)]
        ]))

        let result = try await scorer.validate(
            candidates: [makeCandidate("middle"), makeCandidate("muddle")],
            prefixBeforeWord: "in the "
        )

        XCTAssertEqual(result.map { $0.replacement }, ["middle"])
        XCTAssertEqual(result.first?.source, .spellcheckValidatedByModel)
        XCTAssertEqual(result.first?.validation.method, .modelScore)
    }

    func testCompressedNearTieMarginSuppressesEvenClearCut() async throws {
        // logits 3.0 vs 2.76 → joint margin ~0.24 < clearCutMargin (0.5): a genuine near-tie
        // between look-alike guesses stays suppressed.
        let scorer = CorrectionValidationScorer(runtime: Runtime(logitsByPath: [
            [1]: [makeLogit(10, 3.0), makeLogit(11, 2.76), makeLogit(12, 0)]
        ]))

        let result = try await scorer.validate(
            candidates: [makeCandidate("middle"), makeCandidate("muddle")],
            prefixBeforeWord: "in the "
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testModelPreferringOriginalVetoesEvenSingleCandidate() async throws {
        // The model rates the user's own string slightly higher (4.4 vs 4.0) → advantage < 0 →
        // suppressed. This is the deliberate-spelling / proper-noun protection: any model
        // preference for the original wins (ADR-120 strengthened this over the old
        // "much better" slack).
        let scorer = CorrectionValidationScorer(runtime: Runtime(logitsByPath: [
            [1]: [makeLogit(10, 4.0), makeLogit(12, 4.4), makeLogit(30, 0)]
        ]))

        let result = try await scorer.validate(
            candidates: [makeCandidate("middle")],
            prefixBeforeWord: "in the "
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testReplacementPreferredOverOriginalShows() async throws {
        let scorer = CorrectionValidationScorer(runtime: Runtime(logitsByPath: [
            [1]: [makeLogit(10, 4.4), makeLogit(12, 4.0), makeLogit(30, 0)]
        ]))

        let result = try await scorer.validate(
            candidates: [makeCandidate("middle")],
            prefixBeforeWord: "in the "
        )

        XCTAssertEqual(result.first?.replacement, "middle")
    }

    func testMisspelledOriginalCanStillVetoWhenMuchMorePlausible() async throws {
        let scorer = CorrectionValidationScorer(runtime: Runtime(logitsByPath: [
            [1]: [makeLogit(10, 3.0), makeLogit(12, 5.0), makeLogit(30, 0)]
        ]))

        let result = try await scorer.validate(
            candidates: [makeCandidate("middle")],
            prefixBeforeWord: "in the "
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testWhitespaceOnlySuffixWindowSkipsTheJoinProbe() async throws {
        // The live regression's final gate (ADR-120): right after typing "word ", the suffix
        // window is a bare space — probing P(" " | prefix + replacement) is tokenization noise
        // and must not veto. The stub tokenizer deliberately has no entry for " ".
        let scorer = CorrectionValidationScorer(runtime: Runtime(logitsByPath: [
            [1]: [makeLogit(10, 5), makeLogit(12, 0)]
        ]))

        let result = try await scorer.validate(
            candidates: [makeCandidate("middle")],
            prefixBeforeWord: "in the ",
            suffixWindow: " "
        )

        XCTAssertEqual(result.first?.replacement, "middle")
        XCTAssertNil(result.first?.validation.suffixJoinScore)
    }

    func testSuppressesWhenSuffixJoinIsWeak() async throws {
        let scorer = CorrectionValidationScorer(runtime: Runtime(logitsByPath: [
            [2]: [makeLogit(10, 5), makeLogit(12, 0)],
            [2, 10]: [makeLogit(21, -10), makeLogit(30, 2)]
        ]))

        let result = try await scorer.validate(
            candidates: [makeCandidate("middle")],
            prefixBeforeWord: "Open the ",
            suffixWindow: " config file"
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testAllowsPositiveMidTextSuffixJoin() async throws {
        let scorer = CorrectionValidationScorer(runtime: Runtime(logitsByPath: [
            [1]: [makeLogit(10, 5), makeLogit(12, 0)],
            [1, 10]: [makeLogit(20, 5), makeLogit(30, 0)]
        ]))

        let result = try await scorer.validate(
            candidates: [makeCandidate("middle")],
            prefixBeforeWord: "in the ",
            suffixWindow: " of"
        )

        XCTAssertEqual(result.first?.replacement, "middle")
        XCTAssertGreaterThan(result.first?.validation.suffixJoinScore ?? -.infinity, -1)
    }

    func testGrammarSourcesSurviveModelValidation() async throws {
        let scorer = CorrectionValidationScorer(runtime: Runtime(logitsByPath: [
            [3]: [makeLogit(40, 5), makeLogit(41, 0)]
        ]))

        let grammarOnly = CorrectionCandidate(
            original: "a apple",
            replacement: "an apple",
            originalRange: TextRangeDescriptor(container: .beforeCursor, startOffset: 6, endOffset: 13),
            confidence: 0.82,
            source: .systemGrammarOnly,
            validation: .spellcheckOnly
        )
        let composed = CorrectionCandidate(
            original: "a appl",
            replacement: "an apple",
            originalRange: TextRangeDescriptor(container: .beforeCursor, startOffset: 6, endOffset: 12),
            confidence: 0.9,
            source: .spellcheckThenSystemGrammar,
            validation: .spellcheckOnly
        )

        let grammarResult = try await scorer.validate(
            candidates: [grammarOnly],
            prefixBeforeWord: "I saw "
        )
        let composedResult = try await scorer.validate(
            candidates: [composed],
            prefixBeforeWord: "I saw "
        )

        XCTAssertEqual(grammarResult.first?.replacement, "an apple")
        XCTAssertEqual(grammarResult.first?.source, .systemGrammarValidatedByModel)
        XCTAssertEqual(composedResult.first?.replacement, "an apple")
        XCTAssertEqual(composedResult.first?.source, .spellcheckThenSystemGrammar)
    }

    func testSystemGrammarCanPassAsLongAsModelDoesNotPreferOriginalStrongly() async throws {
        let scorer = CorrectionValidationScorer(runtime: Runtime(logitsByPath: [
            [4]: [makeLogit(50, -10.1), makeLogit(51, -10.0), makeLogit(30, 5.0)]
        ]))
        let candidate = CorrectionCandidate(
            original: "is",
            replacement: "are",
            originalRange: TextRangeDescriptor(container: .beforeCursor, startOffset: 16, endOffset: 18),
            confidence: 0.8,
            source: .systemGrammarOnly,
            validation: .spellcheckOnly
        )

        let result = try await scorer.validate(
            candidates: [candidate],
            prefixBeforeWord: "These popsicles "
        )

        XCTAssertEqual(result.first?.replacement, "are")
        XCTAssertEqual(result.first?.source, .systemGrammarValidatedByModel)
    }

    // MARK: - Clear-cut margin relaxation (ADR-119)

    /// The live regression this retune exists for: predictions.log recorded
    /// `CORRECT word="definately" -> SUPPRESS(lowModelMargin)`. On the real model the joint-nat
    /// margin over "defiantly" is ~6, but look-alike guesses can compress it — a clear-cut
    /// (dictionary-flagged, distance-1, model-top) guess must pass inside the compressed zone.
    func testDefinatelyClearCutPassesInsideCompressedMarginZone() async throws {
        // logits 3.0 vs 2.3 → joint margin ~0.70: above clearCutMargin (0.5), below minimumMargin (2.0).
        let scorer = CorrectionValidationScorer(runtime: Runtime(logitsByPath: [
            [5]: [makeLogit(60, 3.0), makeLogit(61, 2.3), makeLogit(62, 0)]
        ]))

        let result = try await scorer.validate(
            candidates: [
                makeTypoCandidate(replacement: "definitely", id: "definitely"),
                makeTypoCandidate(replacement: "defiantly", id: "defiantly")
            ],
            prefixBeforeWord: "I "
        )

        XCTAssertEqual(result.map(\.replacement), ["definitely"])
        XCTAssertEqual(result.first?.source, .spellcheckValidatedByModel)
        let margin = try XCTUnwrap(result.first?.validation.margin)
        XCTAssertGreaterThan(margin, 0.5)
        XCTAssertLessThan(margin, 2.0, "test must exercise the clear-cut-only zone")
    }

    func testClearCutNearTieStaysSuppressed() async throws {
        // logits 3.0 vs 2.9 → joint margin ~0.1 < clearCutMargin: genuine ambiguity keeps the veto.
        let scorer = CorrectionValidationScorer(runtime: Runtime(logitsByPath: [
            [5]: [makeLogit(60, 3.0), makeLogit(61, 2.9), makeLogit(62, 0)]
        ]))

        let result = try await scorer.validate(
            candidates: [
                makeTypoCandidate(replacement: "definitely", id: "definitely"),
                makeTypoCandidate(replacement: "defiantly", id: "defiantly")
            ],
            prefixBeforeWord: "I "
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testDistantReplacementDoesNotGetClearCutRelaxation() async throws {
        // "definately" → "define" is beyond the edit-distance cap, so the full 2.0-nat bar
        // applies and a 0.70 margin still suppresses.
        let scorer = CorrectionValidationScorer(runtime: Runtime(logitsByPath: [
            [5]: [makeLogit(63, 3.0), makeLogit(61, 2.3), makeLogit(62, 0)]
        ]))

        let result = try await scorer.validate(
            candidates: [
                makeTypoCandidate(replacement: "define", id: "define"),
                makeTypoCandidate(replacement: "defiantly", id: "defiantly")
            ],
            prefixBeforeWord: "I "
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testSpellcheckDecisionBoundaries() {
        let thresholds = CorrectionValidationThresholds()
        func passes(advantage: Double = 3.0, margin: Double, suffixPass: Bool = true, clearCut: Bool) -> Bool {
            CorrectionValidationScorer.spellcheckValidationPasses(
                advantage: advantage,
                margin: margin,
                suffixPass: suffixPass,
                isClearCut: clearCut,
                thresholds: thresholds
            )
        }

        XCTAssertTrue(passes(margin: 0.7, clearCut: true), "the compressed-margin zone opens for clear-cut")
        XCTAssertFalse(passes(margin: 0.7, clearCut: false), "non-clear-cut keeps the 2.0-nat bar")
        XCTAssertTrue(passes(margin: 2.2, clearCut: false), "well-separated candidates pass without relaxation")
        XCTAssertFalse(passes(margin: 0.1, clearCut: true), "near-ties stay suppressed")
        XCTAssertFalse(passes(advantage: -0.4, margin: 0.7, clearCut: true),
                       "any model preference for the original vetoes — never relaxed")
        XCTAssertFalse(passes(margin: 0.7, suffixPass: false, clearCut: true), "suffix join still gates")
        XCTAssertFalse(passes(margin: -0.3, clearCut: true), "a non-top candidate never passes")
    }

    func testBoundedEditDistance() {
        XCTAssertEqual(CorrectionValidationScorer.boundedEditDistance("definately", "definitely", cap: 2), 1)
        XCTAssertEqual(CorrectionValidationScorer.boundedEditDistance("recieve", "receive", cap: 2), 2)
        XCTAssertEqual(CorrectionValidationScorer.boundedEditDistance("colour", "color", cap: 2), 1)
        XCTAssertNil(CorrectionValidationScorer.boundedEditDistance("definately", "define", cap: 2))
        XCTAssertNil(CorrectionValidationScorer.boundedEditDistance("cat", "elephant", cap: 2))
        XCTAssertEqual(CorrectionValidationScorer.boundedEditDistance("", "ab", cap: 2), 2)
        XCTAssertNil(CorrectionValidationScorer.boundedEditDistance("", "abc", cap: 2))
    }

    private func makeTypoCandidate(replacement: String, id: String) -> CorrectionCandidate {
        CorrectionCandidate(
            original: "definately",
            replacement: replacement,
            originalRange: range,
            confidence: 0.83,
            source: .spellcheckOnly,
            validation: .spellcheckOnly
        )
    }

    private func makeCandidate(_ replacement: String) -> CorrectionCandidate {
        CorrectionCandidate(
            original: "mdidle",
            replacement: replacement,
            originalRange: range,
            confidence: 0.7,
            source: .spellcheckOnly,
            validation: .spellcheckOnly
        )
    }

}

private func makeLogit(_ id: TokenID, _ value: Float) -> TokenLogit {
    TokenLogit(tokenID: id, logit: value)
}

private struct Tokenizer: ModelTokenizing {
    // Anchors arrive whitespace-trimmed and words space-prefixed (ADR-120): the scorer moves the
    // anchor's trailing separator onto the scored word so tokenization matches real model input.
    private let ids: [String: TokenID] = [
        "in the": 1,
        "Open the": 2,
        "I saw": 3,
        "These popsicles": 4,
        " middle": 10,
        " muddle": 11,
        " mdidle": 12,
        " of": 20,
        " config file": 21,
        " an apple": 40,
        " a apple": 41,
        " is": 50,
        " are": 51,
        "I": 5,
        " definitely": 60,
        " defiantly": 61,
        " definately": 62,
        " define": 63
    ]

    func tokenize(_ text: String) throws -> [TokenID] {
        guard let id = ids[text] else { return [] }
        return [id]
    }

    func detokenize(_ tokenIDs: [TokenID]) throws -> String {
        ""
    }

    func rawBytes(for tokenID: TokenID) throws -> [UInt8] {
        []
    }
}

private final class Runtime: LocalModelRuntime {
    let metadata = ModelMetadata(identifier: "correction-test", family: "test", vocabularySize: 64, contextLength: 128)
    let tokenizer: ModelTokenizing = Tokenizer()
    private let logitsByPath: [[TokenID]: [TokenLogit]]
    private(set) var anchoredLogitsCallCount = 0

    init(logitsByPath: [[TokenID]: [TokenLogit]]) {
        self.logitsByPath = logitsByPath
    }

    func prepare(promptTokens: [TokenID]) async throws {}
    func logitsForNextToken() async throws -> [TokenLogit] { [] }
    func decodeNext(tokenID: TokenID) async throws {}
    func resetKVCache() async {}

    func anchoredLogits(anchor: [TokenID], suffix: [TokenID]) async throws -> [TokenLogit] {
        anchoredLogitsCallCount += 1
        return logitsByPath[anchor + suffix] ?? []
    }
}
