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
        let effectiveBranchWidth = effectiveBranchWidth(for: request)

        depthLoop: for _ in 0..<maxDepth {
            try Task.checkCancellation()
            if live.isEmpty { break }

            // Batched beam-frontier expansion (ADR-043): score every live branch in ONE runtime
            // call. `LlamaModelRuntime` seeds each branch into its own sequence (a copy of the
            // resident anchor — ADR-018) and advances them all in a single `llama_decode`, instead
            // of one GPU round-trip per branch. The default protocol extension loops, so stub-backed
            // tests behave identically. Results come back in the same order as `live`.
            let frontierLogits = try await runtime.anchoredLogitsBatch(
                anchor: basePrompt,
                suffixes: live.map(\.tokenIDs)
            )

            var nextLive: [GenerationBranch] = []
            for (branch, logits) in zip(live, frontierLogits) {
                try Task.checkCancellation()

                guard !logits.isEmpty else {
                    finalizeIfValid(branch, into: &finalized)
                    continue
                }

                let result = TokenSampler.rank(
                    logits: logits,
                    mode: request.mode,
                    profile: profile,
                    configuration: configuration,
                    // A still-unsatisfied required prefix forces a specific continuation that may rank
                    // far below the model's globally top tokens; bypass raw-logit pre-selection so the
                    // admissible tokens aren't masked out and the branch can't silently collapse to
                    // `noCandidate` (ADR-025).
                    constrained: !branch.remainingPrefix.isEmpty,
                    // Decode-time repetition penalty is scoped to this branch's own emitted tokens, so
                    // a degenerate loop is demoted in favour of a non-repeating sibling. Suppressed
                    // while a required prefix is still being satisfied (mid-word healing, ADR-019): that
                    // path forces a specific continuation that may legitimately repeat an earlier token,
                    // and demoting it would collapse the only admissible branch. Inert unless the
                    // penalties are configured (see DecodingConfiguration.presencePenalty).
                    recentTokens: branch.remainingPrefix.isEmpty ? branch.tokenIDs : [],
                    isAdmissible: { self.tokenAllowed($0, afterRequiredPrefix: branch.remainingPrefix) }
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
                        // Drop branches that splice a garbage symbol into the open word or pile up
                        // punctuation ("gre" → "at$", "...."); a clean branch can then win the beam
                        // instead of the controller suppressing the corrupted best candidate (ADR-052).
                        if MidWordCharsetGuard.violates(completion: child.text, request: request) {
                            continue
                        }
                        // Drop healed mid-word branches that complete the forced stem as a separate
                        // word and would display as a glued insert after `MidWordHealing.strip`.
                        if MidWordBoundaryGuard.violates(completion: child.text, request: request) {
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

            live = prune(nextLive, branchWidth: effectiveBranchWidth)
            if shouldStopEarly(finalized: finalized, live: live, request: request) {
                break depthLoop
            }
        }

        // Branches still alive at the depth cap are valid candidates too.
        for branch in live {
            finalizeIfValid(branch, into: &finalized)
        }

        // Mid-line / FIM branches that reproduce the text already after the caret are no longer just
        // discarded: a branch that emits a genuine "middle" and *then* runs into the suffix is
        // salvaged by truncating it at the overlap point, so the real fill survives instead of the
        // whole branch being thrown away. A branch that is a suffix copy from the very start (or whose
        // salvaged middle is too short / still duplicative) is dropped — identical to the old
        // behaviour: show nothing. The `DefaultCandidateFilter` re-checks duplication as the
        // documented last gate. See ADR-049 / ADR-057.
        let surviving = finalized.compactMap { branch in
            salvagedBranch(branch, request: request)
        }

        // Reorder by how naturally the real suffix continues after each candidate's middle (a
        // round-trip "join" score). Reorder-only: it never drops a candidate, and it is a no-op when
        // the runtime returns no logits (every stub-backed test). See ADR-057.
        let reranked = try await rerankBySuffixLikelihood(surviving, request: request)

        return rerankHealedMidWordClosedContinuations(
            makeCandidates(from: reranked, mode: request.mode),
            request: request
        )
    }

    /// Minimum grapheme length a salvaged (truncated) middle must have to be worth showing. Mirrors
    /// `SuffixOverlapGuard`'s `minimumOverlap` so a 1-2 character fragment left in front of the
    /// duplicated suffix is dropped rather than inserted.
    private static let minimumSalvagedMiddleLength = 3

    /// Returns `branch` unchanged when it does not duplicate the suffix; the truncated "middle" when
    /// the branch runs into the suffix but emitted a substantial fill first; or `nil` when there is
    /// nothing safe to keep (drop it — show nothing).
    private func salvagedBranch(_ branch: GenerationBranch, request: CompletionRequest) -> GenerationBranch? {
        guard let keepCharacters = SuffixOverlapGuard.nonDuplicatingPrefixLength(
            completion: branch.text,
            beforeCursor: request.context.beforeCursor,
            afterCursor: request.context.afterCursor
        ) else {
            return branch // no overlap — keep as is
        }
        let truncated = branch.truncatedToText(prefixCharCount: keepCharacters)
        guard truncated.text.count >= Self.minimumSalvagedMiddleLength,
              !SuffixOverlapGuard.duplicatesSuffix(
                  completion: truncated.text,
                  beforeCursor: request.context.beforeCursor,
                  afterCursor: request.context.afterCursor
              )
        else { return nil }
        return truncated
    }

    /// Pre-decodes the fixed request anchor without expanding any candidate branches. This warms
    /// Metal kernels and seeds the runtime's anchor snapshot so a later identical completion can
    /// start from cached root logits. It intentionally does not sample, filter, or return text.
    public func warmUp(for request: CompletionRequest) async throws {
        let policy = compatibilityStore.policy(for: request.context)
        guard policy.isCompletionEnabled else { return }
        guard policy.allowsMidLineCompletion || request.context.afterCursor.isEmpty else { return }
        guard policy.allowsTabAcceptance else { return }
        guard request.maxCompletionTokens > 0 else { return }

        let (basePrompt, _) = try makeBasePrompt(for: request)
        try Task.checkCancellation()
        _ = try await runtime.anchoredLogitsBatch(anchor: basePrompt, suffixes: [[]])
        try Task.checkCancellation()
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
        guard configuration.enableFillInMiddle,
              !request.context.afterCursor.isEmpty,
              !request.context.geometry.isAtEndOfLine
        else { return nil }
        let tokenizer = runtime.tokenizer
        let pre = try tokenizer.tokenizeAllowingSpecial(Self.fimPrefixMarker)
        let suf = try tokenizer.tokenizeAllowingSpecial(Self.fimSuffixMarker)
        let mid = try tokenizer.tokenizeAllowingSpecial(Self.fimMiddleMarker)
        // A model without trained FIM tokens splits the markers into several literal tokens — that
        // is the signal to fall back rather than feed it angle-bracket text it can't use.
        guard pre.count == 1, suf.count == 1, mid.count == 1 else { return nil }

        let prefixText = Self.trimmingTrailingWhitespace(request.context.beforeCursor)
        // Window the context toward the caret so a long body of text neither blows the latency budget
        // nor dilutes the local join signal: keep the prefix *tail* and the suffix *head* (the bytes
        // nearest the caret). A context already under the cap is fed verbatim. See ADR-057.
        let prefix = Self.keepingLast(configuration.fimMaxPrefixTokens, of: try tokenizer.tokenize(prefixText))
        let suffix = Self.keepingFirst(configuration.fimMaxSuffixTokens, of: try tokenizer.tokenize(request.context.afterCursor))
        return (pre + prefix + suf + suffix + mid, String(prefixText.suffix(32)))
    }

    /// Keep at most the last `limit` tokens (the tail nearest the caret); `limit <= 0` keeps all.
    static func keepingLast(_ limit: Int, of tokens: [TokenID]) -> [TokenID] {
        guard limit > 0, tokens.count > limit else { return tokens }
        return Array(tokens.suffix(limit))
    }

    /// Keep at most the first `limit` tokens (the head nearest the caret); `limit <= 0` keeps all.
    static func keepingFirst(_ limit: Int, of tokens: [TokenID]) -> [TokenID] {
        guard limit > 0, tokens.count > limit else { return tokens }
        return Array(tokens.prefix(limit))
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

    private func tokenAllowed(_ id: TokenID, afterRequiredPrefix prefix: [UInt8]) -> Bool {
        guard !prefix.isEmpty else { return true }
        guard let mmapProfile = profile as? MmapAutocompleteProfile else {
            return profile.tokenAllowed(id, afterRequiredPrefix: prefix)
        }
        return mmapProfile.withRawBytes(for: id) { tokenBytes in
            Self.bytes(tokenBytes, startsWith: prefix) || Self.bytes(prefix, startsWith: tokenBytes)
        } ?? false
    }

    private static func bytes(_ lhs: UnsafeRawBufferPointer, startsWith rhs: [UInt8]) -> Bool {
        guard rhs.count <= lhs.count else { return false }
        for index in rhs.indices where lhs[index] != rhs[index] { return false }
        return true
    }

    private static func bytes(_ lhs: [UInt8], startsWith rhs: UnsafeRawBufferPointer) -> Bool {
        guard rhs.count <= lhs.count else { return false }
        for index in 0..<rhs.count where lhs[index] != rhs[index] { return false }
        return true
    }

    private func finalizeIfValid(_ branch: GenerationBranch, into finalized: inout [GenerationBranch]) {
        if branch.isCompleteAndValid {
            finalized.append(branch)
        }
    }

    /// Keep the highest-scoring branches within the relative-cutoff margin and beam width.
    private func prune(_ branches: [GenerationBranch], branchWidth: Int) -> [GenerationBranch] {
        guard !branches.isEmpty else { return [] }
        var sorted = branches.sorted { $0.score > $1.score }
        let best = sorted[0].score
        sorted = sorted.filter { best - $0.score <= configuration.relativeCutoff }
        if branchWidth > 0 && sorted.count > branchWidth {
            sorted.removeLast(sorted.count - branchWidth)
        }
        return sorted
    }

    /// Proper-noun mid-word completions need one extra branch because the model often keeps several
    /// plausible capitalized continuations alive before the correct possessive/name form wins.
    private func effectiveBranchWidth(for request: CompletionRequest) -> Int {
        let configured = configuration.branchWidth
        guard configured >= 2 else { return configured }
        guard request.mode == .prose || request.mode == .correction else { return configured }
        guard !request.requiredPrefixBytes.isEmpty else { return configured }
        let stem = CurrentWordTypoGuard.trailingWord(of: request.context.beforeCursor)
        guard Self.startsWithUppercaseLetter(stem) else { return configured }
        return max(configured, 3)
    }

    private static func startsWithUppercaseLetter(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        let scalar = String(first)
        return scalar.rangeOfCharacter(from: .letters) != nil
            && scalar == scalar.uppercased()
            && scalar != scalar.lowercased()
    }

    /// Future token log-probabilities are never positive, so a live branch's current score is an
    /// upper bound for every completion it can still produce. Once the finalized top-N unique,
    /// suffix-safe branches all strictly beat that upper bound, no later branch can change the
    /// returned candidate set or order.
    private func shouldStopEarly(
        finalized: [GenerationBranch],
        live: [GenerationBranch],
        request: CompletionRequest
    ) -> Bool {
        let candidateLimit = max(0, configuration.maxCandidates)
        guard candidateLimit > 0, !finalized.isEmpty, !live.isEmpty else { return false }

        var bestByText: [String: GenerationBranch] = [:]
        for branch in finalized {
            guard !SuffixOverlapGuard.duplicatesSuffix(
                completion: branch.text,
                beforeCursor: request.context.beforeCursor,
                afterCursor: request.context.afterCursor
            ) else { continue }
            if let existing = bestByText[branch.text], existing.score >= branch.score { continue }
            bestByText[branch.text] = branch
        }

        let locked = bestByText.values.sorted { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.text < rhs.text
        }
        guard locked.count >= candidateLimit,
              let bestLiveScore = live.map(\.score).max()
        else { return false }

        return locked[candidateLimit - 1].score > bestLiveScore
    }

    // MARK: - Suffix-likelihood rerank (round-trip join score, ADR-057)

    /// Reorders mid-line candidates by how natural the *real* suffix is once each candidate's middle
    /// is inserted: a clean fill makes the upcoming `afterCursor` tokens cheap; a derailing one makes
    /// them expensive. Adds the mean per-token join log-probability (weighted) to a copy of each
    /// branch's score so `makeCandidates` ranks by it.
    ///
    /// Strictly reorder-only — it never drops a candidate — and a guaranteed no-op when the runtime
    /// returns no logits (stub/recording runtimes), so existing deterministic tests are unaffected.
    private func rerankBySuffixLikelihood(
        _ branches: [GenerationBranch],
        request: CompletionRequest
    ) async throws -> [GenerationBranch] {
        guard configuration.suffixRerankTokenCount > 0,
              !request.context.afterCursor.isEmpty,
              branches.count > 1
        else { return branches }

        let suffixTokens = Array(
            ((try? runtime.tokenizer.tokenize(request.context.afterCursor)) ?? [])
                .prefix(configuration.suffixRerankTokenCount)
        )
        guard !suffixTokens.isEmpty else { return branches }

        let trimmedPrefix = Self.trimmingTrailingWhitespace(request.context.beforeCursor)
        var joinAnchors: [(branchIndex: Int, tokens: [TokenID])] = []
        joinAnchors.reserveCapacity(branches.count)
        for (index, branch) in branches.enumerated() {
            try Task.checkCancellation()
            guard let tokens = try? runtime.tokenizer.tokenize(trimmedPrefix + branch.text),
                  !tokens.isEmpty
            else { continue }
            joinAnchors.append((branchIndex: index, tokens: tokens))
        }
        guard !joinAnchors.isEmpty else { return branches }

        let sharedAnchor = Self.commonTokenPrefix(joinAnchors.map(\.tokens))
        let candidateTails = joinAnchors.map { Array($0.tokens.dropFirst(sharedAnchor.count)) }
        var totals = Array(repeating: Float(0), count: branches.count)
        var counts = Array(repeating: 0, count: branches.count)
        for suffixIndex in suffixTokens.indices {
            try Task.checkCancellation()
            let suffixPrefix = Array(suffixTokens.prefix(suffixIndex))
            let probeSuffixes = candidateTails.map { $0 + suffixPrefix }
            let frontier = try await runtime.anchoredLogitsBatch(anchor: sharedAnchor, suffixes: probeSuffixes)
            guard frontier.count == joinAnchors.count else { return branches }

            let target = suffixTokens[suffixIndex]
            for (join, logits) in zip(joinAnchors, frontier) {
                guard let logProbability = Self.logProbability(of: target, in: logits) else { continue }
                totals[join.branchIndex] += logProbability
                counts[join.branchIndex] += 1
            }
        }

        var result = branches
        for index in result.indices where counts[index] > 0 {
            result[index].score += configuration.suffixRerankWeight * (totals[index] / Float(counts[index]))
        }
        return result
    }

    static func commonTokenPrefix(_ sequences: [[TokenID]]) -> [TokenID] {
        guard var prefix = sequences.first else { return [] }
        for sequence in sequences.dropFirst() {
            let count = Swift.min(prefix.count, sequence.count)
            var index = 0
            while index < count, prefix[index] == sequence[index] {
                index += 1
            }
            if index < prefix.count {
                prefix.removeSubrange(index..<prefix.count)
            }
            if prefix.isEmpty { break }
        }
        return prefix
    }

    /// Exact log-softmax probability of `token` from a full-vocabulary logits vector, or `nil` when
    /// the vector is empty or does not contain `token` (so the caller can treat it as "unmeasured").
    static func logProbability(of token: TokenID, in logits: [TokenLogit]) -> Float? {
        guard !logits.isEmpty else { return nil }
        var maxLogit = -Float.greatestFiniteMagnitude
        var targetLogit: Float?
        for entry in logits {
            if entry.logit > maxLogit { maxLogit = entry.logit }
            if entry.tokenID == token { targetLogit = entry.logit }
        }
        guard let target = targetLogit else { return nil }
        var sumExp: Float = 0
        for entry in logits { sumExp += expf(entry.logit - maxLogit) }
        guard sumExp > 0 else { return nil }
        return target - (maxLogit + logf(sumExp))
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

    /// Reorder-only tie-break for healed mid-word requests. If a high-scoring branch leaves a long
    /// current-word fragment open at the token cap (`" dera"` -> `"licious"`), prefer an already
    /// generated branch that reaches a word boundary (`" deranged and"`). Short suffixes stay put so
    /// useful completions such as `"tion"` are not hidden when they are the best available option.
    private func rerankHealedMidWordClosedContinuations(
        _ candidates: [CompletionCandidate],
        request: CompletionRequest
    ) -> [CompletionCandidate] {
        guard candidates.count > 1 else { return candidates }
        guard request.mode == .prose || request.mode == .correction else { return candidates }
        guard !request.requiredPrefixBytes.isEmpty else { return candidates }
        guard !CurrentWordTypoGuard.trailingWord(of: request.context.beforeCursor).isEmpty else {
            return candidates
        }

        let heal = String(decoding: request.requiredPrefixBytes, as: UTF8.self)
        let classes = candidates.map { Self.midWordContinuationClass($0.text, heal: heal) }
        guard classes.contains(.closed) else { return candidates }
        guard classes.contains(.longOpen) else { return candidates }

        return zip(candidates.indices, candidates).sorted { lhs, rhs in
            let lhsClass = classes[lhs.0]
            let rhsClass = classes[rhs.0]
            if lhsClass.priority != rhsClass.priority {
                return lhsClass.priority > rhsClass.priority
            }
            return lhs.0 < rhs.0
        }.map(\.1)
    }

    private enum MidWordContinuationClass: Equatable {
        case closed
        case shortOpen
        case longOpen
        case boundaryOrEmpty

        var priority: Int {
            switch self {
            case .closed: return 3
            case .shortOpen: return 2
            case .boundaryOrEmpty: return 1
            case .longOpen: return 0
            }
        }
    }

    private static func midWordContinuationClass(_ text: String, heal: String) -> MidWordContinuationClass {
        let continuation = MidWordHealing.strip(text, heal: heal)
        let lead = CurrentWordTypoGuard.leadingWord(of: continuation)
        guard !lead.isEmpty else { return .boundaryOrEmpty }
        if lead.count < continuation.count { return .closed }
        if lead.contains("'") || lead.contains("\u{2019}") { return .closed }
        return lead.count >= 5 ? .longOpen : .shortOpen
    }
}
