import CoreGraphics
import Foundation

public typealias TokenID = Int32

public struct AppTarget: Equatable, Hashable {
    public var bundleIdentifier: String
    public var appName: String
    public var windowTitle: String?
    public var domain: String?

    public init(
        bundleIdentifier: String,
        appName: String,
        windowTitle: String? = nil,
        domain: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.windowTitle = windowTitle
        self.domain = domain
    }
}

public struct TextSelection: Equatable {
    public var selectedText: String?
    public var range: Range<String.Index>?

    public init(selectedText: String? = nil, range: Range<String.Index>? = nil) {
        self.selectedText = selectedText
        self.range = range
    }
}

public struct TextFieldGeometry: Equatable {
    public var cursorRect: CGRect?
    public var fieldRect: CGRect?
    public var isAtEndOfLine: Bool
    public var isRightToLeft: Bool
    public var cursorRectQuality: CaretGeometryQuality

    public init(
        cursorRect: CGRect? = nil,
        fieldRect: CGRect? = nil,
        isAtEndOfLine: Bool = true,
        isRightToLeft: Bool = false,
        cursorRectQuality: CaretGeometryQuality = .unknown
    ) {
        self.cursorRect = cursorRect
        self.fieldRect = fieldRect
        self.isAtEndOfLine = isAtEndOfLine
        self.isRightToLeft = isRightToLeft
        self.cursorRectQuality = cursorRectQuality
    }
}

public enum CaretGeometryQuality: String, Equatable, Sendable {
    case exact
    case derived
    case estimated
    case unknown
}

public struct TextFieldTraits: Equatable {
    public var isSecureTextEntry: Bool
    public var isPasswordField: Bool
    public var isPasswordManagerContext: Bool
    public var isWebField: Bool
    public var isTerminalLike: Bool

    public init(
        isSecureTextEntry: Bool = false,
        isPasswordField: Bool = false,
        isPasswordManagerContext: Bool = false,
        isWebField: Bool = false,
        isTerminalLike: Bool = false
    ) {
        self.isSecureTextEntry = isSecureTextEntry
        self.isPasswordField = isPasswordField
        self.isPasswordManagerContext = isPasswordManagerContext
        self.isWebField = isWebField
        self.isTerminalLike = isTerminalLike
    }
}

public struct TextFieldContext: Equatable {
    public var beforeCursor: String
    public var afterCursor: String
    public var selection: TextSelection
    public var geometry: TextFieldGeometry
    public var target: AppTarget
    public var placeholder: String?
    public var labels: [String]
    public var detectedLanguage: String?
    public var typingContext: String?
    public var traits: TextFieldTraits

    public init(
        beforeCursor: String,
        afterCursor: String = "",
        selection: TextSelection = TextSelection(),
        geometry: TextFieldGeometry = TextFieldGeometry(),
        target: AppTarget,
        placeholder: String? = nil,
        labels: [String] = [],
        detectedLanguage: String? = nil,
        typingContext: String? = nil,
        traits: TextFieldTraits = TextFieldTraits()
    ) {
        self.beforeCursor = beforeCursor
        self.afterCursor = afterCursor
        self.selection = selection
        self.geometry = geometry
        self.target = target
        self.placeholder = placeholder
        self.labels = labels
        self.detectedLanguage = detectedLanguage
        self.typingContext = typingContext
        self.traits = traits
    }
}

public enum CompletionMode: Equatable {
    case prose
    case code
    case terminal
    case emoji
    case correction
}

public struct TextRangeDescriptor: Equatable, Sendable {
    public enum Container: String, Equatable, Sendable {
        case beforeCursor
        case afterCursor
    }

    /// Character offsets in the selected text container. V1 intentionally stays string-index based
    /// inside `beforeCursor` / `afterCursor`; native AX/text-marker identifiers can be layered on
    /// when exact mid-text replacement lands.
    public var container: Container
    public var startOffset: Int
    public var endOffset: Int

    public init(container: Container, startOffset: Int, endOffset: Int) {
        self.container = container
        self.startOffset = max(0, startOffset)
        self.endOffset = max(self.startOffset, endOffset)
    }

    public func range(in text: String) -> Range<String.Index>? {
        guard startOffset <= endOffset,
              let start = text.index(text.startIndex, offsetBy: startOffset, limitedBy: text.endIndex),
              let end = text.index(text.startIndex, offsetBy: endOffset, limitedBy: text.endIndex),
              start <= end else {
            return nil
        }
        return start..<end
    }
}

public enum CorrectionCandidateSource: String, Equatable, Sendable {
    case spellcheckValidatedByModel
    case spellcheckOnly
    case priorPrediction
    case systemGrammarValidatedByModel
    case systemGrammarOnly
    case spellcheckThenSystemGrammar
}

public struct CorrectionValidation: Equatable, Sendable {
    public enum Method: String, Equatable, Sendable {
        case none
        case priorPrediction
        case modelScore
    }

    public var method: Method
    public var absoluteScore: Double?
    public var margin: Double?
    public var suffixJoinScore: Double?
    public var boostedByPriorPrediction: Bool
    public var suppressionReason: String?

