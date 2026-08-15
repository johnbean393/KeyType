import Foundation
import ModelRuntime
import Observation
import os

/// Downloads curated MLX bundles into a private staging directory, verifies every pinned file,
/// then promotes the completed directory. A staging directory is never returned by `isInstalled`.
@MainActor
@Observable
public final class MLXBundleDownloadManager {
    public var states: [String: ModelDownloadState] = [:]
    public var onBundleInstalled: ((SupportedMLXModel) -> Void)?

    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private let log = Logger(subsystem: "com.pattonium.KeyType", category: "mlx-bundle-download")

    public init() {}

    public func state(for model: SupportedMLXModel) -> ModelDownloadState {
        states[model.id] ?? .idle
    }

    public func isInstalled(_ model: SupportedMLXModel) -> Bool {
        guard let directory = try? ModelContainer.mlxModelDirectoryURL(identifier: model.id) else { return false }
        return ModelContainer.modelBundleExists(at: directory)
            && model.requiredFiles.allSatisfy {
                FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.relativePath).path)
            }
    }

    public func refreshStates(catalog: [SupportedMLXModel] = MLXModelCatalog.models) {
        for model in catalog where downloadTasks[model.id] == nil {
            if isInstalled(model) {
                states[model.id] = .downloaded
            } else if case .failed = states[model.id] {
                continue
            } else {
                states[model.id] = .idle
            }
        }
    }

    public func download(_ model: SupportedMLXModel) {
        guard downloadTasks[model.id] == nil else { return }
        if isInstalled(model) {
            states[model.id] = .downloaded
            onBundleInstalled?(model)
            return
        }
        states[model.id] = .downloading(progress: 0)
        downloadTasks[model.id] = Task { [weak self] in
            guard let self else { return }
            await self.runDownload(model)
        }
    }

    public func cancel(_ model: SupportedMLXModel) {
        downloadTasks[model.id]?.cancel()
    }

    public func delete(_ model: SupportedMLXModel) {
        cancel(model)
        discardBundle(model)
    }

    /// Removes an artifact that failed integrity or live-preflight validation so the next setup
    /// attempt fetches the pinned bundle again rather than repeatedly reusing corrupted files.
    public func discardBundle(_ model: SupportedMLXModel) {
        guard let directory = try? ModelContainer.mlxModelDirectoryURL(identifier: model.id) else { return }
        try? FileManager.default.removeItem(at: directory)
        states[model.id] = .idle
    }

    private func runDownload(_ model: SupportedMLXModel) async {
        defer { downloadTasks[model.id] = nil }
        let fileManager = FileManager.default
        var stagingRoot: URL?
        do {
            let modelsDirectory = try ModelContainer.mlxModelsDirectoryURL(create: true)
            let staging = modelsDirectory.appendingPathComponent(".\(model.id).staging-\(UUID().uuidString)", isDirectory: true)
            stagingRoot = staging
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

            let totalBytes = max(Int64(1), model.requiredFiles.reduce(Int64(0)) { $0 + $1.expectedSizeBytes })
            var completedBytes: Int64 = 0
            for (file, url) in model.downloadURLs {
                try Task.checkCancellation()
                let destination = staging.appendingPathComponent(file.relativePath, isDirectory: false)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let (temporaryURL, response) = try await URLSession.shared.download(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                try fileManager.moveItem(at: temporaryURL, to: destination)
                try await Self.validateDownloadedFile(destination, manifest: file)
                completedBytes += file.expectedSizeBytes
                states[model.id] = .downloading(progress: Double(completedBytes) / Double(totalBytes))
            }
            // Each file above was size-and-digest checked on a utility executor. The final pass
            // proves the staged directory has exactly the safe shape without rehashing gigabytes.
            try ModelBundleValidator.validate(directory: staging, manifest: model, verifyDigests: false)
            try Task.checkCancellation()

            let destination = try ModelContainer.mlxModelDirectoryURL(identifier: model.id, createParent: true)
            let backup = destination.deletingLastPathComponent()
                .appendingPathComponent(".\(model.id).replacing-\(UUID().uuidString)", isDirectory: true)
            var movedExistingBundle = false
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: destination, to: backup)
                movedExistingBundle = true
            }
            do {
                try fileManager.moveItem(at: staging, to: destination)
            } catch {
                if movedExistingBundle, fileManager.fileExists(atPath: backup.path) {
                    try? fileManager.moveItem(at: backup, to: destination)
                }
                throw error
            }
            if movedExistingBundle {
                try? fileManager.removeItem(at: backup)
            }
            states[model.id] = .downloaded
            onBundleInstalled?(model)
        } catch {
            if let stagingRoot {
                try? fileManager.removeItem(at: stagingRoot)
            }
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                states[model.id] = isInstalled(model) ? .downloaded : .idle
            } else {
                log.error("MLX bundle download failed for \(model.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                states[model.id] = .failed(error.localizedDescription)
            }
        }
    }

    private nonisolated static func validateDownloadedFile(
        _ url: URL,
        manifest: VerifiedModelBundleFile
    ) async throws {
        try await Task.detached(priority: .utility) {
            try ModelFileValidator.validateSize(of: url, expectedBytes: manifest.expectedSizeBytes)
            try ModelFileValidator.validateSHA256(of: url, expectedSHA256: manifest.sha256)
        }.value
    }
}
