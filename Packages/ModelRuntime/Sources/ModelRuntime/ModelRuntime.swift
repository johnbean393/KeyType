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
    /// Tokenize while parsing control markers (e.g. `<|fim_prefix|>`) into their single dedicated
    /// vocab tokens rather than literal text. Used only for app-constructed scaffolding such as
    /// fill-in-the-middle assembly. Defaults to plain `tokenize(_:)` for tokenizers that don't
    /// distinguish special tokens (the FIM caller detects the no-op via marker token counts).
    func tokenizeAllowingSpecial(_ text: String) throws -> [TokenID]
}

public extension ModelTokenizing {
    func tokenizeAllowingSpecial(_ text: String) throws -> [TokenID] {
        try tokenize(text)
    }
}

public protocol LocalModelRuntime {
    var metadata: ModelMetadata { get }
    var tokenizer: ModelTokenizing { get }

    func prepare(promptTokens: [TokenID]) async throws
    func logitsForNextToken() async throws -> [TokenLogit]
    func decodeNext(tokenID: TokenID) async throws
    func resetKVCache() async

    /// Next-token logits for `anchor + suffix`, where `anchor` is a prefix shared across many calls
    /// (the base prompt the multi-branch decoder forks from). Implementations may keep `anchor`
    /// resident and decode only `suffix` (cheap KV fork). Semantically identical to
    /// `prepare(anchor + suffix)` followed by `logitsForNextToken()`.
    func anchoredLogits(anchor: [TokenID], suffix: [TokenID]) async throws -> [TokenLogit]
}

public extension LocalModelRuntime {
    /// Default: no reuse — decode the full `anchor + suffix` every call. Concrete runtimes backed by
    /// a real KV cache override this to fork from a resident `anchor`.
    func anchoredLogits(anchor: [TokenID], suffix: [TokenID]) async throws -> [TokenLogit] {
        try await prepare(promptTokens: anchor + suffix)
        return try await logitsForNextToken()
    }
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

/// Path-aware test runtime: returns next-token logits as a function of the **full token
/// sequence** seen so far (prompt + emitted tokens), not a linear step counter. This is what
/// the M5 multi-branch decoder needs — it re-`prepare`s `basePrompt + branchTokens` to score
/// each branch, so a step-based stub (`StubModelRuntime`) cannot represent path-dependent
/// logits. An optional `perCallDelayNanoseconds` makes generation observably in-flight so
/// cancellation tests can interrupt it (`Task.sleep` is cancellation-aware).
public final class TreeScriptedModelRuntime: LocalModelRuntime {
    public let metadata: ModelMetadata
    public let tokenizer: ModelTokenizing
    private let logitsByPath: [[TokenID]: [TokenLogit]]
    private let perCallDelayNanoseconds: UInt64?
    private var currentTokens: [TokenID] = []

    public init(
        logitsByPath: [[TokenID]: [TokenLogit]],
        metadata: ModelMetadata = ModelMetadata(
            identifier: "tree-scripted",
            family: "stub",
            vocabularySize: 256,
            contextLength: 4096
        ),
        tokenizer: ModelTokenizing = UTF8FallbackTokenizer(),
        perCallDelayNanoseconds: UInt64? = nil
    ) {
        self.logitsByPath = logitsByPath
        self.metadata = metadata
        self.tokenizer = tokenizer
        self.perCallDelayNanoseconds = perCallDelayNanoseconds
    }

    public func prepare(promptTokens: [TokenID]) async throws {
        if let delay = perCallDelayNanoseconds { try await Task.sleep(nanoseconds: delay) }
        currentTokens = promptTokens
    }

    public func logitsForNextToken() async throws -> [TokenLogit] {
        if let delay = perCallDelayNanoseconds { try await Task.sleep(nanoseconds: delay) }
        return logitsByPath[currentTokens] ?? []
    }

    public func decodeNext(tokenID: TokenID) async throws {
        if let delay = perCallDelayNanoseconds { try await Task.sleep(nanoseconds: delay) }
        currentTokens.append(tokenID)
    }

    public func resetKVCache() async {
        currentTokens = []
    }
}
