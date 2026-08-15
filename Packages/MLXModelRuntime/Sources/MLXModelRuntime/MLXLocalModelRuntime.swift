import AutocompleteCore
import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import ModelRuntime
import Tokenizers

/// Native MLX implementation of `LocalModelRuntime`.
///
/// This is the correctness-first backend described in the MLX plan. One actor owns the MLX
/// model and all mutable KV caches. Branch scoring copies the anchor cache and evaluates suffixes
/// sequentially, which is deliberately simple and gives us a reference for later device-side
/// ranking and batched beam work. MTP is intentionally not part of this type.
public actor MLXLocalModelRuntime: RankedLocalModelRuntime {
    public nonisolated let metadata: ModelMetadata
    public nonisolated let tokenizer: ModelTokenizing
    public nonisolated let mlxTokenizer: MLXTokenizerAdapter

    private let model: any LanguageModel
    private let contextLength: Int
    private var prepared: MLXBranchCache?
    private var didShutdown = false

    /// Build a runtime from a local directory previously downloaded in MLX safetensor format.
    /// Prefer `MLXModelLoader.load(modelDirectory:)` for normal callers.
    init(
        context: ModelContext,
        contextLength: Int,
        family: String?
    ) {
        let vocabularySize = Self.vocabularySize(for: context.tokenizer)
        let adapter = MLXTokenizerAdapter(
            tokenizer: context.tokenizer,
            vocabularySize: vocabularySize
        )
        self.model = context.model
        self.contextLength = max(1, contextLength)
        self.mlxTokenizer = adapter
        self.tokenizer = adapter
        self.metadata = ModelMetadata(
            identifier: context.configuration.name,
            family: family ?? "mlx-v\(vocabularySize)",
            vocabularySize: vocabularySize,
            contextLength: max(1, contextLength),
            eosTokenID: context.tokenizer.eosTokenId.map(TokenID.init)
                ?? context.configuration.eosTokenIds.first.map(TokenID.init),
            eotTokenID: context.tokenizer.convertTokenToId("<|im_end|>").map(TokenID.init)
        )
    }

    // MARK: LocalModelRuntime

    public func prepare(promptTokens: [TokenID]) async throws {
        try ensureActive()
        try Task.checkCancellation()
        guard promptTokens.count <= contextLength else {
            throw MLXRuntimeError.promptTooLong(
                promptTokens: promptTokens.count,
                contextLength: contextLength
            )
        }

        if promptTokens.isEmpty {
            prepared = nil
            return
        }

        try validateTokenIDs(promptTokens)
        let promptIDs = promptTokens.map { Int32($0) }
        if let current = prepared,
           current.tokens == promptIDs
        {
            return
        }

        var next: MLXBranchCache
        if let current = prepared,
           Self.hasPrefix(promptIDs, current.tokens)
        {
            next = current.copied()
            let delta = Array(promptTokens.dropFirst(current.tokens.count))
            try evaluate(delta, in: &next)
        } else {
            next = MLXBranchCache(
                tokens: [],
                cache: model.newCache(parameters: nil),
                state: nil,
                logits: []
            )
            try evaluate(promptTokens, in: &next)
        }
        prepared = next
    }

    public func logitsForNextToken() async throws -> [TokenLogit] {
        try ensureActive()
        return prepared?.logits ?? []
    }

    public func decodeNext(tokenID: TokenID) async throws {
        try ensureActive()
        try Task.checkCancellation()
        guard var current = prepared else {
            throw MLXRuntimeError.runtimeNotPrepared
        }
        guard Int(tokenID) >= 0, Int(tokenID) < metadata.vocabularySize else {
            throw MLXRuntimeError.invalidTokenID(tokenID)
        }
        guard current.tokens.count < contextLength else {
            throw MLXRuntimeError.promptTooLong(
                promptTokens: current.tokens.count + 1,
                contextLength: contextLength
            )
        }
        try evaluate([tokenID], in: &current)
        prepared = current
    }

    public func resetKVCache() async {
        prepared = nil
    }

    public func shutdown() async {
        guard !didShutdown else { return }
        didShutdown = true
        prepared = nil
    }

    /// Score one branch from a copied anchor cache.
    public func anchoredLogits(anchor: [TokenID], suffix: [TokenID]) async throws -> [TokenLogit] {
        try ensureActive()
        try Task.checkCancellation()

        if anchor.isEmpty {
            guard !suffix.isEmpty else { return [] }
            guard suffix.count <= contextLength else {
                throw MLXRuntimeError.promptTooLong(
                    promptTokens: suffix.count,
                    contextLength: contextLength
                )
            }
            var branch = makeEmptyBranch()
            try evaluate(suffix, in: &branch)
            return branch.logits
        }

        try await prepare(promptTokens: anchor)
        guard let anchorCache = prepared else { return [] }
        guard anchor.count + suffix.count <= contextLength else {
            throw MLXRuntimeError.promptTooLong(
                promptTokens: anchor.count + suffix.count,
                contextLength: contextLength
            )
        }
        guard !suffix.isEmpty else { return anchorCache.logits }

        var branch = anchorCache.copied()
        try evaluate(suffix, in: &branch)
        return branch.logits
    }

    /// Correctness-first batched API. It keeps the protocol's ordering contract and copies the
    /// anchor once per branch. Later performance work can replace this body with a true MLX batch
    /// dimension without changing `ConstrainedGenerationEngine`.
    public func anchoredLogitsBatch(
        anchor: [TokenID],
        suffixes: [[TokenID]]
    ) async throws -> [[TokenLogit]] {
        try ensureActive()
        try Task.checkCancellation()

        if anchor.isEmpty {
            var results: [[TokenLogit]] = []
            results.reserveCapacity(suffixes.count)
            for suffix in suffixes {
                try Task.checkCancellation()
                guard suffix.count <= contextLength else {
                    throw MLXRuntimeError.promptTooLong(
                        promptTokens: suffix.count,
                        contextLength: contextLength
                    )
                }
                guard !suffix.isEmpty else {
                    results.append([])
                    continue
                }
                var branch = makeEmptyBranch()
                try evaluate(suffix, in: &branch)
                results.append(branch.logits)
            }
            return results
        }

        try await prepare(promptTokens: anchor)
        guard let anchorCache = prepared else {
            return suffixes.map { _ in [] }
        }

        var results: [[TokenLogit]] = []
        results.reserveCapacity(suffixes.count)
        for suffix in suffixes {
            try Task.checkCancellation()
            guard anchor.count + suffix.count <= contextLength else {
                throw MLXRuntimeError.promptTooLong(
                    promptTokens: anchor.count + suffix.count,
                    contextLength: contextLength
                )
            }
            if suffix.isEmpty {
                results.append(anchorCache.logits)
                continue
            }
            var branch = anchorCache.copied()
            try evaluate(suffix, in: &branch)
            results.append(branch.logits)
        }
        return results
    }

    public func rankNextTokensBatch(
        anchor: [TokenID],
        suffixes: [[TokenID]],
        constraints: [RuntimeTokenConstraint],
        topK: Int
    ) async throws -> [[RankedToken]] {
        guard suffixes.count == constraints.count else {
            throw MLXRuntimeError.invalidConstraintCount(
                suffixCount: suffixes.count,
                constraintCount: constraints.count
            )
        }
        let logits = try await anchoredLogitsBatch(anchor: anchor, suffixes: suffixes)
        return zip(logits, constraints).map { branchLogits, constraint in
            MLXRankedLogits.rank(logits: branchLogits, constraint: constraint, topK: topK)
        }
    }

    // MARK: MLX evaluation

    private func makeEmptyBranch() -> MLXBranchCache {
        MLXBranchCache(
            tokens: [],
            cache: model.newCache(parameters: nil),
            state: nil,
            logits: []
        )
    }

    private func evaluate(_ tokens: [TokenID], in branch: inout MLXBranchCache) throws {
        guard !tokens.isEmpty else { return }
        try Task.checkCancellation()
        try validateTokenIDs(tokens)

        let inputIDs = tokens.map { Int32($0) }
        let inputTokens = MLXArray(inputIDs)[.newAxis, .ellipsis]
        let input = LMInput(tokens: inputTokens)
        let result = try model.prepare(input, cache: branch.cache, windowSize: nil)

        switch result {
        case let .logits(output):
            branch.state = output.state
            eval(output.logits, branch.cache)
            branch.logits = Self.materialize(output.logits, vocabularySize: metadata.vocabularySize)
            branch.tokens.append(contentsOf: inputIDs)

        case let .tokens(remaining):
            let remainingTokens = remaining.tokens.asArray(Int32.self)
            guard !remainingTokens.isEmpty else {
                throw MLXRuntimeError.emptyPrepareResult
            }
            let output = model(
                LMInput.Text(tokens: remaining.tokens),
                cache: branch.cache,
                state: branch.state
            )
            branch.state = output.state
            eval(output.logits, branch.cache)
            branch.logits = Self.materialize(output.logits, vocabularySize: metadata.vocabularySize)
            branch.tokens.append(contentsOf: inputIDs)
        }
    }

    private func ensureActive() throws {
        guard !didShutdown else { throw MLXRuntimeError.runtimeShutdown }
    }

    private func validateTokenIDs(_ tokenIDs: [TokenID]) throws {
        for tokenID in tokenIDs {
            guard Int(tokenID) >= 0, Int(tokenID) < metadata.vocabularySize else {
                throw MLXRuntimeError.invalidTokenID(tokenID)
            }
        }
    }

    private static func vocabularySize(for tokenizer: any MLXLMCommon.Tokenizer) -> Int {
        var id = 0
        while tokenizer.convertIdToToken(id) != nil {
            id += 1
        }
        return id
    }

    private static func materialize(_ logits: MLXArray, vocabularySize: Int) -> [TokenLogit] {
        let lastRow = logits[0, -1, 0...]
        eval(lastRow)
        let values = lastRow.asArray(Float.self)
        let count = min(values.count, vocabularySize)
        return (0..<count).map {
            TokenLogit(tokenID: TokenID($0), logit: values[$0])
        }
    }

    private static func hasPrefix(_ tokens: [Int32], _ prefix: [Int32]) -> Bool {
        prefix.count <= tokens.count && tokens.starts(with: prefix)
    }
}

public enum MLXRuntimeError: Error, Equatable, CustomStringConvertible {
    case emptyPrepareResult
    case invalidConstraintCount(suffixCount: Int, constraintCount: Int)
    case invalidTokenID(TokenID)
    case modelDirectoryMissing(String)
    case promptTooLong(promptTokens: Int, contextLength: Int)
    case runtimeNotPrepared
    case runtimeShutdown

    public var description: String {
        switch self {
        case .emptyPrepareResult:
            return "MLX model prepare returned no tokens or logits"
        case let .invalidConstraintCount(suffixCount, constraintCount):
            return "MLX ranked request has \(suffixCount) suffixes and \(constraintCount) constraints"
        case let .invalidTokenID(tokenID):
            return "MLX runtime token ID is out of range: \(tokenID)"
        case let .modelDirectoryMissing(path):
            return "MLX model directory is missing: \(path)"
        case let .promptTooLong(promptTokens, contextLength):
            return "MLX prompt has \(promptTokens) tokens; context limit is \(contextLength)"
        case .runtimeNotPrepared:
            return "MLX runtime must be prepared before decoding"
        case .runtimeShutdown:
            return "MLX runtime has been shut down"
        }
    }
}
