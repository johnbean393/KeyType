import MLXLMCommon
import ModelRuntime

/// A private, copyable snapshot of one MLX sequence.
///
/// `KVCache` values are reference-backed and mutable. Keeping the copy operation here makes
/// branch isolation explicit: scoring one suffix can never mutate the anchor or a sibling branch.
struct MLXBranchCache {
    var tokens: [Int32]
    var cache: [any KVCache]
    var state: LMOutput.State?
    var logits: [TokenLogit]

    func copied() -> MLXBranchCache {
        MLXBranchCache(
            tokens: tokens,
            cache: cache.map { $0.copy() },
            state: state,
            logits: logits
        )
    }
}
