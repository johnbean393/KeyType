//
//  UpdaterController.swift
//  KeyType
//
//  Owns the Sparkle updater for the menu-bar app. KeyType ships outside the App Store as a
//  notarized DMG, so in-app updates are delivered via a signed Sparkle appcast (see ADR and
//  `Scripts/release.sh`). The feed URL and the EdDSA public key live in Info.plist
//  (`SUFeedURL` / `SUPublicEDKey`), injected from the build settings.
//

import Foundation
import Sparkle

/// Thin `@Observable` wrapper around `SPUStandardUpdaterController` so the SwiftUI menu can bind a
/// "Check for Updates…" button and disable it while a check is already in flight. The updater runs
/// its own scheduled background checks; this only adds the manual entry point.
@MainActor
@Observable
final class UpdaterController {
    private let controller: SPUStandardUpdaterController
    /// Mirrors `SPUUpdater.canCheckForUpdates` (false while a check/install is already running) so
    /// the menu item can disable itself.
    private(set) var canCheckForUpdates: Bool = false
    private var observation: NSKeyValueObservation?

    init() {
        // `startingUpdater: true` begins the automatic update schedule immediately; the standard
        // user driver presents Sparkle's own update UI.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        canCheckForUpdates = controller.updater.canCheckForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            let newValue = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = newValue }
        }
    }

    /// Manual "Check for Updates…" action. Sparkle shows its own progress/no-update UI.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
