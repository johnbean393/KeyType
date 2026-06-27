import AutocompleteCore
@testable import ConstrainedGeneration
import ModelRuntime
import TokenProfiles
import XCTest

/// Decode-time repetition penalty in `TokenSampler.rank` (see `DecodingConfiguration.presencePenalty`).
/// The penalty demotes tokens already emitted on the same branch so a degenerate intra-completion loop
/// loses the beam to a non-repeating sibling. It is a *demotion* lever applied only to `value`, never
/// to the raw-logit argmax used for stop detection, and is byte-identical to the un-penalized path
/// when no penalty is configured.
final class RepetitionPenaltyTests: XCTestCase {

    /// Three plain word tokens, no flags — admissible everywhere, never excluded, never a stop.
    private func makeProfile(vocab: Int) -> InMemoryAutocompleteProfile {
        let records = (0..<vocab).map {
            TokenProfileRecord(tokenID: TokenID($0), bytes: Array("w\($0)".utf8))
        }
        return InMemoryAutocompleteProfile(vocabularySize: vocab, records: records)
    }

    private func logits(_ values: [Float]) -> [TokenLogit] {
        values.enumerated().map { TokenLogit(tokenID: TokenID($0.offset), logit: $0.element) }
    }

    private func rank(
        _ logitValues: [Float],
        config: DecodingConfiguration,
        recent: [TokenID]
    ) -> SamplerResult {
        TokenSampler.rank(
            logits: logits(logitValues),
            mode: .prose,
            profile: makeProfile(vocab: logitValues.count),
            configuration: config,
            recentTokens: recent,
            isAdmissible: { _ in true }
        )
    }

    /// With penalties at 0 the result is identical regardless of branch history — the inert default.
    func testZeroPenaltyIsByteIdenticalToUnpenalized() {
        let values: [Float] = [3.0, 2.5, 1.0]
        let config = DecodingConfiguration()
        let baseline = rank(values, config: config, recent: [])
        let withHistory = rank(values, config: config, recent: [0, 0, 0])
        XCTAssertEqual(baseline.tokens, withHistory.tokens)
        XCTAssertEqual(baseline.argmaxTokenID, withHistory.argmaxTokenID)
    }

    /// A repeated token's probability drops once the presence penalty is active, and a previously
    /// lower-ranked sibling overtakes it as the top candidate.
    func testPresencePenaltyDemotesRepeatedToken() {
        // Token 0 leads on raw logits, token 1 is close behind.
        let values: [Float] = [3.0, 2.8, 0.5]
        let config = DecodingConfiguration(presencePenalty: 4.0)

        let baseline = rank(values, config: config, recent: [])
        XCTAssertEqual(baseline.tokens.first?.tokenID, 0, "token 0 wins with no history")

        let penalized = rank(values, config: config, recent: [0])
        XCTAssertEqual(penalized.tokens.first?.tokenID, 1, "repeated token 0 is demoted below token 1")
        // Token 0 either keeps a lower probability or is pushed out of the nucleus entirely (absent ⇒ 0).
        let p0 = penalized.tokens.first(where: { $0.tokenID == 0 })?.probability ?? 0
        let base0 = baseline.tokens.first(where: { $0.tokenID == 0 })?.probability ?? 0
        XCTAssertLessThan(p0, base0, "token 0 probability must drop under the penalty")
    }

    /// The frequency penalty scales with occurrence count: two prior occurrences demote harder than one.
    func testFrequencyPenaltyScalesWithCount() {
        let values: [Float] = [3.0, 2.0, 1.0]
        let config = DecodingConfiguration(frequencyPenalty: 1.5)
        let once = rank(values, config: config, recent: [0]).tokens.first(where: { $0.tokenID == 0 })?.probability ?? 0
        let twice = rank(values, config: config, recent: [0, 0]).tokens.first(where: { $0.tokenID == 0 })?.probability ?? 0
        XCTAssertLessThan(twice, once, "more prior occurrences must penalize harder")
    }

    /// H7: the penalty must not move `argmaxTokenID` — it is tracked on raw logits for stop detection.
    func testArgmaxUnaffectedByPenalty() {
        let values: [Float] = [3.0, 2.8, 0.5]
        let config = DecodingConfiguration(presencePenalty: 10.0)
        let penalized = rank(values, config: config, recent: [0])
        XCTAssertEqual(penalized.argmaxTokenID, 0, "raw-logit argmax stays token 0 despite the penalty")
    }

    /// H6: when the penalty drives the only repeated candidate down, the pool must not collapse to
    /// empty — the floor still keeps the non-repeating sibling, avoiding a spurious `noCandidate`.
    func testPenaltyDoesNotEmptyThePool() {
        let values: [Float] = [5.0, 1.0]
        let config = DecodingConfiguration(minBranchProbability: 0.0, presencePenalty: 50.0)
        let penalized = rank(values, config: config, recent: [0])
        XCTAssertFalse(penalized.tokens.isEmpty, "a non-repeating sibling must survive")
        XCTAssertEqual(penalized.tokens.first?.tokenID, 1)
    }
}
