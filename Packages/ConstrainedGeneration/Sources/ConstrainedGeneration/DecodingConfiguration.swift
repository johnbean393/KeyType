import Foundation

/// Tunables for the constrained multi-branch decoder (see ADR-010).
///
/// Expansion is deterministic best-first (a beam ordered by cumulative log-probability),
/// not stochastic sampling: `temperature` / `topK` / `topP` only *shape the candidate pool*
/// considered at each step. This keeps autocomplete reproducible and testable while still
/// honouring the usual sampling knobs.
public struct DecodingConfiguration: Equatable {
    /// Keep at most this many highest-probability tokens per expansion step.
    public var topK: Int
    /// Nucleus threshold: keep the smallest set of tokens whose cumulative probability
    /// reaches `topP` (after temperature + top-k).
    public var topP: Float
    /// Softens (`> 1`) or sharpens (`< 1`) the logit distribution before ranking. Must be `> 0`.
    public var temperature: Float
    /// Maximum number of live branches carried between steps (beam width).
    public var branchWidth: Int
    /// Cumulative-logprob margin used to prune branches: a branch is dropped when
    /// `bestScore - branchScore > relativeCutoff` (scores are cumulative log-probabilities,
    /// so larger is better and the difference is non-negative).
    public var relativeCutoff: Float
    /// Per-step probability floor. A candidate token whose (post-temperature, in-nucleus)
    /// probability is below this is not used to extend a branch.
    public var minBranchProbability: Float
    /// Upper bound on the number of finalized candidates returned to the caller.
    public var maxCandidates: Int

    public init(
        topK: Int = 64,
        topP: Float = 0.95,
        temperature: Float = 0.8,
        branchWidth: Int = 4,
        relativeCutoff: Float = 6,
        minBranchProbability: Float = 0.02,
        maxCandidates: Int = 5
    ) {
        self.topK = topK
        self.topP = topP
        self.temperature = temperature
        self.branchWidth = branchWidth
        self.relativeCutoff = relativeCutoff
        self.minBranchProbability = minBranchProbability
        self.maxCandidates = maxCandidates
    }
}
