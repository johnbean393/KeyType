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
    public var isAtEndOfLine: Bool
    public var isRightToLeft: Bool

    public init(
        cursorRect: CGRect? = nil,
        isAtEndOfLine: Bool = true,
        isRightToLeft: Bool = false
    ) {
        self.cursorRect = cursorRect
        self.isAtEndOfLine = isAtEndOfLine
        self.isRightToLeft = isRightToLeft
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

    public init(
        beforeCursor: String,
        afterCursor: String = "",
        selection: TextSelection = TextSelection(),
        geometry: TextFieldGeometry = TextFieldGeometry(),
        target: AppTarget,
        placeholder: String? = nil,
        labels: [String] = [],
        detectedLanguage: String? = nil,
        typingContext: String? = nil
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
    case completionsDisabled
    case midLineCompletionDisabled
    case tabShortcutsDisabled
    case invalidUTF8
    case requiredPrefixNotSatisfied
    case displayWidthExceeded
    case maxCompletionLengthExceeded
    case insertionUnsafe
    case currentWordLooksLikeTypo
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
