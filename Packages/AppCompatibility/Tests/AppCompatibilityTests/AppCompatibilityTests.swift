import AutocompleteCore
import CoreGraphics
import XCTest
@testable import AppCompatibility

final class AppCompatibilityTests: XCTestCase {
    func testDomainOverrideMatchesSubdomainAndAppliesGoogleDocsWorkarounds() {
        let target = AppTarget(
            bundleIdentifier: "com.microsoft.edgemac",
            appName: "Edge",
            domain: "www.docs.google.com"
        )
        let context = TextFieldContext(
            beforeCursor: "hello",
            geometry: TextFieldGeometry(cursorRect: .zero, cursorRectQuality: .exact),
            target: target,
            traits: TextFieldTraits(isWebField: true)
        )

        let policy = AppCompatibilityStore().policy(for: context)

        XCTAssertTrue(policy.isCompletionEnabled)
        XCTAssertTrue(policy.allowsTabAcceptance)
        XCTAssertFalse(policy.allowsMidLineCompletion)
        XCTAssertTrue(policy.insertionRequiresPasteAndMatchStyle)
        XCTAssertTrue(policy.insertionRequiresBackspaceAfterPaste)
        XCTAssertEqual(policy.overlayPreference, .textMirror)
        XCTAssertEqual(policy.fontSizeAdjustmentFactor, 0.96, accuracy: 0.001)
        XCTAssertFalse(policy.customInstructions.isEmpty)
    }

    func testTerminalPolicySuppressesTabAcceptanceAndUsesTerminalMode() {
        let target = AppTarget(bundleIdentifier: "com.googlecode.iterm2", appName: "iTerm2")
        let context = TextFieldContext(
            beforeCursor: "git sta",
            target: target,
            traits: TextFieldTraits(isTerminalLike: true)
        )

        let policy = AppCompatibilityStore().policy(for: context)

        XCTAssertFalse(policy.allowsMidLineCompletion)
        XCTAssertFalse(policy.allowsTabAcceptance)
        XCTAssertFalse(policy.allowsTrainingDataCollection)
        XCTAssertFalse(policy.includesEnvironmentContext)
        XCTAssertEqual(policy.completionMode, .terminal)
    }

    func testCursorUsesCodeEditorPolicy() {
        let target = AppTarget(bundleIdentifier: "com.todesktop.230313mzl4w4u92", appName: "Cursor")
        let context = TextFieldContext(beforeCursor: "let value = cur", target: target)

        let policy = AppCompatibilityStore().policy(for: context)

        XCTAssertTrue(policy.isCompletionEnabled)
        XCTAssertTrue(policy.allowsTabAcceptance)
        XCTAssertFalse(policy.includesEnvironmentContext)
        XCTAssertEqual(policy.overlayPreference, .inline)
        XCTAssertEqual(policy.completionMode, .prose)
    }

    func testWeChatUsesChatSurfacePolicy() {
        let target = AppTarget(bundleIdentifier: "com.tencent.xinWeChat", appName: "WeChat")
        let context = TextFieldContext(beforeCursor: "sounds good, I can", target: target)

        let policy = AppCompatibilityStore().policy(for: context)

        XCTAssertTrue(policy.isCompletionEnabled)
        XCTAssertTrue(policy.allowsTabAcceptance)
        XCTAssertEqual(policy.stringInjectionChunkSize, 8)
        XCTAssertFalse(policy.insertionRequiresPasteAndMatchStyle)
        XCTAssertEqual(policy.overlayPreference, .inline)
        XCTAssertEqual(policy.completionMode, .prose)
        XCTAssertEqual(policy.customInstructions, [
            "Continue the current WeChat message only. Keep it short and conversational."
        ])
    }

    func testIAWriterUsesDirectStringInjection() {
        let target = AppTarget(
            bundleIdentifier: "pro.writer.mac",
            appName: "iA Writer",
            domain: "Writer.txt"
        )
        let context = TextFieldContext(beforeCursor: "What ab", target: target)

        let policy = AppCompatibilityStore().policy(for: context)

        XCTAssertTrue(policy.isCompletionEnabled)
        XCTAssertTrue(policy.allowsTabAcceptance)
        XCTAssertEqual(policy.stringInjectionChunkSize, 8)
        XCTAssertFalse(policy.insertionRequiresPasteAndMatchStyle)
        XCTAssertEqual(policy.overlayPreference, .inline)
        XCTAssertEqual(policy.completionMode, .prose)
        XCTAssertEqual(policy.customInstructions, [
            "Continue only the current iA Writer document at the cursor. Preserve the document's prose or Markdown style; avoid file-browser chrome and window titles."
        ])
    }

