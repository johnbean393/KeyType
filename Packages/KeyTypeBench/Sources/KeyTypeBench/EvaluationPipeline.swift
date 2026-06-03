import AppCompatibility
import AutocompleteCore
import ConstrainedGeneration
import Foundation
import ModelRuntime
import Prompting
import TokenProfiles

public struct BenchmarkModelInfo: Codable, Equatable {
    public var identifier: String
    public var filename: String
    public var path: String?
    public var family: String?
    public var quantization: String?

    public init(
        identifier: String,
        filename: String,
        path: String? = nil,
        family: String? = nil,
        quantization: String? = nil
    ) {
        self.identifier = identifier
        self.filename = filename
        self.path = path
        self.family = family
        self.quantization = quantization
    }
}

public enum BenchmarkCompletionOutcome: String, Codable, Equatable {
    case correctInsert
    case acceptableSuppressionOnPositive
    case correctSuppression
    case incorrectSuppression
    case wrongShown
}

public struct BenchmarkRowResult: Codable, Equatable {
    public var schemaVersion: Int
    public var caseID: String
    public var split: BenchmarkSplit
    public var sourceGroup: String
    public var suites: [BenchmarkSuite]
    public var tags: [String]
    public var expectedKind: BenchmarkExpectedKind
    public var outcome: BenchmarkCompletionOutcome
    public var scoreContribution: Double
    public var modelIdentifier: String
    public var modelFilename: String
    public var modelPath: String?
    public var modelFamily: String?
    public var quantization: String?
    public var promptTokenCount: Int
    public var candidateCount: Int
    public var topCandidateText: String?
    public var topKCandidateTexts: [String]
    public var shownText: String?
    public var suppressionReason: String?
    public var generationAttempted: Bool
    public var promptBuildMs: Double
    public var generationMs: Double
    public var totalMs: Double

    public init(
        schemaVersion: Int = 1,
        caseID: String,
        split: BenchmarkSplit,
        sourceGroup: String,
        suites: [BenchmarkSuite],
        tags: [String],
        expectedKind: BenchmarkExpectedKind,
        outcome: BenchmarkCompletionOutcome,
        scoreContribution: Double,
        modelInfo: BenchmarkModelInfo,
        promptTokenCount: Int,
        candidateCount: Int,
        topCandidateText: String?,
        topKCandidateTexts: [String],
        shownText: String?,
        suppressionReason: String?,
        generationAttempted: Bool,
        promptBuildMs: Double,
        generationMs: Double,
        totalMs: Double
    ) {
        self.schemaVersion = schemaVersion
        self.caseID = caseID
        self.split = split
        self.sourceGroup = sourceGroup
        self.suites = suites
        self.tags = tags
        self.expectedKind = expectedKind
        self.outcome = outcome
        self.scoreContribution = scoreContribution
        self.modelIdentifier = modelInfo.identifier
        self.modelFilename = modelInfo.filename
        self.modelPath = modelInfo.path
        self.modelFamily = modelInfo.family
        self.quantization = modelInfo.quantization
        self.promptTokenCount = promptTokenCount
        self.candidateCount = candidateCount
        self.topCandidateText = topCandidateText
        self.topKCandidateTexts = topKCandidateTexts
        self.shownText = shownText
        self.suppressionReason = suppressionReason
        self.generationAttempted = generationAttempted
        self.promptBuildMs = promptBuildMs
        self.generationMs = generationMs
        self.totalMs = totalMs
    }
}

public final class ProductionCompletionEvaluator {
    private let engine: ConstrainedGenerationEngine
    private let filter: DefaultCandidateFilter
    private let promptBuilder: PromptBuilder
    private let compatibilityStore: AppCompatibilityStore
    private let modelInfo: BenchmarkModelInfo
    private let defaultMaxCompletionTokens: Int
    private let defaultMaxDisplayWidth: Int

    public init(
        runtime: LocalModelRuntime,
        profile: AutocompleteProfile,
        modelInfo: BenchmarkModelInfo,
        compatibilityStore: AppCompatibilityStore = AppCompatibilityStore(),
        decodingConfiguration: DecodingConfiguration = DecodingConfiguration(enableFillInMiddle: true),
        defaultMaxCompletionTokens: Int = 4,
        defaultMaxDisplayWidth: Int = 80
    ) {
        self.compatibilityStore = compatibilityStore
        self.engine = ConstrainedGenerationEngine(
            runtime: runtime,
            profile: profile,
            compatibilityStore: compatibilityStore,
            configuration: decodingConfiguration
        )
        self.filter = DefaultCandidateFilter(compatibilityStore: compatibilityStore)
        self.promptBuilder = PromptBuilder(
            tokenCounter: TokenizerPromptTokenCounter(tokenizer: runtime.tokenizer)
        )
        self.modelInfo = modelInfo
        self.defaultMaxCompletionTokens = defaultMaxCompletionTokens
        self.defaultMaxDisplayWidth = defaultMaxDisplayWidth
    }

    public func shutdown() async {
        await engine.shutdown()
    }

