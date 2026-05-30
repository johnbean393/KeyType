import AutocompleteCore
import Foundation

public enum OverlayPreference: Equatable {
    case inline
    case textMirror
    case hidden
}

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
    public var requiresBackspaceAfterPaste: Bool
    public var fontSizeAdjustmentFactor: Double
    public var verticalAlignmentOffset: Double
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
        midLineCompletionsDisabled: Bool = false,
        tabShortcutsDisabled: Bool = false,
        trainingDataCollectionDisabled: Bool = false,
        requiresPasteAndMatchStyle: Bool = false,
        requiresNonBreakingSpaceWorkaround: Bool = false,
        stringInjectionChunkSize: Int? = nil,
        requiresBackspaceAfterPaste: Bool = false,
        fontSizeAdjustmentFactor: Double = 1,
        verticalAlignmentOffset: Double = 0,
        overlayPreference: OverlayPreference? = nil,
        completionMode: CompletionMode? = nil,
        customInstructions: String? = nil,
        environmentContextDisabled: Bool = false,
        secureFieldExclusion: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.domain = domain.map(Self.normalizedDomain)
        self.completionsDisabled = completionsDisabled
        self.midLineCompletionsDisabled = midLineCompletionsDisabled
        self.tabShortcutsDisabled = tabShortcutsDisabled
        self.trainingDataCollectionDisabled = trainingDataCollectionDisabled
        self.requiresPasteAndMatchStyle = requiresPasteAndMatchStyle
        self.requiresNonBreakingSpaceWorkaround = requiresNonBreakingSpaceWorkaround
        self.stringInjectionChunkSize = stringInjectionChunkSize
        self.requiresBackspaceAfterPaste = requiresBackspaceAfterPaste
        self.fontSizeAdjustmentFactor = fontSizeAdjustmentFactor
        self.verticalAlignmentOffset = verticalAlignmentOffset
        self.overlayPreference = overlayPreference
        self.completionMode = completionMode
        self.customInstructions = customInstructions
        self.environmentContextDisabled = environmentContextDisabled
        self.secureFieldExclusion = secureFieldExclusion
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

public struct CompletionPolicy: Equatable {
    public var isCompletionEnabled: Bool
    public var allowsMidLineCompletion: Bool
    public var allowsTabAcceptance: Bool
    public var allowsTrainingDataCollection: Bool
    public var insertionRequiresPasteAndMatchStyle: Bool
    public var insertionRequiresNonBreakingSpace: Bool
    public var stringInjectionChunkSize: Int?
    public var insertionRequiresBackspaceAfterPaste: Bool
    public var fontSizeAdjustmentFactor: Double
    public var verticalAlignmentOffset: Double
    public var overlayPreference: OverlayPreference
    public var completionMode: CompletionMode
    public var customInstructions: [String]
    /// Whether app/window/field metadata is included in the prompt. False for code editors and
    /// terminals (see `TargetOverride.environmentContextDisabled` / ADR-017).
    public var includesEnvironmentContext: Bool
    public var excludesSecureField: Bool