    public init(
        method: Method = .none,
        absoluteScore: Double? = nil,
        margin: Double? = nil,
        suffixJoinScore: Double? = nil,
        boostedByPriorPrediction: Bool = false,
        suppressionReason: String? = nil
    ) {
        self.method = method
        self.absoluteScore = absoluteScore
        self.margin = margin
        self.suffixJoinScore = suffixJoinScore
        self.boostedByPriorPrediction = boostedByPriorPrediction
        self.suppressionReason = suppressionReason
    }

    public static let spellcheckOnly = CorrectionValidation(method: .none)
}

public struct CorrectionCandidate: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var original: String
    public var replacement: String
    public var originalRange: TextRangeDescriptor
    public var confidence: Double
    public var source: CorrectionCandidateSource
    public var validation: CorrectionValidation

    public init(
        id: UUID = UUID(),
        original: String,
        replacement: String,
        originalRange: TextRangeDescriptor,
        confidence: Double,
        source: CorrectionCandidateSource,
        validation: CorrectionValidation
    ) {
        self.id = id
        self.original = original
        self.replacement = replacement
        self.originalRange = originalRange
        self.confidence = confidence
        self.source = source
        self.validation = validation
    }
}

public struct CompletionRequest: Equatable {
    public var context: TextFieldContext
    public var prompt: String
    public var requiredPrefixBytes: [UInt8]
    public var mode: CompletionMode
    public var maxCompletionTokens: Int
    public var maxDisplayWidth: Int

    public init(
        context: TextFieldContext,
        prompt: String,
        requiredPrefixBytes: [UInt8] = [],
        mode: CompletionMode = .prose,
        maxCompletionTokens: Int = 4,
        maxDisplayWidth: Int = 80
    ) {
        self.context = context
        self.prompt = prompt
        self.requiredPrefixBytes = requiredPrefixBytes
        self.mode = mode
        self.maxCompletionTokens = maxCompletionTokens
        self.maxDisplayWidth = maxDisplayWidth
    }
}

public struct CompletionCandidate: Equatable, Identifiable {
    public var id: UUID
    public var text: String
    public var tokenIDs: [TokenID]
    public var logProbability: Double
    public var displayWidth: Int
    public var mode: CompletionMode

    public init(
        id: UUID = UUID(),
        text: String,
        tokenIDs: [TokenID] = [],
        logProbability: Double = 0,
        displayWidth: Int? = nil,
        mode: CompletionMode = .prose
    ) {
        self.id = id
        self.text = text
        self.tokenIDs = tokenIDs
        self.logProbability = logProbability
        self.displayWidth = displayWidth ?? text.count
        self.mode = mode
    }
}

public enum SuppressionReason: Equatable {
    case secureFieldExcluded
    case completionsDisabled
    case midLineCompletionDisabled
    case tabShortcutsDisabled
    case invalidUTF8
    case requiredPrefixNotSatisfied
    case displayWidthExceeded
    case maxCompletionLengthExceeded
    case insertionUnsafe
    /// The user is actively typing in a CJK script, but the candidate starts in a different major
    /// script (typically pinyin/romanized Latin output after Chinese/Japanese/Korean context).
    case scriptMismatch
    case currentWordLooksLikeTypo
    /// The completion leaves the word the user is typing *open* on a stem that cannot begin any word
    /// in the dictionary (e.g. a lone `"x"` after `"th"`) — so it could never resolve to a real word.
    /// Distinct from `currentWordLooksLikeTypo`, which only judges a word that has already *closed*.
    case currentWordHasNoValidCompletion
    /// A mid-line / fill-in-the-middle completion that merely reproduces text already present after
    /// the caret — accepting it would duplicate the existing suffix. See `SuffixOverlapGuard`.
    case duplicatesAfterCursor
    /// A mid-line / fill-in-the-middle completion that is too long or too low-probability to show
    /// without risking a wrong suggestion.
    case lowConfidenceMidLine
    case noCandidate
}

public protocol ContextProviding {
    func currentContext() async throws -> TextFieldContext?
}

public protocol CompletionGenerating {
    func completions(for request: CompletionRequest) async throws -> [CompletionCandidate]
}

public protocol CorrectionDetecting {
    func correctionCandidates(for context: TextFieldContext) async throws -> [CorrectionCandidate]
}

public protocol CandidateFiltering {
    func suppressionReason(
        for candidate: CompletionCandidate,
        request: CompletionRequest
    ) -> SuppressionReason?
}

/// Language-aware dictionary lookup used by the constrained decoder's current-word typo guard.
///
/// The guard reconstructs the word the user is *completing* — the stem already typed at the cursor
/// plus the model's continuation up to the next word boundary — and asks whether it is a real word.
/// A `false` answer lets the engine drop that branch mid-search so the beam spends its budget on
/// correctly-spelled continuations instead (see ADR-015).
///
/// Implementations MUST be conservative: return `true` whenever unsure (unknown language, no
/// dictionary for the script, proper nouns, etc.) so the guard never suppresses a legitimate
/// completion. The macOS implementation wraps `NSSpellChecker` and therefore lives in the app
/// layer; `AutocompleteCore` stays free of AppKit.
public protocol WordRecognizing: Sendable {
    /// `true` when `word` is recognised for `language` (an `NSSpellChecker` language id such as
    /// `"en"` / `"en_US"`, or `nil` to let the implementation auto-detect). Conservative on doubt.
    func recognizes(_ word: String, language: String?) async -> Bool
}
