//
//  KeyTypeApp.swift
//  KeyType
//
//  Created by John Bean on 5/29/26.
//

import AppKit
import SwiftUI

@main
struct KeyTypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appDelegate.permissions)
                .environment(appDelegate.contextCapture)
                .environment(appDelegate.completion)
                .environment(appDelegate.updater)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.menu)

        Window("KeyType", id: AppDelegate.onboardingWindowID) {
            OnboardingView(
                permissionGuidance: appDelegate.permissionGuidance,
                markCompleted: { appDelegate.markOnboardingCompleted() }
            )
                .environment(appDelegate.permissions)
                .environment(appDelegate.settings)
                .environment(appDelegate.modelSetup)
                // Give the setup window a Dock icon while it's open, mirroring Settings. See ADR-058.
                .onAppear { appDelegate.mainWindowDidAppear(id: AppDelegate.onboardingWindowID) }
                .onDisappear { appDelegate.mainWindowDidDisappear(id: AppDelegate.onboardingWindowID) }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commandsRemoved()

        Window("KeyType Settings", id: AppDelegate.settingsWindowID) {
            SettingsView(
                settings: appDelegate.settings,
                telemetry: appDelegate.telemetry,
                modelSetup: appDelegate.modelSetup,
                contextCapture: appDelegate.contextCapture,
                developerOverrides: appDelegate.developerOverrides,
                permissions: appDelegate.permissions,
                clearPersonalData: { appDelegate.clearAllPersonalData() },
                runSetupAgain: {
                    appDelegate.resetOnboarding()
                    appDelegate.requestOpenOnboarding()
                },
                reloadModel: { appDelegate.completion.reloadModel() },
                importModel: { appDelegate.presentModelImportPanel() },
                addApp: { appDelegate.presentAppAddPanel() },
                openDeveloperOverridePanel: { appDelegate.presentDeveloperOverridePanel() },
                showDeveloperPlacementProbe: {
                    appDelegate.completion.showDeveloperPlacementProbe(
                        using: appDelegate.contextCapture.latestTunableSnapshot
                    )
                }
            )
            // Promote KeyType to a dock-visible app while Settings is open so it's easy to switch
            // back to, then drop back to the menu-bar-only agent policy on close. See ADR-058.
            .onAppear { appDelegate.mainWindowDidAppear(id: AppDelegate.settingsWindowID) }
            .onDisappear { appDelegate.mainWindowDidDisappear(id: AppDelegate.settingsWindowID) }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 760, height: 600)
        .defaultPosition(.center)
        .commandsRemoved()
    }
}
