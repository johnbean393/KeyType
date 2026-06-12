//
//  DeveloperOverridePanelController.swift
//  KeyType
//
//  Compact non-activating HUD for placement tuning. This intentionally is not a SwiftUI `Window`:
//  the target app must remain the active/focused app while KeyType's override controls are visible.
//

import AppCompatibility
import AppKit
import AutocompleteCore
import MacContextCapture
import SwiftUI

@MainActor
final class DeveloperOverridePanelController {
    private let settings: SettingsStore
    private let developerOverrides: DeveloperOverrideController
    private let contextCapture: ContextCaptureController
    private let completion: CompletionController

    private lazy var hostingView = NSHostingView(
        rootView: DeveloperOverrideHUDView(
            settings: settings,
            developerOverrides: developerOverrides,
            contextCapture: contextCapture,
            completion: completion
        )
    )
    private lazy var panel = makePanel()

    init(
        settings: SettingsStore,
        developerOverrides: DeveloperOverrideController,
        contextCapture: ContextCaptureController,
        completion: CompletionController
    ) {
        self.settings = settings
        self.developerOverrides = developerOverrides
        self.contextCapture = contextCapture
        self.completion = completion
    }

    func show() {
        if settings.developerOverrideTuningEnabled {
            developerOverrides.reloadFromDisk()
        }
        if !panel.isVisible {
            positionNearMainScreen()
        }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 370, height: 380),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "KeyType Tuning"
        panel.contentView = hostingView
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .utilityWindow
        return panel
    }

    private func positionNearMainScreen() {
        guard let screenFrame = NSScreen.main?.visibleFrame else {
            panel.center()
            return
        }
        let size = panel.frame.size
        let origin = CGPoint(
            x: screenFrame.maxX - size.width - 24,
            y: screenFrame.maxY - size.height - 24
        )
        panel.setFrameOrigin(origin)
    }
}

private struct DeveloperOverrideHUDView: View {
    @Bindable var settings: SettingsStore
    @Bindable var developerOverrides: DeveloperOverrideController
    @Bindable var contextCapture: ContextCaptureController
    let completion: CompletionController

