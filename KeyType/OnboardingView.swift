//
//  OnboardingView.swift
//  KeyType
//
//  Created by Codex on 5/29/26.
//

import SwiftUI

struct OnboardingView: View {
    @Environment(PermissionsManager.self) private var permissions

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            PermissionRow(
                title: "Accessibility",
                requirement: .required,
                explanation: "Lets KeyType read the focused text field across any app so it can predict a short continuation at the cursor.",
                isGranted: permissions.accessibility.isGranted,
                primaryActionTitle: permissions.accessibility.isGranted
                    ? "Open Accessibility Settings"
                    : "Open Accessibility Settings",
                primaryAction: {
                    if !permissions.accessibility.isGranted {
                        _ = permissions.requestAccessibility()
                    }
                    permissions.openAccessibilitySettings()
                }
            )

            PermissionRow(
                title: "Screen Recording",
                requirement: .optional,
                explanation: "Optional. Enables richer context (window contents / OCR) in future milestones. KeyType works without it.",
                isGranted: permissions.screenRecording.isGranted,
                primaryActionTitle: "Open Screen Recording Settings",
                primaryAction: {
                    if !permissions.screenRecording.isGranted {
                        _ = permissions.requestScreenRecording()
                    }
                    permissions.openScreenRecordingSettings()
                }
            )

            Spacer(minLength: 0)

            footer
        }
        .padding(24)
        .frame(width: 460)
        .task {
            permissions.refresh()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to KeyType")
                .font(.title2.weight(.semibold))
            Text("KeyType lives in your menu bar and offers short, on-device tab-autocompletions at the cursor. It needs one permission to do its job.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Button("Refresh status") {
                permissions.refresh()
            }
            Spacer()
            Text("KeyType stays in the menu bar. There's no dock icon.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct PermissionRow: View {
    enum Requirement {
        case required, optional

        var label: String {
            switch self {
            case .required: return "Required"
            case .optional: return "Optional"
            }
        }

        var tint: Color {
            switch self {
            case .required: return .accentColor
            case .optional: return .secondary
            }
        }
    }

    let title: String
    let requirement: Requirement
    let explanation: String
    let isGranted: Bool
    let primaryActionTitle: String
    let primaryAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(isGranted ? Color.green : (requirement == .required ? Color.orange : Color.secondary))
                Text(title)
                    .font(.headline)
                Text(requirement.label)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(requirement.tint.opacity(0.15))
                    )
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

            HStack {
                Button(primaryActionTitle, action: primaryAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                if isGranted {
                    Text("You can revoke this anytime in System Settings.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
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

#Preview {
    OnboardingView()
        .environment(PermissionsManager())
}
