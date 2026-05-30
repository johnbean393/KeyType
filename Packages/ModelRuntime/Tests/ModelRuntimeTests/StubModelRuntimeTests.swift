import AutocompleteCore
import ModelRuntime
import XCTest

/// Tests against `StubModelRuntime` and `UTF8FallbackTokenizer`. These always run and act as
/// the canary for the `LocalModelRuntime` protocol shape — if these break, every dependent
/// (`ConstrainedGeneration`, `Prompting`) is also affected.
final class StubModelRuntimeTests: XCTestCase {
    func testUTF8FallbackTokenizerRoundTripsASCII() throws {
        let tokenizer = UTF8FallbackTokenizer()
        for sample in ["", "a", "hello world", "Tab autocomplete? Yes!"] {
            let tokens = try tokenizer.tokenize(sample)
            let back = try tokenizer.detokenize(tokens)
            XCTAssertEqual(back, sample)
        }
    }

    func testUTF8FallbackRawBytesMatchesByte() throws {
        let tokenizer = UTF8FallbackTokenizer()
        for b: UInt8 in [0x41, 0x7A, 0x20, 0x2E] {
            let bytes = try tokenizer.rawBytes(for: TokenID(b))
            XCTAssertEqual(bytes, [b])
        }
    }

    func testStubRuntimeReplaysScriptedLogits() async throws {
        let scripted: [[TokenLogit]] = [
            [TokenLogit(tokenID: 65, logit: 1.0), TokenLogit(tokenID: 66, logit: 0.5)],
            [TokenLogit(tokenID: 67, logit: 2.0)]
        ]
        let runtime = StubModelRuntime(scriptedLogits: scripted)
        try await runtime.prepare(promptTokens: [10, 11, 12])
        let l0 = try await runtime.logitsForNextToken()
        XCTAssertEqual(l0, scripted[0])
        try await runtime.decodeNext(tokenID: 65)
        let l1 = try await runtime.logitsForNextToken()
        XCTAssertEqual(l1, scripted[1])
        try await runtime.decodeNext(tokenID: 67)
        let l2 = try await runtime.logitsForNextToken()
        XCTAssertEqual(l2, [])
    }

    func testTreeScriptedRuntimeReturnsPathDependentLogits() async throws {
        let rootLogits = [TokenLogit(tokenID: 65, logit: 1.0)]
        let childLogits = [TokenLogit(tokenID: 66, logit: 2.0)]
        let runtime = TreeScriptedModelRuntime(logitsByPath: [
            [10, 11]: rootLogits,
            [10, 11, 65]: childLogits
        ])

        // Re-preparing different paths yields different logits (unlike the step-based stub).
        try await runtime.prepare(promptTokens: [10, 11])
        let atRoot = try await runtime.logitsForNextToken()
        XCTAssertEqual(atRoot, rootLogits)

        try await runtime.prepare(promptTokens: [10, 11, 65])
        let atChild = try await runtime.logitsForNextToken()
        XCTAssertEqual(atChild, childLogits)

        // Unknown path -> empty (no continuation).
        try await runtime.prepare(promptTokens: [10, 11, 99])
        let unknown = try await runtime.logitsForNextToken()
        XCTAssertEqual(unknown, [])
    }

    /// The default `anchoredLogits` extension (used by every stub runtime) must be exactly
    /// `prepare(anchor + suffix)` + `logitsForNextToken()` — that's what keeps the deterministic
    /// engine/FIM tests behaving identically after the engine switched to the anchored API.
    func testAnchoredLogitsDefaultEqualsPreparePlusLogits() async throws {
        let anchor: [TokenID] = [10, 11]
        let rootLogits = [TokenLogit(tokenID: 65, logit: 1.0)]
        let childLogits = [TokenLogit(tokenID: 66, logit: 2.0)]
        let runtime = TreeScriptedModelRuntime(logitsByPath: [
            anchor: rootLogits,
            anchor + [65]: childLogits
        ])

        // Empty suffix == logits right after the anchor.
        let viaAnchoredRoot = try await runtime.anchoredLogits(anchor: anchor, suffix: [])
        try await runtime.prepare(promptTokens: anchor)
        let viaPrepareRoot = try await runtime.logitsForNextToken()
        XCTAssertEqual(viaAnchoredRoot, viaPrepareRoot)
        XCTAssertEqual(viaAnchoredRoot, rootLogits)

        // Non-empty suffix == logits after anchor + suffix.
        let viaAnchoredChild = try await runtime.anchoredLogits(anchor: anchor, suffix: [65])
        try await runtime.prepare(promptTokens: anchor + [65])
        let viaPrepareChild = try await runtime.logitsForNextToken()
        XCTAssertEqual(viaAnchoredChild, viaPrepareChild)
        XCTAssertEqual(viaAnchoredChild, childLogits)
    }
}
