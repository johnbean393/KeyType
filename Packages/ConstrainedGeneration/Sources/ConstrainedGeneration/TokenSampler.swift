import AutocompleteCore
import Foundation
import ModelRuntime
import TokenProfiles

/// A single admissible next-token candidate after masking, biasing, temperature, and
/// top-k / top-p shaping. `probability` is the softmax probability over the admissible
/// (post-bias, post-temperature) distribution; `logProbability` is its natural log and is
/// what the engine accumulates into a branch's cumulative score.
struct RankedToken: Equatable {
    var tokenID: TokenID
    var probability: Float
    var logProbability: Float
}

/// The outcome of ranking one position: the admissible candidate pool plus the model's single
/// most-likely next token over the *whole* (pre-exclusion) distribution. The engine uses the
/// argmax to decide whether the model "wants" to stop here (EOS/EOT/stop as the top choice).
struct SamplerResult: Equatable {
    var tokens: [RankedToken]
    var argmaxTokenID: TokenID?

    static let empty = SamplerResult(tokens: [], argmaxTokenID: nil)
}

/// Pure transformation from raw next-token logits to a ranked, admissible candidate pool.
///
/// Order of operations: drop excluded + inadmissible tokens, add the profile's static/mode
/// bias, divide by temperature, softmax over the surviving set, then top-k, top-p (nucleus),
/// and finally a `minBranchProbability` floor. Deterministic — no RNG (see ADR-010).
enum TokenSampler {
    static func rank(
        logits: [TokenLogit],
        mode: CompletionMode,
        profile: AutocompleteProfile,
        configuration: DecodingConfiguration,
        isAdmissible: (TokenID) -> Bool
    ) -> SamplerResult {
        guard !logits.isEmpty else { return .empty }
        let temperature = max(configuration.temperature, 1e-3)

        // 0. Pre-select the highest raw-logit tokens. Running the profile lookups + softmax over
        //    the full vocabulary (150k+ tokens) per branch is the dominant cost; the surviving
        //    candidate pool only ever needs `topK` entries, so restrict the expensive work to a
        //    generous multiple of that. For small vocabularies (unit tests) this keeps every
        //    token, leaving behaviour identical. Pre-selection ignores per-token bias, which for
        //    the real profile is static and small relative to the logit spread — a token far down
        //    the raw-logit ranking cannot realistically be biased into the top-k.
        let preselectCount = min(logits.count, max(configuration.topK * 4, 256))
        let candidates = preselectCount < logits.count
            ? topByLogit(logits, count: preselectCount)
            : logits

        // 1. Mask + bias + temperature-scale the admissible tokens. The global argmax (over the
        //    pre-exclusion candidates, which include EOS/EOT/stop) is tracked here so the engine
        //    doesn't need a second full pass over the logits to detect a "stop here" signal.
        //    Because `candidates` are the highest-logit tokens, their max is the true global max.
        var scaled: [(tokenID: TokenID, value: Float)] = []
        scaled.reserveCapacity(candidates.count)
        var maxValue = -Float.greatestFiniteMagnitude
        var argmaxTokenID: TokenID?
        var argmaxLogit = -Float.greatestFiniteMagnitude
        for logit in candidates {
            let id = logit.tokenID
            if logit.logit > argmaxLogit {
                argmaxLogit = logit.logit
                argmaxTokenID = id
            }
            if profile.isExcluded(id, mode: mode) { continue }
            if !isAdmissible(id) { continue }
            let value = (logit.logit + profile.bias(for: id, mode: mode)) / temperature
            scaled.append((id, value))
            if value > maxValue { maxValue = value }
        }
        guard !scaled.isEmpty else { return SamplerResult(tokens: [], argmaxTokenID: argmaxTokenID) }

        // 2. Softmax over the admissible set (max-shift for numerical stability).
        var expSum: Float = 0
        var exps = [Float](repeating: 0, count: scaled.count)
        for i in scaled.indices {
            let e = Foundation.exp(scaled[i].value - maxValue)
            exps[i] = e
            expSum += e
        }
        guard expSum > 0 else { return SamplerResult(tokens: [], argmaxTokenID: argmaxTokenID) }

        var ranked: [RankedToken] = scaled.indices.map { i in
            let p = exps[i] / expSum
            return RankedToken(tokenID: scaled[i].tokenID, probability: p, logProbability: Foundation.log(p))
        }

        // 3. Highest probability first (tie-break by token id for determinism).
        ranked.sort { lhs, rhs in
            lhs.probability != rhs.probability
                ? lhs.probability > rhs.probability
                : lhs.tokenID < rhs.tokenID
        }

        // 4. top-k.
        if configuration.topK > 0 && ranked.count > configuration.topK {
            ranked.removeLast(ranked.count - configuration.topK)
        }

        // 5. top-p (nucleus) — always keep at least the single best.
        if configuration.topP < 1 {
            var cumulative: Float = 0
            var cutoff = ranked.count
            for (i, token) in ranked.enumerated() {
                cumulative += token.probability
                if cumulative >= configuration.topP {
                    cutoff = i + 1
                    break
                }
            }
            if cutoff < ranked.count {
                ranked.removeLast(ranked.count - cutoff)
            }
        }

        // 6. minBranchProbability floor (keep at least the best so a sharp distribution
        //    still yields a candidate).
        if configuration.minBranchProbability > 0 && ranked.count > 1 {
            let kept = ranked.prefix { $0.probability >= configuration.minBranchProbability }
            ranked = kept.isEmpty ? Array(ranked.prefix(1)) : Array(kept)
        }

        return SamplerResult(tokens: ranked, argmaxTokenID: argmaxTokenID)
    }

    /// Returns the `count` highest-`logit` entries (in arbitrary order) using a bounded
    /// min-heap, so the full vocabulary is scanned once in O(n log count) without sorting it.
    private static func topByLogit(_ logits: [TokenLogit], count: Int) -> [TokenLogit] {
        var heap = [TokenLogit]()
        heap.reserveCapacity(count)

        func siftUp(_ start: Int) {
            var child = start
            while child > 0 {
                let parent = (child - 1) / 2
                if heap[child].logit < heap[parent].logit {
                    heap.swapAt(child, parent)
                    child = parent
                } else {
                    break
                }
            }
        }

        func siftDown(_ start: Int) {
            var parent = start
            let n = heap.count
            while true {
                let left = 2 * parent + 1
                let right = 2 * parent + 2
                var smallest = parent
                if left < n && heap[left].logit < heap[smallest].logit { smallest = left }
                if right < n && heap[right].logit < heap[smallest].logit { smallest = right }
                if smallest == parent { break }
                heap.swapAt(parent, smallest)
                parent = smallest
            }
        }

        for logit in logits {
            if heap.count < count {
                heap.append(logit)
                siftUp(heap.count - 1)
            } else if logit.logit > heap[0].logit {
                heap[0] = logit
                siftDown(0)
            }
        }
        return heap
    }
}
