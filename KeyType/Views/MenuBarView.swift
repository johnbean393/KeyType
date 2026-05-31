//
//  MenuBarView.swift
//  KeyType
//
//  Created by Codex on 5/29/26.
//

import AppKit
import SwiftUI

/// The always-present menu bar status item label. Unlike `MenuBarView` (the menu's content, which a
/// `.menu`-style `MenuBarExtra` only instantiates when the menu opens), this label view stays alive
/// for the app's lifetime — so it is where we observe the "open onboarding" request and can react to
/// it at launch.
struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "text.cursor")
            .onReceive(NotificationCenter.default.publisher(for: .keyTypeShouldOpenOnboarding)) { _ in
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: AppDelegate.onboardingWindowID)
            }
    }
}

struct MenuBarView: View {
    @Environment(PermissionsManager.self) private var permissions
    @Environment(CompletionController.self) private var completion
    @Environment(UpdaterController.self) private var updater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var completion = completion

        Group {
            Toggle("Completions enabled", isOn: $completion.completionsEnabled)
                .disabled(!permissions.accessibility.isGranted)

            Divider()

            Button("Open KeyType…") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: AppDelegate.onboardingWindowID)
            }
            .keyboardShortcut("o")

            Button("KeyType Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: AppDelegate.settingsWindowID)
            }
            .keyboardShortcut(",")

            Button("Check for Updates…") {
                NSApp.activate(ignoringOtherApps: true)
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)

            Divider()

            Button("Quit KeyType") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

}
