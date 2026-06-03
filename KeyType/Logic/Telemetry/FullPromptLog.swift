//
//  FullPromptLog.swift
//  KeyType
//
//  Developer-only JSON Lines log for sharing full prompt and completion details. Disabled by
//  default and gated by SettingsStore because rows may include opted-in clipboard, OCR, and
//  writing-history context.
//

import AppCompatibility
import AutocompleteCore
import CoreGraphics
import Foundation
import Prompting
import os

@MainActor
final class FullPromptLog {
    nonisolated static let fileName = "prompt-completions.jsonl"
    nonisolated static let maxRows = 1_000

    private let fileURL: URL?
    private let io = DispatchQueue(label: "com.pattonium.KeyType.fullpromptlog", qos: .utility)
    private let iso8601 = ISO8601DateFormatter()
    private let log = Logger(subsystem: "com.pattonium.KeyType", category: "full-prompt-log")

    init() {
        let fm = FileManager.default
        guard let base = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            fileURL = nil
            return
        }

        let directory = base.appendingPathComponent("KeyType/Logs", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(Self.fileName)
        fileURL = url
        log.info("Full prompt log: \(url.path, privacy: .public)")
    }

    func append(
        request: CompletionRequest,
        candidates: [CompletionCandidate],
        outcome: String,
        shownText: String?,
        suppressionReason: String?,
        generationLatencyMs: Double?,
        candidateDiagnostics: [FullPromptCandidateDiagnostic] = [],
        debugInfo: FullPromptDebugInfo? = nil
    ) {
        guard let fileURL else { return }
        let row = FullPromptLogRow(
            timestamp: iso8601.string(from: Date()),
            outcome: outcome,
            generationLatencyMs: generationLatencyMs,
            suppressionReason: suppressionReason,
            shownText: shownText,
            request: FullPromptRequest(request),
            candidates: candidates.enumerated().map { index, candidate in
                FullPromptCandidate(rank: index, candidate: candidate)
            },
            candidateDiagnostics: candidateDiagnostics,
            debugInfo: debugInfo
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]

        guard let data = try? encoder.encode(row),
              var line = String(data: data, encoding: .utf8) else {
            log.error("Could not encode full prompt log row")
            return
        }
        line.append("\n")

        let logger = log
        io.async {
            let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            var rows = existing
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            rows.append(String(line.dropLast()))
            if rows.count > Self.maxRows {
                rows.removeFirst(rows.count - Self.maxRows)
            }
            let output = rows.joined(separator: "\n") + "\n"
            do {
                try output.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                logger.error("Could not write full prompt log: \(error, privacy: .public)")
            }
        }
    }
}

struct FullPromptDebugInfo: Encodable {
    var promptEstimatedTokenCount: Int
    var promptSections: [FullPromptSectionSnapshot]
    var promptContext: FullPromptContext
    var tokenHealing: FullPromptTokenHealing?
    var sideContext: FullPromptSideContextSnapshot
    var settings: FullPromptSettingsSnapshot
    var policy: FullPromptPolicySnapshot
    var requestBudget: FullPromptRequestBudgetSnapshot
}

struct FullPromptSectionSnapshot: Encodable {
    var name: String
    var heading: String?
    var content: String
    var priority: Int
    var minBudget: Int
    var maxBudget: Int
    var truncationMode: String
    var characterCount: Int

    init(_ section: PromptSection) {
        self.name = section.name
        self.heading = section.heading
        self.content = section.content
        self.priority = section.priority
        self.minBudget = section.minBudget
        self.maxBudget = section.maxBudget
        self.truncationMode = Self.truncationDescription(section.truncationMode)
        self.characterCount = section.content.count
    }

    private static func truncationDescription(_ mode: PromptTruncationMode) -> String {
        switch mode {
        case .none: return "none"
        case .preserveStart: return "preserveStart"
        case .preserveEnd: return "preserveEnd"
        case .hard: return "hard"
        }
    }
}

struct FullPromptTokenHealing: Encodable {
    var head: String
    var heal: String
}

