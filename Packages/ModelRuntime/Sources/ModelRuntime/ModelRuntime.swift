import AutocompleteCore
import Foundation

public struct ModelMetadata: Equatable {
    public var identifier: String
    public var family: String
    public var vocabularySize: Int
    public var contextLength: Int
    public var eosTokenID: TokenID?
    public var eotTokenID: TokenID?

    public init(
        identifier: String,
        family: String,
        vocabularySize: Int,
        contextLength: Int,
        eosTokenID: TokenID? = nil,
        eotTokenID: TokenID? = nil
    ) {
        self.identifier = identifier
        self.family = family
        self.vocabularySize = vocabularySize
        self.contextLength = contextLength
        self.eosTokenID = eosTokenID
        self.eotTokenID = eotTokenID
    }
}

public struct TokenLogit: Equatable {
    public var tokenID: TokenID
    public var logit: Float

    public init(tokenID: TokenID, logit: Float) {
        self.tokenID = tokenID
        self.logit = logit
    }
}

public protocol ModelTokenizing {
    func tokenize(_ text: String) throws -> [TokenID]
    func detokenize(_ tokenIDs: [TokenID]) throws -> String
    func rawBytes(for tokenID: TokenID) throws -> [UInt8]
}

public protocol LocalModelRuntime {
    var metadata: ModelMetadata { get }
    var tokenizer: ModelTokenizing { get }

    func prepare(promptTokens: [TokenID]) async throws
    func logitsForNextToken() async throws -> [TokenLogit]
    func decodeNext(tokenID: TokenID) async throws
    func resetKVCache() async
}

public struct UTF8FallbackTokenizer: ModelTokenizing {
    public init() {}

    public func tokenize(_ text: String) throws -> [TokenID] {
        text.utf8.map { TokenID($0) }
    }

    public func detokenize(_ tokenIDs: [TokenID]) throws -> String {
        let bytes = tokenIDs.compactMap { UInt8(exactly: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    public func rawBytes(for tokenID: TokenID) throws -> [UInt8] {
        guard let byte = UInt8(exactly: tokenID) else {
            return []
        }
        return [byte]
    }
}

public final class StubModelRuntime: LocalModelRuntime {
    public let metadata: ModelMetadata
    public let tokenizer: ModelTokenizing
    private var scriptedLogits: [[TokenLogit]]
    private var step: Int = 0

    public init(
        metadata: ModelMetadata = ModelMetadata(
            identifier: "stub-utf8",
            family: "stub",
            vocabularySize: 256,
            contextLength: 4096
        ),
        tokenizer: ModelTokenizing = UTF8FallbackTokenizer(),
        scriptedLogits: [[TokenLogit]] = []
    ) {
        self.metadata = metadata
        self.tokenizer = tokenizer
        self.scriptedLogits = scriptedLogits
    }

    public func prepare(promptTokens: [TokenID]) async throws {
        step = 0
    }

    public func logitsForNextToken() async throws -> [TokenLogit] {
        guard step < scriptedLogits.count else {
            return []
        }
        return scriptedLogits[step]
    }

    public func decodeNext(tokenID: TokenID) async throws {
        step += 1
    }

    public func resetKVCache() async {
        step = 0
    }
}
