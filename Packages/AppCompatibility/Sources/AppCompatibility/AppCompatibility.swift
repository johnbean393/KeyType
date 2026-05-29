import AutocompleteCore
import Foundation

public struct TargetOverride: Equatable {
    public var bundleIdentifier: String?
    public var domain: String?
    public var completionsDisabled: Bool
    public var midLineCompletionsDisabled: Bool
    public var tabShortcutsDisabled: Bool
    public var trainingDataCollectionDisabled: Bool
    public var requiresPasteAndMatchStyle: Bool
    public var requiresNonBreakingSpaceWorkaround: Bool
    public var stringInjectionChunkSize: Int?
    public var fontSizeAdjustmentFactor: Double
    public var verticalAlignmentOffset: Double
    public var customInstructions: String?

    public init(
        bundleIdentifier: String? = nil,
        domain: String? = nil,
        completionsDisabled: Bool = false,
        midLineCompletionsDisabled: Bool = false,
        tabShortcutsDisabled: Bool = false,
        trainingDataCollectionDisabled: Bool = false,
        requiresPasteAndMatchStyle: Bool = false,
        requiresNonBreakingSpaceWorkaround: Bool = false,
        stringInjectionChunkSize: Int? = nil,
        fontSizeAdjustmentFactor: Double = 1,
        verticalAlignmentOffset: Double = 0,
        customInstructions: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.domain = domain
        self.completionsDisabled = completionsDisabled
        self.midLineCompletionsDisabled = midLineCompletionsDisabled
        self.tabShortcutsDisabled = tabShortcutsDisabled
        self.trainingDataCollectionDisabled = trainingDataCollectionDisabled
        self.requiresPasteAndMatchStyle = requiresPasteAndMatchStyle
        self.requiresNonBreakingSpaceWorkaround = requiresNonBreakingSpaceWorkaround
        self.stringInjectionChunkSize = stringInjectionChunkSize
        self.fontSizeAdjustmentFactor = fontSizeAdjustmentFactor
        self.verticalAlignmentOffset = verticalAlignmentOffset
        self.customInstructions = customInstructions
    }

    public func matches(_ target: AppTarget) -> Bool {
        if let bundleIdentifier, bundleIdentifier != target.bundleIdentifier {
            return false
        }
        if let domain, domain != target.domain {
            return false
        }
        return bundleIdentifier != nil || domain != nil
    }
}

public struct CompletionPolicy: Equatable {
    public var isCompletionEnabled: Bool
    public var allowsMidLineCompletion: Bool
    public var allowsTabAcceptance: Bool
    public var allowsTrainingDataCollection: Bool
    public var insertionRequiresPasteAndMatchStyle: Bool
    public var insertionRequiresNonBreakingSpace: Bool
    public var stringInjectionChunkSize: Int?
    public var fontSizeAdjustmentFactor: Double
    public var verticalAlignmentOffset: Double
    public var customInstructions: [String]

    public init(
        isCompletionEnabled: Bool = true,
        allowsMidLineCompletion: Bool = true,
        allowsTabAcceptance: Bool = true,
        allowsTrainingDataCollection: Bool = true,
        insertionRequiresPasteAndMatchStyle: Bool = false,
        insertionRequiresNonBreakingSpace: Bool = false,
        stringInjectionChunkSize: Int? = nil,
        fontSizeAdjustmentFactor: Double = 1,
        verticalAlignmentOffset: Double = 0,
        customInstructions: [String] = []
    ) {
        self.isCompletionEnabled = isCompletionEnabled
        self.allowsMidLineCompletion = allowsMidLineCompletion
        self.allowsTabAcceptance = allowsTabAcceptance
        self.allowsTrainingDataCollection = allowsTrainingDataCollection
        self.insertionRequiresPasteAndMatchStyle = insertionRequiresPasteAndMatchStyle
        self.insertionRequiresNonBreakingSpace = insertionRequiresNonBreakingSpace
        self.stringInjectionChunkSize = stringInjectionChunkSize
        self.fontSizeAdjustmentFactor = fontSizeAdjustmentFactor
        self.verticalAlignmentOffset = verticalAlignmentOffset
        self.customInstructions = customInstructions
    }
}

public struct AppCompatibilityStore {
    private var overrides: [TargetOverride]

    public init(overrides: [TargetOverride] = AppCompatibilityStore.defaultOverrides) {
        self.overrides = overrides
    }

    public func policy(for target: AppTarget) -> CompletionPolicy {
        var policy = CompletionPolicy()

        for override in overrides where override.matches(target) {
            if override.completionsDisabled {
                policy.isCompletionEnabled = false
            }
            if override.midLineCompletionsDisabled {
                policy.allowsMidLineCompletion = false
            }
            if override.tabShortcutsDisabled {
                policy.allowsTabAcceptance = false
            }
            if override.trainingDataCollectionDisabled {
                policy.allowsTrainingDataCollection = false
            }

            policy.insertionRequiresPasteAndMatchStyle = policy.insertionRequiresPasteAndMatchStyle || override.requiresPasteAndMatchStyle
            policy.insertionRequiresNonBreakingSpace = policy.insertionRequiresNonBreakingSpace || override.requiresNonBreakingSpaceWorkaround
            policy.stringInjectionChunkSize = override.stringInjectionChunkSize ?? policy.stringInjectionChunkSize
            policy.fontSizeAdjustmentFactor *= override.fontSizeAdjustmentFactor
            policy.verticalAlignmentOffset += override.verticalAlignmentOffset

            if let customInstructions = override.customInstructions, !customInstructions.isEmpty {
                policy.customInstructions.append(customInstructions)
            }
        }

        return policy
    }

    public static let defaultOverrides: [TargetOverride] = [
        TargetOverride(
            bundleIdentifier: "com.apple.Terminal",
            midLineCompletionsDisabled: true,
            trainingDataCollectionDisabled: true,
            customInstructions: "Respect shell syntax and avoid prose-style continuations."
        ),
        TargetOverride(
            bundleIdentifier: "com.google.Chrome",
            domain: "docs.google.com",
            requiresPasteAndMatchStyle: true,
            verticalAlignmentOffset: 1
        )
    ]
}
