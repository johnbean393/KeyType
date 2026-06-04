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
    /// When true, mid-line requests (non-empty `afterCursor`) are decoded with native
    /// fill-in-the-middle: the prompt is assembled as `<|fim_prefix|>{prefix}<|fim_suffix|>{suffix}
    /// <|fim_middle|>` so the model conditions on the suffix instead of colliding with it. Requires
    /// a model whose vocab has single-token FIM markers; otherwise the engine falls back to base
    /// continuation. See ADR-017.
    public var enableFillInMiddle: Bool
    /// Caret-ward window applied to the fill-in-the-middle *prefix*: only the last
    /// `fimMaxPrefixTokens` tokens (the text nearest the caret) are fed to the model. A long body of
    /// text otherwise blows the latency budget and dilutes the local join signal. `<= 0` disables
    /// the cap; the always-applied default is a large-but-finite window. See ADR-057.
    public var fimMaxPrefixTokens: Int
    /// Caret-ward window applied to the fill-in-the-middle *suffix*: only the first
    /// `fimMaxSuffixTokens` tokens (the text nearest the caret) are fed to the model. The suffix only
    /// needs enough to anchor the join. `<= 0` disables the cap. See ADR-057.
    public var fimMaxSuffixTokens: Int
    /// How many leading `afterCursor` tokens the suffix-likelihood rerank scores. The rerank measures
    /// how natural the real suffix is once a candidate's middle is inserted (a round-trip join
    /// score) and reorders candidates accordingly — it never suppresses. `<= 0` disables the rerank.
    /// See ADR-057.
    public var suffixRerankTokenCount: Int
    /// Weight of the mean per-token suffix-join log-probability added to a branch's cumulative score
    /// before final ranking. See ADR-057.
    public var suffixRerankWeight: Float

    public init(
        topK: Int = 64,
        topP: Float = 0.95,
        temperature: Float = 0.8,
        branchWidth: Int = 2,
        relativeCutoff: Float = 6,
        minBranchProbability: Float = 0.02,
        maxCandidates: Int = 5,
        enableFillInMiddle: Bool = false,
        fimMaxPrefixTokens: Int = 256,
        fimMaxSuffixTokens: Int = 64,
        suffixRerankTokenCount: Int = 3,
        suffixRerankWeight: Float = 1.0
    ) {
        self.topK = topK
        self.topP = topP
        self.temperature = temperature
        self.branchWidth = branchWidth
        self.relativeCutoff = relativeCutoff
        self.minBranchProbability = minBranchProbability
        self.maxCandidates = maxCandidates
        self.enableFillInMiddle = enableFillInMiddle
        self.fimMaxPrefixTokens = fimMaxPrefixTokens
        self.fimMaxSuffixTokens = fimMaxSuffixTokens
        self.suffixRerankTokenCount = suffixRerankTokenCount
        self.suffixRerankWeight = suffixRerankWeight
    }
}
