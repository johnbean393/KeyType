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
import Observation

/// Tracks the macOS privacy permissions KeyType depends on.
///
/// - Accessibility is **required**: it gates AX-based caret/text-field capture and
///   later synthetic keystroke injection. Without it, KeyType cannot function.
/// - Screen Recording is **optional**: enables richer context capture (window/OCR) in
///   future milestones. The app should run fine without it.
@MainActor
@Observable
final class PermissionsManager {
    struct PermissionState: Equatable {
        var isGranted: Bool
    }

    private(set) var accessibility = PermissionState(isGranted: false)
    private(set) var screenRecording = PermissionState(isGranted: false)

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

    /// Triggers the standard Screen Recording consent prompt. Returns the current preflight
    /// status; the system will surface the toggle in Privacy & Security › Screen Recording.
    @discardableResult
    func requestScreenRecording() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        refresh()
        return granted
    }

    // MARK: - Deep links

    func openAccessibilitySettings() {
        openSettings(pane: "Privacy_Accessibility")
    }

    func openScreenRecordingSettings() {
        openSettings(pane: "Privacy_ScreenCapture")
    }

    private func openSettings(pane: String) {
        // Documented x-apple.systempreferences scheme for the Privacy & Security panes.
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
