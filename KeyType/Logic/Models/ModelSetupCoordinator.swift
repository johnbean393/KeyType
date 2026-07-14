//
//  ModelSetupCoordinator.swift
//  KeyType
//
//  App-level orchestration that turns "download a model" into a complete, usable setup: it owns the
//  `ModelDownloadManager` (GGUF fetch) and chains `ProfileGenerator` (ACPF build) after a GGUF lands,
//  exposing a single combined per-model state the onboarding wizard and Settings can render. A model
//  is only `.ready` once both its GGUF and its ACPF profile exist on disk.
//

import Foundation
import LlamaModelRuntime
import ModelManagement
import ModelProfileGeneration
import ModelRuntime
import Observation
import os

@MainActor
@Observable
final class ModelSetupCoordinator {

    /// Combined download + profile-generation state for one model.
    enum SetupState: Equatable {
        case idle
        case downloading(progress: Double?)
        case paused(progress: Double?)
        case preparingProfile
        case ready
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .downloading, .preparingProfile: return true
            case .idle, .paused, .ready, .failed: return false
            }
        }
    }

    let downloads: ModelDownloadManager

    /// Progress of an in-flight import of a user-supplied GGUF from outside the curated catalog.
    /// Failures are not part of this state — they are surfaced via `onImportFailure` so the app can
    /// present a modal alert the user must dismiss (see ADR-036), rather than an inline status line.
    enum ImportState: Equatable {
        case idle
        case preparing(filename: String)
    }

    /// Profile-generation phase per filename. Absent means no profile work is in flight.
    private enum ProfilePhase: Equatable {
        case preparing
        case ready
        case failed(String)
    }
    private var profilePhases: [String: ProfilePhase] = [:]
    private var profileTasks: [String: Task<Void, Never>] = [:]

    /// Live state of a user-initiated "Import a GGUF…" action. Observable, so Settings can show
    /// progress and surface failures. Returns to `.idle` once the import is fully prepared.
    private(set) var importState: ImportState = .idle
    private var importTask: Task<Void, Never>?

    /// Called on the main actor when a model becomes fully usable (GGUF + ACPF present).
    var onModelReady: ((String) -> Void)?

    /// Called on the main actor with a user-facing message when an import fails (incompatible GGUF,
    /// copy/profile error, …). The app wires this to a modal `NSAlert` the user must dismiss.
    var onImportFailure: ((String) -> Void)?

    private let log = Logger(subsystem: "com.pattonium.KeyType", category: "model-setup")

    init(downloads: ModelDownloadManager? = nil) {
        // The default is computed in-body (not as a default argument) because the manager's
        // initializer is main-actor isolated and default-argument expressions are not.
        let downloads = downloads ?? ModelDownloadManager()
        self.downloads = downloads
        self.downloads.onGGUFInstalled = { [weak self] model in
            self?.startProfileGeneration(forFilename: model.filename)
        }
    }

    var catalog: [DownloadableRuntimeModel] { downloads.catalog }

    // MARK: - State

    /// The merged setup state for `model`, derived from the live download state plus any
    /// profile-generation phase. Observable, so SwiftUI refreshes as either input changes.
    func state(for model: DownloadableRuntimeModel) -> SetupState {
        if let phase = profilePhases[model.filename] {
            switch phase {
            case .preparing: return .preparingProfile
            case .ready: return .ready
            case .failed(let message): return .failed(message)
            }
        }
        switch downloads.state(for: model) {
        case .idle:
            return isFullyInstalled(model) ? .ready : .idle
        case .downloading(let progress):
            return .downloading(progress: progress)
        case .paused(let progress):
            return .paused(progress: progress)
        case .downloaded:
            return isFullyInstalled(model) ? .ready : .idle
        case .failed(let message):
            return .failed(message)
        }
    }

    /// A model is usable only when both its GGUF and its ACPF profile are on disk.
    func isFullyInstalled(_ model: DownloadableRuntimeModel) -> Bool {
        downloads.isInstalled(filename: model.filename) && isProfilePresent(for: model)
    }

    private func isProfilePresent(for model: DownloadableRuntimeModel) -> Bool {
        guard let url = try? ModelContainer.profileURL(family: model.tokenizerFamily) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Actions

    /// Begins (or resumes) setup for `model`: downloads the GGUF if missing, otherwise builds the
    /// missing ACPF profile, otherwise no-ops if already ready. Selecting a model is the user's
    /// explicit consent for any multi-gigabyte download.
    func beginSetup(for model: DownloadableRuntimeModel) {
        if isFullyInstalled(model) {
            profilePhases[model.filename] = .ready
            onModelReady?(model.filename)
            return
        }
        if downloads.isInstalled(filename: model.filename) {
            startProfileGeneration(forFilename: model.filename)
        } else {
            downloads.download(model)
        }
    }

    /// Pause an in-flight GGUF download, keeping resume data so it can continue later.
    func pause(_ model: DownloadableRuntimeModel) {
        downloads.pause(filename: model.filename)
    }

    /// Resume a previously paused GGUF download.
    func resume(_ model: DownloadableRuntimeModel) {
        downloads.resume(model)
    }

    func cancel(_ model: DownloadableRuntimeModel) {
        downloads.cancel(filename: model.filename)
        profileTasks[model.filename]?.cancel()
        profileTasks[model.filename] = nil
        if case .preparing = profilePhases[model.filename] {
            profilePhases[model.filename] = nil
        }
        downloads.refreshStates()
    }

    /// Import a GGUF the user already has on disk (downloaded elsewhere, outside our catalog): copy
    /// it into the Models directory, build its ACPF profile from the GGUF's own tokenizer, then —
    /// via `onModelReady` — select it and reload the engine. The model is only made the active one
    /// once both files are present, mirroring the catalog setup path. Off-catalog models are
    /// unvetted, so callers warn the user that behavior may be unexpected.
    func importModel(from sourceURL: URL) {
        let filename = sourceURL.lastPathComponent
        guard filename.lowercased().hasSuffix(".gguf") else {
            reportImportFailure("Choose a model file with a .gguf extension.", filename: filename, detail: nil)
            return
        }
        importTask?.cancel()
        importState = .preparing(filename: filename)
        importTask = Task { [weak self] in
            do {
                // Compatibility gate first, straight from the chosen file: if this build of
                // llama.cpp can't load the GGUF (unsupported architecture or a newer GGUF format),
                // reject it with a clear warning before copying anything into the Models directory.
                try await Self.assertModelCompatible(at: sourceURL, filename: filename)
                let destination = try ModelContainer.modelURL(filename: filename)
                try Self.copyIntoModelsDirectory(from: sourceURL, to: destination)
                try await ProfileGenerator.generateProfileIfNeeded(forModelFilename: filename)
                guard let self, !Task.isCancelled else { return }
                self.importState = .idle
                self.importTask = nil
                self.downloads.refreshStates()
                self.log.info("Imported GGUF \(filename, privacy: .public) ready (GGUF + ACPF present)")
                self.onModelReady?(filename)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.importTask = nil
                self.reportImportFailure(Self.message(for: error), filename: filename, detail: String(describing: error))
            }
        }
    }

    /// Clear any in-flight state, log, and hand the user-facing message to `onImportFailure` (which
    /// the app shows as a modal alert). `detail` is logged for diagnostics; `message` is shown.
    private func reportImportFailure(_ message: String, filename: String, detail: String?) {
        importState = .idle
        log.error("Import failed for \(filename, privacy: .public): \(detail ?? message, privacy: .public)")
        onImportFailure?(message)
    }

    /// Probe whether the vendored llama.cpp build can actually bring up `url`. Loading is the
    /// authoritative compatibility check: `llama_model_load_from_file` returns NULL (surfaced as
    /// `LlamaRuntimeError.modelLoadFailed`) for a GGUF whose architecture or format version this
    /// build doesn't support. A tiny context keeps the probe cheap, and we free it immediately —
    /// ggml-metal asserts at process exit if a context's GPU residency was never released (ADR-021).
    /// Throws `IncompatibleModelError` when the model is unusable so the caller can warn and abort.
    private static func assertModelCompatible(at url: URL, filename: String) async throws {
        do {
            let probe = try LlamaModelRuntime(modelURL: url, contextLength: 256, reuseThreshold: 0)
            await probe.shutdown()
        } catch let error as LlamaRuntimeError where Self.indicatesIncompatibility(error) {
            throw IncompatibleModelError(filename: filename, underlying: error)
        }
    }

    /// llama.cpp failure modes that mean "this build can't use this GGUF at all" (as opposed to a
    /// transient/runtime decode error): the model, its context, or its vocab never came up.
    private static func indicatesIncompatibility(_ error: LlamaRuntimeError) -> Bool {
        switch error {
        case .modelLoadFailed, .contextInitFailed, .vocabUnavailable:
            return true
        default:
            return false
        }
    }

    /// User-facing message for an import failure. `CustomStringConvertible` errors (our typed llama /
    /// profile errors) carry a readable description; `localizedDescription` would flatten them to a
    /// generic "operation couldn't be completed" string, so prefer the description.
    private static func message(for error: Error) -> String {
        if let incompatible = error as? IncompatibleModelError { return incompatible.description }
        if let convertible = error as? CustomStringConvertible, !(error is LocalizedError) {
            return convertible.description
        }
        return error.localizedDescription
    }

    /// Raised when a user-imported GGUF can't be loaded by the current llama.cpp build.
    struct IncompatibleModelError: Error, CustomStringConvertible {
        let filename: String
        let underlying: LlamaRuntimeError
        var description: String {
            "“\(filename)” isn’t compatible with this version of KeyType’s model runtime (llama.cpp) "
            + "and can’t be used. It may use an unsupported architecture or a newer GGUF format than "
            + "this build supports."
        }
    }

    /// Copy `source` to its destination inside the Models directory, creating the directory and
    /// replacing any existing file with the same name (re-importing refreshes the on-disk copy).
    private static func copyIntoModelsDirectory(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        _ = try ModelContainer.modelsDirectoryURL(create: true)
        if source.standardizedFileURL == destination.standardizedFileURL { return }
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    }

    func refresh() {
        downloads.refreshStates()
        // Drop stale "ready" phases for files that were deleted out from under us.
        for model in catalog where profilePhases[model.filename] == .ready && !isFullyInstalled(model) {
            profilePhases[model.filename] = nil
        }
    }

    private func startProfileGeneration(forFilename filename: String) {
        guard profileTasks[filename] == nil else { return }
        profilePhases[filename] = .preparing
        let task = Task { [weak self] in
            do {
                try await ProfileGenerator.generateProfileIfNeeded(forModelFilename: filename)
                guard let self else { return }
                self.profilePhases[filename] = .ready
                self.profileTasks[filename] = nil
                self.log.info("Model \(filename, privacy: .public) ready (GGUF + ACPF present)")
                self.onModelReady?(filename)
            } catch {
                guard let self else { return }
                self.profilePhases[filename] = .failed(error.localizedDescription)
                self.profileTasks[filename] = nil
                self.log.error("Profile generation failed for \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        profileTasks[filename] = task
    }
}
