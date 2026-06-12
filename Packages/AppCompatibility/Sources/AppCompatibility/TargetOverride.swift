import AutocompleteCore
import Foundation

public struct TargetOverride: Equatable {
    public var bundleIdentifier: String?
    public var domain: String?
    public var completionsDisabled: Bool
    public var midLineCompletionsEnabled: Bool
    public var midLineCompletionsDisabled: Bool
    public var tabShortcutsDisabled: Bool
    public var trainingDataCollectionDisabled: Bool
    public var requiresPasteAndMatchStyle: Bool
    public var requiresNonBreakingSpaceWorkaround: Bool
    public var stringInjectionChunkSize: Int?
    public var requiresBackspaceAfterPaste: Bool
    public var fontSizeAdjustmentFactor: Double
    public var horizontalAlignmentOffset: Double
    public var verticalAlignmentOffset: VerticalAlignmentOffsetResolver
    public var overlayPreference: OverlayPreference?
    public var completionMode: CompletionMode?
    public var customInstructions: String?
    /// Drop app/window/field metadata from the prompt for this target. Helpful for code editors and
    /// terminals, where that metadata (e.g. an Xcode window title) biases a base model toward code
    /// and numbers instead of the user's prose. See ADR-017.
    public var environmentContextDisabled: Bool
    public var secureFieldExclusion: Bool

    public init(
        bundleIdentifier: String? = nil,
        domain: String? = nil,
        completionsDisabled: Bool = false,
        midLineCompletionsEnabled: Bool = false,
        midLineCompletionsDisabled: Bool = false,
        tabShortcutsDisabled: Bool = false,
        trainingDataCollectionDisabled: Bool = false,
        requiresPasteAndMatchStyle: Bool = false,
        requiresNonBreakingSpaceWorkaround: Bool = false,
        stringInjectionChunkSize: Int? = nil,
        requiresBackspaceAfterPaste: Bool = false,
        fontSizeAdjustmentFactor: Double = 1,
        horizontalAlignmentOffset: Double = 0,
        verticalAlignmentOffset: @escaping VerticalAlignmentOffsetResolver = { _ in 0 },
        overlayPreference: OverlayPreference? = nil,
        completionMode: CompletionMode? = nil,
        customInstructions: String? = nil,
        environmentContextDisabled: Bool = false,
        secureFieldExclusion: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.domain = domain.map(Self.normalizedDomain)
        self.completionsDisabled = completionsDisabled
        self.midLineCompletionsEnabled = midLineCompletionsEnabled
        self.midLineCompletionsDisabled = midLineCompletionsDisabled
        self.tabShortcutsDisabled = tabShortcutsDisabled
        self.trainingDataCollectionDisabled = trainingDataCollectionDisabled
        self.requiresPasteAndMatchStyle = requiresPasteAndMatchStyle
        self.requiresNonBreakingSpaceWorkaround = requiresNonBreakingSpaceWorkaround
        self.stringInjectionChunkSize = stringInjectionChunkSize
        self.requiresBackspaceAfterPaste = requiresBackspaceAfterPaste
        self.fontSizeAdjustmentFactor = fontSizeAdjustmentFactor
        self.horizontalAlignmentOffset = horizontalAlignmentOffset
        self.verticalAlignmentOffset = verticalAlignmentOffset
        self.overlayPreference = overlayPreference
        self.completionMode = completionMode
        self.customInstructions = customInstructions
        self.environmentContextDisabled = environmentContextDisabled
        self.secureFieldExclusion = secureFieldExclusion
    }

    public static func == (lhs: TargetOverride, rhs: TargetOverride) -> Bool {
        lhs.bundleIdentifier == rhs.bundleIdentifier
            && lhs.domain == rhs.domain
            && lhs.completionsDisabled == rhs.completionsDisabled
            && lhs.midLineCompletionsEnabled == rhs.midLineCompletionsEnabled
            && lhs.midLineCompletionsDisabled == rhs.midLineCompletionsDisabled
            && lhs.tabShortcutsDisabled == rhs.tabShortcutsDisabled
            && lhs.trainingDataCollectionDisabled == rhs.trainingDataCollectionDisabled
            && lhs.requiresPasteAndMatchStyle == rhs.requiresPasteAndMatchStyle
            && lhs.requiresNonBreakingSpaceWorkaround == rhs.requiresNonBreakingSpaceWorkaround
            && lhs.stringInjectionChunkSize == rhs.stringInjectionChunkSize
            && lhs.requiresBackspaceAfterPaste == rhs.requiresBackspaceAfterPaste
            && lhs.fontSizeAdjustmentFactor == rhs.fontSizeAdjustmentFactor
            && lhs.horizontalAlignmentOffset == rhs.horizontalAlignmentOffset
            && lhs.verticalAlignmentOffset(0) == rhs.verticalAlignmentOffset(0)
            && lhs.verticalAlignmentOffset(12) == rhs.verticalAlignmentOffset(12)
            && lhs.verticalAlignmentOffset(24) == rhs.verticalAlignmentOffset(24)
            && lhs.overlayPreference == rhs.overlayPreference
            && lhs.completionMode == rhs.completionMode
            && lhs.customInstructions == rhs.customInstructions
            && lhs.environmentContextDisabled == rhs.environmentContextDisabled
            && lhs.secureFieldExclusion == rhs.secureFieldExclusion
    }

    public func matches(_ target: AppTarget) -> Bool {
        if let bundleIdentifier, bundleIdentifier != target.bundleIdentifier {
            return false
        }
        if let domain {
            guard let targetDomain = target.domain.map(Self.normalizedDomain),
                  targetDomain == domain || targetDomain.hasSuffix(".\(domain)") else {
                return false
            }
        }
        return bundleIdentifier != nil || domain != nil
    }

    private static func normalizedDomain(_ domain: String) -> String {
        domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingPrefix("www.")
    }
}

private extension String {
    func trimmingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
