import AutocompleteCore
import ConstrainedGeneration
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

    func testMisspelledOriginalDoesNotVetoClearSingleCandidate() async throws {
        let scorer = CorrectionValidationScorer(runtime: Runtime(logitsByPath: [
            [1]: [makeLogit(10, 4.0), makeLogit(12, 4.4), makeLogit(30, 0)]
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
    private let ids: [String: TokenID] = [
        "in the ": 1,
        "Open the ": 2,
        "I saw ": 3,
        "These popsicles ": 4,
        "middle": 10,
        "muddle": 11,
        "mdidle": 12,
        " of": 20,
        " config file": 21,
        "an apple": 40,
        "a apple": 41,
        "is": 50,
        "are": 51
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
