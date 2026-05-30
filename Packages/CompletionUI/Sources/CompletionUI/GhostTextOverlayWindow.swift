//
//  GhostTextOverlayWindow.swift
//  CompletionUI
//
//  The real inline ghost-text overlay (M6). Reuses the proven Red Dot `NSPanel` recipe (the same
//  borderless, non-activating, all-spaces, click-through panel as `CaretDebugOverlayWindow`, see
//  ADR-004 / ADR-006), but hosts dimmed completion text sized to the measured string and pinned to
//  the caret so it reads as a continuation of what the user typed. See ADR-016.
//

import AppKit
import AutocompleteCore
import CoreGraphics
import SwiftUI

@MainActor
public final class GhostTextOverlayWindow {
    private lazy var window: NSPanel = makeWindow()
    private let hosting = NSHostingView(rootView: GhostTextView(text: ""))

    public nonisolated init() {}

    /// Show `text` in `font`, positioned inline at the caret described by `placement`.
    ///
    /// Coordinates are AppKit (bottom-left origin, points). LTR ghost text starts at the caret's
    /// right edge and extends rightward; RTL text ends at the caret's left edge and extends
    /// leftward. The vertical extent matches the caret rect (so the text sits on the same line),
    /// shifted by `placement.verticalOffset`.
    public func show(text: String, font: NSFont, placement: OverlayPlacement, textColor: NSColor? = nil) {
        guard !text.isEmpty else { hide(); return }

        hosting.rootView = GhostTextView(text: text, font: font, isRightToLeft: placement.isRightToLeft, textColor: textColor)

        let caret = placement.cursorRect
        let lineHeight = max(caret.height, ceil(font.ascender - font.descender))
        let singleLineWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
        let maxWidth = Self.availableTextWidth(for: placement, singleLineWidth: singleLineWidth)
        let measuredWidth = min(singleLineWidth, maxWidth)
        let height = Self.measuredTextHeight(text, font: font, width: measuredWidth, minimumHeight: lineHeight)

        let x: CGFloat
        let y: CGFloat
        switch placement.mode {
        case .mirror:
            x = placement.isRightToLeft ? caret.maxX - measuredWidth : caret.minX
            y = caret.maxY + 2 - CGFloat(placement.verticalOffset)
        default:
            x = placement.isRightToLeft
                ? caret.minX - measuredWidth
                : caret.maxX
            y = caret.minY + (caret.height - height) / 2 - CGFloat(placement.verticalOffset)
        }

        window.setFrame(
            CGRect(x: x, y: y, width: measuredWidth, height: height),
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
            contentRect: CGRect(origin: .zero, size: CGSize(width: 1, height: 1)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.backgroundColor = .clear
        panel.contentView = hosting
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

    static func availableTextWidth(for placement: OverlayPlacement, singleLineWidth: CGFloat) -> CGFloat {
        guard let field = placement.fieldRect, !field.isEmpty else {
            return max(1, singleLineWidth)
        }

        let caret = placement.cursorRect
        let remaining: CGFloat
        switch placement.mode {
        case .mirror:
            remaining = field.width
        default:
            remaining = placement.isRightToLeft
                ? caret.minX - field.minX
                : field.maxX - caret.maxX
        }

        return max(1, min(singleLineWidth, floor(remaining)))
    }

    private static func measuredTextHeight(
        _ text: String,
        font: NSFont,
        width: CGFloat,
        minimumHeight: CGFloat
    ) -> CGFloat {
        guard width > 0 else { return minimumHeight }
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return max(minimumHeight, ceil(rect.height))
    }
}

/// Real `CompletionOverlayPresenting` backed by `GhostTextOverlayWindow`. The app resolves a
/// placement (via `OverlayPlacementResolver`) and the field font, then calls `show`; this presenter
/// owns the borderless panel and keeps it pinned to the caret.
@MainActor
public final class InlineGhostTextPresenter: CompletionOverlayPresenting {
    private let window: GhostTextOverlayWindow
    public private(set) var visibleCandidate: CompletionCandidate?

    public nonisolated init(window: GhostTextOverlayWindow = GhostTextOverlayWindow()) {
        self.window = window
    }

    public func show(candidate: CompletionCandidate, placement: OverlayPlacement, font: NSFont?, textColor: NSColor?) {
        let resolved = Self.resolveFont(font, placement: placement)
        window.show(text: candidate.text, font: resolved, placement: placement, textColor: textColor)
        visibleCandidate = candidate
    }

    public func hide() {
        window.hide()
        visibleCandidate = nil
    }

    public var isVisible: Bool { window.isVisible }

    /// Resolve the ghost-text font. We keep the field's **typeface** (family) from AX, but size it
    /// from the **caret height** rather than AX's reported point size: several apps report the
    /// correct family but a default/stale size, which made the ghost text too small. The caret rect
    /// height ≈ the glyph box (ascent+descent) at the rendered size, so we scale the typeface by the
    /// font's own metric ratio — when AX's size is already correct this reproduces it, and when it's
    /// wrong the caret height corrects it. Falls back to a system font when no field font is known.
    static func resolveFont(_ font: NSFont?, placement: OverlayPlacement) -> NSFont {
        let factor = CGFloat(placement.fontSizeAdjustmentFactor)
        let caretHeight = placement.cursorRect.height

        if let font {
            let metricsHeight = font.ascender - font.descender // ascent+descent at font.pointSize
            let derived = (caretHeight > 0 && metricsHeight > 0)
                ? caretHeight * font.pointSize / metricsHeight
                : font.pointSize
            let size = max(1, derived * factor)
            return NSFont(descriptor: font.fontDescriptor, size: size) ?? font
        }

        // No field font: estimate the point size from the caret height (≈1.2× the point size for
        // typical UI fonts), since we have no metrics to scale by.
        let estimated = caretHeight > 0 ? caretHeight * 0.83 : NSFont.systemFontSize
        return .systemFont(ofSize: max(8, min(96, estimated * factor)))
    }
}
