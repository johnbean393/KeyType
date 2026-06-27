//
//  DeveloperSettingsView.swift
//  KeyType
//
//  The "Developer" Settings pane: diagnostics and local-only tuning controls that aren't part of
//  the everyday flow. Gated features stay opt-in because prompt logs, screenshots, and screen-derived
//  override calibration can contain sensitive local context.
//

import AppCompatibility
import Foundation
import SwiftUI

struct DeveloperSettingsView: View {
    @Bindable var settings: SettingsStore
    @Bindable var contextCapture: ContextCaptureController
    @Bindable var developerOverrides: DeveloperOverrideController
    let permissions: PermissionsManager
    let openTuningPanel: () -> Void
    let showPlacementProbe: () -> Bool

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

            Section {
                Toggle(isOn: developerOverrideEnabledBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable live override tuning")
                        Text("Loads per-app compatibility overrides from DeveloperOverrides.json and watches it for changes.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button("Open Tuning HUD") {
                        openTuningPanel()
                    }
                    .disabled(!settings.developerOverrideTuningEnabled)

                    Button("Show Probe") {
                        _ = showPlacementProbe()
                    }
                    .disabled(!settings.developerOverrideTuningEnabled || contextCapture.latestTunableSnapshot == nil)

                    Button("Open JSON") {
                        developerOverrides.openOverridesFile()
                    }
                    .disabled(!settings.developerOverrideTuningEnabled)

                    Button("Reload") {
                        developerOverrides.reloadFromDisk()
                    }
                    .disabled(!settings.developerOverrideTuningEnabled)
                }

                LabeledContent("Last target") {
                    Text(contextCapture.lastTunableSummary.isEmpty ? "(none captured)" : contextCapture.lastTunableSummary)
                        .font(.footnote.monospaced())
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                LabeledContent("File") {
                    Text(developerOverrides.overridesURL.path)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                LabeledContent("Loaded") {
                    Text("\(developerOverrides.document.overrides.count) override\(developerOverrides.document.overrides.count == 1 ? "" : "s")")
                }
                if let lastLoadedAt = developerOverrides.lastLoadedAt {
                    LabeledContent("Updated") {
                        Text(lastLoadedAt.formatted(date: .abbreviated, time: .standard))
                    }
                }
                if let lastError = developerOverrides.lastError {
                    Text(lastError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Per-App Overrides")
            }
        }
        .formStyle(.grouped)
    }

    private var developerOverrideEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.developerOverrideTuningEnabled },
            set: { isEnabled in
                settings.developerOverrideTuningEnabled = isEnabled
                developerOverrides.setEnabled(isEnabled)
            }
        )
    }
}
