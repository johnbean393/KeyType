import AutocompleteCore

public extension AppCompatibilityStore {
    static let defaultOverrides: [TargetOverride] = {
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
                bundleIdentifier: "com.todesktop.230313mzl4w4u92",
                environmentContextDisabled: true
            ),
            TargetOverride(
                bundleIdentifier: "com.apple.TextEdit",
                verticalAlignmentOffset: { _ in 7 }
            ),
            TargetOverride(
                bundleIdentifier: "com.apple.Safari",
                fontSizeAdjustmentFactor: 0.98,
                verticalAlignmentOffset: { _ in 4 }
            ),
            TargetOverride(
                bundleIdentifier: "com.google.Chrome",
                verticalAlignmentOffset: { _ in 4 }
            ),
            TargetOverride(
                bundleIdentifier: "com.google.Chrome",
                domain: "docs.google.com",
                requiresPasteAndMatchStyle: true,
                requiresBackspaceAfterPaste: true,
                fontSizeAdjustmentFactor: 0.96,
                verticalAlignmentOffset: { _ in 1 },
                overlayPreference: .textMirror,
                customInstructions: "Continue only the Google Docs document text at the cursor. Avoid UI labels, menus, comments, and browser chrome."
            ),
            TargetOverride(
                domain: "docs.google.com",
                requiresPasteAndMatchStyle: true,
                requiresBackspaceAfterPaste: true,
                fontSizeAdjustmentFactor: 0.96,
                verticalAlignmentOffset: { _ in 1 },
                overlayPreference: .textMirror,
                customInstructions: "Continue only the Google Docs document text at the cursor. Avoid UI labels, menus, comments, and browser chrome."
            ),
            TargetOverride(
                domain: "mail.google.com",
                requiresPasteAndMatchStyle: true,
                verticalAlignmentOffset: { _ in 1 },
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
                bundleIdentifier: "com.apple.mail",
                customInstructions: "Continue the current email draft. Prefer concise, natural prose."
            ),
            TargetOverride(
                bundleIdentifier: "com.apple.MobileSMS",
                stringInjectionChunkSize: 8,
                verticalAlignmentOffset: { lineHeight in return -7 },
                customInstructions: "Continue the current message. Keep it short and conversational."
            ),
            TargetOverride(
                bundleIdentifier: "pro.writer.mac",
                stringInjectionChunkSize: 8,
                overlayPreference: .inline,
                customInstructions: "Continue only the current iA Writer document at the cursor. Preserve the document's prose or Markdown style; avoid file-browser chrome and window titles."
            ),
            TargetOverride(
                bundleIdentifier: "com.tencent.xinWeChat",
                stringInjectionChunkSize: 8,
                overlayPreference: .inline,
                customInstructions: "Continue the current WeChat message only. Keep it short and conversational."
            ),
            TargetOverride(
                bundleIdentifier: "md.obsidian",
                overlayPreference: .inline,
                customInstructions: "Continue only the current Obsidian note at the cursor. Preserve Markdown style; avoid vault chrome, backlinks, and file-tree text.",
                environmentContextDisabled: true
            ),
            TargetOverride(
                bundleIdentifier: "com.tinyspeck.slackmacgap",
                stringInjectionChunkSize: 8,
                overlayPreference: .textMirror,
                customInstructions: "Continue the current Slack message only. Keep it short and conversational."
            ),
            TargetOverride(
                bundleIdentifier: "notion.id",
                requiresPasteAndMatchStyle: true,
                overlayPreference: .textMirror,
                customInstructions: "Continue the current Notion block only; do not include page chrome or database UI text."
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