    func testMessagesUsesDirectStringInjection() {
        let target = AppTarget(bundleIdentifier: "com.apple.MobileSMS", appName: "Messages")
        let context = TextFieldContext(beforeCursor: "this is a wo", target: target)

        let policy = AppCompatibilityStore().policy(for: context)

        XCTAssertTrue(policy.isCompletionEnabled)
        XCTAssertTrue(policy.allowsTabAcceptance)
        XCTAssertEqual(policy.stringInjectionChunkSize, 8)
        XCTAssertFalse(policy.insertionRequiresPasteAndMatchStyle)
        XCTAssertEqual(policy.overlayPreference, .inline)
        XCTAssertEqual(policy.completionMode, .prose)
        XCTAssertEqual(policy.customInstructions, [
            "Continue the current message. Keep it short and conversational."
        ])
    }

    func testObsidianUsesMarkdownEditorPolicy() {
        let target = AppTarget(bundleIdentifier: "md.obsidian", appName: "Obsidian")
        let context = TextFieldContext(
            beforeCursor: "## Notes\nLet's",
            target: target,
            traits: TextFieldTraits(isWebField: true)
        )

        let policy = AppCompatibilityStore().policy(for: context)

        XCTAssertTrue(policy.isCompletionEnabled)
        XCTAssertTrue(policy.allowsTabAcceptance)
        XCTAssertFalse(policy.allowsMidLineCompletion)
        XCTAssertFalse(policy.includesEnvironmentContext)
        XCTAssertEqual(policy.overlayPreference, .inline)
        XCTAssertEqual(policy.completionMode, .prose)
        XCTAssertEqual(policy.customInstructions, [
            "Continue only the current Obsidian note at the cursor. Preserve Markdown style; avoid vault chrome, backlinks, and file-tree text."
        ])
    }

    func testOverrideCanExplicitlyEnableMidLineCompletion() {
        let target = AppTarget(bundleIdentifier: "com.example.proven-midline", appName: "Proven")
        let context = TextFieldContext(beforeCursor: "before", afterCursor: "after", target: target)
        let store = AppCompatibilityStore(overrides: [
            TargetOverride(bundleIdentifier: target.bundleIdentifier, midLineCompletionsEnabled: true)
        ])

        let policy = store.policy(for: context)

        XCTAssertTrue(policy.allowsMidLineCompletion)
    }

    func testSlackNativeUsesTextMirrorWithVerticalAlignmentFix() {
        let target = AppTarget(bundleIdentifier: "com.tinyspeck.slackmacgap", appName: "Slack")
        let context = TextFieldContext(beforeCursor: "Let's", target: target)

        let policy = AppCompatibilityStore().policy(for: context)

        XCTAssertTrue(policy.isCompletionEnabled)
        XCTAssertFalse(policy.insertionRequiresPasteAndMatchStyle)
        XCTAssertEqual(policy.stringInjectionChunkSize, 8)
        XCTAssertEqual(policy.overlayPreference, .textMirror)
        XCTAssertEqual(policy.verticalAlignmentOffset(24), 24, accuracy: 0.001)
        XCTAssertEqual(policy.customInstructions, [
            "Continue the current Slack message only. Keep it short and conversational."
        ])
    }

    func testSlackDomainKeepsWebSurfacePolicyWithoutNativeOffset() {
        let target = AppTarget(
            bundleIdentifier: "com.google.Chrome",
            appName: "Chrome",
            domain: "app.slack.com"
        )
        let context = TextFieldContext(beforeCursor: "Let's", target: target)

        let policy = AppCompatibilityStore().policy(for: context)

        XCTAssertTrue(policy.isCompletionEnabled)
        XCTAssertTrue(policy.insertionRequiresPasteAndMatchStyle)
        XCTAssertNil(policy.stringInjectionChunkSize)
        XCTAssertEqual(policy.overlayPreference, .textMirror)
        XCTAssertEqual(policy.verticalAlignmentOffset(24), 0, accuracy: 0.001)
        XCTAssertEqual(policy.customInstructions, [
            "Continue the current message only. Keep it short and conversational."
        ])
    }

    func testNotionNativeUsesTextMirrorWithVerticalAlignmentFix() {
        let target = AppTarget(bundleIdentifier: "notion.id", appName: "Notion")
        let context = TextFieldContext(beforeCursor: "K", target: target)

        let policy = AppCompatibilityStore().policy(for: context)

        XCTAssertTrue(policy.isCompletionEnabled)
        XCTAssertTrue(policy.insertionRequiresPasteAndMatchStyle)
        XCTAssertEqual(policy.overlayPreference, .textMirror)
        XCTAssertEqual(policy.verticalAlignmentOffset(24), 24, accuracy: 0.001)
        XCTAssertEqual(policy.customInstructions, [
            "Continue the current Notion block only; do not include page chrome or database UI text."
        ])
    }

    func testNotionDomainKeepsWebSurfacePolicyWithoutNativeOffset() {
        let target = AppTarget(
            bundleIdentifier: "com.google.Chrome",
            appName: "Chrome",
            domain: "notion.so"
        )
        let context = TextFieldContext(beforeCursor: "K", target: target)

        let policy = AppCompatibilityStore().policy(for: context)

        XCTAssertTrue(policy.isCompletionEnabled)
        XCTAssertTrue(policy.insertionRequiresPasteAndMatchStyle)
        XCTAssertEqual(policy.overlayPreference, .textMirror)
        XCTAssertEqual(policy.verticalAlignmentOffset(24), 0, accuracy: 0.001)
        XCTAssertEqual(policy.customInstructions, [
            "Continue the current Notion block only; do not include page chrome or database UI text."
        ])
    }

