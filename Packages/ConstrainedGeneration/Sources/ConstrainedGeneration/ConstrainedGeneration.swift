import AppCompatibility
import AutocompleteCore
import Foundation
import ModelRuntime
import TokenProfiles

/// Real constrained, multi-branch decoder (M5, see ADR-010).
///
/// The engine drives the `LocalModelRuntime` protocol — to score a branch it asks for
/// `anchoredLogits(anchor: basePrompt, suffix: branchTokens)`, which keeps `basePrompt` resident
/// and decodes only the branch's divergent suffix (ADR-018). Search is a deterministic best-first beam ordered by
/// cumulative log-probability; `temperature` / `topK` / `topP` shape the per-step candidate
/// pool (no RNG). Admissibility (required prefix + byte/trie constraints) and token policy
/// (exclusions, bias, stop behaviour, display width) come from the `AutocompleteProfile`, so the
/// engine works identically against the in-memory and the memory-mapped ACPF profile.
public final class ConstrainedGenerationEngine: CompletionGenerating {
    private let runtime: LocalModelRuntime
    private let profile: AutocompleteProfile
    private let compatibilityStore: AppCompatibilityStore
    private let configuration: DecodingConfiguration
    private let wordRecognizer: WordRecognizing?

    public init(
        runtime: LocalModelRuntime,
        profile: AutocompleteProfile,
        compatibilityStore: AppCompatibilityStore = AppCompatibilityStore(),
        configuration: DecodingConfiguration = DecodingConfiguration(),
        wordRecognizer: WordRecognizing? = nil
    ) {
        self.runtime = runtime
        self.profile = profile
        self.compatibilityStore = compatibilityStore
        self.configuration = configuration
        self.wordRecognizer = wordRecognizer
    }

    /// Tear down the underlying runtime, releasing any native model/GPU resources. Call before the
    /// process exits; the engine is inert afterwards. See ADR-021.
    public func shutdown() async {
        await runtime.shutdown()
    }

    public func completions(for request: CompletionRequest) async throws -> [CompletionCandidate] {
        let policy = compatibilityStore.policy(for: request.context)
        guard policy.isCompletionEnabled else { return [] }
        guard policy.allowsMidLineCompletion || request.context.afterCursor.isEmpty else { return [] }
        guard policy.allowsTabAcceptance else { return [] }

        let (basePrompt, promptTail) = try makeBasePrompt(for: request)

        // Drops branches whose current word completes into a misspelling, mid-search, so the beam
        // keeps exploring correctly-spelled continuations instead (see ADR-015 / CurrentWordTypoGuard).
        let typoGuard = CurrentWordTypoGuard(recognizer: wordRecognizer, request: request)

        var live = [GenerationBranch(requiredPrefix: request.requiredPrefixBytes)]
        var finalized: [GenerationBranch] = []
        let maxDepth = max(0, request.maxCompletionTokens)

        depthLoop: for _ in 0..<maxDepth {
            try Task.checkCancellation()
            if live.isEmpty { break }

            var nextLive: [GenerationBranch] = []
            for branch in live {
                try Task.checkCancellation()

                // Anchored reuse (ADR-018): the base prompt is decoded once and kept resident; each
                // branch only decodes its own divergent suffix. Across keystrokes the anchor grows
                // by the typed tokens, so steady-state typing decodes only the typed delta.
                let logits = try await runtime.anchoredLogits(anchor: basePrompt, suffix: branch.tokenIDs)
                guard !logits.isEmpty else {
                    finalizeIfValid(branch, into: &finalized)
                    continue
                }

                let result = TokenSampler.rank(
                    logits: logits,
                    mode: request.mode,
                    profile: profile,
                    configuration: configuration,
                    isAdmissible: { profile.tokenAllowed($0, afterRequiredPrefix: branch.remainingPrefix) }
                )

                // The model's single most likely continuation being a terminator is the
                // signal to stop this branch and keep what we have so far.
                if let top = result.argmaxTokenID, isHardStop(top) {
                    finalizeIfValid(branch, into: &finalized)
                    continue
                }
                if result.tokens.isEmpty {
                    finalizeIfValid(branch, into: &finalized)
                    continue
                }

                for token in result.tokens {
                    let id = token.tokenID
                    if isHardStop(id) { continue } // never displayed; argmax handles "stop here"

                    let tokenBytes = profileBytes(for: id)
                    let outcome = branch.extending(
                        withToken: id,
                        bytes: tokenBytes,
                        logProbability: token.logProbability,
                        maxDisplayWidth: request.maxDisplayWidth
                    )

                    switch outcome {
                    case .inadmissiblePrefix, .invalidUTF8, .overWidth:
                        continue // drop this extension
                    case let .extended(child):
                        // If this token just closed the word the user is completing and that word is
                        // a misspelling, drop the branch now — never finalise it and never spend
                        // further beam budget continuing from the wrong spelling.
                        if await typoGuard.shouldDrop(parentText: branch.text, childText: child.text) {
                            continue
                        }
                        switch profile.stopBehavior(for: id) {
                        case .stopAndDisplay:
                            // The sentence-end flag is context-free; only stop on a *real*
                            // boundary. A false one ("1.", "Mr.", "e.g.") keeps generating so we
                            // don't truncate a numbered list / abbreviation mid-thought.
                            if SentenceBoundary.isTerminal(promptTail + child.text) {
                                finalizeIfValid(child, into: &finalized)
                            } else {
                                nextLive.append(child)
                            }
                        case .stopAndSuppress:
                            continue
                        case .continueGeneration:
                            nextLive.append(child)
                        }
                    }
                }
            }

            live = prune(nextLive)
        }

        // Branches still alive at the depth cap are valid candidates too.
        for branch in live {
            finalizeIfValid(branch, into: &finalized)
        }

        return makeCandidates(from: finalized, mode: request.mode)
    }