struct FullPromptSideContextSnapshot: Encodable {
    var reused: Bool
    var historyEnabled: Bool
    var clipboardEnabled: Bool
    var ocrEnabled: Bool
    var previousUserInputs: [String]
    var pasteboardText: String?
    var screenText: String?
}

struct FullPromptSettingsSnapshot: Encodable {
    var completionLength: String
    var fullPromptLoggingEnabled: Bool
    var perAppDisabledBundleIdentifiers: [String]
}

struct FullPromptPolicySnapshot: Encodable {
    var isCompletionEnabled: Bool
    var allowsMidLineCompletion: Bool
    var allowsTabAcceptance: Bool
    var allowsTrainingDataCollection: Bool
    var insertionRequiresPasteAndMatchStyle: Bool
    var insertionRequiresNonBreakingSpace: Bool
    var stringInjectionChunkSize: Int?
    var insertionRequiresBackspaceAfterPaste: Bool
    var fontSizeAdjustmentFactor: Double
    var overlayPreference: String
    var completionMode: String
    var customInstructions: [String]
    var includesEnvironmentContext: Bool
    var excludesSecureField: Bool

    init(_ policy: CompletionPolicy) {
        self.isCompletionEnabled = policy.isCompletionEnabled
        self.allowsMidLineCompletion = policy.allowsMidLineCompletion
        self.allowsTabAcceptance = policy.allowsTabAcceptance
        self.allowsTrainingDataCollection = policy.allowsTrainingDataCollection
        self.insertionRequiresPasteAndMatchStyle = policy.insertionRequiresPasteAndMatchStyle
        self.insertionRequiresNonBreakingSpace = policy.insertionRequiresNonBreakingSpace
        self.stringInjectionChunkSize = policy.stringInjectionChunkSize
        self.insertionRequiresBackspaceAfterPaste = policy.insertionRequiresBackspaceAfterPaste
        self.fontSizeAdjustmentFactor = policy.fontSizeAdjustmentFactor
        self.overlayPreference = Self.overlayDescription(policy.overlayPreference)
        self.completionMode = Self.modeDescription(policy.completionMode)
        self.customInstructions = policy.customInstructions
        self.includesEnvironmentContext = policy.includesEnvironmentContext
        self.excludesSecureField = policy.excludesSecureField
    }

    private static func overlayDescription(_ preference: OverlayPreference) -> String {
        switch preference {
        case .inline: return "inline"
        case .textMirror: return "textMirror"
        case .hidden: return "hidden"
        }
    }
}

struct FullPromptRequestBudgetSnapshot: Encodable {
    var baseMaxCompletionTokens: Int
    var actualMaxCompletionTokens: Int
    var baseMaxDisplayWidth: Int
    var actualMaxDisplayWidth: Int
    var healSlackCharacters: Int
    var requiredPrefixByteCount: Int
}

struct FullPromptCandidateDiagnostic: Encodable {
    var rank: Int
    var text: String
    var passesFilter: Bool
    var suppressionReason: String?
}

private struct FullPromptLogRow: Encodable {
    var version = 1
    var timestamp: String
    var outcome: String
    var generationLatencyMs: Double?
    var suppressionReason: String?
    var shownText: String?
    var request: FullPromptRequest
    var candidates: [FullPromptCandidate]
    var candidateDiagnostics: [FullPromptCandidateDiagnostic]
    var debugInfo: FullPromptDebugInfo?
}

private struct FullPromptRequest: Encodable {
    var prompt: String
    var requiredPrefixBytes: [UInt8]
    var requiredPrefixText: String?
    var mode: String
    var maxCompletionTokens: Int
    var maxDisplayWidth: Int
    var context: FullPromptContext

    init(_ request: CompletionRequest) {
        self.prompt = request.prompt
        self.requiredPrefixBytes = request.requiredPrefixBytes
        self.requiredPrefixText = String(data: Data(request.requiredPrefixBytes), encoding: .utf8)
        self.mode = Self.modeDescription(request.mode)
        self.maxCompletionTokens = request.maxCompletionTokens
        self.maxDisplayWidth = request.maxDisplayWidth
        self.context = FullPromptContext(request.context)
    }

