//
//  OnboardingView.swift
//  KeyType
//
//  First-run onboarding wizard. A finite, guided flow:
//  welcome -> permissions -> model -> privacy -> keybinds -> turn off macOS predictions -> done.
//
//  Layout invariants (mirrored from the reference design): the Back/Continue footer is pinned
//  outside the scrolling content so a tall step can never push Continue off-screen, and each middle
//  step shows a progress indicator so the flow reads as finite.
//

import AppKit
import ModelManagement
import ModelRuntime
import SwiftUI

struct OnboardingView: View {
    let permissionGuidance: PermissionGuidanceController
    var markCompleted: () -> Void = {}

    @Environment(PermissionsManager.self) private var permissions
    @Environment(SettingsStore.self) private var settings
    @Environment(ModelSetupCoordinator.self) private var modelSetup
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var step: Step = .welcome
    @State private var selectedModelFilename: String = ModelContainer.defaultModelFilename

    var body: some View {
        VStack(spacing: 0) {
            if let index = step.progressIndex {
                StepProgress(current: index, total: Step.totalProgressSteps)
                    .padding(.horizontal, 28)
                    .padding(.top, 22)
                    .padding(.bottom, 4)
            }

            ScrollView {
                stepContent
                    .padding(.horizontal, 28)
                    .padding(.top, step.progressIndex == nil ? 28 : 14)
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            footer
                .padding(.horizontal, 28)
                .padding(.top, 8)
                .padding(.bottom, 22)
        }
        .frame(width: 480, height: 600)
        .task {
            permissions.refresh()
            modelSetup.refresh()
        }
        // The guided overlay is a floating panel tied to the permissions step. Tear it down when the
        // user navigates away or closes onboarding so it can't linger over System Settings.
        .onChange(of: step) { _, newStep in
            if newStep != .permissions { permissionGuidance.dismiss() }
        }
        .onDisappear { permissionGuidance.dismiss() }
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome: welcomeStep
        case .permissions: permissionsStep
        case .model: modelStep
        case .privacy: privacyStep
        case .keybinds: keybindsStep
        case .predictions: predictionsStep
        case .done: doneStep
        }
    }

    // MARK: - Footer / navigation

