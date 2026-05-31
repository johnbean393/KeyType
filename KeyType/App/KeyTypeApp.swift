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
                permissions: appDelegate.permissions,
                clearPersonalData: { appDelegate.clearAllPersonalData() },
                runSetupAgain: {
                    appDelegate.resetOnboarding()
                    appDelegate.requestOpenOnboarding()
                },
                reloadModel: { appDelegate.completion.reloadModel() },
                importModel: { appDelegate.presentModelImportPanel() }
            )
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commandsRemoved()
    }
}
