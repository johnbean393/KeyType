//
//  ModelSetupCoordinator.swift
//  KeyType
//
//  Coordinates artifact download with the tokenizer/profile validation that makes a model safe
//  for the constrained decoder. Downloaded does not mean selectable: only `.ready` does.
//

import Foundation
import MLXModelProfileGeneration
import ModelManagement
import ModelProfileGeneration
import Observation

@MainActor
@Observable
final class ModelSetupCoordinator {
    enum SetupState: Equatable {
        case idle
        case downloading(Double?)
        case paused(Double?)
        case preparingProfile
        case ready
        case failed(String)
    }

    enum ImportState: Equatable {
        case idle
        case preparing(String)
    }

    let downloads = ModelDownloadManager()
    let mlxDownloads = MLXBundleDownloadManager()
    let catalog = RuntimeModelCatalog.models
    let mlxCatalog = MLXModelCatalog.models()

    var onModelReady: ((String) -> Void)?
    var onImportFailure: ((String) -> Void)?
    private(set) var importState: ImportState = .idle
    private var profileStates: [String: SetupState] = [:]
    private var mlxPreparationStates: [String: SetupState] = [:]
    private var mlxPreparationTasks: [String: Task<Void, Never>] = [:]

    init() {
        downloads.onGGUFInstalled = { [weak self] model in
            self?.prepareGGUF(model)
        }
        mlxDownloads.onBundleInstalled = { [weak self] model in
            self?.prepareMLX(model)
        }
    }

    var recommendedModelID: String? {
        MLXModelCatalog.recommended()?.id
    }

    func refresh() {
        downloads.refreshStates()
        mlxDownloads.refreshStates(catalog: mlxCatalog)
        for model in mlxCatalog where mlxDownloads.isInstalled(model) {
            prepareMLX(model, selectWhenReady: false)
        }
    }

    func state(for model: DownloadableRuntimeModel) -> SetupState {
        if let state = profileStates[model.filename] { return state }
        return setupState(downloads.state(for: model))
    }

    func state(for model: SupportedMLXModel) -> SetupState {
        if let state = mlxPreparationStates[model.id] { return state }
        return setupState(mlxDownloads.state(for: model))
    }

    func isFullyInstalled(_ model: DownloadableRuntimeModel) -> Bool {
        if case .ready = state(for: model) { return true }
        return false
    }

    func isFullyInstalled(_ model: SupportedMLXModel) -> Bool {
        if case .ready = state(for: model) { return true }
        return false
    }

    func beginSetup(for model: DownloadableRuntimeModel) {
        if downloads.isInstalled(filename: model.filename) {
            prepareGGUF(model)
        } else {
            downloads.download(model)
        }
    }

    func beginSetup(for model: SupportedMLXModel) {
        if mlxDownloads.isInstalled(model) {
            prepareMLX(model)
        } else {
            mlxDownloads.download(model)
        }
    }

    func cancel(_ model: DownloadableRuntimeModel) {
        downloads.cancel(filename: model.filename)
        profileStates[model.filename] = nil
    }

    func cancel(_ model: SupportedMLXModel) {
        mlxDownloads.cancel(model)
        mlxPreparationTasks[model.id]?.cancel()
        mlxPreparationStates[model.id] = nil
    }

    func pause(_ model: DownloadableRuntimeModel) {
        downloads.pause(filename: model.filename)
    }

    func resume(_ model: DownloadableRuntimeModel) {
        downloads.resume(model)
    }

    /// MLX bundles are staged atomically rather than range-resumed. A cancelled download restarts
    /// cleanly, which avoids making a partial multi-file bundle appear ready.
    func pause(_ model: SupportedMLXModel) {}

    func resume(_ model: SupportedMLXModel) {
        mlxDownloads.download(model)
    }

    func importModel(from sourceURL: URL) {
        importState = .preparing(sourceURL.lastPathComponent)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await downloads.installLocalModel(from: sourceURL)
                guard let model = downloads.catalog.first(where: { $0.filename == sourceURL.lastPathComponent }) else {
                    try await ProfileGenerator.generateProfileIfNeeded(forModelFilename: sourceURL.lastPathComponent)
                    onModelReady?(sourceURL.lastPathComponent)
                    importState = .idle
                    return
                }
                prepareGGUF(model)
                importState = .idle
            } catch {
                importState = .idle
                onImportFailure?(error.localizedDescription)
            }
        }
    }

    private func prepareGGUF(_ model: DownloadableRuntimeModel) {
        guard !isPreparing(profileStates[model.filename]) else { return }
        profileStates[model.filename] = .preparingProfile
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await ProfileGenerator.generateProfileIfNeeded(forModelFilename: model.filename)
                profileStates[model.filename] = .ready
                onModelReady?(model.filename)
            } catch {
                profileStates[model.filename] = .failed(error.localizedDescription)
            }
        }
    }

    private func prepareMLX(_ model: SupportedMLXModel, selectWhenReady: Bool = true) {
        guard !isPreparing(mlxPreparationStates[model.id]) else { return }
        mlxPreparationStates[model.id] = .preparingProfile
        mlxPreparationTasks[model.id] = Task { [weak self] in
            guard let self else { return }
            defer { self.mlxPreparationTasks[model.id] = nil }
            do {
                let prepared = try await MLXModelPreflight.prepare(model)
                await MLXModelPreflight.shutdown(prepared)
                try Task.checkCancellation()
                mlxPreparationStates[model.id] = .ready
                if selectWhenReady { onModelReady?(model.id) }
            } catch is CancellationError {
                mlxPreparationStates[model.id] = .idle
            } catch {
                mlxDownloads.discardBundle(model)
                mlxPreparationStates[model.id] = .failed(error.localizedDescription)
            }
        }
    }

    private func setupState(_ state: ModelDownloadState) -> SetupState {
        switch state {
        case .idle: .idle
        case let .downloading(progress): .downloading(progress)
        case let .paused(progress): .paused(progress)
        case .downloaded: .idle
        case let .failed(message): .failed(message)
        }
    }

    private func isPreparing(_ state: SetupState?) -> Bool {
        if case .preparingProfile = state { return true }
        return false
    }
}
