import AutocompleteCore

/// Optional runtime fast path for callers that only need a small ranked candidate set.
///
/// The protocol is deliberately separate from `LocalModelRuntime`, so existing backends and the
/// constrained engine keep their vocabulary-wide correctness path until a backend proves parity.
public protocol RankedLocalModelRuntime: LocalModelRuntime {
    func rankNextTokensBatch(
        anchor: [TokenID],
        suffixes: [[TokenID]],
        constraints: [RuntimeTokenConstraint],
        topK: Int
    ) async throws -> [[RankedToken]]
}

public struct RuntimeTokenConstraint: Equatable, Sendable {
    public var allowedTokenIDs: Set<TokenID>?
    public var biasByTokenID: [TokenID: Float]

    public init(
        allowedTokenIDs: Set<TokenID>? = nil,
        biasByTokenID: [TokenID: Float] = [:]
    ) {
        self.allowedTokenIDs = allowedTokenIDs
        self.biasByTokenID = biasByTokenID
    }
}

public struct RankedToken: Equatable, Sendable {
    public var tokenID: TokenID
    public var score: Float

    public init(tokenID: TokenID, score: Float) {
        self.tokenID = tokenID
        self.score = score
    }
}
