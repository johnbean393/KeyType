//
//  PrivacySettingsView.swift
//  KeyType
//
//  The "Privacy" Settings pane: the switches that gate sensitive context (history, clipboard, OCR)
//  and the single "Clear all personal data" action. Split out of SettingsView so each sidebar
//  category lives in its own file. See ADR-023.
//

import SwiftUI

struct PrivacySettingsView: View {
    @Bindable var settings: SettingsStore
    let permissions: PermissionsManager
    let clearPersonalData: () -> Void

    @State private var showClearConfirmation = false

    var body: some View {
        Form {
            Section("Privacy") {
                Toggle(isOn: $settings.historyEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Personalize from my writing history")
                        Text("Stores recent typing locally (encrypted) to improve suggestions. Off by default.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $settings.clipboardEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use clipboard as context")
                        Text("Includes clipboard text in the prompt. Off by default.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $settings.ocrEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use on-screen text (OCR) as context (Beta)")
                        Text("Reads visible text from the focused window. Off by default; requires Screen Recording.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if settings.ocrEnabled, !permissions.screenRecording.isGranted {
                            Text("Screen Recording is not granted — OCR context stays off until you allow it in System Settings.")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .onChange(of: settings.ocrEnabled) { _, isOn in
                    // Enabling OCR is useless without Screen Recording; pop the system prompt and
                    // deep-link to the pane so the toggle is actionable rather than silently inert.
                    if isOn, !permissions.screenRecording.isGranted {
                        _ = permissions.requestScreenRecording()
                        permissions.openScreenRecordingSettings()
                    }
                }
                Toggle(isOn: $settings.screenshotCalibrationEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use screenshots to improve suggestion appearance")
                        Text("Calibrates ghost-text font size and vertical alignment from the focused field. Off by default; requires Screen Recording.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if settings.screenshotCalibrationEnabled, !permissions.screenRecording.isGranted {
                            Text("Screen Recording is not granted — screenshot calibration stays off until you allow it in System Settings.")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .onChange(of: settings.screenshotCalibrationEnabled) { _, isOn in
                    if isOn, !permissions.screenRecording.isGranted {
                        _ = permissions.requestScreenRecording()
                        permissions.openScreenRecordingSettings()
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    showClearConfirmation = true
                } label: {
                    Text("Clear all personal data…")
                }
                .confirmationDialog(
                    "Clear all personal data?",
                    isPresented: $showClearConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Clear everything", role: .destructive) {
                        clearPersonalData()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Deletes all stored writing history and local telemetry from this device. This cannot be undone.")
                }
            } footer: {
                Text("Everything KeyType stores stays on this device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
