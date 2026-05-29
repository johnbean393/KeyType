//
//  CaretDebugOverlayWindow.swift
//  CompletionUI
//
//  Ported from the sibling Red Dot project's `RedDotOverlayWindow` (see ADR-004 / ADR-006).
//  Kept as a *debug* overlay for now: a borderless, non-activating, all-spaces, click-through
//  panel pinned at the caret. M6 will swap the debug marker for real ghost-text.
//

import AppKit
import CoreGraphics
import SwiftUI

@MainActor
public final class CaretDebugOverlayWindow {
    private let markerSize = CGSize(width: 14, height: 22)
    private lazy var window: NSPanel = makeWindow()

    public nonisolated init() {}

    /// Position the overlay at `caretRect` (AppKit coordinates: bottom-left origin, points).
    /// The marker is centred horizontally on the caret and aligned to its vertical extent so
    /// the debug overlay actually sits *on* the caret rather than above/below it.
    public func show(at caretRect: CGRect) {
        let height = max(markerSize.height, caretRect.height)
        let x = caretRect.midX - markerSize.width / 2
        let y = caretRect.minY + (caretRect.height - height) / 2
        window.setFrame(
            CGRect(origin: CGPoint(x: x, y: y), size: CGSize(width: markerSize.width, height: height)),
            display: true
        )

        if !window.isVisible {
            window.orderFrontRegardless()
        }
    }

    public func hide() {
        window.orderOut(nil)
    }

    public var isVisible: Bool { window.isVisible }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: markerSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.backgroundColor = .clear
        panel.contentView = NSHostingView(rootView: CaretMarkerView())
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.isReleasedWhenClosed = false

        return panel
    }
}

private struct CaretMarkerView: View {
    var body: some View {
        // Thin vertical bar with a slight glow so it's visible against light or dark text.
        // The marker is intentionally narrow so it doesn't obscure the underlying caret.
        Rectangle()
            .fill(Color.accentColor.opacity(0.7))
            .frame(width: 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .overlay(
                Rectangle()
                    .stroke(Color.white.opacity(0.6), lineWidth: 0.5)
                    .frame(width: 2)
            )
    }
}
