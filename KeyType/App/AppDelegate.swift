//
//  AppDelegate.swift
//  KeyType
//
//  Created by Codex on 5/29/26.
//

import AppKit
import MacContextCapture
import Personalization
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let onboardingWindowID = "onboarding"
    static let settingsWindowID = "settings"
    /// Stores the onboarding version the user last *completed*, not a yes/no flag, so a future
    /// revamp can re-show the wizard by bumping `currentOnboardingVersion`. An absent key reads as 0.
    private static let onboardingCompletedVersionKey = "KeyType.onboardingCompletedVersion"
    private static let currentOnboardingVersion = 1

    let permissions: PermissionsManager
    /// Drives the "drag KeyType into the System Settings list" guided permission flow.
    let permissionGuidance: PermissionGuidanceController
    let settings: SettingsStore
    /// Owns model download + ACPF profile generation; shared by the onboarding wizard and Settings.
    let modelSetup = ModelSetupCoordinator()
    /// Owns the Sparkle updater (in-app updates via the signed appcast). See `UpdaterController`.
    let updater = UpdaterController()
    // One AX tracker feeds the (debug) context capture, the live completion pipeline, and the
    // writing-history recorder.
    private let tracker: AccessibilityContextTracker
    // Shared, encrypted writing-history store + local telemetry. Built once so the recorder (writes)
    // and the prompt path (reads) use the same database connection. See ADR-023.
    let history: WritingHistoryStoring
    let telemetry: CompletionTelemetryStore
    let contextCapture: ContextCaptureController
    let screenContext: ScreenContextController
    let completion: CompletionController
    let historyRecorder: WritingHistoryRecorder
    private let acceptance = CompletionAcceptanceController()
    private var permissionSyncTimer: Timer?
    /// Set once the user has confirmed quitting and the async model teardown is under way, so the
    /// confirmation alert isn't shown twice and `applicationShouldTerminate` doesn't re-prompt.
    private var isTerminating = false
    /// True while the GGUF import open panel is on screen. The AX/keyboard pipeline must stay fully
    /// stopped for the panel's lifetime (its synchronous AX reads deadlock against the panel), so
    /// `syncContextCaptureWithPermission()` is suppressed — otherwise the 1 Hz permission timer would
    /// restart the tracker mid-panel and re-trigger the hang.
    private var isPresentingImportPanel = false

    override init() {
        let permissions = PermissionsManager()
        self.permissions = permissions
        self.permissionGuidance = PermissionGuidanceController(permissions: permissions)
        let tracker = AccessibilityContextTracker()
        self.tracker = tracker
        let settings = SettingsStore()
        self.settings = settings
        let history = KeyTypeModuleGraph.makeWritingHistory()
        let telemetry = CompletionTelemetryStore()
        self.history = history
        self.telemetry = telemetry
        let compatibilityStore = KeyTypeModuleGraph.makeCompatibilityStore(
            userDisabledBundleIdentifiers: settings.perAppDisabled
        )
        self.contextCapture = ContextCaptureController(tracker: tracker)
        let screenContext = ScreenContextController(
            tracker: tracker,
            settings: settings,
            permissions: permissions,
            compatibilityStore: compatibilityStore
        )
        self.screenContext = screenContext
        self.completion = CompletionController(
            tracker: tracker,
            settings: settings,
            history: history,
            screenTextProvider: screenContext.screenTextProvider,
            telemetry: telemetry,
            compatibilityStore: compatibilityStore
        )
        self.historyRecorder = WritingHistoryRecorder(
            tracker: tracker,
            store: history,
            settings: settings,
            compatibilityStore: compatibilityStore
        )
        super.init()
        acceptance.completionController = completion
        acceptance.settings = settings
        // When a model finishes setup (GGUF + ACPF both present), make it the selected model and
        // reload the engine so the change takes effect without a relaunch.
        modelSetup.onModelReady = { [weak self] filename in
            guard let self else { return }
            self.settings.selectedModelFilename = filename
            self.completion.reloadModel()
        }
        // Import failures (an incompatible GGUF, a copy/profile error) are shown as a modal alert the
        // user must dismiss, rather than an inline status line in Settings. See ADR-036.
        modelSetup.onImportFailure = { message in
            AppDelegate.presentImportFailureAlert(message)
        }
    }

    /// Present an import failure as an app-modal `NSAlert` the user has to explicitly dismiss. The
    /// app is an accessory (no dock icon), so we activate first to make sure the alert comes to the
    /// front rather than appearing behind whatever the user is typing into.
    static func presentImportFailureAlert(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Can’t Use This Model"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// One-action wipe of all on-device personal data: every stored writing sample and the local
    /// telemetry counters. Backs the Settings "Clear all personal data" control. See ADR-023.
    func clearAllPersonalData() {
        history.clearAll()
        telemetry.clearAll()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Background / agent app: no dock icon. LSUIElement in Info.plist already suppresses the
        // dock icon; making the activation policy explicit guards against alternate launch paths.
        NSApp.setActivationPolicy(.accessory)

        permissions.startMonitoring()
        syncContextCaptureWithPermission()
        startObservingPermissionChanges()

        if shouldShowOnboardingOnLaunch {
            // The always-present `MenuBarLabel` observes this and calls `openWindow(id:)`. Defer one
            // run loop so that label view is subscribed before we post (the menu's content view is
            // instantiated lazily and can't be relied on at launch).
            DispatchQueue.main.async { [weak self] in
                self?.requestOpenOnboarding()
            }
        }
    }

    /// Start/stop the context tracker so it only runs when AX is actually granted. We poll the
    /// `PermissionsManager` (which itself polls AX status at 1 Hz) once per second; this is a
    /// background, low-frequency check — the tracker itself reacts to AX notifications.
    private func startObservingPermissionChanges() {
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncContextCaptureWithPermission()
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        permissionSyncTimer = timer
    }

    private func syncContextCaptureWithPermission() {
        // Don't resurrect the AX pipeline while the import panel is up — see `isPresentingImportPanel`.
        guard !isPresentingImportPanel else { return }
        if permissions.accessibility.isGranted {
            contextCapture.start()
            completion.start()
            historyRecorder.start()
            acceptance.start()
        } else {
            contextCapture.stop()
            completion.stop()
            historyRecorder.stop()
            acceptance.stop()
        }
        // OCR screen capture has its own opt-in switch and permission on top of Accessibility. Polled
        // here (1 Hz) so flipping the Settings toggle or granting Screen Recording takes effect within
        // ~1 s without a relaunch. See ADR-040.
        if permissions.accessibility.isGranted, settings.ocrEnabled, permissions.screenRecording.isGranted {
            screenContext.start()
        } else {
            screenContext.stop()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running as a menu-bar agent even after the onboarding window is dismissed.
        false
    }

    /// Gate every quit path (menu item, ⌘Q) behind a confirmation, then tear the model down before
    /// exiting. The teardown is mandatory, not just polite: llama.cpp's ggml-metal backend aborts in
    /// its process-exit C++ destructors unless the llama context/model were freed first (the GPU
    /// residency-set assert in the crash report). We free them asynchronously, then let termination
    /// proceed via `reply(toApplicationShouldTerminate:)`. See ADR-021.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateNow }

        // The agent has no dock icon, so bring the alert to the front explicitly.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Quit KeyType?"
        alert.informativeText = "KeyType will stop suggesting completions until you open it again."
        alert.alertStyle = .warning
        // First button is the default (highlighted, triggered by Return) and sits on the right.
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return .terminateCancel
        }

        isTerminating = true
        Task { @MainActor in
            await completion.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Present the "Import a GGUF…" open panel and, on success, hand the chosen file to the model
    /// setup coordinator.
    ///
    /// Why this lives in `AppDelegate` (and not the SwiftUI view): the open panel is hosted by an
    /// out-of-process remote view service. KeyType's AX context tracker makes *synchronous*
    /// `AXUIElementCopyAttributeValue` reads whenever focus changes — and the panel taking focus
    /// fires exactly that. Those reads run on the main thread, which is also what has to service the
    /// panel, so they deadlock and the app hangs. We therefore quiesce the whole AX/keyboard pipeline
    /// for the panel's lifetime, then restore it (gated on AX still being granted) once it closes.
    func presentModelImportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf")].compactMap { $0 }
        panel.allowsOtherFileTypes = false
        panel.prompt = "Import"
        panel.message = "Choose a GGUF model file to import."

        // Stop everything that reads AX or taps the keyboard before the panel appears, and latch the
        // flag so the 1 Hz permission timer can't restart any of it while the panel is up.
        isPresentingImportPanel = true
        contextCapture.stop()
        completion.stop()
        historyRecorder.stop()
        acceptance.stop()
        screenContext.stop()

        NSApp.activate(ignoringOtherApps: true)
        // `begin` (not `runModal`) keeps the main run loop turning while the panel is up; combined
        // with the paused AX pipeline this is what stops the hang.
        panel.begin { [weak self] response in
            guard let self else { return }
            self.isPresentingImportPanel = false
            self.syncContextCaptureWithPermission()
            guard response == .OK, let url = panel.url else { return }
            self.modelSetup.importModel(from: url)
        }
    }

    func requestOpenOnboarding() {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .keyTypeShouldOpenOnboarding, object: nil)
    }

    func markOnboardingCompleted() {
        UserDefaults.standard.set(Self.currentOnboardingVersion, forKey: Self.onboardingCompletedVersionKey)
    }

    /// Clears the completion marker so the wizard re-runs on the next request. Backs the Settings
    /// "Run setup again" control.
    func resetOnboarding() {
        UserDefaults.standard.removeObject(forKey: Self.onboardingCompletedVersionKey)
    }

    private var shouldShowOnboardingOnLaunch: Bool {
        let completed = UserDefaults.standard.integer(forKey: Self.onboardingCompletedVersionKey)
        // Show on first run, after an onboarding-version bump, or whenever a required permission is
        // missing (the user can't actually use KeyType until those are granted).
        return completed < Self.currentOnboardingVersion || !permissions.requiredPermissionsGranted
    }
}

extension Notification.Name {
    static let keyTypeShouldOpenOnboarding = Notification.Name("KeyType.shouldOpenOnboarding")
}
