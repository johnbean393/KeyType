//
//  DeveloperSettingsView.swift
//  KeyType
//
//  The "Developer" Settings pane: diagnostics that aren't part of the everyday flow. Currently the
//  caret debug overlay (moved here from the menu bar), which draws captured caret and field geometry
//  to verify context capture. Gated on Accessibility, like the capture pipeline it visualizes.
//

import SwiftUI

struct DeveloperSettingsView: View {
    @Bindable var settings: SettingsStore
    @Bindable var contextCapture: ContextCaptureController
    let permissions: PermissionsManager

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $contextCapture.debugOverlayEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show caret debug overlay")
                        Text("Draws the detected caret, field, and available text rectangles to verify context capture.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!permissions.accessibility.isGranted)

                Toggle(isOn: $settings.fullPromptLoggingEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Log full prompts and completions")
                        Text("Writes shareable JSONL to ~/Library/Application Support/KeyType/Logs/\(FullPromptLog.fileName) and keeps the newest \(FullPromptLog.maxRows) rows.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                if !permissions.accessibility.isGranted {
                    Text("Requires Accessibility access.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
