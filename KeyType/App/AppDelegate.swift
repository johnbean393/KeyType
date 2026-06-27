//
//  AppDelegate.swift
//  KeyType
//
//  Created by Codex on 5/29/26.
//

import AppKit
import AppCompatibility
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
    let developerOverrides: DeveloperOverrideController
    let screenContext: ScreenContextController
    let completion: CompletionController
    let correction: CorrectionController
    let historyRecorder: WritingHistoryRecorder
    private let acceptance = CompletionAcceptanceController()
    private lazy var developerOverridePanel = DeveloperOverridePanelController(
        settings: settings,
        developerOverrides: developerOverrides,
        contextCapture: contextCapture,
        completion: completion
    )
    private var permissionSyncTimer: Timer?
    private var developerProbePollTimer: Timer?
    private var lastDeveloperProbeTriggerDate: Date?
    /// Set once the user has confirmed quitting and the async model teardown is under way, so the
    /// confirmation alert isn't shown twice and `applicationShouldTerminate` doesn't re-prompt.
    private var isTerminating = false
    /// True while an open panel is on screen. The AX/keyboard pipeline must stay fully stopped for
    /// the panel's lifetime (its synchronous AX reads deadlock against the panel), so
    /// `syncContextCaptureWithPermission()` is suppressed — otherwise the 1 Hz permission timer would
    /// restart the tracker mid-panel and re-trigger the hang.
    private var isPresentingOpenPanel = false
    /// IDs of the main windows (Settings, onboarding/setup) currently on screen. KeyType normally runs
    /// as a dockless `.accessory` agent, but while one of these windows is open we promote it to a
    /// `.regular` (dock-visible) app so the user can ⌘-Tab back and forth like a normal app, then
    /// revert once they're all closed. A set (not a counter/bool) keeps this idempotent against repeated
    /// `onAppear` calls and correct when both windows overlap. See ADR-058.
    private var dockVisibleWindowIDs: Set<String> = []

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
        let developerOverrides = DeveloperOverrideController()
        self.developerOverrides = developerOverrides
        let compatibilityStore = KeyTypeModuleGraph.makeCompatibilityStore(
            userDisabledBundleIdentifiers: settings.perAppDisabled,
            runtimeOverrideStore: developerOverrides.runtimeOverrideStore
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
        self.correction = CorrectionController(
            tracker: tracker,
            settings: settings,
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
        completion.shouldSuppressForCorrection = { [weak correction] context in
            correction?.shouldSuppressCompletion(for: context) ?? false
        }
        correction.validateWithModel = { [weak completion] candidates, target, context in
            guard let completion else { return [] }
            return try await completion.validateCorrectionCandidates(candidates, target: target, context: context)
        }
        correction.onWillShowCorrection = { [weak completion] context in
            completion?.suppressVisibleCompletionForCorrection(context: context)
        }
        correction.onCorrectionAccepted = { [weak completion] in
            completion?.refreshAfterCorrectionAccepted()
        }
        acceptance.completionController = completion
        acceptance.correctionController = correction
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

    func presentDeveloperOverridePanel() {
        developerOverridePanel.show()
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

        AppBundleWebAppClassifier.shared.primeRunningApplications()
        developerOverrides.setEnabled(settings.developerOverrideTuningEnabled)
        permissions.startMonitoring()
        syncContextCaptureWithPermission()
        startObservingPermissionChanges()
        startObservingDeveloperProbeTriggerFile()

        if shouldShowOnboardingOnLaunch {
            // The always-present `MenuBarLabel` observes this and calls `openWindow(id:)`. Defer one
            // run loop so that label view is subscribed before we post (the menu's content view is
            // instantiated lazily and can't be relied on at launch).
            DispatchQueue.main.async { [weak self] in
                self?.requestOpenOnboarding()
            }
        }
    }

    private func startObservingDeveloperProbeTriggerFile() {
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollDeveloperProbeTriggerFile()
            }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        developerProbePollTimer = timer
    }

    private func pollDeveloperProbeTriggerFile() {
        guard settings.developerOverrideTuningEnabled else { return }
        let url = Self.developerProbeTriggerURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modificationDate = attributes[.modificationDate] as? Date,
              modificationDate != lastDeveloperProbeTriggerDate else {
            return
        }
        lastDeveloperProbeTriggerDate = modificationDate
        let text = (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .newlines)
        let probeText = text.flatMap { $0.isEmpty ? nil : $0 } ?? " ghost text probe"
        Task { @MainActor [weak self] in
            guard let self else { return }
            var snapshot = self.contextCapture.latestTunableSnapshot
                ?? self.contextCapture.latestSnapshot
            if snapshot == nil {
                snapshot = try? await MacContextCaptureService().captureFocusedFieldSnapshot()
            }
            _ = self.completion.showDeveloperPlacementProbe(
                using: snapshot,
                text: probeText
            )
        }
    }

    private static var developerProbeTriggerURL: URL {
        URL(fileURLWithPath: "/tmp/KeyTypeDeveloperPlacementProbe.txt")
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
        // Don't resurrect the AX pipeline while an open panel is up — see `isPresentingOpenPanel`.
        guard !isPresentingOpenPanel else { return }
        if permissions.accessibility.isGranted {
            contextCapture.start()
            correction.start()
            completion.start()
            historyRecorder.start()
            acceptance.start()
        } else {
            contextCapture.stop()
            completion.stop()
            correction.stop()
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

    /// Show the Dock icon while one of KeyType's main windows (Settings, onboarding/setup) is open.
    /// The app ships as a `.accessory` (menu-bar-only) agent, but a dockless app is awkward to switch
    /// back to once you've clicked away from its window; promoting to `.regular` gives the window a Dock
    /// icon and a normal ⌘-Tab entry. Idempotent, and only flips the policy on the first window to open.
    /// See ADR-058.
    func mainWindowDidAppear(id: String) {
        let wasEmpty = dockVisibleWindowIDs.isEmpty
        dockVisibleWindowIDs.insert(id)
        guard wasEmpty else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Revert to the dockless `.accessory` policy once the last main window closes, so KeyType
    /// disappears from the Dock and ⌘-Tab and goes back to being a pure menu-bar agent. See ADR-058.
    func mainWindowDidDisappear(id: String) {
        guard dockVisibleWindowIDs.remove(id) != nil, dockVisibleWindowIDs.isEmpty else { return }
        NSApp.setActivationPolicy(.accessory)
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

        presentSafeOpenPanel(panel) { [weak self] response, url in
            guard response == .OK, let url else { return }
            self?.modelSetup.importModel(from: url)
        }
    }

    /// Present an app-bundle picker for manual per-app Settings entries. This uses the same safe open
    /// panel wrapper as model import because application panels take focus and can otherwise trigger
    /// the AX deadlock documented above.
    func presentAppAddPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsOtherFileTypes = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        panel.message = "Choose an app to show in per-app completions."

        presentSafeOpenPanel(panel) { [weak self] response, url in
            guard response == .OK, let url else { return }
            guard let bundle = Bundle(url: url), let bundleIdentifier = bundle.bundleIdentifier else {
                Self.presentAppAddFailureAlert()
                return
            }

            self?.settings.addManualApp(
                bundleIdentifier: bundleIdentifier,
                name: Self.displayName(for: bundle, at: url)
            )
        }
    }

    private func presentSafeOpenPanel(
        _ panel: NSOpenPanel,
        onCompletion: @escaping (NSApplication.ModalResponse, URL?) -> Void
    ) {
        // Stop everything that reads AX or taps the keyboard before the panel appears, and latch the
        // flag so the 1 Hz permission timer can't restart any of it while the panel is up.
        isPresentingOpenPanel = true
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
            let url = panel.url
            self.isPresentingOpenPanel = false
            self.syncContextCaptureWithPermission()
            onCompletion(response, url)
        }
    }

    private static func displayName(for bundle: Bundle, at url: URL) -> String {
        if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return displayName
        }
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private static func presentAppAddFailureAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Can’t Add This App"
        alert.informativeText = "The selected item is not an app bundle with a bundle identifier."
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