    public init(
        isCompletionEnabled: Bool = true,
        allowsMidLineCompletion: Bool = true,
        allowsTabAcceptance: Bool = true,
        allowsTrainingDataCollection: Bool = true,
        insertionRequiresPasteAndMatchStyle: Bool = false,
        insertionRequiresNonBreakingSpace: Bool = false,
        stringInjectionChunkSize: Int? = nil,
        insertionRequiresBackspaceAfterPaste: Bool = false,
        fontSizeAdjustmentFactor: Double = 1,
        verticalAlignmentOffset: Double = 0,
        overlayPreference: OverlayPreference = .inline,
        completionMode: CompletionMode = .prose,
        customInstructions: [String] = [],
        includesEnvironmentContext: Bool = true,
        excludesSecureField: Bool = false
    ) {
        self.isCompletionEnabled = isCompletionEnabled
        self.allowsMidLineCompletion = allowsMidLineCompletion
        self.allowsTabAcceptance = allowsTabAcceptance
        self.allowsTrainingDataCollection = allowsTrainingDataCollection
        self.insertionRequiresPasteAndMatchStyle = insertionRequiresPasteAndMatchStyle
        self.insertionRequiresNonBreakingSpace = insertionRequiresNonBreakingSpace
        self.stringInjectionChunkSize = stringInjectionChunkSize
        self.insertionRequiresBackspaceAfterPaste = insertionRequiresBackspaceAfterPaste
        self.fontSizeAdjustmentFactor = fontSizeAdjustmentFactor
        self.verticalAlignmentOffset = verticalAlignmentOffset
        self.overlayPreference = overlayPreference
        self.completionMode = completionMode
        self.customInstructions = customInstructions
        self.includesEnvironmentContext = includesEnvironmentContext
        self.excludesSecureField = excludesSecureField
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
            if override.secureFieldExclusion {
                policy.excludesSecureField = true
            }
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
            if override.environmentContextDisabled {
                policy.includesEnvironmentContext = false
            }

            policy.insertionRequiresPasteAndMatchStyle = policy.insertionRequiresPasteAndMatchStyle || override.requiresPasteAndMatchStyle
            policy.insertionRequiresNonBreakingSpace = policy.insertionRequiresNonBreakingSpace || override.requiresNonBreakingSpaceWorkaround
            policy.stringInjectionChunkSize = override.stringInjectionChunkSize ?? policy.stringInjectionChunkSize
            policy.insertionRequiresBackspaceAfterPaste = policy.insertionRequiresBackspaceAfterPaste || override.requiresBackspaceAfterPaste
            policy.fontSizeAdjustmentFactor *= override.fontSizeAdjustmentFactor
            policy.verticalAlignmentOffset += override.verticalAlignmentOffset
            policy.overlayPreference = override.overlayPreference ?? policy.overlayPreference
            policy.completionMode = override.completionMode ?? policy.completionMode

            if let customInstructions = override.customInstructions, !customInstructions.isEmpty {
                policy.customInstructions.append(customInstructions)
            }
        }

