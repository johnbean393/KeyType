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

    /// `const llama_model *` exposed for vocab introspection (read-only queries via the
    /// thread-safe llama metadata API). Internal to the package; consumers go through
    /// `makeIntrospector()`.
    nonisolated internal var modelPointer: OpaquePointer { model }
    /// `const llama_vocab *` exposed for vocab introspection. Same threading caveats as
    /// `LlamaTokenizer` — read-only access on the documented-thread-safe APIs.
    nonisolated internal var vocabPointer: OpaquePointer { vocab }
    private nonisolated let reuseThreshold: Int
    private nonisolated let nBatch: Int
    /// When true, `anchoredLogits` decodes the base prompt once, snapshots the sequence state, and
    /// restores that snapshot before decoding each branch's suffix — instead of re-prefilling the
    /// whole prompt per branch (see ADR-018). Gated so it can be disabled if ever incorrect.
    private nonisolated let enableKVFork: Bool
    /// When true, consecutive `anchoredLogitsBatch` calls that form a beam frontier (each level's
    /// suffixes are one-token extensions of the previous level's) keep every branch's KV state
    /// resident and decode only the *new* token per branch — extending a sequence in place, or
    /// forking it (snapshot/restore) only when a branch splits — instead of reseeding the anchor and
    /// re-decoding the whole suffix every level (ADR-046). Falls back to the ADR-043 reseed path for
    /// any call whose parents are not resident, so correctness never depends on the fast path.
    private nonisolated let enableIncrementalBeam: Bool
    /// Number of distinct sequences the context can hold simultaneously (`n_ctx_params.n_seq_max`).
    /// This is the most beam branches `anchoredLogitsBatch` can expand in a single `llama_decode`;
    /// it bounds the resident per-sequence recurrent-state buffers (~19 MB each on this model), so
    /// it tracks the decoder's `branchWidth` rather than being set large. See ADR-043.
    private nonisolated let maxSequences: Int
    /// The single sequence the runtime decodes into.
    private nonisolated let anchorSeq: llama_seq_id = 0
    /// Incremental-beam frontier (ADR-046): maps a resident branch *suffix* to the sequence id whose
    /// KV holds `anchor + suffix`. Valid only across consecutive `anchoredLogitsBatch` calls on the
    /// same anchor; any other decode path invalidates it via `invalidateFrontier()`. The empty
    /// suffix (root) is implicit — its state is `anchorSnapshot`, so it is never stored here.
    private var frontier: [[TokenID]: Int] = [:]
    /// Tokens whose post-decode sequence state is captured in `anchorSnapshot`.
    private var anchorTokens: [TokenID] = []
    /// Serialized seq-0 state (`llama_state_seq_get_data`) immediately after decoding `anchorTokens`.
    /// Recurrent-memory safe (unlike cross-sequence `seq_cp`, which aborts on this hybrid model).
    private var anchorSnapshot: [UInt8]?
    /// Next-token logits at the end of `anchorTokens`, cached so the empty-suffix root branch needs
    /// no decode and stays correct even after a sibling branch overwrote the live logits buffer.
    private var anchorEndLogits: [TokenLogit]?
    /// Previous anchor snapshots keyed by their exact token sequence. BPE tokenization can rewrite
    /// the final token(s) as the user types inside a word; a recent older anchor often remains an
    /// exact prefix of the new prompt, so restoring it avoids a full prompt re-decode without any
    /// unsafe recurrent-state rollback.
    private struct AnchorHistoryEntry {
        var tokens: [TokenID]
        var snapshot: [UInt8]
    }
    private nonisolated let anchorSnapshotHistoryLimit: Int
    private var anchorSnapshotHistory: [AnchorHistoryEntry] = []

    private var currentTokens: [TokenID] = []
    /// How many tokens the most recent `prepare(promptTokens:)` actually pushed through
    /// `llama_decode`. Exposed for tests that want to assert KV reuse really happened.
    public private(set) var lastPrepareDecodedCount: Int = 0

    /// Set once the native context/model have been freed (either via `shutdown()` or `deinit`), so
    /// teardown happens exactly once and is never double-freed. See ADR-021.
    private var didFreeNativeResources = false

    public init(
        modelURL: URL,
        contextLength: Int = 4096,
        reuseThreshold: Int = 8,
        enableKVFork: Bool = true,
        // The beam frontier is decoded in parallel sequences (ADR-043) — this is the default and only
        // decode path. Sized to exactly the decoder's `branchWidth` (4): the anchor is held as a
        // serialized snapshot, not a concurrent live sequence, so peak concurrent sequences equals
        // the branch count. An on-device sweep showed latency plateaus once `n_seq_max ≥ branchWidth`
        // (4/5/8 are within noise — `n_seq_max` is a recurrent-buffer capacity bound, not the matmul
        // batch dimension, so there is no power-of-two effect); wider frontiers chunk gracefully.
        // On this hybrid model the parallel (split) recurrent path reorders near-tied logits by ~0.12
        // vs a lone single-sequence decode (same envelope ADR-012/018 already accepted: identical
        // argmax and top-k set, only ranks 3+ of near-ties shuffle).
        maxSequences: Int = 4,
        // Incremental beam decoding (ADR-046): keep branch KV resident across levels and decode only
        // the new token. On by default; the reseed path (ADR-043) remains as a per-call fallback.
        enableIncrementalBeam: Bool = true,
        // Retain a bounded set of prior anchor snapshots so retokenized character-by-character
        // typing can restore the newest exact prefix instead of clearing and decoding the full
        // prompt. Each entry is a native sequence snapshot, so keep the default intentionally small.
        anchorSnapshotHistoryLimit: Int = 8
    ) throws {
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

        let seqMax = max(1, maxSequences)
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(contextLength)
        ctxParams.n_batch = max(512, UInt32(contextLength))
        ctxParams.n_ubatch = min(ctxParams.n_batch, 512)
        // Allow the beam frontier to live in parallel sequences so `anchoredLogitsBatch` can expand
        // it in one decode (ADR-043). Costs ~one recurrent-state buffer per sequence.
        ctxParams.n_seq_max = UInt32(seqMax)
        // Unified KV buffer across sequences: our branch sequences all share the long anchor prefix
        // (the case unified is meant for), and it makes the cache a single `n_ctx`-cell pool shared
        // across sequences — which is the budget the batched path's group-size cap assumes.
        ctxParams.kv_unified = true
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
        self.enableKVFork = enableKVFork
        self.enableIncrementalBeam = enableIncrementalBeam
        self.maxSequences = Int(llama_n_seq_max(loadedCtx))
        self.anchorSnapshotHistoryLimit = max(0, anchorSnapshotHistoryLimit)
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

    /// Free the llama context and model up front. The ggml-metal backend keeps a process-global
    /// device whose C++ destructor (run via `__cxa_finalize` on `exit()`) asserts that every GPU
    /// residency set has been released; `llama_free`/`llama_model_free` are what release them. If we
    /// rely on this actor's `deinit` running at process teardown the timing is not guaranteed, so the
    /// assert fires and aborts on quit. Calling `shutdown()` before terminating frees the resources
    /// deterministically. The runtime is inert afterwards — do not issue further generation calls.
    public func shutdown() {
        guard !didFreeNativeResources else { return }
        didFreeNativeResources = true
        llama_free(ctx)
        llama_model_free(model)
    }

    deinit {
        guard !didFreeNativeResources else { return }
        didFreeNativeResources = true
        llama_free(ctx)
        llama_model_free(model)
    }

    // MARK: - LocalModelRuntime

    public func prepare(promptTokens: [TokenID]) async throws {
        // `prepare` decodes into / clears seq 0, which may back a resident beam frontier — drop it.
        invalidateFrontier()
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
        // Reuse the resident KV cache only when the previous tokens are a *prefix* of the new
        // prompt (a pure append). Any divergence would require rolling back already-decoded
        // positions with `llama_memory_seq_rm`, which is unsafe for models with recurrent /
        // hybrid memory (SSM / Gated Delta Net layers, e.g. Qwen3.5): their state can't be
        // partially rewound, so a later decode collides with a position the memory still holds
        // (M-RoPE requires the new start position Y to satisfy X < Y). For every non-append
        // case we clear and fully re-decode, which is always correct on both attention-only and
        // hybrid models. The multi-branch decoder no longer relies on this path for branches — it
        // calls `anchoredLogits` (ADR-018), which decodes the base prompt once and snapshot/restores
        // it per branch. `prepare` remains the pure-append-or-clear path for greedy/profiling callers.
        let isPureAppend = common == currentTokens.count
        let shouldReuse = isPureAppend && common >= reuseThreshold && common > 0

        if shouldReuse && common == promptTokens.count {
            // The prompt is byte-identical to what's already in seq 0. The logits buffer
            // from the previous `llama_decode` is still valid, so we can simply skip the
            // decode entirely — the strongest possible form of KV reuse.
            lastPrepareDecodedCount = 0
            return
        }

        if shouldReuse {
            // Pure append: keep [0, common) and decode the new suffix. `common < promptTokens.count`
            // here (the identical case returned above), so there's at least one token to push
            // through `llama_decode`, refreshing the logits buffer for the final position.
            let suffix = Array(promptTokens[common..<promptTokens.count])
            try decodeTokens(suffix, startingAt: common)
            currentTokens = promptTokens
            lastPrepareDecodedCount = suffix.count
        } else {
            // No usable resident prefix (fresh prompt, a divergence that would need a rollback,
            // or the new prompt is shorter than what's resident). Clear and fully re-decode.
            llama_memory_clear(memory, true)
            try decodeTokens(promptTokens, startingAt: 0)
            currentTokens = promptTokens
            lastPrepareDecodedCount = promptTokens.count
        }
    }

    public func logitsForNextToken() async throws -> [TokenLogit] {
        guard !currentTokens.isEmpty else { return [] }
        return try readLogits()
    }

    /// Reads the logits buffer from the most recent `llama_decode` (last position). Unlike
    /// `logitsForNextToken`, no `currentTokens` guard — callers that just decoded know logits exist.
    private func readLogits() throws -> [TokenLogit] {
        guard let raw = llama_get_logits_ith(ctx, -1) else {
            throw LlamaRuntimeError.logitsUnavailable
        }
        let vocabSize = metadata.vocabularySize
        let buffer = UnsafeBufferPointer(start: raw, count: vocabSize)
        // Fill the destination storage in one pass without per-element `append` bookkeeping —
        // this vector is vocabulary-wide (150k+) and is rebuilt for every branch expansion.
        return [TokenLogit](unsafeUninitializedCapacity: vocabSize) { dst, initializedCount in
            for i in 0..<vocabSize {
                dst[i] = TokenLogit(tokenID: TokenID(i), logit: buffer[i])
            }
            initializedCount = vocabSize
        }
    }

    public func decodeNext(tokenID: TokenID) async throws {
        try decodeTokens([tokenID], startingAt: currentTokens.count)
        currentTokens.append(tokenID)
    }

    public func resetKVCache() async {
        llama_memory_clear(memory, true)
        currentTokens = []
        lastPrepareDecodedCount = 0
        anchorTokens = []
        anchorSnapshot = nil
        anchorEndLogits = nil
        anchorSnapshotHistory.removeAll(keepingCapacity: true)
        invalidateFrontier()
    }

    // MARK: - Anchored KV reuse (ADR-018)

    /// Next-token logits for `anchor + suffix`. Decodes `anchor` once, snapshots the sequence state
    /// (`llama_state_seq_get_data`), then for every branch restores that snapshot and decodes only
    /// the divergent `suffix` — instead of re-prefilling the whole prompt per branch. Across
    /// keystrokes the anchor grows by the typed tokens, which is a pure append of the prior anchor,
    /// so only the typed delta is decoded.
    ///
    /// Snapshot/restore (not cross-sequence `seq_cp`) is used because this model's hybrid recurrent
    /// memory aborts on `seq_cp`; `get_data`/`set_data` serialize the full per-sequence state
    /// (attention KV + recurrent state) and are safe.
    public func anchoredLogits(anchor: [TokenID], suffix: [TokenID]) async throws -> [TokenLogit] {
        guard enableKVFork else {
            try await prepare(promptTokens: anchor + suffix)
            return try await logitsForNextToken()
        }
        if anchor.isEmpty && suffix.isEmpty { return [] }
        let total = anchor.count + suffix.count
        if total > metadata.contextLength {
            throw LlamaRuntimeError.promptTooLong(promptTokens: total, contextLength: metadata.contextLength)
        }

        // 1. Ensure a snapshot for exactly `anchor` exists (cheap when it already does).
        try ensureAnchor(anchor)

        // 2. Root branch (empty suffix): the cached anchor-end logits are always valid for the
        //    current anchor, even after a sibling branch overwrote the live logits buffer.
        if suffix.isEmpty {
            if let cached = anchorEndLogits { return cached }
            return try readLogits()
        }

        // 3. Branch: restore the anchor snapshot (discards any previous branch's suffix from the
        //    sequence) and decode just this branch's suffix. This rewrites seq 0, so any resident
        //    beam frontier is now stale.
        invalidateFrontier()
        try restoreAnchor()
        try decodeTokens(suffix, startingAt: anchor.count, seqID: anchorSeq)
        currentTokens = anchor + suffix
        return try readLogits()
    }

    /// Batched beam-frontier expansion (ADR-043): decode `anchor + suffix` for every `suffix` in a
    /// single `llama_decode` per group of up to `maxSequences` branches, instead of one decode call
    /// per branch. Each branch is seeded into its own sequence with a fresh copy of the resident
    /// anchor snapshot (cheap — ~0.3 ms), then one batch advances them all in parallel; the dominant
    /// per-completion cost is the *number* of `llama_decode` round-trips, so collapsing 12 branch
    /// calls into ~3 batched ones roughly halves latency. Results are returned in input order and
    /// are identical (top-k) to scoring each branch with `anchoredLogits`.
    public func anchoredLogitsBatch(anchor: [TokenID], suffixes: [[TokenID]]) async throws -> [[TokenLogit]] {
        guard enableKVFork else {
            var out: [[TokenLogit]] = []
            out.reserveCapacity(suffixes.count)
            for suffix in suffixes { out.append(try await anchoredLogits(anchor: anchor, suffix: suffix)) }
            return out
        }
        guard !suffixes.isEmpty else { return [] }
        let longest = anchor.count + (suffixes.map(\.count).max() ?? 0)
        if longest > metadata.contextLength {
            throw LlamaRuntimeError.promptTooLong(promptTokens: longest, contextLength: metadata.contextLength)
        }

        // Decode the anchor once (or reuse the resident snapshot); the per-branch seeds copy it.
        try ensureAnchor(anchor)

        var results = [[TokenLogit]](repeating: [], count: suffixes.count)

        // A root (empty) suffix marks the start of a fresh beam, so any frontier left resident by a
        // previous completion on this same anchor (where `ensureAnchor` took its no-op fast path) is
        // stale — drop it before this beam builds its own.
        if suffixes.contains(where: \.isEmpty) { invalidateFrontier() }

        // Empty-suffix (root) branches reuse the cached anchor-end logits — no decode needed, and
        // always valid even after a sibling branch overwrote the live logits buffer.
        var pending: [(index: Int, suffix: [TokenID])] = []
        for (i, suffix) in suffixes.enumerated() {
            if suffix.isEmpty {
                results[i] = try anchorEndLogits ?? readLogits()
            } else {
                pending.append((index: i, suffix: suffix))
            }
        }
        guard !pending.isEmpty else { return results }

        // Fast path (ADR-046): if every branch's parent (`suffix.dropLast()`) is resident from the
        // previous level, decode only each branch's new token in its parent's sequence — extending
        // in place, forking on a split. Returns false (no state mutated) if not satisfiable.
        if enableIncrementalBeam, try incrementalFrontierBatch(anchor: anchor, pending: pending, into: &results) {
            currentTokens = anchor
            return results
        }

        // Fallback (ADR-043): reseed the anchor snapshot into one sequence per branch and re-decode
        // each full suffix. Then register the resident frontier so the *next* level can go
        // incremental — but only when it ran as a single group (a multi-group reseed clears the
        // cache between groups, leaving only the last group resident).
        let cellsPerSeq = anchor.count + (pending.map(\.suffix.count).max() ?? 0)
        let budgetCap = max(1, metadata.contextLength / max(1, cellsPerSeq))
        let groupSize = max(1, min(maxSequences, budgetCap))

        invalidateFrontier()
        var cursor = 0
        while cursor < pending.count {
            let end = min(cursor + groupSize, pending.count)
            try decodeBranchGroup(anchor: anchor, group: Array(pending[cursor..<end]), into: &results)
            cursor = end
        }
        if pending.count <= groupSize {
            for (slot, item) in pending.enumerated() { frontier[item.suffix] = slot }
        }

        // Leave the resident token bookkeeping at the pristine anchor. Future `ensureAnchor` reuse
        // and any interleaved single-branch `anchoredLogits` restore from the snapshot, so they do
        // not depend on whatever the last batched group left live in the sequences.
        currentTokens = anchor
        return results
    }

    /// Incremental beam-frontier expansion (ADR-046). Each pending branch's suffix is one token
    /// longer than its parent `suffix.dropLast()`; if the parent's KV is resident (root parents use
    /// `anchorSnapshot`), seed each branch's sequence from its parent — the first child of a parent
    /// extends the parent's sequence *in place*, additional children fork it via snapshot/restore —
    /// and decode only the one new token. One `llama_decode` advances the whole frontier. Returns
    /// `false` without mutating state when the frontier can't satisfy the request (caller reseeds).
    private func incrementalFrontierBatch(
        anchor: [TokenID],
        pending: [(index: Int, suffix: [TokenID])],
        into results: inout [[TokenLogit]]
    ) throws -> Bool {
        guard anchorSnapshot != nil, pending.count <= maxSequences else { return false }

        // Group children by parent, preserving first-seen order; bail if any non-root parent is not
        // resident (then the reseed fallback handles the whole call).
        struct Child { var index: Int; var suffix: [TokenID]; var token: TokenID }
        var groups: [[TokenID]: [Child]] = [:]
        var parentOrder: [[TokenID]] = []
        for item in pending {
            guard let token = item.suffix.last else { return false }
            let parent = Array(item.suffix.dropLast())
            if !parent.isEmpty, frontier[parent] == nil { return false }
            if groups[parent] == nil { groups[parent] = []; parentOrder.append(parent) }
            groups[parent]!.append(Child(index: item.index, suffix: item.suffix, token: token))
        }

        // Slots reused in place by a non-root parent's first child are off-limits to forks.
        var reusedSlots = Set<Int>()
        for parent in parentOrder where !parent.isEmpty {
            if let seq = frontier[parent] { reusedSlots.insert(seq) }
        }
        var freeSlots = (0..<maxSequences).filter { !reusedSlots.contains($0) }

        // Resolve each child to a (seq, position, token); fork copies are seeded here, before the
        // single decode, from a snapshot of the parent taken *before* any in-place token is appended.
        struct Plan { var index: Int; var seq: Int; var position: Int; var token: TokenID; var suffix: [TokenID] }
        var plans: [Plan] = []
        plans.reserveCapacity(pending.count)
        for parent in parentOrder {
            let children = groups[parent]!
            let isRoot = parent.isEmpty
            let parentLen = anchor.count + parent.count
            var forkSource: [UInt8]?
            func sourceSnapshot() throws -> [UInt8] {
                if isRoot { return anchorSnapshot! }
                if let s = forkSource { return s }
                let s = try captureSequenceState(seq: llama_seq_id(frontier[parent]!))
                forkSource = s
                return s
            }
            for (childIndex, child) in children.enumerated() {
                let seq: Int
                if childIndex == 0, !isRoot {
                    seq = frontier[parent]!            // extend in place
                } else {
                    guard !freeSlots.isEmpty else { return false }
                    seq = freeSlots.removeFirst()      // fork: clear the slot, copy the parent in
                    llama_memory_seq_rm(memory, llama_seq_id(seq), 0, -1)
                    try restore(try sourceSnapshot(), intoSeq: llama_seq_id(seq))
                }
                plans.append(Plan(index: child.index, seq: seq, position: parentLen, token: child.token, suffix: child.suffix))
            }
        }

        var batch = llama_batch_init(Int32(plans.count), 0, 1)
        defer { llama_batch_free(batch) }
        for (i, plan) in plans.enumerated() {
            batch.token[i] = llama_token(plan.token)
            batch.pos[i] = llama_pos(plan.position)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = llama_seq_id(plan.seq)
            batch.logits[i] = 1
        }
        batch.n_tokens = Int32(plans.count)
        let rc = llama_decode(ctx, batch)
        if rc != 0 { throw LlamaRuntimeError.decodeFailed(rc) }

        var newFrontier: [[TokenID]: Int] = [:]
        for (i, plan) in plans.enumerated() {
            guard let raw = llama_get_logits_ith(ctx, Int32(i)) else { throw LlamaRuntimeError.logitsUnavailable }
            results[plan.index] = materializeLogits(raw)
            newFrontier[plan.suffix] = plan.seq
        }
        frontier = newFrontier
        return true
    }

    /// Seeds each branch in `group` into its own sequence (a copy of the anchor snapshot), then runs
    /// one `llama_decode` over all their suffix tokens and reads each branch's final-token logits.
    private func decodeBranchGroup(
        anchor: [TokenID],
        group: [(index: Int, suffix: [TokenID])],
        into results: inout [[TokenLogit]]
    ) throws {
        guard let snapshot = anchorSnapshot else { throw LlamaRuntimeError.sequenceStateSnapshotFailed }

        // Fresh cache, then one anchor copy per branch sequence (slot 0..<group.count).
        llama_memory_clear(memory, true)
        for slot in group.indices {
            try restore(snapshot, intoSeq: llama_seq_id(slot))
        }

        let totalTokens = group.reduce(0) { $0 + $1.suffix.count }
        var batch = llama_batch_init(Int32(totalTokens), 0, 1)
        defer { llama_batch_free(batch) }

        var lastBatchIndex = [Int](repeating: -1, count: group.count)
        var cursor = 0
        for (slot, item) in group.enumerated() {
            for (k, token) in item.suffix.enumerated() {
                batch.token[cursor] = llama_token(token)
                batch.pos[cursor] = llama_pos(anchor.count + k)
                batch.n_seq_id[cursor] = 1
                batch.seq_id[cursor]![0] = llama_seq_id(slot)
                let isLast = (k == item.suffix.count - 1)
                batch.logits[cursor] = isLast ? 1 : 0
                if isLast { lastBatchIndex[slot] = cursor }
                cursor += 1
            }
        }
        batch.n_tokens = Int32(totalTokens)

        let rc = llama_decode(ctx, batch)
        if rc != 0 { throw LlamaRuntimeError.decodeFailed(rc) }

        for (slot, item) in group.enumerated() {
            let idx = lastBatchIndex[slot]
            guard idx >= 0, let raw = llama_get_logits_ith(ctx, Int32(idx)) else {
                throw LlamaRuntimeError.logitsUnavailable
            }
            results[item.index] = materializeLogits(raw)
        }
    }

    /// Copies a llama logits row (`vocabularySize` floats) into a `[TokenLogit]` vector.
    private func materializeLogits(_ raw: UnsafePointer<Float>) -> [TokenLogit] {
        let vocabSize = metadata.vocabularySize
        let buffer = UnsafeBufferPointer(start: raw, count: vocabSize)
        return [TokenLogit](unsafeUninitializedCapacity: vocabSize) { dst, initializedCount in
            for v in 0..<vocabSize {
                dst[v] = TokenLogit(tokenID: TokenID(v), logit: buffer[v])
            }
            initializedCount = vocabSize
        }
    }

    /// Makes `anchorSnapshot`/`anchorEndLogits` describe exactly `anchor`. Reuses an existing
    /// snapshot when `anchor` extends it (cross-keystroke append decodes only the typed delta);
    /// otherwise clears and fully decodes. No `reuseThreshold` gate — a single typed token must
    /// reuse.
    private func ensureAnchor(_ anchor: [TokenID]) throws {
        if anchorSnapshot != nil && anchorTokens == anchor {
            lastPrepareDecodedCount = 0
            return
        }

        // The anchor is changing, so any resident beam frontier (seqs holding `oldAnchor + suffix`)
        // is stale — drop it before mutating the cache. Preserve the current anchor snapshot first:
        // BPE typing often rewrites the tail token, but an older exact-prefix snapshot can still be
        // restored safely and decoded forward.
        invalidateFrontier()
        rememberAnchorSnapshotForHistory()

        if let snapshot = anchorSnapshot,
           anchorTokens.count < anchor.count,
           Self.commonPrefixLength(anchorTokens, anchor) == anchorTokens.count,
           !anchorTokens.isEmpty {
            // Cross-keystroke append: restore the prior anchor, decode only the typed delta.
            try restore(snapshot)
            let delta = Array(anchor[anchorTokens.count..<anchor.count])
            try decodeTokens(delta, startingAt: anchorTokens.count, seqID: anchorSeq)
            lastPrepareDecodedCount = delta.count
        } else if let entry = bestHistoricalPrefix(for: anchor) {
            try restore(entry.snapshot)
            let delta = Array(anchor[entry.tokens.count..<anchor.count])
            try decodeTokens(delta, startingAt: entry.tokens.count, seqID: anchorSeq)
            lastPrepareDecodedCount = delta.count
        } else {
            llama_memory_clear(memory, true)
            try decodeTokens(anchor, startingAt: 0, seqID: anchorSeq)
            lastPrepareDecodedCount = anchor.count
        }
        currentTokens = anchor
        anchorTokens = anchor
        anchorSnapshot = try captureSequenceState()
        anchorEndLogits = try readLogits()
    }

    private func rememberAnchorSnapshotForHistory() {
        guard anchorSnapshotHistoryLimit > 0,
              !anchorTokens.isEmpty,
              let snapshot = anchorSnapshot
        else { return }

        if let existing = anchorSnapshotHistory.firstIndex(where: { $0.tokens == anchorTokens }) {
            anchorSnapshotHistory.remove(at: existing)
        }
        anchorSnapshotHistory.append(AnchorHistoryEntry(tokens: anchorTokens, snapshot: snapshot))
        if anchorSnapshotHistory.count > anchorSnapshotHistoryLimit {
            anchorSnapshotHistory.removeFirst(anchorSnapshotHistory.count - anchorSnapshotHistoryLimit)
        }
    }

    private func bestHistoricalPrefix(for anchor: [TokenID]) -> AnchorHistoryEntry? {
        var best: AnchorHistoryEntry?
        for entry in anchorSnapshotHistory.reversed() {
            guard entry.tokens.count < anchor.count,
                  Self.hasPrefix(anchor, prefix: entry.tokens)
            else { continue }
            if best == nil || entry.tokens.count > best!.tokens.count {
                best = entry
            }
        }
        return best
    }

    /// Restores the live sequence to the captured `anchor` state.
    private func restoreAnchor() throws {
        guard let snapshot = anchorSnapshot else { return }
        try restore(snapshot)
        currentTokens = anchorTokens
    }

    private func captureSequenceState(seq: llama_seq_id = 0) throws -> [UInt8] {
        let size = llama_state_seq_get_size(ctx, seq)
        guard size > 0 else { throw LlamaRuntimeError.sequenceStateSnapshotFailed }
        var buffer = [UInt8](repeating: 0, count: size)
        let written = buffer.withUnsafeMutableBufferPointer {
            llama_state_seq_get_data(ctx, $0.baseAddress, size, seq)
        }
        guard written > 0 else { throw LlamaRuntimeError.sequenceStateSnapshotFailed }
        return buffer
    }

    /// Drops the incremental-beam frontier (ADR-046). Called by every decode path other than a
    /// same-anchor `anchoredLogitsBatch`, so a stale resident frontier is never reused after the
    /// cache has been mutated underneath it.
    private func invalidateFrontier() { frontier.removeAll(keepingCapacity: true) }

    private func restore(_ snapshot: [UInt8]) throws {
        try restore(snapshot, intoSeq: anchorSeq)
    }

    /// Restores a captured sequence snapshot into an arbitrary destination sequence. Used by the
    /// batched path to seed each branch's sequence with its own copy of the anchor.
    private func restore(_ snapshot: [UInt8], intoSeq seqID: llama_seq_id) throws {
        let read = snapshot.withUnsafeBufferPointer {
            llama_state_seq_set_data(ctx, $0.baseAddress, snapshot.count, seqID)
        }
        guard read > 0 else { throw LlamaRuntimeError.sequenceStateSnapshotFailed }
    }

    // MARK: - Internals

    private func decodeTokens(_ tokens: [TokenID], startingAt startPos: Int, seqID: llama_seq_id = 0) throws {
        guard !tokens.isEmpty else { return }
        var offset = 0
        while offset < tokens.count {
            let end = min(offset + nBatch, tokens.count)
            let chunk = Array(tokens[offset..<end])
            let isLastChunk = (end == tokens.count)
            try decodeChunk(chunk, startingAt: startPos + offset, requestLogitsOnLast: isLastChunk, seqID: seqID)
            offset = end
        }
    }

    /// Decode a single chunk that fits inside `n_batch`. Logits are requested only on the
    /// final position of the final chunk so `logitsForNextToken` can read them.
    private func decodeChunk(
        _ tokens: [TokenID],
        startingAt startPos: Int,
        requestLogitsOnLast: Bool,
        seqID: llama_seq_id = 0
    ) throws {
        var batch = llama_batch_init(Int32(tokens.count), 0, 1)
        defer { llama_batch_free(batch) }
        for i in 0..<tokens.count {
            batch.token[i] = llama_token(tokens[i])
            batch.pos[i] = llama_pos(startPos + i)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = seqID
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

    private static func hasPrefix(_ tokens: [TokenID], prefix: [TokenID]) -> Bool {
        guard prefix.count <= tokens.count else { return false }
        for i in prefix.indices where tokens[i] != prefix[i] { return false }
        return true
    }
}
