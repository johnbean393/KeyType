import AppKit
import ApplicationServices
import AutocompleteCore
import Foundation

public enum AccessibilityPermissionStatus: Equatable {
    case trusted
    case notTrusted
}

public struct AccessibilityPermissionChecker {
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

        let app = NSWorkspace.shared.frontmostApplication
        let target = AppTarget(
            bundleIdentifier: app?.bundleIdentifier ?? "unknown",
            appName: app?.localizedName ?? "Unknown"
        )

        return TextFieldContext(
            beforeCursor: "",
            target: target,
            typingContext: "focused macOS text field"
        )
    }
}
