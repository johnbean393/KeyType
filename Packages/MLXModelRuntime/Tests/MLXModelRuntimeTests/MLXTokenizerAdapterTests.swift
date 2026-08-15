import AutocompleteCore
import MLXLMCommon
import XCTest
@testable import MLXModelRuntime

final class MLXTokenizerAdapterTests: XCTestCase {
    func testRawBytesPreserveByteFallbackTokens() throws {
        let tokenizer = FakeTokenizer(tokens: [
            0: "A",
            1: "<0xC3>",
            2: "<0xA9>",
            3: "<|im_end|>",
            4: "<0xGG>",
            5: "<0x123>",
        ])
        let adapter = MLXTokenizerAdapter(tokenizer: tokenizer, vocabularySize: 6)

        XCTAssertEqual(try adapter.rawBytes(for: 1), [0xC3])
        XCTAssertEqual(try adapter.rawBytes(for: 2), [0xA9])
        let reconstructed = [1, 2]
            .flatMap { try! adapter.rawBytes(for: TokenID($0)) }
        XCTAssertEqual(String(decoding: reconstructed, as: UTF8.self), "é")
        XCTAssertEqual(try adapter.rawBytes(for: 3), [])
        XCTAssertEqual(tokenizer.singletonDecodeCalls, 0)
    }

    func testOrdinaryAndMalformedTokensKeepDecodeFallback() throws {
        let tokenizer = FakeTokenizer(tokens: [
            0: "A",
            1: "<0xGG>",
            2: "<0x123>",
        ])
        let adapter = MLXTokenizerAdapter(tokenizer: tokenizer, vocabularySize: 3)

        XCTAssertEqual(try adapter.rawBytes(for: 0), [0x41])
        XCTAssertEqual(try adapter.rawBytes(for: 1), Array("<0xGG>".utf8))
        XCTAssertEqual(try adapter.rawBytes(for: 2), Array("<0x123>".utf8))
        XCTAssertEqual(tokenizer.singletonDecodeCalls, 3)
    }

    func testRawBytesRejectsOutOfRangeTokenIDs() {
        let adapter = MLXTokenizerAdapter(
            tokenizer: FakeTokenizer(tokens: [0: "A"]),
            vocabularySize: 1
        )

        XCTAssertThrowsError(try adapter.rawBytes(for: -1)) { error in
            XCTAssertEqual(error as? MLXTokenizerError, .invalidTokenID(-1))
        }
        XCTAssertThrowsError(try adapter.rawBytes(for: 1)) { error in
            XCTAssertEqual(error as? MLXTokenizerError, .invalidTokenID(1))
        }
    }
}

private final class FakeTokenizer: @unchecked Sendable, MLXLMCommon.Tokenizer {
    let tokens: [Int: String]
    private(set) var singletonDecodeCalls = 0

    init(tokens: [Int: String]) {
        self.tokens = tokens
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        []
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        if tokenIds.count == 1 {
            singletonDecodeCalls += 1
        }
        return tokenIds.compactMap { id in
            guard let token = tokens[id] else { return nil }
            if token == "<0xC3>" { return "\u{FFFD}" }
            if token == "<0xA9>" { return "\u{FFFD}" }
            return token
        }.joined()
    }

    func convertTokenToId(_ token: String) -> Int? {
        tokens.first(where: { $0.value == token })?.key
    }

    func convertIdToToken(_ id: Int) -> String? {
        tokens[id]
    }

    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        []
    }
}
