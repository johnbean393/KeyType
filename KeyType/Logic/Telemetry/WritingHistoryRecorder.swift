//
//  WritingHistoryRecorder.swift
//  KeyType
//
//  Captures the user's own writing into the local, encrypted history store so it can personalize
//  future completions (`previousUserInputs`). Strictly opt-in and privacy-gated: nothing is recorded
//  unless the user has enabled history in Settings, the app/domain allows training-data collection
//  (AppCompatibility), and the field is not secure/sensitive. Data never leaves the device. See
//  ADR-023.
//

import AppCompatibility
import AutocompleteCore
import Foundation
import MacContextCapture
import Observation
import Personalization
import Prompting
import os

@MainActor
@Observable
final class WritingHistoryRecorder {
    private let tracker: AccessibilityContextTracker
    private let store: WritingHistoryStoring
    private let settings: SettingsStore
    private let compatibilityStore: AppCompatibilityStore
    private let log = Logger(subsystem: "com.pattonium.KeyType", category: "history-recorder")

    /// Minimum characters before a field's text is worth keeping as a sample.
    private let minimumCharacters = 20
    /// Commit the pending field after this much typing inactivity, even without a focus change.
    private let idleCommitInterval: TimeInterval = 4.0

    private var listenerToken: UUID?
    private(set) var isRunning = false

    /// The field currently being edited: its identity (so we can tell when focus moves) and the most
    /// recent full text seen. Committed when focus changes, the app switches, or typing goes idle.
    private struct Pending {
        var identity: String
        var sample: WritingHistorySample
    }
    private var pending: Pending?
    private var idleTimer: Timer?

    init(
        tracker: AccessibilityContextTracker,
        store: WritingHistoryStoring,
        settings: SettingsStore,
        compatibilityStore: AppCompatibilityStore = KeyTypeModuleGraph.makeCompatibilityStore()
    ) {
        self.tracker = tracker
        self.store = store
        self.settings = settings
        self.compatibilityStore = compatibilityStore
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        listenerToken = tracker.addListener { [weak self] snapshot in
            self?.handle(snapshot)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let listenerToken {
            tracker.removeListener(listenerToken)
        }
        listenerToken = nil
        commitPending()
    }

    // MARK: - Capture

    private func handle(_ snapshot: FocusedFieldSnapshot?) {
        // History is fully opt-in; when disabled we keep no pending state at all.
        guard settings.historyEnabled else {
            pending = nil
            invalidateIdleTimer()
            return
        }

        guard let snapshot else {
            commitPending()
            return
        }

        let context = snapshot.context
        let identity = Self.identity(for: context)
        let text = (context.beforeCursor + context.afterCursor)

        if let current = pending, current.identity != identity {
            // Focus moved to a different field/app — persist what we had, then start fresh.
            commitPending()
        }

        // Build/refresh the pending sample for the live field.
        pending = Pending(
            identity: identity,
            sample: WritingHistorySample(
                text: text,
                appBundleIdentifier: context.target.bundleIdentifier,
                domain: context.target.domain,
                typingContext: context.typingContext,
                language: context.detectedLanguage
            )
        )
        scheduleIdleCommit()
    }

    private func commitPending() {
        invalidateIdleTimer()
        guard let pending else { return }
        self.pending = nil

        let sample = pending.sample
        guard settings.historyEnabled else { return }
        guard sample.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).count >= minimumCharacters else { return }
        // Belt-and-suspenders junk gate: skip entries that aren't prose (bare URLs, UUID blobs,
        // filesystem paths) before they reach the encrypted DB. Mirrored in WritingHistorySelection
        // for samples already on disk from before this guard was introduced.
        guard WritingHistoryFilter.isProse(sample.text) else { return }

        // Re-resolve the policy from the captured metadata: secure/sensitive fields and apps that
        // disable training-data collection must never contribute samples.
        let target = AppTarget(
            bundleIdentifier: sample.appBundleIdentifier ?? "",
            appName: "",
            domain: sample.domain
        )
        let policy = compatibilityStore.policy(for: target)
        guard policy.allowsTrainingDataCollection, !policy.excludesSecureField else { return }
        guard !settings.perAppDisabled.contains(sample.appBundleIdentifier ?? "") else { return }

        // Commits are low-frequency (focus change / app switch / typing idle), so a direct encrypted
        // write here is fine; it never runs per keystroke. The store serializes DB access internally.
        store.record(sample)
    }

    private func scheduleIdleCommit() {
        invalidateIdleTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: idleCommitInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.commitPending()
            }
        }
        timer.tolerance = 1.0
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func invalidateIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    /// Field identity used to detect when the user has moved to a different field. Deliberately
    /// coarse (app + window + placeholder) so ongoing edits in one field keep refreshing a single
    /// pending sample rather than spawning many.
    private static func identity(for context: TextFieldContext) -> String {
        [
            context.target.bundleIdentifier,
            context.target.windowTitle ?? "",
            context.target.domain ?? "",
            context.placeholder ?? ""
        ].joined(separator: "\u{1}")
    }
}