    @State private var draft = DeveloperTargetOverride(
        fontSizeAdjustmentFactor: 1,
        horizontalOffsetPoints: 0,
        verticalOffsetPoints: 0,
        verticalOffsetLineHeightMultiplier: 0
    )
    @State private var scope: DeveloperOverrideScope = .bundle
    @State private var hasLoadedTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            targetSummary
            Divider()
            placementControls
            overlayControls
            actionBar
            if let lastError = developerOverrides.lastError {
                Text(lastError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(width: 370)
        .onAppear {
            if settings.developerOverrideTuningEnabled {
                loadLastTarget()
            }
        }
        .onChange(of: scope) { _, _ in
            loadLastTarget()
        }
        .onChange(of: contextCapture.latestTunableSnapshot?.context) { _, _ in
            loadLastTarget()
            completion.refreshVisibleSuggestion(using: contextCapture.latestTunableSnapshot)
        }
        .onChange(of: placementSignature) { _, _ in
            applyDraft()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(.orange)
            Text("Override Tuning")
                .font(.headline)
            Spacer()
            Toggle("", isOn: developerOverrideEnabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private var targetSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(targetTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(targetSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("Auto")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }

            Picker("Scope", selection: $scope) {
                ForEach(DeveloperOverrideScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .disabled(!settings.developerOverrideTuningEnabled || !hasDomainTarget)
        }
    }

    private var placementControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HUDSliderRow(
                title: "Scale",
                value: optionalDoubleBinding(\.fontSizeAdjustmentFactor, default: 1, step: 0.005),
                range: 0.85...1.15,
                step: 0.005,
                format: "%.3f"
            )
            HUDSliderRow(
                title: "X",
                value: optionalDoubleBinding(\.horizontalOffsetPoints, default: 0, step: 1),
                range: -80...80,
                step: 1,
                format: "%.0f"
            )
            HUDSliderRow(
                title: "Y pt",
                value: optionalDoubleBinding(\.verticalOffsetPoints, default: 0, step: 1),
                range: -80...80,
                step: 1,
                format: "%.0f"
            )
            HUDSliderRow(
                title: "Y line",
                value: optionalDoubleBinding(\.verticalOffsetLineHeightMultiplier, default: 0, step: 0.05),
                range: -3...3,
                step: 0.05,
                format: "%.2f"
            )
        }
        .disabled(!settings.developerOverrideTuningEnabled || !hasLoadedTarget)
    }

    private var overlayControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Overlay", selection: overlayPreferenceBinding) {
                Text("Inherit").tag(nil as DeveloperOverlayPreference?)
                Text("Inline").tag(Optional(DeveloperOverlayPreference.inline))
                Text("Mirror").tag(Optional(DeveloperOverlayPreference.textMirror))
                Text("Hidden").tag(Optional(DeveloperOverlayPreference.hidden))
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            Toggle("Paste and match style", isOn: $draft.requiresPasteAndMatchStyle)
                .controlSize(.small)
                .onChange(of: draft.requiresPasteAndMatchStyle) { _, _ in applyDraft() }
        }
        .disabled(!settings.developerOverrideTuningEnabled || !hasLoadedTarget)
    }

    private var actionBar: some View {
        HStack {
            Button("Reset") {
                resetPlacement()
            }
            .controlSize(.small)
            .disabled(!settings.developerOverrideTuningEnabled || !hasLoadedTarget)

            Button("Delete") {
                deleteDraft()
            }
            .controlSize(.small)
            .disabled(!settings.developerOverrideTuningEnabled || !hasLoadedTarget)

            Spacer()

            Button("JSON") {
                developerOverrides.openOverridesFile()
            }
            .controlSize(.small)

            Button("Reveal") {
                developerOverrides.revealOverridesFile()
            }
            .controlSize(.small)
        }
    }

    private var developerOverrideEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.developerOverrideTuningEnabled },
            set: { isEnabled in
                settings.developerOverrideTuningEnabled = isEnabled
                developerOverrides.setEnabled(isEnabled)
                if isEnabled {
                    loadLastTarget()
                }
            }
        )
    }

    private var overlayPreferenceBinding: Binding<DeveloperOverlayPreference?> {
        Binding(
            get: { draft.overlayPreference },
            set: {
                draft.overlayPreference = $0
                applyDraft()
            }
        )
    }

    private var placementSignature: PlacementSignature {
        PlacementSignature(
            scale: draft.fontSizeAdjustmentFactor ?? 1,
            x: draft.horizontalOffsetPoints ?? 0,
            y: draft.verticalOffsetPoints ?? 0,
            line: draft.verticalOffsetLineHeightMultiplier ?? 0
        )
    }

    private var hasDomainTarget: Bool {
        guard let snapshot = contextCapture.latestTunableSnapshot else { return false }
        return snapshot.context.target.domain?.isEmpty == false
    }

    private var targetTitle: String {
        guard let snapshot = contextCapture.latestTunableSnapshot else {
            return "No captured target"
        }
        return snapshot.context.target.appName
    }

    private var targetSubtitle: String {
        guard let snapshot = contextCapture.latestTunableSnapshot else {
            return "Focus the app you want to tune, then use this HUD."
        }
        let target = snapshot.context.target
        switch scope {
        case .bundle:
            return target.bundleIdentifier
        case .domain:
            return target.domain ?? target.bundleIdentifier
        }
    }

    private func optionalDoubleBinding(
        _ keyPath: WritableKeyPath<DeveloperTargetOverride, Double?>,
        default defaultValue: Double,
        step: Double
    ) -> Binding<Double> {
        Binding(
            get: { draft[keyPath: keyPath] ?? defaultValue },
            set: { draft[keyPath: keyPath] = rounded($0, step: step) }
        )
    }

    private func loadLastTarget() {
        guard let snapshot = contextCapture.latestTunableSnapshot else {
            hasLoadedTarget = false
            return
        }

        if scope == .domain, snapshot.context.target.domain == nil {
            scope = .bundle
        }

        let scoped = scopedDraft(from: developerOverrides.draft(for: snapshot))
        if let saved = developerOverrides.document.overrides.first(where: { $0.stableID == scoped.stableID }) {
            draft = saved
        } else {
            draft = scoped
        }
        hasLoadedTarget = true
    }

    private func scopedDraft(from base: DeveloperTargetOverride) -> DeveloperTargetOverride {
        var result = base
        switch scope {
        case .bundle:
            result.domain = ""
            result.id = result.bundleIdentifier.isEmpty ? result.stableID : "bundle:\(result.bundleIdentifier)"
        case .domain:
            result.bundleIdentifier = ""
            result.name = result.domain
            result.id = result.domain.isEmpty ? result.stableID : "domain:\(result.domain.lowercased())"
        }
        return result
    }

    private func applyDraft() {
        guard settings.developerOverrideTuningEnabled, hasLoadedTarget else { return }
        var override = draft
        override.id = override.stableID
        developerOverrides.upsert(override)
        draft = override
        completion.refreshVisibleSuggestion(using: contextCapture.latestTunableSnapshot)
    }

    private func resetPlacement() {
        draft.fontSizeAdjustmentFactor = 1
        draft.horizontalOffsetPoints = 0
        draft.verticalOffsetPoints = 0
        draft.verticalOffsetLineHeightMultiplier = 0
        draft.overlayPreference = nil
        draft.requiresPasteAndMatchStyle = false
        applyDraft()
    }

    private func deleteDraft() {
        developerOverrides.deleteOverride(id: draft.stableID)
        loadLastTarget()
    }

    private func rounded(_ value: Double, step: Double) -> Double {
        (value / step).rounded() * step
    }
}

private struct HUDSliderRow: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var format: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .frame(width: 42, alignment: .leading)
            Slider(value: $value, in: range, step: step)
            Text(String(format: format, value))
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 24)
        }
    }
}

private struct PlacementSignature: Equatable {
    var scale: Double
    var x: Double
    var y: Double
    var line: Double
}

private enum DeveloperOverrideScope: String, CaseIterable, Identifiable {
    case bundle
    case domain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bundle: return "Bundle"
        case .domain: return "Domain"
        }
    }
}
