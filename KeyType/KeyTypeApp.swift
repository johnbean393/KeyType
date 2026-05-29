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
        } label: {
            Image(systemName: "text.cursor")
        }
        .menuBarExtraStyle(.menu)

        Window("KeyType", id: AppDelegate.onboardingWindowID) {
            OnboardingView()
                .environment(appDelegate.permissions)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commandsRemoved()
    }
}
