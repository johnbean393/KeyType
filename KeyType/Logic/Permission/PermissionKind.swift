//
//  PermissionKind.swift
//  KeyType
//
//  Created by Codex on 5/31/26.
//

import Foundation

/// How KeyType guides the user toward granting a privacy permission.
enum PermissionGuidanceStyle: Sendable {
    /// Open System Settings and float KeyType's drag helper anchored to the correct list.
    case guidedOverlay

    /// Open the matching System Settings pane without the overlay.
    case settingsOnly
}

/// One macOS privacy permission KeyType can request, with the metadata the guided drag-and-drop
/// flow needs. Runtime grant state lives in `PermissionsManager`; this type owns only metadata so
/// the UI and guidance controller can reason in terms of a single value rather than three separate
/// booleans and deep links.
enum PermissionKind: String, CaseIterable, Identifiable, Sendable {
    case accessibility = "Privacy_Accessibility"
    case inputMonitoring = "Privacy_ListenEvent"
    case screenRecording = "Privacy_ScreenCapture"

    var id: Self { self }

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        case .screenRecording: "Screen Recording"
        }
    }

    var systemImageName: String {
        switch self {
        case .accessibility: "accessibility"
        case .inputMonitoring: "keyboard.fill"
        case .screenRecording: "rectangle.dashed.badge.record"
        }
    }

    /// The `x-apple.systempreferences:com.apple.preference.security?<pane>` fragment.
    var settingsPane: String { rawValue }

    var guidanceStyle: PermissionGuidanceStyle {
        switch self {
        case .accessibility, .inputMonitoring, .screenRecording:
            .guidedOverlay
        }
    }
}
