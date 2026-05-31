//
//  PermissionGuidanceController.swift
//  KeyType
//
//  Created by Codex on 5/31/26.
//

import AppKit
import Foundation

/// Coordinates KeyType's guided permission flow.
///
/// `PermissionsManager` answers whether a permission is granted. This controller answers *how* we
/// guide the user through granting it: it opens System Settings, floats the drag helper anchored to
/// the right privacy pane, and tears everything down once access lands. Keeping those roles
/// separate avoids turning the permission state store into an AppKit window manager.
@MainActor
final class PermissionGuidanceController {
    private let permissions: PermissionsManager
    private let hostApp: PermissionHostApp

    private var overlayController: PermissionOverlayWindowController?
    private var trackingTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var activePermission: PermissionKind?
    private var pendingSourceFrameInScreen: CGRect?
    private var didPresentCurrentOverlay = false

    init(
        permissions: PermissionsManager,
        hostApp: PermissionHostApp? = nil
    ) {
        self.permissions = permissions
        self.hostApp = hostApp ?? PermissionHostApp.current()
    }

    deinit {
        trackingTimer?.invalidate()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    /// Public entry point used by onboarding and the menu-bar permission buttons. The controller
    /// chooses the experience from the permission's metadata so the view layer just asks for help.
    func requestAccess(for permission: PermissionKind, sourceFrameInScreen: CGRect? = nil) {
        permissions.refresh()
        guard !permissions.isGranted(permission) else {
            return
        }

        permissions.requestSystemAccess(for: permission)
        guard !permissions.isGranted(permission) else {
            return
        }

        switch permission.guidanceStyle {
        case .guidedOverlay:
            presentGuidance(for: permission, sourceFrameInScreen: sourceFrameInScreen)
        case .settingsOnly:
            dismiss()
            permissions.openSettings(for: permission)
        }
    }

    func dismiss() {
        trackingTimer?.invalidate()
        trackingTimer = nil

        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }

        overlayController?.close()
        overlayController = nil
        activePermission = nil
        pendingSourceFrameInScreen = nil
        didPresentCurrentOverlay = false
    }

    private func presentGuidance(for permission: PermissionKind, sourceFrameInScreen: CGRect?) {
        dismiss()
        permissions.refresh()
        guard !permissions.isGranted(permission) else {
            return
        }

        activePermission = permission
        pendingSourceFrameInScreen = sourceFrameInScreen
        overlayController = PermissionOverlayWindowController(
            hostApp: hostApp,
            permission: permission,
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        )

        permissions.openSettings(for: permission)
        startTracking()
    }

    private func startTracking() {
        trackingTimer?.invalidate()
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self else {
                return
            }
            MainActor.assumeIsolated {
                self.refreshPosition()
            }
        }

        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else {
                return
            }
            MainActor.assumeIsolated {
                self.refreshPosition()
            }
        }

        refreshPosition()
    }

    private func refreshPosition() {
        guard let activePermission else {
            dismiss()
            return
        }

        permissions.refresh()
        guard !permissions.isGranted(activePermission) else {
            dismiss()
            return
        }

        guard let snapshot = SystemSettingsWindowLocator.frontmostWindow() else {
            overlayController?.hide()
            return
        }

        if didPresentCurrentOverlay {
            overlayController?.updatePosition(
                with: snapshot.frame,
                visibleFrame: snapshot.visibleFrame
            )
            return
        }

        overlayController?.present(
            from: pendingSourceFrameInScreen,
            settingsFrame: snapshot.frame,
            visibleFrame: snapshot.visibleFrame
        )
        didPresentCurrentOverlay = true
    }
}
