import XCTest
@testable import TokenProfiles

/// Mode-aware bias for `.markupTag` tokens: penalised in prose (where `</code>` leaked into
/// suggestions), fully re-enabled in code/terminal where markup is working material. Mirrors the
/// emoji penalty/cancel pattern.
final class BiasPolicyMarkupTagTests: XCTestCase {

    private let tagBytes = Array("</code>".utf8)

    func testStaticBiasCarriesMarkupTagPenalty() {
        let bias = BiasPolicy.staticBias(flags: [.markupTag], displayWidth: 7, bytes: tagBytes)
        XCTAssertEqual(bias, BiasPolicy.markupTagStaticPenalty)
    }

    func testCodeModeDeltaCancelsThePenalty() {
        let bias = BiasPolicy.staticBias(flags: [.markupTag], displayWidth: 7, bytes: tagBytes)
        let delta = BiasPolicy.delta(flags: [.markupTag], mode: .code, bytes: tagBytes)
        XCTAssertEqual(bias + delta, 0, "markup tags must be fully re-enabled in code mode")
    }

    func testTerminalModeDeltaCancelsThePenalty() {
        let bias = BiasPolicy.staticBias(flags: [.markupTag], displayWidth: 7, bytes: tagBytes)
        let delta = BiasPolicy.delta(flags: [.markupTag], mode: .terminal, bytes: tagBytes)
        XCTAssertEqual(bias + delta, 0, "markup tags must be fully re-enabled in terminal mode")
    }

    func testProseModeKeepsThePenalty() {
        XCTAssertEqual(BiasPolicy.delta(flags: [.markupTag], mode: .prose, bytes: tagBytes), 0)
    }

    func testCorrectionModeKeepsThePenalty() {
        XCTAssertEqual(BiasPolicy.delta(flags: [.markupTag], mode: .correction, bytes: tagBytes), 0)
    }

    func testPenaltyOutweighsObservedLeakMargin() {
        // The leaked `</code>` was shown at logprob −0.35 with legitimate runners-up at −1.7…−3.8;
        // the penalty must exceed that gap or the leak persists in flat distributions.
        XCTAssertLessThanOrEqual(BiasPolicy.markupTagStaticPenalty, -4.0)
    }

    func testExcludedTokenStillInfinitelyNegativeRegardlessOfMarkupFlag() {
        let bias = BiasPolicy.staticBias(flags: [.excluded, .special], displayWidth: 10, bytes: Array("<unused56>".utf8))
        XCTAssertEqual(bias, -Float.infinity)
    }
}
