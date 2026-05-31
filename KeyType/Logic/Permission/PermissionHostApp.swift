//
//  PermissionHostApp.swift
//  KeyType
//
//  Created by Codex on 5/31/26.
//

import AppKit
import Foundation

/// Captures the app identity macOS expects during the drag-and-drop permission flow.
///
/// The draggable payload is the app bundle URL, but the overlay also wants the icon and display
/// name so the helper looks like a real "drag this app into the list" instruction rather than a
/// generic placeholder.
struct PermissionHostApp {
    let displayName: String
    let bundleURL: URL
    let icon: NSImage

    static func current(bundle: Bundle = .main) -> PermissionHostApp {
        let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String
            ?? bundle.bundleURL.deletingPathExtension().lastPathComponent
        let icon = NSWorkspace.shared.icon(forFile: bundle.bundleURL.path)
        icon.size = NSSize(width: 48, height: 48)
        return PermissionHostApp(
            displayName: displayName,
            bundleURL: bundle.bundleURL,
            icon: icon
        )
    }
}
