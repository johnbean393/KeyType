import AppCompatibility
import AutocompleteCore
import Foundation
import ModelRuntime
import TokenProfiles

public struct DecodingConfiguration: Equatable {
    public var topK: Int
    public var topP: Float
    public var temperature: Float
    public var branchWidth: Int
    public var relativeCutoff: Float

    public init(
        topK: Int = 64,
        topP: Float = 0.95,
        temperature: Float = 0.8,
        branchWidth: Int = 8,
        relativeCutoff: Float = 8
    ) {
        self.topK = topK
        self.topP = topP
        self.temperature = temperature
        self.branchWidth = branchWidth
        self.relativeCutoff = relativeCutoff
    }
}

public struct CandidateBranch: Equatable {
    public var tokenIDs: [TokenID]
    public var text: String
    public var score: Float
    public var displayWidth: Int

    public init(tokenIDs: [TokenID] = [], text: String = "", score: Float = 0, displayWidth: Int = 0) {
        self.tokenIDs = tokenIDs
        self.text = text
        self.score = score
        self.displayWidth = displayWidth
    }
}

public final class ConstrainedGenerationEngine: CompletionGenerating {
    private let runtime: LocalModelRuntime
    private let profile: AutocompleteProfile
    private let compatibilityStore: AppCompatibilityStore
    private let configuration: DecodingConfiguration

    public init(
        runtime: LocalModelRuntime,
        profile: AutocompleteProfile,
        compatibilityStore: AppCompatibilityStore = AppCompatibilityStore(),
        configuration: DecodingConfiguration = DecodingConfiguration()
    ) {
        self.runtime = runtime
        self.profile = profile
        self.compatibilityStore = compatibilityStore
        self.configuration = configuration
    }

    public func completions(for request: CompletionRequest) async throws -> [CompletionCandidate] {
        let policy = compatibilityStore.policy(for: request.context.target)
        guard policy.isCompletionEnabled else {
            return []
        }
        guard policy.allowsMidLineCompletion || request.context.afterCursor.isEmpty else {
            return []
        }

        let promptTokens = try runtime.tokenizer.tokenize(request.prompt)
        try await runtime.prepare(promptTokens: promptTokens)

        var branches = [CandidateBranch()]

        for _ in 0..<request.maxCompletionTokens {
            let logits = try await runtime.logitsForNextToken()
            guard !logits.isEmpty else {
                break
            }

            let ranked = logits
                .filter { !profile.isExcluded($0.tokenID, mode: request.mode) }
                .filter { profile.tokenAllowed($0.tokenID, afterRequiredPrefix: request.requiredPrefixBytes) }
                .map { logit in
                    TokenLogit(
                        tokenID: logit.tokenID,
                        logit: logit.logit + profile.bias(for: logit.tokenID, mode: request.mode)
                    )
                }
                .sorted { $0.logit > $1.logit }
                .prefix(max(1, min(configuration.branchWidth, configuration.topK)))

            guard let next = ranked.first else {
                break
            }

            try await runtime.decodeNext(tokenID: next.tokenID)
            let bytesText = try runtime.tokenizer.detokenize([next.tokenID])
            let width = profile.displayWidth(for: next.tokenID)

            branches = branches.map {
                CandidateBranch(
                    tokenIDs: $0.tokenIDs + [next.tokenID],
                    text: $0.text + bytesText,
                    score: $0.score + next.logit,
                    displayWidth: $0.displayWidth + max(width, bytesText.count)
                )
            }

            if branches.contains(where: { $0.displayWidth > request.maxDisplayWidth }) {
                break
            }
            if profile.stopBehavior(for: next.tokenID) != .continueGeneration {
                break
            }
        }

        return branches
            .filter { !$0.text.isEmpty && $0.displayWidth <= request.maxDisplayWidth }
            .map {
                CompletionCandidate(
                    text: $0.text,
                    tokenIDs: $0.tokenIDs,
                    logProbability: Double($0.score),
                    displayWidth: $0.displayWidth,
                    mode: request.mode
                )
            }
    }
}