        return policy
    }

    public func policy(for context: TextFieldContext) -> CompletionPolicy {
        var policy = policy(for: context.target)

        if context.traits.isTerminalLike {
            applyTerminalSafety(to: &policy)
        }

        if context.traits.isWebField, context.geometry.cursorRectQuality == .estimated {
            policy.overlayPreference = .textMirror
        }

        if context.traits.isSecureTextEntry
            || context.traits.isPasswordField
            || context.traits.isPasswordManagerContext
            || looksSensitive(context) {
            applySecureExclusion(to: &policy)
        }

        return policy
    }

    private func applySecureExclusion(to policy: inout CompletionPolicy) {
        policy.excludesSecureField = true
        policy.isCompletionEnabled = false
        policy.allowsTabAcceptance = false
        policy.allowsTrainingDataCollection = false
        policy.overlayPreference = .hidden
        policy.customInstructions.removeAll()
    }

    private func applyTerminalSafety(to policy: inout CompletionPolicy) {
        policy.allowsMidLineCompletion = false
        policy.allowsTabAcceptance = false
        policy.allowsTrainingDataCollection = false
        policy.overlayPreference = .textMirror
        policy.completionMode = .terminal
        policy.includesEnvironmentContext = false
    }

    private func looksSensitive(_ context: TextFieldContext) -> Bool {
        let haystack = ([context.placeholder] + context.labels.map(Optional.some))
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        guard !haystack.isEmpty else { return false }

        let sensitiveTerms = [
            "password", "passcode", "passphrase", "master key", "secret key",
            "security code", "verification code", "one-time code", "one time code",
            "totp", "2fa", "mfa", "cvv", "cvc"
        ]
        return sensitiveTerms.contains { haystack.contains($0) }
    }

    public static let defaultOverrides: [TargetOverride] = {
        var result: [TargetOverride] = []

        let terminalInstructions = "Treat this as a terminal prompt. Do not generate prose, chatty explanations, or text that would interfere with shell/TUI Tab completion."
        let terminalBundles = [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "dev.warp.Warp-Stable",
            "com.mitchellh.ghostty",
            "com.mitchellh.ghostty.debug",
            "org.alacritty",
            "net.kovidgoyal.kitty",
            "com.github.wez.wezterm"
        ]
        result += terminalBundles.map {
            TargetOverride(
                bundleIdentifier: $0,
                midLineCompletionsDisabled: true,
                tabShortcutsDisabled: true,
                trainingDataCollectionDisabled: true,
                overlayPreference: .textMirror,
                completionMode: .terminal,
                customInstructions: terminalInstructions,
                environmentContextDisabled: true
            )
        }

        let passwordManagerBundles = [
            "com.1password.1password",
            "com.apple.Passwords",
            "com.bitwarden.desktop",
            "com.callpod.keepermac.lite",
            "com.dashlane.Dashlane",
            "com.dashlane.dashlanephonefinal",
            "com.keepersecurity.passwordmanager",
            "com.lastpass.LastPass",
            "com.lastpass.lastpassmacdesktop"
        ]
        result += passwordManagerBundles.map {
            TargetOverride(
                bundleIdentifier: $0,
                completionsDisabled: true,
                tabShortcutsDisabled: true,
                trainingDataCollectionDisabled: true,
                overlayPreference: .hidden,
                secureFieldExclusion: true
            )
        }

        result += [
        // Code editors: the window title / app metadata biases a base model toward code and
        // numbers, so we strip environment context and keep only the cursor-local text. ADR-017.
        TargetOverride(
            bundleIdentifier: "com.apple.dt.Xcode",
            environmentContextDisabled: true
        ),
        TargetOverride(
            bundleIdentifier: "com.microsoft.VSCode",
            environmentContextDisabled: true
        ),
        TargetOverride(
            bundleIdentifier: "com.microsoft.VSCodeInsiders",
            environmentContextDisabled: true
        ),
        TargetOverride(
            bundleIdentifier: "com.apple.Safari",
            fontSizeAdjustmentFactor: 0.98,
            verticalAlignmentOffset: 1
        ),
        TargetOverride(
            bundleIdentifier: "com.google.Chrome",
            domain: "docs.google.com",
            requiresPasteAndMatchStyle: true,
            requiresBackspaceAfterPaste: true,
            fontSizeAdjustmentFactor: 0.96,
            verticalAlignmentOffset: 1,
            overlayPreference: .textMirror,
            customInstructions: "Continue only the Google Docs document text at the cursor. Avoid UI labels, menus, comments, and browser chrome."
        ),
        TargetOverride(
            domain: "docs.google.com",
            requiresPasteAndMatchStyle: true,
            requiresBackspaceAfterPaste: true,
            fontSizeAdjustmentFactor: 0.96,
            verticalAlignmentOffset: 1,
            overlayPreference: .textMirror,
            customInstructions: "Continue only the Google Docs document text at the cursor. Avoid UI labels, menus, comments, and browser chrome."
        ),
        TargetOverride(
            domain: "mail.google.com",
            requiresPasteAndMatchStyle: true,
            verticalAlignmentOffset: 1,
            customInstructions: "Continue the email being drafted. Keep the tone concise and context-appropriate."
        ),
        TargetOverride(
            domain: "notion.so",
            requiresPasteAndMatchStyle: true,
            overlayPreference: .textMirror,
            customInstructions: "Continue the current Notion block only; do not include page chrome or database UI text."
        ),
        TargetOverride(
            domain: "slack.com",
            requiresPasteAndMatchStyle: true,
            overlayPreference: .textMirror,
            customInstructions: "Continue the current message only. Keep it short and conversational."
        ),
        TargetOverride(
            domain: "discord.com",
            requiresPasteAndMatchStyle: true,
            overlayPreference: .textMirror,
            customInstructions: "Continue the current message only. Keep it short and conversational."
        ),
        TargetOverride(
            bundleIdentifier: "com.apple.mail",
            customInstructions: "Continue the current email draft. Prefer concise, natural prose."
        ),
        TargetOverride(
            bundleIdentifier: "com.apple.MobileSMS",
            customInstructions: "Continue the current message. Keep it short and conversational."
        ),
        TargetOverride(
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            requiresPasteAndMatchStyle: true,
            overlayPreference: .textMirror,
            customInstructions: "Continue the current Slack message only. Keep it short and conversational."
        ),
        TargetOverride(
            bundleIdentifier: "notion.id",
            requiresPasteAndMatchStyle: true,
            overlayPreference: .textMirror,
            customInstructions: "Continue the current Notion block only; do not include page chrome or database UI text."
        ),
        TargetOverride(
            bundleIdentifier: "com.hnc.Discord",
            requiresPasteAndMatchStyle: true,
            overlayPreference: .textMirror,
            customInstructions: "Continue the current Discord message only. Keep it short and conversational."
        )
        ]

        let passwordDomains = [
            "1password.com",
            "bitwarden.com",
            "dashlane.com",
            "lastpass.com",
            "keepersecurity.com"
        ]
        result += passwordDomains.map {
            TargetOverride(
                domain: $0,
                completionsDisabled: true,
                tabShortcutsDisabled: true,
                trainingDataCollectionDisabled: true,
                overlayPreference: .hidden,
                secureFieldExclusion: true
            )
        }

        return result
    }()
}

private extension String {
    func trimmingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
