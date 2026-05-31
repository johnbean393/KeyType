//
//  ScreenContextController.swift
//  KeyType
//
//  Owns the out-of-band OCR capture of the focused app window and exposes its cached text as a
//  `ScreenTextProviding` for the completion prompt's `[Screen context]` section. Capture is
//  refreshed on focus/window change (driven by the AX tracker) plus a slow periodic timer — never
//  on the per-keystroke path, since OCR is far too slow for that. Every capture is gated on the
//  off-by-default OCR switch, Screen Recording permission, and per-field/per-app safety. See ADR-040.
//

import AppKit
import AppCompatibility
import AutocompleteCore
import Foundation
import MacContextCapture
import Observation
import os

@MainActor
@Observable
final class ScreenContextController {
    private let tracker: AccessibilityContextTracker
    private let settings: SettingsStore
    private let permissions: PermissionsManager
    private let compatibilityStore: AppCompatibilityStore
    private let engine: WindowOCRCaptureEngine
    private let log = Logger(subsystem: "com.pattonium.KeyType", category: "screen-context")

    /// How often to re-OCR the focused window while it stays focused, so the context tracks slow
    /// on-screen changes (a scrolled doc, an updated panel) without a focus change to trigger it.
    private let refreshInterval: TimeInterval = 4.0

    private(set) var isRunning = false
    private var listenerToken: UUID?
    private var refreshTimer: Timer?
    /// Identity of the window we last captured, so per-keystroke snapshot re-emits (same window)
    /// don't kick off a fresh capture — only an actual focus/window change does.
    private var lastWindowKey: String?

    /// The cached-OCR provider to inject into `CompletionController`.
    var screenTextProvider: ScreenTextProviding { engine }

    init(
        tracker: AccessibilityContextTracker,
        settings: SettingsStore,
        permissions: PermissionsManager,
        compatibilityStore: AppCompatibilityStore,
        engine: WindowOCRCaptureEngine = WindowOCRCaptureEngine()
    ) {
        self.tracker = tracker
        self.settings = settings
        self.permissions = permissions
        self.compatibilityStore = compatibilityStore
        self.engine = engine
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        listenerToken = tracker.addListener { [weak self] snapshot in
            self?.handle(snapshot)
        }
        let timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshTick()
            }
        }
        timer.tolerance = refreshInterval / 2
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        log.debug("Started screen-context OCR capture")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let listenerToken {
            tracker.removeListener(listenerToken)
        }
        listenerToken = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        lastWindowKey = nil
        engine.clear()
        log.debug("Stopped screen-context OCR capture")
    }

    // MARK: - Triggers

    /// Focus/window change: only re-capture when the *window* identity changes, so typing (which
    /// re-emits snapshots for the same window) doesn't thrash OCR.
    private func handle(_ snapshot: FocusedFieldSnapshot?) {
        guard isEligible(snapshot), let snapshot else {
            lastWindowKey = nil
            engine.clear()
            return
        }
        let key = windowKey(for: snapshot)
        guard key != lastWindowKey else { return }
        lastWindowKey = key
        capture(for: snapshot)
    }

    /// Periodic refresh while a window stays focused.
    private func refreshTick() {
        let snapshot = tracker.currentSnapshot
        guard isEligible(snapshot), let snapshot else {
            lastWindowKey = nil
            engine.clear()
            return
        }
        lastWindowKey = windowKey(for: snapshot)
        capture(for: snapshot)
    }

    private func capture(for snapshot: FocusedFieldSnapshot) {
        guard let pid = frontmostPID(matching: snapshot.context.target.bundleIdentifier) else { return }
        // The field's own text is already captured via AX; pass it so it's stripped from the OCR and
        // screen context carries only the *surrounding* on-screen text.
        let context = snapshot.context
        let fieldText = context.beforeCursor + context.afterCursor
        engine.refresh(pid: pid, fieldText: fieldText)
    }

    // MARK: - Eligibility

    /// Capture is permitted only when OCR is opted into, Screen Recording is granted, and the focused
    /// field is a safe, completion-enabled, non-secure surface that isn't KeyType itself. The screen
    /// *read* is the privacy-sensitive act, so it is gated at least as tightly as completion display.
    private func isEligible(_ snapshot: FocusedFieldSnapshot?) -> Bool {
        guard settings.ocrEnabled, permissions.screenRecording.isGranted else { return false }
        guard let snapshot else { return false }
        let context = snapshot.context
        let traits = context.traits
        if traits.isSecureTextEntry || traits.isPasswordField || traits.isPasswordManagerContext {
            return false
        }
        let bundle = context.target.bundleIdentifier
        if bundle == "unknown" { return false }
        if bundle == Bundle.main.bundleIdentifier { return false }
        if settings.perAppDisabled.contains(bundle) { return false }
        if !compatibilityStore.policy(for: context).isCompletionEnabled { return false }
        return true
    }

    private func windowKey(for snapshot: FocusedFieldSnapshot) -> String {
        snapshot.context.target.bundleIdentifier + "\u{1}" + (snapshot.context.target.windowTitle ?? "")
    }

    /// Resolve the pid to capture from the frontmost application, but only when it matches the
    /// focused field's app — guards against capturing some other app if focus and frontmost diverge.
    private func frontmostPID(matching bundleIdentifier: String) -> pid_t? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == bundleIdentifier else {
            return nil
        }
        return app.processIdentifier
    }
}
