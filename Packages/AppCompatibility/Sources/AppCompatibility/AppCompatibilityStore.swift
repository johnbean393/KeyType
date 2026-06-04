import AutocompleteCore

public struct AppCompatibilityStore {
    private var overrides: [TargetOverride]

    public init(overrides: [TargetOverride] = AppCompatibilityStore.defaultOverrides) {
        self.overrides = overrides
    }

    /// Builds a store from the built-in `overrides` plus user-chosen per-app disables (from
    /// Settings). Each disabled bundle id gets an injected override that turns completions, Tab
    /// acceptance, and training-data collection off for that app, layered on top of the defaults,
    /// so a user disable always wins. See ADR-023.
    public init(
        overrides: [TargetOverride] = AppCompatibilityStore.defaultOverrides,
        userDisabledBundleIdentifiers: Set<String>
    ) {
        self.overrides = overrides + userDisabledBundleIdentifiers.map { bundleID in
            TargetOverride(
                bundleIdentifier: bundleID,
                completionsDisabled: true,
                tabShortcutsDisabled: true,
                trainingDataCollectionDisabled: true
            )
        }
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
            if override.midLineCompletionsEnabled {
                policy.allowsMidLineCompletion = true
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
            let currentVerticalAlignmentOffset = policy.verticalAlignmentOffset
            let overrideVerticalAlignmentOffset = override.verticalAlignmentOffset
            policy.verticalAlignmentOffset = { lineHeight in
                currentVerticalAlignmentOffset(lineHeight) + overrideVerticalAlignmentOffset(lineHeight)
            }
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
}
