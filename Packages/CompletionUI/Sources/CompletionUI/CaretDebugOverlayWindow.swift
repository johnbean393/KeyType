//
//  CaretDebugOverlayWindow.swift
//  CompletionUI
//
//  Ported from the sibling Red Dot project's `RedDotOverlayWindow` (see ADR-004 / ADR-006).
//  Kept as a *debug* overlay for now: a borderless, non-activating, all-spaces, click-through
//  panel that visualizes the captured caret geometry and the field rect used for placement.
//

import AppKit
import CoreGraphics

public struct CaretDebugOverlaySnapshot: Equatable {
    public var caretRect: CGRect
    public var fieldRect: CGRect?
    public var availableTextRect: CGRect?
    public var isRightToLeft: Bool

    public init(
        caretRect: CGRect,
        fieldRect: CGRect? = nil,
        isRightToLeft: Bool = false,
        availableTextRect: CGRect? = nil
    ) {
        self.caretRect = caretRect
        self.fieldRect = fieldRect
        self.isRightToLeft = isRightToLeft
        self.availableTextRect = availableTextRect ?? Self.availableTextRect(
            caretRect: caretRect,
            fieldRect: fieldRect,
            isRightToLeft: isRightToLeft
        )
    }

    public static func availableTextRect(
        caretRect: CGRect,
        fieldRect: CGRect?,
        isRightToLeft: Bool
    ) -> CGRect? {
        guard let fieldRect,
              !fieldRect.isEmpty,
              !caretRect.isEmpty else {
            return nil
        }

        let height = min(max(1, caretRect.height), fieldRect.height)
        let y = min(max(caretRect.minY, fieldRect.minY), fieldRect.maxY - height)
        if isRightToLeft {
            return CGRect(
                x: fieldRect.minX,
                y: y,
                width: max(0, caretRect.minX - fieldRect.minX),
                height: height
            )
        }

        return CGRect(
            x: caretRect.maxX,
            y: y,
            width: max(0, fieldRect.maxX - caretRect.maxX),
            height: height
        )
    }
}

@MainActor
public final class CaretDebugOverlayWindow {
    private let markerSize = CGSize(width: 14, height: 22)
    private lazy var window: NSPanel = makeWindow()
    private lazy var overlayView = CaretDebugOverlayView(frame: .zero)

    public nonisolated init() {}

    /// Position the overlay at `caretRect` (AppKit coordinates: bottom-left origin, points).
    /// The marker is centred horizontally on the caret and aligned to its vertical extent so
    /// the debug overlay actually sits *on* the caret rather than above/below it.
    public func show(at caretRect: CGRect) {
        show(snapshot: CaretDebugOverlaySnapshot(caretRect: caretRect))
    }

    public func show(snapshot: CaretDebugOverlaySnapshot) {
        let screenFrame = Self.screenFrame()
        overlayView.screenFrame = screenFrame
        overlayView.snapshot = snapshot
        overlayView.frame = CGRect(origin: .zero, size: screenFrame.size)
        overlayView.needsDisplay = true
        window.setFrame(screenFrame, display: true)

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
        panel.contentView = overlayView
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

    private static func screenFrame() -> CGRect {
        NSScreen.screens
            .map(\.frame)
            .reduce(CGRect.null) { $0.union($1) }
    }
}

private final class CaretDebugOverlayView: NSView {
    var screenFrame: CGRect = .zero
    var snapshot: CaretDebugOverlaySnapshot?
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let snapshot else { return }

        if let field = snapshot.fieldRect, !field.isEmpty {
            drawRect(field, label: "field", color: .systemGreen)
        }
        if let available = snapshot.availableTextRect, !available.isEmpty {
            drawRect(available, label: "available", color: .systemYellow)
        }
        drawRect(snapshot.caretRect, label: "caret", color: .systemRed)
        drawCaretMarker(in: snapshot.caretRect)
    }

    private func drawRect(_ globalRect: CGRect, label: String, color: NSColor) {
        let rect = localRect(globalRect)
        color.withAlphaComponent(0.16).setFill()
        color.withAlphaComponent(0.95).setStroke()

        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.fill()
        path.stroke()

        let labelRect = CGRect(x: rect.minX + 4, y: rect.maxY + 4, width: 260, height: 18)
        let labelText = "\(label) \(Int(globalRect.minX)),\(Int(globalRect.minY)) \(Int(globalRect.width))x\(Int(globalRect.height))"
        labelText.draw(
            in: labelRect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .backgroundColor: NSColor.black.withAlphaComponent(0.55)
            ]
        )
    }

    private func drawCaretMarker(in globalRect: CGRect) {
        let rect = localRect(globalRect)
        let markerHeight = max(22, rect.height)
        let markerRect = CGRect(
            x: rect.midX - 1,
            y: rect.minY + (rect.height - markerHeight) / 2,
            width: 2,
            height: markerHeight
        )

        NSColor.controlAccentColor.withAlphaComponent(0.75).setFill()
        markerRect.fill()
        NSColor.white.withAlphaComponent(0.65).setStroke()
        let path = NSBezierPath(rect: markerRect)
        path.lineWidth = 0.5
        path.stroke()
    }

    private func localRect(_ globalRect: CGRect) -> CGRect {
        globalRect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }
}
