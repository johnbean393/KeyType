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
    var debugOverlayEnabled: Bool = true {
        didSet { applyOverlayVisibility() }
    }

    private var listenerToken: UUID?

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
            log.debug("No focused field")
            return
        }

        lastSummary = Self.summary(for: snapshot)
        log.debug("\(self.lastSummary, privacy: .public)")

        if debugOverlayEnabled, let rect = snapshot.caretRect, !rect.isEmpty {
            overlay.show(at: rect)
        } else {
            overlay.hide()
        }
    }

    private func applyOverlayVisibility() {
        if !debugOverlayEnabled {
            overlay.hide()
            return
        }
        if let rect = tracker.currentSnapshot?.caretRect, !rect.isEmpty {
            overlay.show(at: rect)
        }
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
}
