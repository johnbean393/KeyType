//
//  ModelSettingsView.swift
//  KeyType
//
//  The "Model" Settings pane: the active model picker, the catalog of downloadable/installed models
//  with their live setup state, "import your own GGUF", and configuration for remote OpenAI-compatible
//  API models as an alternative to local GGUF inference. Split out of SettingsView so each sidebar
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
    @State private var showAddAPIModel = false
    /// Ephemeral editing state for the "add API model" sheet.
    @State private var editDisplayName = ""
    @State private var editEndpoint = ""
    @State private var editAPIKey = ""
    @State private var editModelName = ""

    var body: some View {
        Form {
            // ── Engine type toggle ────────────────────────────────────────
            Section {
                Picker("Engine", selection: $settings.useRemoteModel) {
                    Text("Local (GGUF)").tag(false)
                    Text("Remote API").tag(true)
                }
                .pickerStyle(.radioGroup)
                .onChange(of: settings.useRemoteModel) { reloadModel() }
            } footer: {
                Text(settings.useRemoteModel
                    ? "Offload inference to an external server — saves Mac GPU/RAM resources."
                    : "Run models directly on your Mac using llama.cpp."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if settings.useRemoteModel {
                remoteModelSection
            } else {
                localModelSection
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showAddAPIModel) {
            addAPIModelSheet
        }
        .task { availableModels = Self.loadModels() }
        .onChange(of: modelSetupSignature) { availableModels = Self.loadModels() }
        .onChange(of: modelSetup.importState) { availableModels = Self.loadModels() }
    }

    // MARK: - Local model section (existing)

    @ViewBuilder
    private var localModelSection: some View {
        Section("Model") {
            Picker("Completion model", selection: $settings.selectedModelFilename) {
                Text("Default (\(ModelContainer.defaultModelFilename))").tag(String?.none)
                ForEach(availableModels, id: \.self) { name in
                    Text(name).tag(String?.some(name))
                }
            }
            .onChange(of: settings.selectedModelFilename) { reloadModel() }
        }

        Section("Available models") {
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

    // MARK: - Remote API model section

    @ViewBuilder
    private var remoteModelSection: some View {
        if settings.apiModels.isEmpty {
            Section {
                Button("Add API Model…") { presentAddSheet() }
            } footer: {
                Text("Add an OpenAI-compatible endpoint (LM Studio, Ollama, vLLM, or any cloud API).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            Section("API Models") {
                ForEach(settings.apiModels) { model in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName).font(.body)
                            Text(model.endpoint)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text("Model: \(model.modelName)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if model.id == settings.selectedAPIModelID {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { indexSet in
                    let toRemove = indexSet.map { settings.apiModels[$0].id }
                    settings.apiModels.remove(atOffsets: indexSet)
                    if settings.selectedAPIModelID.map({ toRemove.contains($0) }) == true {
                        settings.selectedAPIModelID = settings.apiModels.first?.id
                        reloadModel()
                    }
                }
            }

            Section {
                Picker("Active model", selection: $settings.selectedAPIModelID) {
                    ForEach(settings.apiModels) { model in
                        Text(model.displayName).tag(Optional(model.id))
                    }
                }
                .onChange(of: settings.selectedAPIModelID) { reloadModel() }
            } header: {
                Text("Selection")
            }

            Section {
                Button("Add API Model…") { presentAddSheet() }
            }
        }
    }

    // MARK: - Add API model sheet

    private var addAPIModelSheet: some View {
        VStack(spacing: 0) {
            Form {
                Section("Add API Model") {
                    TextField("Display name", text: $editDisplayName)
                        .textFieldStyle(.roundedBorder)
                    TextField("API endpoint", text: $editEndpoint)
                        .textFieldStyle(.roundedBorder)
                        .help("e.g. http://localhost:1234/v1")
                    TextField("Model name", text: $editModelName)
                        .textFieldStyle(.roundedBorder)
                        .help("e.g. qwen2.5-7b-instruct, gpt-4o-mini")
                    SecureField("API key (optional)", text: $editAPIKey)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel", role: .cancel) {
                    showAddAPIModel = false
                }
                Spacer()
                Button("Add") {
                    let config = APIModelConfig(
                        displayName: editDisplayName,
                        endpoint: editEndpoint,
                        apiKey: editAPIKey,
                        modelName: editModelName
                    )
                    settings.apiModels.append(config)
                    settings.selectedAPIModelID = config.id
                    resetEditFields()
                    showAddAPIModel = false
                    reloadModel()
                }
                .buttonStyle(.borderedProminent)
                .disabled(editDisplayName.isEmpty || editEndpoint.isEmpty || editModelName.isEmpty)
            }
            .padding()
        }
        .frame(width: 480)
    }

    private func presentAddSheet() {
        resetEditFields()
        showAddAPIModel = true
    }

    private func resetEditFields() {
        editDisplayName = ""
        editEndpoint = ""
        editAPIKey = ""
        editModelName = ""
    }

    // MARK: - Shared helpers

    private var modelSetupSignature: String {
        modelSetup.catalog
            .map { "\($0.filename):\(String(describing: modelSetup.state(for: $0)))" }
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
