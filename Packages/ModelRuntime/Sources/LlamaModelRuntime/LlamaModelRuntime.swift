import AutocompleteCore
import Foundation
import ModelRuntime
import llama

/// Concrete `LocalModelRuntime` backed by llama.cpp (see ADR-007).
///
/// The runtime is an `actor` so every llama call is serialised — `llama_context` is not
/// thread-safe and Swift's actor isolation gives us a clean off-main-actor execution model
/// for free. Static metadata (vocab size, EOS, EOT) and the `tokenizer` are `nonisolated`
/// so consumers can read them synchronously like they can on `StubModelRuntime`.
///
/// KV-cache prefix reuse is an internal detail of `prepare(promptTokens:)`. It keeps the
/// largest possible matching prefix of the previous prompt in seq 0 and only decodes the
/// changed suffix; identical prompts re-decode just the trailing token so fresh logits
/// always come from the latest `llama_decode` call. The protocol surface is unchanged.
public actor LlamaModelRuntime: LocalModelRuntime {
    public nonisolated let metadata: ModelMetadata
    public nonisolated let tokenizer: ModelTokenizing

    // `nonisolated(unsafe)` because `OpaquePointer` is not statically `Sendable`. Actor
    // isolation already guarantees that every llama call against these pointers is
    // serialised; the pointers themselves are immutable after `init`.
    private nonisolated(unsafe) let model: OpaquePointer
    private nonisolated(unsafe) let ctx: OpaquePointer
    private nonisolated(unsafe) let vocab: OpaquePointer
    private nonisolated(unsafe) let memory: OpaquePointer
    private nonisolated let reuseThreshold: Int
    private nonisolated let nBatch: Int

    private var currentTokens: [TokenID] = []
    /// How many tokens the most recent `prepare(promptTokens:)` actually pushed through
    /// `llama_decode`. Exposed for tests that want to assert KV reuse really happened.
    public private(set) var lastPrepareDecodedCount: Int = 0

    public init(modelURL: URL, contextLength: Int = 2048, reuseThreshold: Int = 8) throws {
        guard ModelContainer.modelExists(at: modelURL) else {
            throw LlamaRuntimeError.modelFileMissing(path: modelURL.path)
        }
        _ = LlamaBackend.shared

        var modelParams = llama_model_default_params()
        modelParams.use_mmap = true
        modelParams.use_mlock = false

        guard let loadedModel = llama_model_load_from_file(modelURL.path, modelParams) else {
            throw LlamaRuntimeError.modelLoadFailed
        }

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(contextLength)
        ctxParams.n_batch = max(512, UInt32(contextLength))
        ctxParams.n_ubatch = min(ctxParams.n_batch, 512)
        ctxParams.no_perf = true

        guard let loadedCtx = llama_init_from_model(loadedModel, ctxParams) else {
            llama_model_free(loadedModel)
            throw LlamaRuntimeError.contextInitFailed
        }

        guard let loadedVocab = llama_model_get_vocab(loadedModel) else {
            llama_free(loadedCtx)
            llama_model_free(loadedModel)
            throw LlamaRuntimeError.vocabUnavailable
        }

        guard let loadedMemory = llama_get_memory(loadedCtx) else {
            llama_free(loadedCtx)
            llama_model_free(loadedModel)
            throw LlamaRuntimeError.memoryUnavailable
        }

        let vocabSize = Int(llama_vocab_n_tokens(loadedVocab))
        let eosRaw = llama_vocab_eos(loadedVocab)
        let eotRaw = llama_vocab_eot(loadedVocab)
        let effectiveContextLength = Int(llama_n_ctx(loadedCtx))

        self.model = loadedModel
        self.ctx = loadedCtx
        self.vocab = loadedVocab
        self.memory = loadedMemory
        self.reuseThreshold = max(0, reuseThreshold)
        self.nBatch = Int(llama_n_batch(loadedCtx))
        self.metadata = ModelMetadata(
            identifier: modelURL.lastPathComponent,
            family: "llama",
            vocabularySize: vocabSize,
            contextLength: effectiveContextLength,
            eosTokenID: eosRaw == LLAMA_TOKEN_NULL ? nil : TokenID(eosRaw),
            eotTokenID: eotRaw == LLAMA_TOKEN_NULL ? nil : TokenID(eotRaw)
        )
        self.tokenizer = LlamaTokenizer(vocab: loadedVocab, vocabSize: vocabSize)
    }

    deinit {
        llama_free(ctx)
        llama_model_free(model)
    }

    // MARK: - LocalModelRuntime

    public func prepare(promptTokens: [TokenID]) async throws {
        guard !promptTokens.isEmpty else {
            llama_memory_clear(memory, true)
            currentTokens = []
            lastPrepareDecodedCount = 0
            return
        }
        if promptTokens.count > metadata.contextLength {
            throw LlamaRuntimeError.promptTooLong(
                promptTokens: promptTokens.count,
                contextLength: metadata.contextLength
            )
        }

        let common = Self.commonPrefixLength(currentTokens, promptTokens)
        let shouldReuse = common >= reuseThreshold && common > 0

        if shouldReuse && common == promptTokens.count && common == currentTokens.count {
            // The prompt is byte-identical to what's already in seq 0. The logits buffer
            // from the previous `llama_decode` is still valid, so we can simply skip the
            // decode entirely — the strongest possible form of KV reuse.
            lastPrepareDecodedCount = 0
            return
        }

        if shouldReuse && common < promptTokens.count {
            // Keep [0, common) and decode the new suffix. We always have at least one
            // token to push through `llama_decode` here (common < promptTokens.count),
            // so the logits buffer is refreshed for the final position.
            if common < currentTokens.count {
                _ = llama_memory_seq_rm(memory, 0, llama_pos(common), -1)
            }
            let suffix = Array(promptTokens[common..<promptTokens.count])
            try decodeTokens(suffix, startingAt: common)
            currentTokens = promptTokens
            lastPrepareDecodedCount = suffix.count
        } else {
            // No usable prefix (or `common == promptTokens.count < currentTokens.count`,
            // where the previous KV has extra tokens past the prompt that we'd have to
            // re-decode anyway). Cheaper and simpler to clear and fully redecode.
            llama_memory_clear(memory, true)
            try decodeTokens(promptTokens, startingAt: 0)
            currentTokens = promptTokens
            lastPrepareDecodedCount = promptTokens.count
        }
    }

    public func logitsForNextToken() async throws -> [TokenLogit] {
        guard !currentTokens.isEmpty else { return [] }
        guard let raw = llama_get_logits_ith(ctx, -1) else {
            throw LlamaRuntimeError.logitsUnavailable
        }
        let vocabSize = metadata.vocabularySize
        let buffer = UnsafeBufferPointer(start: raw, count: vocabSize)
        var result = [TokenLogit]()
        result.reserveCapacity(vocabSize)
        for i in 0..<vocabSize {
            result.append(TokenLogit(tokenID: TokenID(i), logit: buffer[i]))
        }
        return result
    }

    public func decodeNext(tokenID: TokenID) async throws {
        try decodeTokens([tokenID], startingAt: currentTokens.count)
        currentTokens.append(tokenID)
    }

    public func resetKVCache() async {
        llama_memory_clear(memory, true)
        currentTokens = []
        lastPrepareDecodedCount = 0
    }

    // MARK: - Internals

    private func decodeTokens(_ tokens: [TokenID], startingAt startPos: Int) throws {
        guard !tokens.isEmpty else { return }
        var offset = 0
        while offset < tokens.count {
            let end = min(offset + nBatch, tokens.count)
            let chunk = Array(tokens[offset..<end])
            let isLastChunk = (end == tokens.count)
            try decodeChunk(chunk, startingAt: startPos + offset, requestLogitsOnLast: isLastChunk)
            offset = end
        }
    }

    /// Decode a single chunk that fits inside `n_batch`. Logits are requested only on the
    /// final position of the final chunk so `logitsForNextToken` can read them.
    private func decodeChunk(
        _ tokens: [TokenID],
        startingAt startPos: Int,
        requestLogitsOnLast: Bool
    ) throws {
        var batch = llama_batch_init(Int32(tokens.count), 0, 1)
        defer { llama_batch_free(batch) }
        for i in 0..<tokens.count {
            batch.token[i] = llama_token(tokens[i])
            batch.pos[i] = llama_pos(startPos + i)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = 0
            let isLast = (i == tokens.count - 1)
            batch.logits[i] = (isLast && requestLogitsOnLast) ? 1 : 0
        }
        batch.n_tokens = Int32(tokens.count)
        let rc = llama_decode(ctx, batch)
        if rc != 0 {
            throw LlamaRuntimeError.decodeFailed(rc)
        }
    }

    private static func commonPrefixLength(_ a: [TokenID], _ b: [TokenID]) -> Int {
        var i = 0
        let n = min(a.count, b.count)
        while i < n && a[i] == b[i] { i += 1 }
        return i
    }
}
