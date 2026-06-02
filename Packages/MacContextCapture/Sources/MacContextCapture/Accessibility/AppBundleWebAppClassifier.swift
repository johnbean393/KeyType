//
//  AppBundleWebAppClassifier.swift
//  MacContextCapture
//
//  Caches bundle-level web-app detection so AX reads can use a cheap bundle-id lookup. The
//  expensive filesystem scan runs once per app bundle at launch / app-launch boundaries.
//

import AppKit
import Foundation

public final class AppBundleWebAppClassifier: @unchecked Sendable {
    public static let shared = AppBundleWebAppClassifier()

    private let lock = NSLock()
    private var scannedBundleIdentifiers = Set<String>()
    private var webBackedBundleIdentifiers = Set<String>()
    private var didPrimeRunningApplications = false

    public init() {}

    public func primeRunningApplications(
        _ applications: [NSRunningApplication] = NSWorkspace.shared.runningApplications
    ) {
        lock.lock()
        let shouldPrime = !didPrimeRunningApplications
        didPrimeRunningApplications = true
        lock.unlock()

        guard shouldPrime else { return }
        applications.forEach(scanIfNeeded)
    }

    public func noteLaunchedApplication(_ application: NSRunningApplication?) {
        guard let application else { return }
        scanIfNeeded(application)
    }

    public func isWebBacked(bundleIdentifier: String) -> Bool {
        if Self.bundleIdentifierIsKnownWebBacked(bundleIdentifier) {
            return true
        }

        lock.lock()
        defer { lock.unlock() }
        return webBackedBundleIdentifiers.contains(bundleIdentifier)
    }

    private func scanIfNeeded(_ application: NSRunningApplication) {
        guard let bundleIdentifier = application.bundleIdentifier else {
            return
        }

        lock.lock()
        let shouldScan = scannedBundleIdentifiers.insert(bundleIdentifier).inserted
        lock.unlock()

        guard shouldScan else { return }

        if Self.bundleIdentifierIsKnownWebBacked(bundleIdentifier) {
            lock.lock()
            webBackedBundleIdentifiers.insert(bundleIdentifier)
            lock.unlock()
            return
        }

        guard let bundleURL = application.bundleURL else {
            return
        }

        let isWebBacked = Self.bundleContainsElectronMarkers(at: bundleURL)
        guard isWebBacked else { return }

        lock.lock()
        webBackedBundleIdentifiers.insert(bundleIdentifier)
        lock.unlock()
    }

    static func bundleIdentifierIsKnownWebBacked(_ bundleIdentifier: String) -> Bool {
        knownWebBackedBrowserBundleIdentifiers.contains(bundleIdentifier)
    }

    private static let knownWebBackedBrowserBundleIdentifiers: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Canary",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera"
    ]

    static func bundleContainsElectronMarkers(
        at bundleURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let knownMarkerPaths = [
            "Contents/Frameworks/Electron Framework.framework",
            "Contents/Frameworks/Electron Helper.app",
            "Contents/Frameworks/Electron Framework.framework/Resources/electron.asar",
            "Contents/Resources/app.asar",
            "Contents/Resources/default_app.asar",
            "Contents/Resources/electron.asar"
        ]

        for relativePath in knownMarkerPaths {
            if fileManager.fileExists(atPath: bundleURL.appendingPathComponent(relativePath).path) {
                return true
            }
        }

        if containsElectronNamedEntry(
            in: bundleURL.appendingPathComponent("Contents/Frameworks"),
            fileManager: fileManager
        ) {
            return true
        }

        if containsAsarResource(
            in: bundleURL.appendingPathComponent("Contents/Resources"),
            fileManager: fileManager
        ) {
            return true
        }

        return false
    }

    private static func containsElectronNamedEntry(in directory: URL, fileManager: FileManager) -> Bool {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
        ) else {
            return false
        }

        return entries.contains { entry in
            let name = entry.lastPathComponent.lowercased()
            return name.contains("electron")
                && (name.hasSuffix(".framework") || name.hasSuffix(".app") || name.hasSuffix(".dylib"))
        }
    }

    private static func containsAsarResource(in directory: URL, fileManager: FileManager) -> Bool {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
        ) else {
            return false
        }

        return entries.contains { $0.pathExtension.caseInsensitiveCompare("asar") == .orderedSame }
    }
}
