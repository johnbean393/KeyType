//
//  SettingsView.swift
//  KeyType
//
//  The KeyType Settings window. Laid out like Cotypist: a category sidebar on the left and the
//  matching settings pane on the right. Each pane lives in its own file (e.g. `ModelSettingsView`,
//  `PrivacySettingsView`); this file owns only the sidebar/category chrome and routes the selection
//  to the matching pane.
//

import Personalization
import SwiftUI

struct SettingsView: View {
    let settings: SettingsStore
    let telemetry: CompletionTelemetryStore
    let modelSetup: ModelSetupCoordinator
    let contextCapture: ContextCaptureController
    let developerOverrides: DeveloperOverrideController
    let permissions: PermissionsManager
    let clearPersonalData: () -> Void
    let runSetupAgain: () -> Void
    /// Tear down and reload the completion engine from the currently selected model. Invoked when the
    /// user picks a different installed model so the change takes effect immediately (see ADR-021).
    let reloadModel: () -> Void
    /// Present the GGUF import open panel. Owned by `AppDelegate` because it must quiesce the AX
    /// pipeline around the panel to avoid a main-thread deadlock (see `presentModelImportPanel`).
    let importModel: () -> Void
    /// Present the app-bundle picker with the same AX-pipeline quiescing used by model import.
    let addApp: () -> Void
    /// Show the compact non-activating developer tuning HUD.
    let openDeveloperOverridePanel: () -> Void
    /// Draw a synthetic ghost-text sample at the last tunable target for placement testing.
    let showDeveloperPlacementProbe: () -> Bool

    @State private var selection: SettingsCategory = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: $selection) { category in
                NavigationLink(value: category) {
                    SidebarRow(category: category)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 240)
            .listStyle(.sidebar)
        } detail: {
            detail
                .frame(minWidth: 480, idealWidth: 520)
                .navigationTitle(selection.title)
        }
        .frame(minWidth: 760, minHeight: 600)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general:
            GeneralSettingsView(settings: settings)
        case .model:
            ModelSettingsView(
                settings: settings,
                modelSetup: modelSetup,
                reloadModel: reloadModel,
                importModel: importModel
            )
        case .shortcuts:
            ShortcutsSettingsView(settings: settings)
        case .privacy:
            PrivacySettingsView(settings: settings, permissions: permissions, clearPersonalData: clearPersonalData)
        case .apps:
            AppsSettingsView(settings: settings, addApp: addApp)
        case .statistics:
            StatisticsSettingsView(
                telemetry: telemetry,
                makeLatencyExport: { LatencyExportContext.makeExportData(telemetry: telemetry, settings: settings) }
            )
        case .developer:
            DeveloperSettingsView(
                settings: settings,
                contextCapture: contextCapture,
                developerOverrides: developerOverrides,
                permissions: permissions,
                openTuningPanel: openDeveloperOverridePanel,
                showPlacementProbe: showDeveloperPlacementProbe
            )
        case .setup:
            SetupSettingsView(runSetupAgain: runSetupAgain)
        }
    }
}

// MARK: - Sidebar

/// The Settings categories shown in the left-hand sidebar, Cotypist-style. Each carries a title and
/// a tinted SF Symbol for the sidebar row.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case model
    case shortcuts
    case privacy
    case apps
    case statistics
    case developer
    case setup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .model: return "Model"
        case .shortcuts: return "Shortcuts"
        case .privacy: return "Privacy"
        case .apps: return "Apps"
        case .statistics: return "Statistics"
        case .developer: return "Developer"
        case .setup: return "Setup"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape.fill"
        case .model: return "cpu.fill"
        case .shortcuts: return "command"
        case .privacy: return "lock.shield.fill"
        case .apps: return "square.grid.2x2.fill"
        case .statistics: return "chart.bar.fill"
        case .developer: return "hammer.fill"
        case .setup: return "wand.and.stars"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .model: return .purple
        case .shortcuts: return .indigo
        case .privacy: return .green
        case .apps: return .orange
        case .statistics: return .teal
        case .developer: return .pink
        case .setup: return .blue
        }
    }
}

/// A sidebar row with a tinted, rounded-square icon — matching the Cotypist settings layout.
private struct SidebarRow: View {
    let category: SettingsCategory

    var body: some View {
        Label {
            Text(category.title)
        } icon: {
            Image(systemName: category.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(category.tint.gradient)
                )
        }
        .padding(.vertical, 2)
    }
}
