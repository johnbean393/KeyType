import AutocompleteCore
import Foundation

public struct DeveloperTargetOverrideDocument: Codable, Equatable {
    public var version: Int
    public var overrides: [DeveloperTargetOverride]

    public init(version: Int = 1, overrides: [DeveloperTargetOverride] = []) {
        self.version = version
        self.overrides = overrides
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case overrides
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.overrides = try container.decodeIfPresent([DeveloperTargetOverride].self, forKey: .overrides) ?? []
    }
}

public enum DeveloperOverlayPreference: String, Codable, CaseIterable, Identifiable {
    case inline
    case textMirror
    case hidden

    public var id: String { rawValue }

    var targetPreference: OverlayPreference {
        switch self {
        case .inline: return .inline
        case .textMirror: return .textMirror
        case .hidden: return .hidden
        }
    }
}

public enum DeveloperCompletionMode: String, Codable, CaseIterable, Identifiable {
    case prose
    case code
    case terminal
    case emoji
    case correction

    public var id: String { rawValue }

    var targetMode: CompletionMode {
        switch self {
        case .prose: return .prose
        case .code: return .code
        case .terminal: return .terminal
        case .emoji: return .emoji
        case .correction: return .correction
        }
    }
}

public struct DeveloperTargetOverride: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var bundleIdentifier: String
    public var domain: String

    public var completionsDisabled: Bool
    public var midLineCompletionsEnabled: Bool
    public var midLineCompletionsDisabled: Bool
    public var tabShortcutsDisabled: Bool
    public var trainingDataCollectionDisabled: Bool
    public var requiresPasteAndMatchStyle: Bool
    public var requiresNonBreakingSpaceWorkaround: Bool
    public var stringInjectionChunkSize: Int?
    public var requiresBackspaceAfterPaste: Bool
    public var fontSizeAdjustmentFactor: Double?
    public var horizontalOffsetPoints: Double?
    public var verticalOffsetPoints: Double?
    public var verticalOffsetLineHeightMultiplier: Double?
    public var overlayPreference: DeveloperOverlayPreference?
    public var completionMode: DeveloperCompletionMode?
    public var customInstructions: String
    public var environmentContextDisabled: Bool
    public var secureFieldExclusion: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case enabled
        case bundleIdentifier
        case domain
        case completionsDisabled
        case midLineCompletionsEnabled
        case midLineCompletionsDisabled
        case tabShortcutsDisabled
        case trainingDataCollectionDisabled
        case requiresPasteAndMatchStyle
        case requiresNonBreakingSpaceWorkaround
        case stringInjectionChunkSize
        case requiresBackspaceAfterPaste
        case fontSizeAdjustmentFactor
        case horizontalOffsetPoints
        case verticalOffsetPoints
        case verticalOffsetLineHeightMultiplier
        case overlayPreference
        case completionMode
        case customInstructions
        case environmentContextDisabled
        case secureFieldExclusion
    }

    public init(
        id: String = "",
        name: String = "",
        enabled: Bool = true,
        bundleIdentifier: String = "",
        domain: String = "",
        completionsDisabled: Bool = false,
        midLineCompletionsEnabled: Bool = false,
        midLineCompletionsDisabled: Bool = false,
        tabShortcutsDisabled: Bool = false,
        trainingDataCollectionDisabled: Bool = false,
        requiresPasteAndMatchStyle: Bool = false,
        requiresNonBreakingSpaceWorkaround: Bool = false,
        stringInjectionChunkSize: Int? = nil,
        requiresBackspaceAfterPaste: Bool = false,
        fontSizeAdjustmentFactor: Double? = nil,
        horizontalOffsetPoints: Double? = nil,
        verticalOffsetPoints: Double? = nil,
        verticalOffsetLineHeightMultiplier: Double? = nil,
        overlayPreference: DeveloperOverlayPreference? = nil,
        completionMode: DeveloperCompletionMode? = nil,
        customInstructions: String = "",
        environmentContextDisabled: Bool = false,
        secureFieldExclusion: Bool = false
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.bundleIdentifier = bundleIdentifier
        self.domain = domain
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
        self.horizontalOffsetPoints = horizontalOffsetPoints
        self.verticalOffsetPoints = verticalOffsetPoints
        self.verticalOffsetLineHeightMultiplier = verticalOffsetLineHeightMultiplier
        self.overlayPreference = overlayPreference
        self.completionMode = completionMode
        self.customInstructions = customInstructions
        self.environmentContextDisabled = environmentContextDisabled
        self.secureFieldExclusion = secureFieldExclusion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier) ?? ""
        self.domain = try container.decodeIfPresent(String.self, forKey: .domain) ?? ""
        self.completionsDisabled = try container.decodeIfPresent(Bool.self, forKey: .completionsDisabled) ?? false
        self.midLineCompletionsEnabled = try container.decodeIfPresent(Bool.self, forKey: .midLineCompletionsEnabled) ?? false
        self.midLineCompletionsDisabled = try container.decodeIfPresent(Bool.self, forKey: .midLineCompletionsDisabled) ?? false
        self.tabShortcutsDisabled = try container.decodeIfPresent(Bool.self, forKey: .tabShortcutsDisabled) ?? false
        self.trainingDataCollectionDisabled = try container.decodeIfPresent(Bool.self, forKey: .trainingDataCollectionDisabled) ?? false
        self.requiresPasteAndMatchStyle = try container.decodeIfPresent(Bool.self, forKey: .requiresPasteAndMatchStyle) ?? false
        self.requiresNonBreakingSpaceWorkaround = try container.decodeIfPresent(Bool.self, forKey: .requiresNonBreakingSpaceWorkaround) ?? false
        self.stringInjectionChunkSize = try container.decodeIfPresent(Int.self, forKey: .stringInjectionChunkSize)
        self.requiresBackspaceAfterPaste = try container.decodeIfPresent(Bool.self, forKey: .requiresBackspaceAfterPaste) ?? false
        self.fontSizeAdjustmentFactor = try container.decodeIfPresent(Double.self, forKey: .fontSizeAdjustmentFactor)
        self.horizontalOffsetPoints = try container.decodeIfPresent(Double.self, forKey: .horizontalOffsetPoints)
        self.verticalOffsetPoints = try container.decodeIfPresent(Double.self, forKey: .verticalOffsetPoints)
        self.verticalOffsetLineHeightMultiplier = try container.decodeIfPresent(Double.self, forKey: .verticalOffsetLineHeightMultiplier)
        self.overlayPreference = try container.decodeIfPresent(DeveloperOverlayPreference.self, forKey: .overlayPreference)
        self.completionMode = try container.decodeIfPresent(DeveloperCompletionMode.self, forKey: .completionMode)
        self.customInstructions = try container.decodeIfPresent(String.self, forKey: .customInstructions) ?? ""
        self.environmentContextDisabled = try container.decodeIfPresent(Bool.self, forKey: .environmentContextDisabled) ?? false
        self.secureFieldExclusion = try container.decodeIfPresent(Bool.self, forKey: .secureFieldExclusion) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(domain, forKey: .domain)
        try container.encode(completionsDisabled, forKey: .completionsDisabled)
        try container.encode(midLineCompletionsEnabled, forKey: .midLineCompletionsEnabled)
        try container.encode(midLineCompletionsDisabled, forKey: .midLineCompletionsDisabled)
        try container.encode(tabShortcutsDisabled, forKey: .tabShortcutsDisabled)
        try container.encode(trainingDataCollectionDisabled, forKey: .trainingDataCollectionDisabled)
        try container.encode(requiresPasteAndMatchStyle, forKey: .requiresPasteAndMatchStyle)
        try container.encode(requiresNonBreakingSpaceWorkaround, forKey: .requiresNonBreakingSpaceWorkaround)
        try container.encodeIfPresent(stringInjectionChunkSize, forKey: .stringInjectionChunkSize)
        try container.encode(requiresBackspaceAfterPaste, forKey: .requiresBackspaceAfterPaste)
        try container.encodeIfPresent(fontSizeAdjustmentFactor, forKey: .fontSizeAdjustmentFactor)
        try container.encodeIfPresent(horizontalOffsetPoints, forKey: .horizontalOffsetPoints)
        try container.encodeIfPresent(verticalOffsetPoints, forKey: .verticalOffsetPoints)
        try container.encodeIfPresent(verticalOffsetLineHeightMultiplier, forKey: .verticalOffsetLineHeightMultiplier)
        try container.encodeIfPresent(overlayPreference, forKey: .overlayPreference)
        try container.encodeIfPresent(completionMode, forKey: .completionMode)
        try container.encode(customInstructions, forKey: .customInstructions)
        try container.encode(environmentContextDisabled, forKey: .environmentContextDisabled)
        try container.encode(secureFieldExclusion, forKey: .secureFieldExclusion)
    }

    public var stableID: String {
        let trimmedID = trimmed(id)
        if !trimmedID.isEmpty {
            return trimmedID
        }
        if let bundle = optionalTrimmed(bundleIdentifier) {
            return "bundle:\(bundle)"
        }
        if let domain = optionalTrimmed(domain) {
            return "domain:\(domain.lowercased())"
        }
        return "override"
    }

    public func targetOverride() -> TargetOverride? {
        guard enabled else { return nil }
        let bundle = optionalTrimmed(bundleIdentifier)
        let normalizedDomain = optionalTrimmed(domain)
        guard bundle != nil || normalizedDomain != nil else { return nil }

        let pointOffset = verticalOffsetPoints ?? 0
        let lineHeightMultiplier = verticalOffsetLineHeightMultiplier ?? 0
        return TargetOverride(
            bundleIdentifier: bundle,
            domain: normalizedDomain,
            completionsDisabled: completionsDisabled,
            midLineCompletionsEnabled: midLineCompletionsEnabled,
            midLineCompletionsDisabled: midLineCompletionsDisabled,
            tabShortcutsDisabled: tabShortcutsDisabled,
            trainingDataCollectionDisabled: trainingDataCollectionDisabled,
            requiresPasteAndMatchStyle: requiresPasteAndMatchStyle,
            requiresNonBreakingSpaceWorkaround: requiresNonBreakingSpaceWorkaround,
            stringInjectionChunkSize: stringInjectionChunkSize,
            requiresBackspaceAfterPaste: requiresBackspaceAfterPaste,
            fontSizeAdjustmentFactor: fontSizeAdjustmentFactor ?? 1,
            horizontalAlignmentOffset: horizontalOffsetPoints ?? 0,
            verticalAlignmentOffset: { lineHeight in
                pointOffset + lineHeightMultiplier * lineHeight
            },
            overlayPreference: overlayPreference?.targetPreference,
            completionMode: completionMode?.targetMode,
            customInstructions: optionalTrimmed(customInstructions),
            environmentContextDisabled: environmentContextDisabled,
            secureFieldExclusion: secureFieldExclusion
        )
    }

    private func optionalTrimmed(_ value: String) -> String? {
        let trimmedValue = trimmed(value)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
