//
//  ContextCaptureController.swift
//  KeyType
//
//  Owns the AX-notification-driven context tracker and the debug overlay window,
//  bridges them at the app target (so MacContextCapture and CompletionUI stay decoupled),
//  and logs each emitted TextFieldContext via os.Logger.
//

import AppKit
import AutocompleteCore
import CompletionUI
import Foundation
import MacContextCapture
import Observation
import os

@MainActor
@Observable
final class ContextCaptureController {
    
    private let tracker: AccessibilityContextTracker
    private let overlay: CaretDebugOverlayWindow
    private let log = Logger(subsystem: "com.pattonium.KeyType", category: "context-capture")

    private(set) var isRunning = false
    private(set) var lastSummary: String = ""
    private(set) var latestSnapshot: FocusedFieldSnapshot?
    private(set) var latestTunableSnapshot: FocusedFieldSnapshot?
    private(set) var lastTunableSummary: String = ""
    var debugOverlayEnabled: Bool = false {
        didSet { applyOverlayVisibility() }
    }

    private var listenerToken: UUID?
    private var lastLoggedSummary: String?

    init(
        tracker: AccessibilityContextTracker = AccessibilityContextTracker(),
        overlay: CaretDebugOverlayWindow = CaretDebugOverlayWindow()
    ) {
        self.tracker = tracker
        self.overlay = overlay
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        listenerToken = tracker.addListener { [weak self] snapshot in
            self?.handle(snapshot)
        }
        tracker.start()
        log.debug("Started AccessibilityContextTracker")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let listenerToken {
            tracker.removeListener(listenerToken)
        }
        listenerToken = nil
        tracker.stop()
        overlay.hide()
        log.debug("Stopped AccessibilityContextTracker")
    }

    private func handle(_ snapshot: FocusedFieldSnapshot?) {
        guard let snapshot else {
            overlay.hide()
            lastSummary = "(no focused field)"
            latestSnapshot = nil
            log.debug("No focused field")
            return
        }

        latestSnapshot = snapshot
        lastSummary = Self.summary(for: snapshot)
        if !Self.isKeyTypeTarget(snapshot.context.target) {
            latestTunableSnapshot = snapshot
            lastTunableSummary = lastSummary
        }
        // The tracker re-emits on caret-geometry repolls even when nothing the user cares about
        // changed; only log when the summary actually changes to keep the debug log readable.
        if lastSummary != lastLoggedSummary {
            lastLoggedSummary = lastSummary
            log.debug("\(self.lastSummary, privacy: .public)")
        }

        if debugOverlayEnabled, let overlaySnapshot = Self.debugOverlaySnapshot(for: snapshot) {
            overlay.show(snapshot: overlaySnapshot)
        } else {
            overlay.hide()
        }
    }

    private func applyOverlayVisibility() {
        if !debugOverlayEnabled {
            overlay.hide()
            return
        }
        if let snapshot = tracker.currentSnapshot,
           let overlaySnapshot = Self.debugOverlaySnapshot(for: snapshot) {
            overlay.show(snapshot: overlaySnapshot)
        }
    }

    static func debugOverlaySnapshot(for snapshot: FocusedFieldSnapshot) -> CaretDebugOverlaySnapshot? {
        guard let caretRect = snapshot.caretRect, !caretRect.isEmpty else {
            return nil
        }

        let geometry = snapshot.context.geometry
        return CaretDebugOverlaySnapshot(
            caretRect: caretRect,
            fieldRect: geometry.fieldRect,
            isRightToLeft: geometry.isRightToLeft
        )
    }

    /// Compact, privacy-conscious one-line summary of a `TextFieldContext`. Lengths and
    /// short edge characters only; never the full text the user is editing.
    static func summary(for snapshot: FocusedFieldSnapshot) -> String {
        let ctx = snapshot.context
        let before = ctx.beforeCursor
        let after = ctx.afterCursor
        let beforeTail = String(before.suffix(12))
        let afterHead = String(after.prefix(12))
        let rect = snapshot.caretRect
            .map { "(\(Int($0.minX)),\(Int($0.minY))) \(Int($0.width))x\(Int($0.height))" }
            ?? "nil"
        let domain = ctx.target.domain.map { " domain=\($0)" } ?? ""
        let title = ctx.target.windowTitle.map { " title=\"\(truncate($0, to: 40))\"" } ?? ""
        let language = ctx.detectedLanguage.map { " lang=\($0)" } ?? ""
        let labels = ctx.labels.isEmpty ? "" : " labels=[\(ctx.labels.prefix(2).joined(separator: ","))]"
        let qual = snapshot.caretQuality ?? "n/a"
        let source = snapshot.caretSource ?? "n/a"
        return """
        AX[\(ctx.target.bundleIdentifier)]\(title)\(domain) \
        before=\(before.count)ch …"\(escape(beforeTail))" \
        after=\(after.count)ch "\(escape(afterHead))"… \
        eol=\(ctx.geometry.isAtEndOfLine) rtl=\(ctx.geometry.isRightToLeft)\(language)\(labels) \
        rect=\(rect) caret=\(source)/\(qual)
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func truncate(_ s: String, to max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max)) + "…"
    }

    private static func isKeyTypeTarget(_ target: AppTarget) -> Bool {
        let bundleIdentifier = target.bundleIdentifier.lowercased()
        if let ownBundleIdentifier = Bundle.main.bundleIdentifier?.lowercased(),
           bundleIdentifier == ownBundleIdentifier {
            return true
        }
        if bundleIdentifier.hasPrefix("com.pattonium.keytype") {
            return true
        }
        return target.appName.localizedCaseInsensitiveContains("KeyType")
    }
    
}
