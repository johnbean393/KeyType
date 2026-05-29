//
//  MenuBarView.swift
//  KeyType
//
//  Created by Codex on 5/29/26.
//

import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(PermissionsManager.self) private var permissions
    @Environment(ContextCaptureController.self) private var contextCapture
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var contextCapture = contextCapture

        Group {
            statusLine

            Divider()

            Toggle("Show caret debug overlay", isOn: $contextCapture.debugOverlayEnabled)
                .disabled(!permissions.accessibility.isGranted)

            Divider()

            Button("Open KeyType…") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: AppDelegate.onboardingWindowID)
            }
            .keyboardShortcut("o")

            Divider()

            Button("Quit KeyType") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .onReceive(NotificationCenter.default.publisher(for: .keyTypeShouldOpenOnboarding)) { _ in
            openWindow(id: AppDelegate.onboardingWindowID)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        let ax = permissions.accessibility
        Text(ax.isGranted
             ? "Accessibility: granted"
             : "Accessibility: not granted")
        .font(.system(size: 11))
        .foregroundStyle(ax.isGranted ? Color.secondary : Color.red)
    }
}
