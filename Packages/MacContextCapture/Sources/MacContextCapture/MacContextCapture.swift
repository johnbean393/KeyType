import AppKit
import ApplicationServices
import AutocompleteCore
import Foundation

public enum AccessibilityPermissionStatus: Equatable {
    case trusted
    case notTrusted
}

public struct AccessibilityPermissionChecker: Sendable {
    public init() {}

    public func status(promptIfNeeded: Bool = false) -> AccessibilityPermissionStatus {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: promptIfNeeded
        ] as CFDictionary

        return AXIsProcessTrustedWithOptions(options) ? .trusted : .notTrusted
    }
}

public protocol FocusedTextContextCapturing {
    func captureFocusedTextContext() async throws -> TextFieldContext?
}

/// Pull-style context capture: the existing `ContextProviding`/`FocusedTextContextCapturing`
/// entry point. Reads the system-wide focused element once, runs it through `FocusedFieldReader`
/// to build a full `TextFieldContext`, and returns it. The push-style (notification-driven)
/// tracker lives in `AccessibilityContextTracker`.
public final class MacContextCaptureService: FocusedTextContextCapturing, ContextProviding {
    private let permissionChecker: AccessibilityPermissionChecker

    public init(permissionChecker: AccessibilityPermissionChecker = AccessibilityPermissionChecker()) {
        self.permissionChecker = permissionChecker
    }

    public func currentContext() async throws -> TextFieldContext? {
        try await captureFocusedTextContext()
    }

    public func captureFocusedTextContext() async throws -> TextFieldContext? {
        guard permissionChecker.status() == .trusted else {
            return nil
        }
        return await MainActor.run { Self.captureOnMain() }
    }

    public func captureFocusedFieldSnapshot() async throws -> FocusedFieldSnapshot? {
        guard permissionChecker.status() == .trusted else {
            return nil
        }
        return await MainActor.run { Self.captureSnapshotOnMain() }
    }

    @MainActor
    private static func captureOnMain() -> TextFieldContext? {
        if let snapshot = captureSnapshotOnMain() {
            return snapshot.context
        }

        let system = AXUIElementCreateSystemWide()
        guard AXCaretHelper.focusedElement(systemElement: system) == nil else { return nil }

        // Fall back to the bundle-id-only context we used to return so callers that just want
        // to know which app is frontmost still get an answer.
        let app = NSWorkspace.shared.frontmostApplication
        return TextFieldContext(
            beforeCursor: "",
            target: AppTarget(
                bundleIdentifier: app?.bundleIdentifier ?? "unknown",
                appName: app?.localizedName ?? "Unknown"
            ),
            typingContext: "focused macOS app (no AX text field)"
        )
    }

    @MainActor
    private static func captureSnapshotOnMain() -> FocusedFieldSnapshot? {
        let system = AXUIElementCreateSystemWide()
        guard let element = AXCaretHelper.focusedElement(systemElement: system) else {
            return nil
        }

        let reader = FocusedFieldReader()
        return reader.snapshot(of: element)
    }
}