    private static func modeDescription(_ mode: CompletionMode) -> String {
        switch mode {
        case .prose: return "prose"
        case .code: return "code"
        case .terminal: return "terminal"
        case .emoji: return "emoji"
        case .correction: return "correction"
        }
    }
}

struct FullPromptContext: Encodable {
    var beforeCursor: String
    var afterCursor: String
    var selectedText: String?
    var geometry: FullPromptGeometry
    var target: FullPromptTarget
    var placeholder: String?
    var labels: [String]
    var detectedLanguage: String?
    var typingContext: String?
    var traits: FullPromptTraits

    init(_ context: TextFieldContext) {
        self.beforeCursor = context.beforeCursor
        self.afterCursor = context.afterCursor
        self.selectedText = context.selection.selectedText
        self.geometry = FullPromptGeometry(context.geometry)
        self.target = FullPromptTarget(context.target)
        self.placeholder = context.placeholder
        self.labels = context.labels
        self.detectedLanguage = context.detectedLanguage
        self.typingContext = context.typingContext
        self.traits = FullPromptTraits(context.traits)
    }
}

struct FullPromptTarget: Encodable {
    var bundleIdentifier: String
    var appName: String
    var windowTitle: String?
    var domain: String?

    init(_ target: AppTarget) {
        self.bundleIdentifier = target.bundleIdentifier
        self.appName = target.appName
        self.windowTitle = target.windowTitle
        self.domain = target.domain
    }
}

struct FullPromptGeometry: Encodable {
    var cursorRect: FullPromptRect?
    var fieldRect: FullPromptRect?
    var isAtEndOfLine: Bool
    var isRightToLeft: Bool
    var cursorRectQuality: String

    init(_ geometry: TextFieldGeometry) {
        self.cursorRect = geometry.cursorRect.map(FullPromptRect.init)
        self.fieldRect = geometry.fieldRect.map(FullPromptRect.init)
        self.isAtEndOfLine = geometry.isAtEndOfLine
        self.isRightToLeft = geometry.isRightToLeft
        self.cursorRectQuality = geometry.cursorRectQuality.rawValue
    }
}

struct FullPromptRect: Encodable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        self.x = Double(rect.minX)
        self.y = Double(rect.minY)
        self.width = Double(rect.width)
        self.height = Double(rect.height)
    }
}

struct FullPromptTraits: Encodable {
    var isSecureTextEntry: Bool
    var isPasswordField: Bool
    var isPasswordManagerContext: Bool
    var isWebField: Bool
    var isTerminalLike: Bool

    init(_ traits: TextFieldTraits) {
        self.isSecureTextEntry = traits.isSecureTextEntry
        self.isPasswordField = traits.isPasswordField
        self.isPasswordManagerContext = traits.isPasswordManagerContext
        self.isWebField = traits.isWebField
        self.isTerminalLike = traits.isTerminalLike
    }
}

private struct FullPromptCandidate: Encodable {
    var rank: Int
    var id: UUID
    var text: String
    var tokenIDs: [TokenID]
    var logProbability: Double
    var displayWidth: Int
    var mode: String

    init(rank: Int, candidate: CompletionCandidate) {
        self.rank = rank
        self.id = candidate.id
        self.text = candidate.text
        self.tokenIDs = candidate.tokenIDs
        self.logProbability = candidate.logProbability
        self.displayWidth = candidate.displayWidth
        self.mode = Self.modeDescription(candidate.mode)
    }

    private static func modeDescription(_ mode: CompletionMode) -> String {
        FullPromptPolicySnapshot.modeDescription(mode)
    }
}

private extension FullPromptPolicySnapshot {
    static func modeDescription(_ mode: CompletionMode) -> String {
        switch mode {
        case .prose: return "prose"
        case .code: return "code"
        case .terminal: return "terminal"
        case .emoji: return "emoji"
        case .correction: return "correction"
        }
    }
}