    // MARK: - Prompt assembly

    static let fimPrefixMarker = "<|fim_prefix|>"
    static let fimSuffixMarker = "<|fim_suffix|>"
    static let fimMiddleMarker = "<|fim_middle|>"

    /// Returns the token sequence to decode plus a short text tail (for sentence-boundary checks).
    /// Uses native fill-in-the-middle for mid-line requests when enabled and supported by the
    /// model; otherwise tokenizes the caller-assembled `request.prompt` (base continuation).
    private func makeBasePrompt(for request: CompletionRequest) throws -> (tokens: [TokenID], tail: String) {
        if let fim = try fillInMiddlePrompt(for: request) {
            return fim
        }
        // A short tail of the prompt so sentence-boundary disambiguation can see context that
        // precedes the generated text (e.g. an abbreviation the prompt ends on).
        return (try runtime.tokenizer.tokenize(request.prompt), String(request.prompt.suffix(32)))
    }

    /// Assembles `<|fim_prefix|>{prefix}<|fim_suffix|>{suffix}<|fim_middle|>` from the raw context
    /// (not the scaffolded `request.prompt`). Returns `nil` — so the caller falls back to base
    /// continuation — when FIM is disabled, there is no suffix, or the model's vocab does not encode
    /// the markers as single tokens.
    private func fillInMiddlePrompt(for request: CompletionRequest) throws -> (tokens: [TokenID], tail: String)? {
        guard configuration.enableFillInMiddle, !request.context.afterCursor.isEmpty else { return nil }
        let tokenizer = runtime.tokenizer
        let pre = try tokenizer.tokenizeAllowingSpecial(Self.fimPrefixMarker)
        let suf = try tokenizer.tokenizeAllowingSpecial(Self.fimSuffixMarker)
        let mid = try tokenizer.tokenizeAllowingSpecial(Self.fimMiddleMarker)
        // A model without trained FIM tokens splits the markers into several literal tokens — that
        // is the signal to fall back rather than feed it angle-bracket text it can't use.
        guard pre.count == 1, suf.count == 1, mid.count == 1 else { return nil }

        let prefixText = Self.trimmingTrailingWhitespace(request.context.beforeCursor)
        let prefix = try tokenizer.tokenize(prefixText)
        let suffix = try tokenizer.tokenize(request.context.afterCursor)
        return (pre + prefix + suf + suffix + mid, String(prefixText.suffix(32)))
    }

    static func trimmingTrailingWhitespace(_ text: String) -> String {
        var view = Substring(text)
        while let last = view.last, last.isWhitespace { view = view.dropLast() }
        return String(view)
    }

    // MARK: - Helpers

    private func isHardStop(_ id: TokenID) -> Bool {
        if let eos = runtime.metadata.eosTokenID, id == eos { return true }
        if let eot = runtime.metadata.eotTokenID, id == eot { return true }
        return profile.stopBehavior(for: id) == .stopAndSuppress
    }

    private func profileBytes(for id: TokenID) -> [UInt8] {
        if let bytes = profile.record(for: id)?.bytes { return bytes }
        return (try? runtime.tokenizer.rawBytes(for: id)) ?? []
    }

    private func finalizeIfValid(_ branch: GenerationBranch, into finalized: inout [GenerationBranch]) {
        if branch.isCompleteAndValid {
            finalized.append(branch)
        }
    }

    /// Keep the highest-scoring branches within the relative-cutoff margin and beam width.
    private func prune(_ branches: [GenerationBranch]) -> [GenerationBranch] {
        guard !branches.isEmpty else { return [] }
        var sorted = branches.sorted { $0.score > $1.score }
        let best = sorted[0].score
        sorted = sorted.filter { best - $0.score <= configuration.relativeCutoff }
        if configuration.branchWidth > 0 && sorted.count > configuration.branchWidth {
            sorted.removeLast(sorted.count - configuration.branchWidth)
        }
        return sorted
    }

    /// Dedupe by emitted text (best score wins), rank, and cap to `maxCandidates`.
    private func makeCandidates(from branches: [GenerationBranch], mode: CompletionMode) -> [CompletionCandidate] {
        var bestByText: [String: GenerationBranch] = [:]
        for branch in branches {
            if let existing = bestByText[branch.text], existing.score >= branch.score { continue }
            bestByText[branch.text] = branch
        }

        let ordered = bestByText.values.sorted { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.text < rhs.text
        }

        return ordered.prefix(max(0, configuration.maxCandidates)).map { branch in
            CompletionCandidate(
                text: branch.text,
                tokenIDs: branch.tokenIDs,
                logProbability: Double(branch.score),
                displayWidth: branch.displayWidth,
                mode: mode
            )
        }
    }
}
