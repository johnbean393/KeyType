//
//  DeveloperOverrideController.swift
//  KeyType
//
//  File-backed per-app override tuning for local development. The shipped defaults stay in
//  AppCompatibility; this controller lets a developer layer live JSON overrides on top without
//  rebuilding or reinstalling the app.
//

import AppCompatibility
import AppKit
import AutocompleteCore
import Foundation
import MacContextCapture
import Observation

@MainActor
@Observable
final class DeveloperOverrideController {
    let runtimeOverrideStore: RuntimeTargetOverrideStore
    let overridesURL: URL

    private let fileManager: FileManager
    private var reloadTimer: Timer?
    private var lastKnownModificationDate: Date?

    private(set) var document = DeveloperTargetOverrideDocument()
    private(set) var lastLoadedAt: Date?
    private(set) var lastError: String?
    private(set) var isMonitoring = false

    init(
        runtimeOverrideStore: RuntimeTargetOverrideStore = RuntimeTargetOverrideStore(),
        fileManager: FileManager = .default
    ) {
        self.runtimeOverrideStore = runtimeOverrideStore
        self.fileManager = fileManager
        self.overridesURL = Self.defaultOverridesURL(fileManager: fileManager)
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            do {
                try ensureOverridesFileExists()
                reloadFromDisk()
                startMonitoring()
            } catch {
                applyFailure(error)
            }
        } else {
            stopMonitoring()
            runtimeOverrideStore.replace(overrides: [])
        }
    }

    func reloadFromDisk() {
        do {
            try ensureOverridesFileExists()
            let data = try Data(contentsOf: overridesURL)
            let decoded = try JSONDecoder().decode(DeveloperTargetOverrideDocument.self, from: data)
            let normalized = normalizedDocument(decoded)
            document = normalized
            applyRuntimeOverrides(from: normalized)
            lastKnownModificationDate = modificationDate()
            lastLoadedAt = Date()
            lastError = nil
        } catch {
            applyFailure(error)
        }
    }

    func upsert(_ override: DeveloperTargetOverride) {
        var normalized = normalizedOverride(override)
        if normalized.id.isEmpty {
            normalized.id = normalized.stableID
        }

        var overrides = document.overrides
        if let index = overrides.firstIndex(where: { $0.stableID == normalized.stableID }) {
            overrides[index] = normalized
        } else {
            overrides.append(normalized)
        }
        save(overrides: overrides)
    }

    func deleteOverride(id: String) {
        save(overrides: document.overrides.filter { $0.stableID != id })
    }

    func clearOverrides() {
        save(overrides: [])
    }

    func openOverridesFile() {
        do {
            try ensureOverridesFileExists()
            NSWorkspace.shared.open(overridesURL)
        } catch {
            applyFailure(error)
        }
    }

    func revealOverridesFile() {
        do {
            try ensureOverridesFileExists()
            NSWorkspace.shared.activateFileViewerSelecting([overridesURL])
        } catch {
            applyFailure(error)
        }
    }

    func draft(for snapshot: FocusedFieldSnapshot?) -> DeveloperTargetOverride {
        guard let context = snapshot?.context else {
            return DeveloperTargetOverride(
                id: "bundle:",
                name: "",
                fontSizeAdjustmentFactor: 1,
                horizontalOffsetPoints: 0,
                verticalOffsetPoints: 0,
                verticalOffsetLineHeightMultiplier: 0
            )
        }

        let bundleIdentifier = context.target.bundleIdentifier
        let domain = context.target.domain ?? ""
        let name = context.target.appName
        let id: String
        if !bundleIdentifier.isEmpty {
            id = "bundle:\(bundleIdentifier)"
        } else if !domain.isEmpty {
            id = "domain:\(domain.lowercased())"
        } else {
            id = "override"
        }

        return DeveloperTargetOverride(
            id: id,
            name: name,
            bundleIdentifier: bundleIdentifier,
            domain: domain,
            fontSizeAdjustmentFactor: 1,
            horizontalOffsetPoints: 0,
            verticalOffsetPoints: 0,
            verticalOffsetLineHeightMultiplier: 0
        )
    }

    private func save(overrides: [DeveloperTargetOverride]) {
        do {
            let document = DeveloperTargetOverrideDocument(
                version: 1,
                overrides: overrides.map(normalizedOverride)
            )
            try write(document: document)
            self.document = document
            applyRuntimeOverrides(from: document)
            lastKnownModificationDate = modificationDate()
            lastLoadedAt = Date()
            lastError = nil
        } catch {
            applyFailure(error)
        }
    }

    private func startMonitoring() {
        guard reloadTimer == nil else {
            isMonitoring = true
            return
        }

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reloadIfChanged()
            }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        reloadTimer = timer
        isMonitoring = true
    }

    private func stopMonitoring() {
        reloadTimer?.invalidate()
        reloadTimer = nil
        isMonitoring = false
    }

    private func reloadIfChanged() {
        guard let modifiedAt = modificationDate(),
              modifiedAt != lastKnownModificationDate else {
            return
        }
        reloadFromDisk()
    }

    private func applyRuntimeOverrides(from document: DeveloperTargetOverrideDocument) {
        let overrides = document.overrides.compactMap { $0.targetOverride() }
        runtimeOverrideStore.replace(overrides: overrides)
    }

    private func applyFailure(_ error: Error) {
        lastError = error.localizedDescription
        runtimeOverrideStore.replace(overrides: [])
    }

    private func ensureOverridesFileExists() throws {
        try fileManager.createDirectory(
            at: overridesURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )

        guard !fileManager.fileExists(atPath: overridesURL.path) else { return }
        try write(document: DeveloperTargetOverrideDocument())
    }

    private func write(document: DeveloperTargetOverrideDocument) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        try fileManager.createDirectory(
            at: overridesURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try data.write(to: overridesURL, options: [.atomic])
    }

    private func normalizedDocument(_ document: DeveloperTargetOverrideDocument) -> DeveloperTargetOverrideDocument {
        DeveloperTargetOverrideDocument(
            version: max(1, document.version),
            overrides: document.overrides.map(normalizedOverride)
        )
    }

    private func normalizedOverride(_ override: DeveloperTargetOverride) -> DeveloperTargetOverride {
        var result = override
        result.id = result.stableID
        result.name = trimmed(result.name)
        result.bundleIdentifier = trimmed(result.bundleIdentifier)
        result.domain = trimmed(result.domain)
        result.customInstructions = trimmed(result.customInstructions)
        return result
    }

    private func modificationDate() -> Date? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: overridesURL.path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func defaultOverridesURL(fileManager: FileManager) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return applicationSupport
            .appendingPathComponent("KeyType", isDirectory: true)
            .appendingPathComponent("DeveloperOverrides.json")
    }
}
