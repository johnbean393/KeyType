//
//  PermissionsManager.swift
//  KeyType
//
//  Created by Codex on 5/29/26.
//

import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import IOKit.hid
import Observation

/// Tracks the macOS privacy permissions KeyType depends on.
///
/// - Accessibility is **required**: it gates AX-based caret/text-field capture and
///   later synthetic keystroke injection. Without it, KeyType cannot function.
/// - Input Monitoring is **required**: the global acceptance hotkey is a `CGEvent` session tap that
///   listens for key-downs, which macOS gates behind Input Monitoring (listen-event) access.
/// - Screen Recording is **optional**: enables richer context capture (window/OCR) in
///   future milestones. The app should run fine without it.
@MainActor
@Observable
final class PermissionsManager {
    struct PermissionState: Equatable {
        var isGranted: Bool
    }

    private(set) var accessibility = PermissionState(isGranted: false)
    private(set) var inputMonitoring = PermissionState(isGranted: false)
    private(set) var screenRecording = PermissionState(isGranted: false)

    /// Both permissions KeyType needs to deliver and accept completions are granted.
    var requiredPermissionsGranted: Bool {
        accessibility.isGranted && inputMonitoring.isGranted
    }

    private var pollTimer: Timer?

    init() {
        refresh()
    }

    // No deinit: `PermissionsManager` lives for the app's lifetime (owned by `AppDelegate`).
    // Call `stopMonitoring()` explicitly from tests if you need a deterministic teardown.

    /// Begin a low-frequency main-actor poll so the UI reflects external changes
    /// (the user toggling the switch in System Settings) without manual refresh.
    func startMonitoring() {
        guard pollTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func refresh() {
        let ax = AXIsProcessTrusted()
        if accessibility.isGranted != ax {
            accessibility = PermissionState(isGranted: ax)
        }
        let listen = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if inputMonitoring.isGranted != listen {
            inputMonitoring = PermissionState(isGranted: listen)
        }
        let screen = CGPreflightScreenCaptureAccess()
        if screenRecording.isGranted != screen {
            screenRecording = PermissionState(isGranted: screen)
        }
    }

    // MARK: - Requests

    /// Pops the system Accessibility prompt (which deep-links the user to System Settings).
    /// Returns the current trusted status synchronously; the real grant happens asynchronously
    /// once the user toggles the switch.
    @discardableResult
    func requestAccessibility() -> Bool {
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true
        ]
        let trusted = AXIsProcessTrustedWithOptions(options)
        refresh()
        return trusted
    }

    /// Pops the system Input Monitoring consent prompt (deep-links to System Settings). Returns the
    /// current listen-event status; the real grant happens asynchronously once the user toggles it.
    @discardableResult
    func requestInputMonitoring() -> Bool {
        let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        refresh()
        return granted
    }

    /// Triggers the standard Screen Recording consent prompt. Returns the current preflight
    /// status; the system will surface the toggle in Privacy & Security › Screen Recording.
    @discardableResult
    func requestScreenRecording() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        refresh()
        return granted
    }

    // MARK: - Kind-based access

    /// Latest cached grant state for a specific permission kind. Lets higher-level UI and the
    /// guided drag flow reason in terms of `PermissionKind` instead of three separate properties.
    func isGranted(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .accessibility: accessibility.isGranted
        case .inputMonitoring: inputMonitoring.isGranted
        case .screenRecording: screenRecording.isGranted
        }
    }

    /// Asks macOS to register or prompt for the current process before any manual guidance. TCC
    /// grants permission to the running process's code identity, so resolving that identity through
    /// the native request API first makes the subsequent drag helper a reliable convenience rather
    /// than the thing that establishes identity.
    @discardableResult
    func requestSystemAccess(for kind: PermissionKind) -> Bool {
        switch kind {
        case .accessibility: requestAccessibility()
        case .inputMonitoring: requestInputMonitoring()
        case .screenRecording: requestScreenRecording()
        }
    }

    /// Opens the System Settings pane matching the permission kind.
    func openSettings(for kind: PermissionKind) {
        openSettings(pane: kind.settingsPane)
    }

    // MARK: - Deep links

    func openAccessibilitySettings() {
        openSettings(pane: "Privacy_Accessibility")
    }

    func openInputMonitoringSettings() {
        openSettings(pane: "Privacy_ListenEvent")
    }

    func openScreenRecordingSettings() {
        openSettings(pane: "Privacy_ScreenCapture")
    }

    /// Opens System Settings › Keyboard so the user can turn off macOS's "Show inline predictive
    /// text", which otherwise renders its own ghost text alongside KeyType's. There is no documented
    /// deep link to that specific toggle, so this opens the Keyboard pane and the UI explains the
    /// remaining clicks.
    func openKeyboardSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Best-effort read of macOS's global "Show inline predictive text" default
    /// (`NSAutomaticInlinePredictionEnabled`). Returns `nil` when the key is unset (we can't tell),
    /// otherwise the stored boolean. Used only to show a soft hint on the onboarding step — the
    /// step is always skippable because we cannot reliably detect this on every macOS version.
    static func inlinePredictionDefaultEnabled() -> Bool? {
        let key = "NSAutomaticInlinePredictionEnabled"
        guard let global = UserDefaults(suiteName: "NSGlobalDomain"),
              global.object(forKey: key) != nil else {
            return nil
        }
        return global.bool(forKey: key)
    }

    private func openSettings(pane: String) {
        // Documented x-apple.systempreferences scheme for the Privacy & Security panes.
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