    public func evaluate(_ benchmarkCase: KeyTypeBenchCase) async throws -> BenchmarkRowResult {
        let totalStart = DispatchTime.now()
        let context = benchmarkCase.context.coreContext()

        if let reason = policySuppressionReason(for: context) {
            let score = BenchmarkScorer.score(
                expected: benchmarkCase.expected,
                shownText: nil,
                suppressionReason: reason
            )
            return BenchmarkRowResult(
                caseID: benchmarkCase.id,
                split: benchmarkCase.split,
                sourceGroup: benchmarkCase.sourceGroup,
                suites: benchmarkCase.suites,
                tags: benchmarkCase.tags,
                expectedKind: benchmarkCase.expected.kind,
                outcome: score.outcome,
                scoreContribution: score.contribution,
                modelInfo: modelInfo,
                promptTokenCount: 0,
                candidateCount: 0,
                topCandidateText: nil,
                topKCandidateTexts: [],
                shownText: nil,
                suppressionReason: reason,
                generationAttempted: false,
                promptBuildMs: 0,
                generationMs: 0,
                totalMs: elapsedMilliseconds(since: totalStart)
            )
        }

        let promptStart = DispatchTime.now()
        let heal = MidWordHealing.plan(for: context)
        let promptContext = heal.map { context.replacingBeforeCursor($0.head) } ?? context
        let policy = compatibilityStore.policy(for: promptContext)
        let promptResult = promptBuilder.buildPrompt(
            context: promptContext,
            customInstructions: policy.customInstructions,
            previousUserInputs: benchmarkCase.context.previousUserInputs,
            pasteboardText: benchmarkCase.context.clipboardContext,
            screenText: benchmarkCase.context.screenContext,
            includeEnvironmentContext: policy.includesEnvironmentContext
        )
        let promptBuildMs = elapsedMilliseconds(since: promptStart)

        let requiredPrefixBytes = heal.map { Array($0.heal.utf8) } ?? []
        let healSlack = heal?.heal.count ?? 0
        let request = CompletionRequest(
            context: context,
            prompt: promptResult.prompt,
            requiredPrefixBytes: requiredPrefixBytes,
            mode: policy.completionMode,
            maxCompletionTokens: (benchmarkCase.limits?.maxCompletionTokens ?? defaultMaxCompletionTokens) + (healSlack > 0 ? 2 : 0),
            maxDisplayWidth: (benchmarkCase.limits?.maxDisplayWidth ?? defaultMaxDisplayWidth) + healSlack
        )

        let generationStart = DispatchTime.now()
        let candidates = try await engine.completions(for: request)
        let generationMs = elapsedMilliseconds(since: generationStart)

        let topK = Array(candidates.prefix(5)).map(\.text)
        let top = candidates.first
        let visible: VisibleSuggestion
        if let best = top {
            if let reason = filter.suppressionReason(for: best, request: request) {
                visible = VisibleSuggestion(shownText: nil, suppressionReason: String(describing: reason))
            } else if let shown = Self.visibleText(for: best, request: request) {
                visible = VisibleSuggestion(shownText: shown, suppressionReason: nil)
            } else {
                visible = VisibleSuggestion(shownText: nil, suppressionReason: "emptyAfterBoundary")
            }
        } else {
            visible = VisibleSuggestion(shownText: nil, suppressionReason: "noCandidate")
        }

        let score = BenchmarkScorer.score(
            expected: benchmarkCase.expected,
            shownText: visible.shownText,
            suppressionReason: visible.suppressionReason
        )
        return BenchmarkRowResult(
            caseID: benchmarkCase.id,
            split: benchmarkCase.split,
            sourceGroup: benchmarkCase.sourceGroup,
            suites: benchmarkCase.suites,
            tags: benchmarkCase.tags,
            expectedKind: benchmarkCase.expected.kind,
            outcome: score.outcome,
            scoreContribution: score.contribution,
            modelInfo: modelInfo,
            promptTokenCount: promptResult.estimatedTokenCount,
            candidateCount: candidates.count,
            topCandidateText: top?.text,
            topKCandidateTexts: topK,
            shownText: visible.shownText,
            suppressionReason: visible.suppressionReason,
            generationAttempted: true,
            promptBuildMs: promptBuildMs,
            generationMs: generationMs,
            totalMs: elapsedMilliseconds(since: totalStart)
        )
    }

    private struct VisibleSuggestion {
        var shownText: String?
        var suppressionReason: String?
    }

    private func policySuppressionReason(for context: TextFieldContext) -> String? {
        let policy = compatibilityStore.policy(for: context)
        if policy.excludesSecureField { return "secureFieldExcluded" }
        if !policy.isCompletionEnabled { return "completionsDisabled" }
        if !policy.allowsMidLineCompletion, !context.afterCursor.isEmpty {
            return "midLineCompletionDisabled"
        }
        if !policy.allowsTabAcceptance { return "tabShortcutsDisabled" }
        return nil
    }

    private static func visibleText(for candidate: CompletionCandidate, request: CompletionRequest) -> String? {
        let completion = request.requiredPrefixBytes.isEmpty
            ? candidate.text
            : MidWordHealing.strip(
                candidate.text,
                heal: String(decoding: request.requiredPrefixBytes, as: UTF8.self)
            )
        var anchored = CaretBoundary.reconcile(completion, beforeCursor: request.context.beforeCursor)
        if request.context.afterCursor.isEmpty {
            while let last = anchored.last, last.isWhitespace {
                anchored.removeLast()
            }
        }
        return anchored.isEmpty ? nil : anchored
    }
}

private func elapsedMilliseconds(since start: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
}

public enum BenchmarkModelInfoFactory {
    public static func quantization(from filename: String) -> String? {
        let stem = (filename as NSString).deletingPathExtension
        let parts = stem.split(separator: ".").flatMap { $0.split(separator: "-") }
        let knownPrefixes = ["Q", "IQ", "I"]
        for part in parts.reversed() {
            let upper = part.uppercased()
            if knownPrefixes.contains(where: { upper.hasPrefix($0) }),
               upper.contains("_") || upper.rangeOfCharacter(from: .decimalDigits) != nil {
                return String(part)
            }
        }
        return nil
    }
}