    @ViewBuilder
    private var footer: some View {
        switch step {
        case .welcome:
            HStack {
                Spacer()
                Button("Get Started") { step = .permissions }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        case .done:
            HStack {
                Spacer()
                Button("Start Using KeyType") { finish() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        case .permissions:
            navigation(
                back: .welcome,
                next: .model,
                canContinue: permissions.requiredPermissionsGranted,
                disabledHint: "Grant Accessibility and Input Monitoring to continue."
            )
        case .model:
            navigation(
                back: .permissions,
                next: .privacy,
                canContinue: selectedModelIsReady,
                disabledHint: "Set up a model, or choose “Set up later”.",
                trailingAccessory: selectedModelIsReady ? nil : AnyView(
                    Button("Set up later") { step = .privacy }
                        .buttonStyle(.link)
                )
            )
        case .privacy:
            navigation(back: .model, next: .keybinds, canContinue: true)
        case .keybinds:
            navigation(back: .privacy, next: .predictions, canContinue: true)
        case .predictions:
            navigation(back: .keybinds, next: .done, canContinue: true)
        }
    }

    private func navigation(
        back: Step,
        next: Step,
        canContinue: Bool,
        disabledHint: String = "",
        trailingAccessory: AnyView? = nil
    ) -> some View {
        HStack {
            Button("Back") { step = back }
                .controlSize(.large)
            Spacer()
            if let trailingAccessory { trailingAccessory }
            Button("Continue") { step = next }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canContinue)
                .help(canContinue ? "" : disabledHint)
        }
    }

    private func finish() {
        markCompleted()
        dismissWindow(id: AppDelegate.onboardingWindowID)
    }

    private var selectedModelIsReady: Bool {
        guard let model = modelSetup.catalog.first(where: { $0.filename == selectedModelFilename }) else {
            return false
        }
        return modelSetup.isFullyInstalled(model)
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 18) {
            Image(systemName: "text.cursor")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.tint)
                .padding(.top, 8)
            Text("Welcome to KeyType")
                .font(.title.weight(.semibold))
            Text("On-device tab-autocomplete for any text field on your Mac. Private by default, powered by a local model.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    @ViewBuilder
    private var permissionsStep: some View {
        StepHeader(
            title: "Enable KeyType",
            subtitle: "KeyType needs a couple of permissions to read the focused field and accept completions."
        )
        VStack(spacing: 10) {
            PermissionCard(
                kind: .accessibility,
                requirement: .required,
                explanation: "Reads the focused text field and caret position across any app.",
                isGranted: permissions.accessibility.isGranted,
                guidance: permissionGuidance
            )
            PermissionCard(
                kind: .inputMonitoring,
                requirement: .required,
                explanation: "Detects configured global accept keys so KeyType can insert a completion.",
                isGranted: permissions.inputMonitoring.isGranted,
                guidance: permissionGuidance
            )
            PermissionCard(
                kind: .screenRecording,
                requirement: .optional,
                explanation: "Optional. Lets KeyType read on-screen text (OCR) from the focused window as extra context, when you enable it in Privacy. KeyType works without it.",
                isGranted: permissions.screenRecording.isGranted,
                guidance: permissionGuidance
            )
        }
    }

    @ViewBuilder
    private var modelStep: some View {
        StepHeader(
            title: "Choose a model",
            subtitle: "Everything runs locally on your Mac. Pick one to download, or use one you've already added."
        )
        VStack(spacing: 10) {
            ForEach(modelSetup.catalog) { model in
                ModelCard(
                    model: model,
                    state: modelSetup.state(for: model),
                    isSelected: selectedModelFilename == model.filename,
                    onSelect: {
                        selectedModelFilename = model.filename
                        modelSetup.beginSetup(for: model)
                    },
                    onCancel: { modelSetup.cancel(model) },
                    onPause: { modelSetup.pause(model) },
                    onResume: { modelSetup.resume(model) }
                )
            }
        }
    }

    @ViewBuilder
    private var privacyStep: some View {
        @Bindable var settings = settings
        StepHeader(
            title: "Privacy",
            subtitle: "Writing history and clipboard context start on. Turn off anything you're not comfortable with — everything stays on this device."
        )
        VStack(spacing: 10) {
            ToggleCard(
                title: "Personalize from my writing history",
                detail: "Stores recent typing locally (encrypted) to improve suggestions.",
                isOn: $settings.historyEnabled
            )
            ToggleCard(
                title: "Use clipboard as context",
                detail: "Includes clipboard text in the prompt.",
                isOn: $settings.clipboardEnabled
            )
        }
    }

    @ViewBuilder
    private var keybindsStep: some View {
        @Bindable var settings = settings
        StepHeader(
            title: "Acceptance keys",
            subtitle: "Press Change and then the keys you want. Use Clear to leave an action unassigned."
        )
        VStack(spacing: 10) {
            CardContainer {
                KeyRecorderView(
                    title: "Accept word",
                    subtitle: "Inserts the next word of the suggestion.",
                    shortcut: settings.acceptWordShortcut,
                    onChange: { settings.acceptWordShortcut = $0 },
                    onClear: { settings.acceptWordShortcut = .unassigned },
                    onReset: settings.acceptWordShortcut != .defaultAcceptWord
                        ? { settings.acceptWordShortcut = .defaultAcceptWord } : nil
                )
            }
            CardContainer {
                KeyRecorderView(
                    title: "Accept entire suggestion",
                    subtitle: "Inserts the whole suggestion at once.",
                    shortcut: settings.acceptFullShortcut,
                    onChange: { settings.acceptFullShortcut = $0 },
                    onClear: { settings.acceptFullShortcut = .unassigned },
                    onReset: settings.acceptFullShortcut != .defaultAcceptFull
                        ? { settings.acceptFullShortcut = .defaultAcceptFull } : nil
                )
            }
        }
    }

    @ViewBuilder
    private var predictionsStep: some View {
        StepHeader(
            title: "Turn off macOS predictions",
            subtitle: "macOS has its own inline prediction that draws ghost text too. Turn it off so it doesn't collide with KeyType."
        )
        VStack(alignment: .leading, spacing: 14) {
            CardContainer {
                VStack(alignment: .leading, spacing: 10) {
                    Label {
                        Text("Open Keyboard settings, then:")
                            .font(.callout.weight(.medium))
                    } icon: {
                        Image(systemName: "keyboard")
                    }
                    instructionRow(number: 1, text: "Click Edit… next to Text Input → Input Sources.")
                    instructionRow(number: 2, text: "Turn off “Show inline predictive text”.")
                    instructionRow(number: 3, text: "Click Done.")

                    if let enabled = PermissionsManager.inlinePredictionDefaultEnabled() {
                        Label(
                            enabled ? "Looks like it's still on." : "Looks like it's already off.",
                            systemImage: enabled ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(enabled ? Color.orange : Color.green)
                        .padding(.top, 2)
                    }

                    Button("Open Keyboard Settings") { permissions.openKeyboardSettings() }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                }
            }
            Text("This step is optional, but strongly recommended for the best experience.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func instructionRow(number: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var doneStep: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Color.green.opacity(0.12))
                Image(systemName: "checkmark")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.green)
            }
            .frame(width: 64, height: 64)
            .padding(.top, 12)

            Text("You're all set")
                .font(.title.weight(.semibold))
            Text("Start typing anywhere. \(acceptanceShortcutSummary)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Label("Find KeyType in your menu bar.", systemImage: "menubar.arrow.up.rectangle")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
    }

    private var acceptanceShortcutSummary: String {
        let word = settings.acceptWordShortcut
        let full = settings.acceptFullShortcut

        switch (word.isAssigned, full.isAssigned) {
        case (true, true):
            return "Press \(word.displayString) to accept a word, \(full.displayString) for the whole suggestion."
        case (true, false):
            return "Press \(word.displayString) to accept a word. Accept entire suggestion is unassigned."
        case (false, true):
            return "Press \(full.displayString) to accept the whole suggestion. Accept word is unassigned."
        case (false, false):
            return "Acceptance shortcuts are unassigned. Set them in Settings when needed."
        }
    }

    // MARK: - Step model

    enum Step: Int, CaseIterable {
        case welcome, permissions, model, privacy, keybinds, predictions, done

        static let totalProgressSteps = 5

        /// 1-based index inside the progress indicator, or `nil` for the intro/outro steps.
        var progressIndex: Int? {
            switch self {
            case .welcome, .done: return nil
            case .permissions: return 1
            case .model: return 2
            case .privacy: return 3
            case .keybinds: return 4
            case .predictions: return 5
            }
        }
    }
}

// MARK: - Reusable pieces

private struct StepHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }
}

private struct StepProgress: View {
    let current: Int
    let total: Int

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(1...total, id: \.self) { index in
                    Capsule()
                        .fill(index <= current ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: index == current ? 22 : 16, height: 5)
                        .animation(.easeInOut(duration: 0.2), value: current)
                }
            }
            Text("Step \(current) of \(total)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CardContainer<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
            )
    }
}

private struct ToggleCard: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        CardContainer {
            Toggle(isOn: $isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct PermissionCard: View {
    enum Requirement {
        case required, optional
        var label: String { self == .required ? "Required" : "Optional" }
        var tint: Color { self == .required ? .accentColor : .secondary }
    }

    let kind: PermissionKind
    let requirement: Requirement
    let explanation: String
    let isGranted: Bool
    let guidance: PermissionGuidanceController

    /// Screen-space rect of the Allow button, captured so the guided overlay can animate out of it.
    @State private var allowButtonFrame = CGRect.zero

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(isGranted ? Color.green : (requirement == .required ? Color.orange : Color.secondary))
                    Text(kind.title).font(.headline)
                    Text(requirement.label)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(requirement.tint.opacity(0.15)))
                        .foregroundStyle(requirement.tint)
                    Spacer()
                    Text(isGranted ? "Granted" : "Not granted")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(isGranted ? Color.green : Color.secondary)
                }
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !isGranted {
                    Button("Allow") {
                        guidance.requestAccess(for: kind, sourceFrameInScreen: allowButtonFrame)
                    }
                    .buttonStyle(.borderedProminent)
                    .background(ScreenFrameReader(frameInScreen: $allowButtonFrame))
                }
            }
        }
    }
}

private struct ModelCard: View {
    let model: DownloadableRuntimeModel
    let state: ModelSetupCoordinator.SetupState
    let isSelected: Bool
    let onSelect: () -> Void
    let onCancel: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "cpu")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayName).font(.headline)
                        Text(model.detail).font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Text(model.approximateSizeLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    if isSelected, case .ready = state {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                statusView
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.15),
                                  lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statusView: some View {
        switch state {
        case .idle:
            EmptyView()
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 4) {
                if let progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView()
                }
                HStack(spacing: 12) {
                    Text(progress != nil ? "Downloading \(Int((progress! * 100).rounded()))%" : "Downloading…")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("Pause", action: onPause).font(.footnote)
                    Button("Cancel", action: onCancel).font(.footnote)
                }
            }
        case .paused(let progress):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress ?? 0)
                HStack(spacing: 12) {
                    Text(progress != nil ? "Paused at \(Int((progress! * 100).rounded()))%" : "Paused")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("Resume", action: onResume).font(.footnote)
                    Button("Cancel", action: onCancel).font(.footnote)
                }
            }
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
