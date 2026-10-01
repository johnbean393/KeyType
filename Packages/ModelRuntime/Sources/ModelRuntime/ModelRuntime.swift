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
    /// Model-required tokens at the start of a complete causal input (for example Gemma's BOS).
    /// Fragment tokenization must remain prefix-free for suffix scoring and token-budget slicing.
    var promptPrefixTokens: [TokenID] { get }
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
    var promptPrefixTokens: [TokenID] { [] }

    /// Adds the model's input prefix once, without parsing control-token spellings in user text
    /// or appending EOS, which would terminate the continuation we are asking the model to make.
    func tokenizePrompt(_ text: String) throws -> [TokenID] {
        promptPrefixTokens + (try tokenize(text))
    }

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

    /// Release any native resources held by the runtime (model, context, GPU residency sets) and
    /// leave the runtime inert. Must be called before the process exits when the runtime is backed
    /// by a GPU backend whose process-teardown destructors assert that all resources were freed
    /// (e.g. llama.cpp's ggml-metal device). Idempotent; safe to call when nothing was allocated.
    func shutdown() async

    /// Next-token logits for `anchor + suffix`, where `anchor` is a prefix shared across many calls
    /// (the base prompt the multi-branch decoder forks from). Implementations may keep `anchor`
    /// resident and decode only `suffix` (cheap KV fork). Semantically identical to
    /// `prepare(anchor + suffix)` followed by `logitsForNextToken()`.
    func anchoredLogits(anchor: [TokenID], suffix: [TokenID]) async throws -> [TokenLogit]

    /// Next-token logits for `anchor + suffix` for *every* `suffix` in `suffixes`, returned in the
    /// same order. Semantically identical to calling `anchoredLogits(anchor:suffix:)` once per
    /// suffix, but lets a real runtime expand a whole beam frontier in a single batched
    /// `llama_decode` (one GPU round-trip instead of one per branch — the dominant per-completion
    /// cost; see ADR-043). Each branch is seeded with its own copy of the resident anchor state.
    func anchoredLogitsBatch(anchor: [TokenID], suffixes: [[TokenID]]) async throws -> [[TokenLogit]]
}

public extension LocalModelRuntime {
    /// Default: no reuse — decode the full `anchor + suffix` every call. Concrete runtimes backed by
    /// a real KV cache override this to fork from a resident `anchor`.
    func anchoredLogits(anchor: [TokenID], suffix: [TokenID]) async throws -> [TokenLogit] {
        try await prepare(promptTokens: anchor + suffix)
        return try await logitsForNextToken()
    }

    /// Default: score each branch sequentially via `anchoredLogits`. Stubs and pure-Swift runtimes
    /// keep this loop unchanged, so every deterministic engine/FIM test is byte-for-byte identical;
    /// only `LlamaModelRuntime` overrides it with true multi-sequence batched decoding.
    func anchoredLogitsBatch(anchor: [TokenID], suffixes: [[TokenID]]) async throws -> [[TokenLogit]] {
        var out: [[TokenLogit]] = []
        out.reserveCapacity(suffixes.count)
        for suffix in suffixes {
            out.append(try await anchoredLogits(anchor: anchor, suffix: suffix))
        }
        return out
    }

    /// Default: pure-Swift runtimes hold no native resources, so teardown is a no-op.
    func shutdown() async {}
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
