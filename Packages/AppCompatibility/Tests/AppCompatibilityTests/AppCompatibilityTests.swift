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

    func testEstimatedWebCaretFallsBackToTextMirrorOverlay() {
        let target = AppTarget(bundleIdentifier: "com.google.Chrome", appName: "Chrome", domain: "example.com")
        let context = TextFieldContext(
            beforeCursor: "hello",
            geometry: TextFieldGeometry(cursorRect: .zero, cursorRectQuality: .estimated),
            target: target,
            traits: TextFieldTraits(isWebField: true)
        )

        let policy = AppCompatibilityStore(overrides: []).policy(for: context)

        XCTAssertEqual(policy.overlayPreference, .textMirror)
    }
}