    func testDiscordNativeUsesTextMirrorWithoutNativeOffset() {
        let target = AppTarget(bundleIdentifier: "com.hnc.Discord", appName: "Discord")
        let context = TextFieldContext(beforeCursor: "This", target: target)

        let policy = AppCompatibilityStore().policy(for: context)

        XCTAssertTrue(policy.isCompletionEnabled)
        XCTAssertFalse(policy.insertionRequiresPasteAndMatchStyle)
        XCTAssertEqual(policy.stringInjectionChunkSize, 8)
        XCTAssertEqual(policy.overlayPreference, .textMirror)
        XCTAssertEqual(policy.verticalAlignmentOffset(24), 0, accuracy: 0.001)
        XCTAssertEqual(policy.customInstructions, [
            "Continue the current Discord message only. Keep it short and conversational."
        ])
    }

    func testDiscordDomainKeepsWebSurfacePolicyWithoutNativeOffset() {
        let target = AppTarget(
            bundleIdentifier: "com.google.Chrome",
            appName: "Chrome",
            domain: "discord.com"
        )
        let context = TextFieldContext(beforeCursor: "This", target: target)

        let policy = AppCompatibilityStore().policy(for: context)

        XCTAssertTrue(policy.isCompletionEnabled)
        XCTAssertTrue(policy.insertionRequiresPasteAndMatchStyle)
        XCTAssertEqual(policy.overlayPreference, .textMirror)
        XCTAssertEqual(policy.verticalAlignmentOffset(24), 0, accuracy: 0.001)
        XCTAssertEqual(policy.customInstructions, [
            "Continue the current message only. Keep it short and conversational."
        ])
    }

    func testPasswordManagerBundleIsSecureExcluded() {
        let target = AppTarget(bundleIdentifier: "com.1password.1password", appName: "1Password")
        let context = TextFieldContext(beforeCursor: "sec", target: target)

        let policy = AppCompatibilityStore().policy(for: context)

        XCTAssertTrue(policy.excludesSecureField)
        XCTAssertFalse(policy.isCompletionEnabled)
        XCTAssertFalse(policy.allowsTabAcceptance)
        XCTAssertEqual(policy.overlayPreference, .hidden)
    }

    func testPasswordFieldHintsAreSecureExcludedInAnyApp() {
        let target = AppTarget(bundleIdentifier: "com.google.Chrome", appName: "Chrome")
        let context = TextFieldContext(
            beforeCursor: "hunter",
            target: target,
            placeholder: "Password",
            labels: ["Account password"]
        )

        let policy = AppCompatibilityStore(overrides: []).policy(for: context)

        XCTAssertTrue(policy.excludesSecureField)
        XCTAssertFalse(policy.isCompletionEnabled)
        XCTAssertFalse(policy.allowsTabAcceptance)
        XCTAssertFalse(policy.allowsTrainingDataCollection)
    }

    func testUserPerAppDisableOverridesDefaultEnabledPolicy() {
        let target = AppTarget(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit")
        let context = TextFieldContext(beforeCursor: "hello there", target: target)

        // By default TextEdit allows completions.
        XCTAssertTrue(AppCompatibilityStore().policy(for: context).isCompletionEnabled)

        // A user-chosen per-app disable (from Settings) must turn it off.
        let store = AppCompatibilityStore(
            userDisabledBundleIdentifiers: ["com.apple.TextEdit"]
        )
        let policy = store.policy(for: context)
        XCTAssertFalse(policy.isCompletionEnabled)
        XCTAssertFalse(policy.allowsTabAcceptance)
        XCTAssertFalse(policy.allowsTrainingDataCollection)
    }

    func testUserPerAppDisableLeavesOtherAppsUnaffected() {
        let store = AppCompatibilityStore(
            userDisabledBundleIdentifiers: ["com.apple.TextEdit"]
        )
        let other = AppTarget(bundleIdentifier: "com.apple.Notes", appName: "Notes")
        let context = TextFieldContext(beforeCursor: "hello there", target: other)
        XCTAssertTrue(store.policy(for: context).isCompletionEnabled)
    }

    func testEstimatedWebCaretKeepsInlineOverlayPreference() {
        let target = AppTarget(bundleIdentifier: "com.google.Chrome", appName: "Chrome", domain: "example.com")
        let context = TextFieldContext(
            beforeCursor: "hello",
            geometry: TextFieldGeometry(cursorRect: .zero, cursorRectQuality: .estimated),
            target: target,
            traits: TextFieldTraits(isWebField: true)
        )

        let policy = AppCompatibilityStore(overrides: []).policy(for: context)

        XCTAssertEqual(policy.overlayPreference, .inline)
    }
}
