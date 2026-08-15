//
//  ModelSettingsView.swift
//  KeyType
//
//  The "Model" Settings pane: the active model picker, the catalog of downloadable/installed models
//  with their live setup state, and "import your own GGUF". Split out of SettingsView so each sidebar
//  category lives in its own file. See ADR-021.
//

import ModelManagement
import ModelRuntime
import SwiftUI

struct ModelSettingsView: View {
    @Bindable var settings: SettingsStore
    let modelSetup: ModelSetupCoordinator
    /// Tear down and reload the completion engine from the currently selected model so a new pick
    /// takes effect immediately (see ADR-021).
    let reloadModel: () -> Void
    /// Present the GGUF import open panel. Owned by `AppDelegate` because it must quiesce the AX
    /// pipeline around the panel to avoid a main-thread deadlock.
    let importModel: () -> Void

    @State private var availableModels: [String] = []

    var body: some View {
        Form {
            Section("Model") {
                Picker("Completion model", selection: $settings.selectedModelFilename) {
                    Text("Default (\(ModelContainer.defaultModelFilename))").tag(String?.none)
                    ForEach(modelSetup.mlxCatalog.filter(modelSetup.isFullyInstalled), id: \.id) { model in
                        Text("\(model.onboardingLabel): \(model.displayName)").tag(String?.some(model.id))
                    }
                    ForEach(availableModels, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                // Honor the "takes effect immediately" promise: a new selection flushes the resident
                // model + KV cache and reloads from the chosen GGUF without a relaunch (see ADR-021).
                .onChange(of: settings.selectedModelFilename) { reloadModel() }
            }

            Section("Available models") {
                ForEach(modelSetup.mlxCatalog) { model in
                    MLXSettingsModelRow(
                        model: model,
                        state: modelSetup.state(for: model),
                        isInstalled: modelSetup.mlxDownloads.isInstalled(model),
                        onSetup: { modelSetup.beginSetup(for: model) },
                        onCancel: { modelSetup.cancel(model) },
                        onDelete: { deleteMLXModel(model) }
                    )
                }
                ForEach(modelSetup.catalog) { model in
                    SettingsModelRow(
                        model: model,
                        state: modelSetup.state(for: model),
                        isInstalled: modelSetup.downloads.isInstalled(filename: model.filename),
                        onSetup: { modelSetup.beginSetup(for: model) },
                        onCancel: { modelSetup.cancel(model) },
                        onPause: { modelSetup.pause(model) },
                        onResume: { modelSetup.resume(model) },
                        onDelete: {
                            modelSetup.downloads.deleteModel(filename: model.filename)
                            modelSetup.refresh()
                            availableModels = Self.loadModels()
                        }
                    )
                }
            }

            Section {
                Button("Import a GGUF…", action: importModel)
                    .disabled(isImporting)
                importStatusLine
            } header: {
                Text("Use your own base model")
            } footer: {
                Text("KeyType is tuned for the models above; other models may produce unexpected or low-quality completions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { availableModels = Self.loadModels() }
        // A download/profile finishing changes a model's setup state but not `availableModels`,
        // which is loaded from disk. Reading every model's state here establishes the observation
        // dependency, so this fires (and re-reads the installed GGUFs) the moment one lands —
        // making freshly downloaded models selectable without a restart.
        .onChange(of: modelSetupSignature) { availableModels = Self.loadModels() }
        // An import lands a brand-new file in the Models directory that isn't in the catalog, so it
        // won't move `modelSetupSignature`. Re-read the installed GGUFs when the import state settles
        // so the freshly imported model appears in (and can be shown selected by) the picker.
        .onChange(of: modelSetup.importState) { availableModels = Self.loadModels() }
    }

    /// Changes whenever any catalog model's combined setup state changes, so the picker stays in sync.
    private var modelSetupSignature: String {
        (modelSetup.catalog
            .map { "\($0.filename):\(String(describing: modelSetup.state(for: $0)))" }
            + modelSetup.mlxCatalog.map { "\($0.id):\(String(describing: modelSetup.state(for: $0)))" })
            .joined(separator: "|")
    }

    private var isImporting: Bool {
        if case .preparing = modelSetup.importState { return true }
        return false
    }

    @ViewBuilder
    private var importStatusLine: some View {
        switch modelSetup.importState {
        case .idle:
            EmptyView()
        case .preparing(let filename):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Preparing \(filename)…").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private static func loadModels() -> [String] {
        guard let dir = try? ModelContainer.modelsDirectoryURL(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        return names.filter { $0.lowercased().hasSuffix(".gguf") }.sorted()
    }

    private func deleteMLXModel(_ model: SupportedMLXModel) {
        if settings.selectedModelFilename == model.id {
            settings.selectedModelFilename = nil
            reloadModel()
        }
        modelSetup.mlxDownloads.delete(model)
        modelSetup.refresh()
    }
}

private struct MLXSettingsModelRow: View {
    let model: SupportedMLXModel
    let state: ModelSetupCoordinator.SetupState
    let isInstalled: Bool
    let onSetup: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(model.onboardingLabel) — \(model.displayName)")
                    Text("\(model.approximateDownloadSizeLabel) download · \(model.minimumMemoryLabel) memory · Apple-silicon MLX")
                        .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
                Spacer()
                action
            }
            statusLine
        }
    }

    @ViewBuilder private var action: some View {
        switch state {
        case .ready: Button("Delete", role: .destructive, action: onDelete).font(.callout)
        case .downloading, .preparingProfile: Button("Cancel", action: onCancel).font(.callout)
        case .paused: EmptyView()
        case .idle, .failed:
            if isInstalled {
                HStack(spacing: 8) { Button("Validate", action: onSetup); Button("Delete", role: .destructive, action: onDelete) }.font(.callout)
            } else { Button("Set up", action: onSetup).font(.callout) }
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch state {
        case .idle: Text(model.detail).font(.footnote).foregroundStyle(.secondary)
        case let .downloading(progress):
            if let progress { ProgressView(value: progress); Text("Downloading \(Int((progress * 100).rounded()))%").font(.footnote).foregroundStyle(.secondary) }
            else { ProgressView().controlSize(.small) }
        case .paused: EmptyView()
        case .preparingProfile: HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Validating model…").font(.footnote).foregroundStyle(.secondary) }
        case .ready: Label("Ready", systemImage: "checkmark.circle.fill").font(.footnote.weight(.medium)).foregroundStyle(.green)
        case let .failed(message): Label(message, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One catalog model row in Settings: name, size, live setup state, and the contextual action
/// (Set up / Cancel / Delete).
private struct SettingsModelRow: View {
    let model: DownloadableRuntimeModel
    let state: ModelSetupCoordinator.SetupState
    let isInstalled: Bool
    let onSetup: () -> Void
    let onCancel: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.displayName)
                    Text(model.approximateSizeLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                action
            }
            statusLine
        }
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .ready:
            Button("Delete", role: .destructive, action: onDelete)
                .font(.callout)
        case .downloading:
            HStack(spacing: 8) {
                Button("Pause", action: onPause)
                Button("Cancel", action: onCancel)
            }
            .font(.callout)
        case .paused:
            HStack(spacing: 8) {
                Button("Resume", action: onResume)
                Button("Cancel", action: onCancel)
            }
            .font(.callout)
        case .preparingProfile:
            Button("Cancel", action: onCancel)
                .font(.callout)
        case .idle, .failed:
            if isInstalled {
                HStack(spacing: 8) {
                    Button("Prepare", action: onSetup)
                    Button("Delete", role: .destructive, action: onDelete)
                }
                .font(.callout)
            } else {
                Button("Set up", action: onSetup)
                    .font(.callout)
                    .disabled(!model.isDownloadable)
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch state {
        case .idle:
            if let reason = model.unavailableReason {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .downloading(let progress):
            if let progress {
                ProgressView(value: progress)
                Text("Downloading \(Int((progress * 100).rounded()))%")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        case .paused(let progress):
            ProgressView(value: progress ?? 0)
            Text(progress != nil ? "Paused at \(Int((progress! * 100).rounded()))%" : "Paused")
                .font(.footnote).foregroundStyle(.secondary)
        case .preparingProfile:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Preparing model…").font(.footnote).foregroundStyle(.secondary)
            }
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.medium)).foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
