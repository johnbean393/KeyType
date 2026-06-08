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

public enum CaretGeometryQuality: String, Equatable {
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

public struct CompletionRequest: Equatable {
    public var context: TextFieldContext
    public var prompt: String
    public var requiredPrefixBytes: [UInt8]
    public var mode: CompletionMode
    public var maxCompletionTokens: Int
    public var maxDisplayWidth: Int
    /// Side-context text injected into the prompt that the user did NOT type — clipboard contents and
    /// on-screen OCR text. Carried alongside the request so the output filter can drop a completion
    /// that merely parrots it verbatim (`ContextEchoGuard`). Writing-history samples are deliberately
    /// excluded: they are scoped to the same app/domain and reproducing the user's own recurring
    /// phrases is the point of that feature.
    public var injectedContext: [String]

    public init(
        context: TextFieldContext,
        prompt: String,
        requiredPrefixBytes: [UInt8] = [],
        mode: CompletionMode = .prose,
        maxCompletionTokens: Int = 4,
        maxDisplayWidth: Int = 80,
        injectedContext: [String] = []
    ) {
        self.context = context
        self.prompt = prompt
        self.requiredPrefixBytes = requiredPrefixBytes
        self.mode = mode
        self.maxCompletionTokens = maxCompletionTokens
        self.maxDisplayWidth = maxDisplayWidth
        self.injectedContext = injectedContext
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
    /// The completion reproduces a phrase that is already present in the recent text before the caret.
    /// Accepting it would create a verbatim repetition loop. See `PrefixRepetitionGuard`.
    case repeatsRecentPrefix
    /// The completion verbatim-reproduces a span of injected side context the user did not type
    /// (clipboard, on-screen OCR text) — the small model parroting context instead of predicting.
    /// See `ContextEchoGuard`.
    case echoesInjectedContext
    case noCandidate
}

public protocol ContextProviding {
    func currentContext() async throws -> TextFieldContext?
}

public protocol CompletionGenerating {
    func completions(for request: CompletionRequest) async throws -> [CompletionCandidate]
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
