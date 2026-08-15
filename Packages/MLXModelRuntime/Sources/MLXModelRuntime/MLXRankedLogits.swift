import AutocompleteCore
import ModelRuntime

/// Correctness-first ranking over materialized logits. The public seam lets a future MLX
/// implementation replace this helper with device-side masking, log-softmax, and top-k without
/// changing callers.
enum MLXRankedLogits {
    static func rank(
        logits: [TokenLogit],
        constraint: RuntimeTokenConstraint,
        topK: Int
    ) -> [RankedToken] {
        let ranked = logits.compactMap { logit -> RankedToken? in
            if let allowed = constraint.allowedTokenIDs,
               !allowed.contains(logit.tokenID)
            {
                return nil
            }
            let score = logit.logit + (constraint.biasByTokenID[logit.tokenID] ?? 0)
            guard score.isFinite else { return nil }
            return RankedToken(tokenID: logit.tokenID, score: score)
        }
        .sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.tokenID < $1.tokenID
        }
        return topK > 0 ? Array(ranked.prefix(topK)) : ranked
    }
}
