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
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))

    /// The parameters of the last `show`, kept so the overlay can be advanced past an accepted word
    /// without waiting for an AX snapshot (`advanceAfterAccepting`). Cleared on `hide`.
    private var lastShow: (text: String, style: OverlayTextStyle, placement: OverlayPlacement, mirrorContext: TextMirrorOverlayContext?)?

    /// Capsule geometry: padding inside the pill and the gap between the caret and the pill's top.
    static let capsuleHorizontalPadding = CapsuleCompletionView.defaultHorizontalPadding
    static let capsuleVerticalPadding = CapsuleCompletionView.defaultVerticalPadding
    static let capsuleGapBelowCaret: CGFloat = 5
    static let correctionBadgeGapBelowCaret: CGFloat = 5
    static let correctionBadgeHorizontalPadding: CGFloat = 8
    static let correctionBadgeVerticalPadding: CGFloat = 4
    static let correctionBadgeInterItemSpacing: CGFloat = 6
    static let anchoredCorrectionGap: CGFloat = 6
    static let anchoredCorrectionPadding: CGFloat = 3

    public nonisolated init() {}

    /// Show `text` in `font`, positioned inline at the caret described by `placement`.
    ///
    /// Coordinates are AppKit (bottom-left origin, points). LTR ghost text starts at the caret's
    /// right edge and extends rightward; RTL text ends at the caret's left edge and extends
    /// leftward. The vertical extent matches the caret rect (so the text sits on the same line),
    /// shifted by `placement.verticalOffset`.
    public func show(text: String, font: NSFont, placement: OverlayPlacement, textColor: NSColor? = nil) {
        show(
            text: text,
            style: OverlayTextStyle(font: font, textColor: textColor),
            placement: placement
        )
    }

    public func show(
        text: String,
        style: OverlayTextStyle,
        placement: OverlayPlacement,
        mirrorContext: TextMirrorOverlayContext? = nil
    ) {
        guard !text.isEmpty else { hide(); return }
        let font = style.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let canUseTextMirror = Self.canUseTextMirror(placement: placement, mirrorContext: mirrorContext)
        guard canUseTextMirror || !Self.shouldSuppressMirrorOverflow(text: text, font: font, placement: placement) else {
            hide()
            return
        }
        guard canUseTextMirror || !Self.shouldSuppressInlineSingleLineOverflow(text: text, font: font, placement: placement) else {
            hide()
            return
        }

        let layout = canUseTextMirror
            ? Self.textMirrorLayout(for: style, placement: placement)
            : Self.layout(for: text, font: font, placement: placement)
        switch (placement.presentation, canUseTextMirror) {
        case (.capsule, _):
            // The capsule is a self-contained popover surface, so give it a drop shadow to lift it
            // off whatever text it sits below; ghost text deliberately has none (it should read as
            // part of the field).
            window.hasShadow = true
            hosting.rootView = AnyView(
                CapsuleCompletionView(
                    text: text,
                    font: font,
                    horizontalPadding: Self.capsuleHorizontalPadding,
                    verticalPadding: Self.capsuleVerticalPadding
                )
            )
        case (.inlineGhost, true):
            window.hasShadow = false
            hosting.rootView = AnyView(
                TextMirrorCompletionView(
                    mirrorContext: mirrorContext!,
                    completion: text,
                    style: style,
                    placement: placement
                )
            )
        case (.inlineGhost, false):
            window.hasShadow = false
            hosting.rootView = AnyView(
                GhostTextView(
                    lines: layout.lines,
                    font: font,
                    isRightToLeft: placement.isRightToLeft,
                    textColor: style.textColor
                )
            )
        }

        window.setFrame(
            layout.frame.offsetBy(
                dx: CGFloat(placement.horizontalOffset),
                dy: -CGFloat(placement.verticalOffset(Double(layout.lineHeight)))
            ),
            display: true
        )

        if !window.isVisible {
            window.orderFrontRegardless()
        }

        lastShow = (text, style, placement, mirrorContext)
    }

    public func showCorrection(
        original: String,
        replacement: String,
        style: OverlayTextStyle,
        placement: OverlayPlacement
    ) {
        guard !original.isEmpty, !replacement.isEmpty else { hide(); return }
        let font = style.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let layout = Self.correctionBadgeLayout(
            original: original,
            replacement: replacement,
            font: font,
            placement: placement
        )

        window.hasShadow = true
        hosting.rootView = AnyView(
            CorrectionBadgeView(original: original, replacement: replacement, font: font)
        )
        window.setFrame(
            layout.frame.offsetBy(
                dx: CGFloat(placement.horizontalOffset),
                dy: -CGFloat(placement.verticalOffset(Double(layout.lineHeight)))
            ),
            display: true
        )
        if !window.isVisible {
            window.orderFrontRegardless()
        }
        lastShow = ("\(original) -> \(replacement)", style, placement, nil)
    }

    public func showAnchoredCorrection(
        replacement: String,
        wordRect: CGRect,
        style: OverlayTextStyle,
        placement: OverlayPlacement
    ) {
        guard !replacement.isEmpty, !wordRect.isEmpty else {
            showCorrection(original: "", replacement: replacement, style: style, placement: placement)
            return
        }
        let font = style.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let layout = Self.anchoredCorrectionLayout(
            replacement: replacement,
            wordRect: wordRect,
            font: font,
            placement: placement
        )

        window.hasShadow = false
        hosting.rootView = AnyView(
            AnchoredCorrectionView(
                replacement: replacement,
                font: font,
                lineRect: layout.lineRect,
                replacementRect: layout.replacementRect
            )
        )
        window.setFrame(
            layout.frame.offsetBy(
                dx: CGFloat(placement.horizontalOffset),
                dy: -CGFloat(placement.verticalOffset(Double(layout.lineHeight)))
            ),
            display: true
        )
        if !window.isVisible {
            window.orderFrontRegardless()
        }
        lastShow = (replacement, style, placement, nil)
    }

    /// Eagerly shrink the shown inline ghost text past an accepted word: shift it by the rendered
    /// width of `head` and redraw `remainder`, *now*, instead of waiting for the target app's AX
    /// value-changed notification. That notification lags the keystroke by tens-to-hundreds of ms in
    /// many native apps (it's near-instant in web fields), so without this the remainder visibly
    /// stalls after each Tab until the next snapshot lands. Because the prior overlay already drew
    /// `remainder` at exactly `head`'s width past the caret, shifting by that width lands it where it
    /// already sat on screen; the later AX snapshot re-pins it precisely. No-op for capsule and
    /// text-mirror presentations, which need the AX path's full surrounding context. See ADR-054.
    public func advanceAfterAccepting(head: String, remainder: String) {
        guard let last = lastShow,
              last.placement.presentation == .inlineGhost,
              last.placement.mode != .mirror,
              let font = last.style.font else { return }
        guard !remainder.isEmpty else { hide(); return }
        let headWidth = Self.measuredWidth(head, font: font)
        let placement = Self.advanced(last.placement, byAcceptedWidth: headWidth)
        show(text: remainder, style: last.style, placement: placement)
    }

    /// Shift an inline-ghost placement's caret rect by `width` along the writing direction (rightward
    /// for LTR, leftward for RTL), so the post-acceptance remainder draws where it already appeared.
    static func advanced(_ placement: OverlayPlacement, byAcceptedWidth width: CGFloat) -> OverlayPlacement {
        var result = placement
        let caret = placement.cursorRect
        let newX = placement.isRightToLeft ? caret.minX - width : caret.minX + width
        result.cursorRect = CGRect(x: newX, y: caret.minY, width: caret.width, height: caret.height)
        return result
    }

    public func hide() {
        window.orderOut(nil)
        lastShow = nil
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
        panel.animationBehavior = .none

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
            remaining = placement.isRightToLeft
                ? caret.minX - field.minX
                : field.maxX - caret.maxX
        default:
            remaining = placement.isRightToLeft
                ? caret.minX - field.minX
                : field.maxX - caret.maxX
        }

        return max(1, min(singleLineWidth, floor(remaining)))
    }

    static func trustedCaretHeight(for placement: OverlayPlacement, fallbackLineHeight: CGFloat) -> CGFloat {
        let caretHeight = placement.cursorRect.height
        guard caretHeight > 0 else {
            return fallbackLineHeight
        }

        if let field = placement.fieldRect,
           !field.isEmpty,
           field.height >= 40,
           caretHeight >= field.height * 0.65 {
            return max(8, min(32, fallbackLineHeight))
        }

        if let field = placement.fieldRect,
           !field.isEmpty,
           field.height >= 40,
           isApproximateCaretQuality(placement.cursorRectQuality),
           caretHeight > fallbackLineHeight * 1.4 {
            return max(8, min(32, fallbackLineHeight))
        }

        return max(8, min(48, caretHeight))
    }

    private static func isApproximateCaretQuality(_ quality: CaretGeometryQuality) -> Bool {
        quality == .derived || quality == .estimated
    }

    private static func visualCaretHeight(for placement: OverlayPlacement, lineHeight: CGFloat) -> CGFloat {
        let caretHeight = placement.cursorRect.height
        guard caretHeight > 0 else { return lineHeight }
        guard isApproximateCaretQuality(placement.cursorRectQuality),
              caretHeight > lineHeight * 1.4 else {
            return caretHeight
        }
        return lineHeight
    }

    public static func shouldSuppressMirrorOverflow(text: String, font: NSFont, placement: OverlayPlacement) -> Bool {
        guard placement.mode == .mirror,
              isApproximateCaretQuality(placement.cursorRectQuality),
              let field = placement.fieldRect,
              !field.isEmpty else {
            return false
        }

        let requiredWidth = ceil(measuredWidth(text, font: font)) + 2
        let availableWidth = placement.isRightToLeft
            ? placement.cursorRect.minX - field.minX
            : field.maxX - placement.cursorRect.maxX
        return requiredWidth > max(0, floor(availableWidth))
    }

    public static func shouldSuppressInlineSingleLineOverflow(text: String, font: NSFont, placement: OverlayPlacement) -> Bool {
        guard placement.presentation == .inlineGhost,
              placement.mode != .mirror,
              let field = placement.fieldRect,
              !field.isEmpty else {
            return false
        }

        let fontLineHeight = ceil(font.ascender - font.descender)
        let lineHeight = max(trustedCaretHeight(for: placement, fallbackLineHeight: fontLineHeight), fontLineHeight)
        guard field.height < max(80, lineHeight * 2.5) else {
            return false
        }

        let requiredWidth = ceil(measuredWidth(text, font: font)) + 2
        let availableWidth = placement.isRightToLeft
            ? placement.cursorRect.minX - field.minX
            : field.maxX - placement.cursorRect.maxX
        return requiredWidth > max(0, floor(availableWidth))
    }

    struct Layout: Equatable {
        var frame: CGRect
        var lines: [GhostTextLine]
        var lineHeight: CGFloat
    }

    struct AnchoredCorrectionLayout: Equatable {
        var frame: CGRect
        var lineRect: CGRect
        var replacementRect: CGRect
        var lineHeight: CGFloat
    }

    static func layout(for text: String, font: NSFont, placement: OverlayPlacement) -> Layout {
        if placement.presentation == .capsule {
            return capsuleLayout(for: text, font: font, placement: placement)
        }
        let caret = placement.cursorRect
        let fontLineHeight = ceil(font.ascender - font.descender)
        let lineHeight = max(Self.trustedCaretHeight(for: placement, fallbackLineHeight: fontLineHeight), fontLineHeight)
        let visualCaretHeight = Self.visualCaretHeight(for: placement, lineHeight: lineHeight)
        let singleLineWidth = ceil(measuredWidth(text, font: font)) + 2
        guard
            !placement.isRightToLeft,
            let field = placement.fieldRect,
            !field.isEmpty,
            field.height >= max(80, lineHeight * 2.5),
            (placement.mode != .mirror || !isApproximateCaretQuality(placement.cursorRectQuality)),
            caret.maxX < field.maxX
        else {
            let width = availableTextWidth(for: placement, singleLineWidth: singleLineWidth)
            let x: CGFloat
            let y: CGFloat
            switch placement.mode {
            case .mirror:
                x = placement.isRightToLeft ? caret.maxX - width : caret.maxX
                y = caret.minY + (visualCaretHeight - lineHeight) / 2
            default:
                x = placement.isRightToLeft ? caret.minX - width : caret.maxX
                y = caret.minY + (visualCaretHeight - lineHeight) / 2
            }
            return Layout(
                frame: CGRect(x: x, y: y, width: width, height: lineHeight),
                lines: [GhostTextLine(text: text, reservedHeight: lineHeight)],
                lineHeight: lineHeight
            )
        }

        let firstLineInset = max(0, caret.maxX - field.minX)
        let firstLineWidth = max(1, field.maxX - caret.maxX)
        let fullLineWidth = max(1, field.width)
        if singleLineWidth <= firstLineWidth {
            return Layout(
                frame: CGRect(
                    x: placement.isRightToLeft ? caret.minX - singleLineWidth : caret.maxX,
                    y: caret.minY + (visualCaretHeight - lineHeight) / 2,
                    width: singleLineWidth,
                    height: lineHeight
                ),
                lines: [GhostTextLine(text: text, reservedHeight: lineHeight)],
                lineHeight: lineHeight
            )
        }
        let lines = wrappedLines(
            for: text,
            font: font,
            firstLineWidth: firstLineWidth,
            fullLineWidth: fullLineWidth,
            firstLineInset: firstLineInset,
            lineHeight: lineHeight
        )
        let height = lineHeight * CGFloat(lines.count)
        let y = caret.minY + (visualCaretHeight - lineHeight) / 2 - (height - lineHeight)

        return Layout(
            frame: CGRect(x: field.minX, y: y, width: fullLineWidth, height: height),
            lines: lines,
            lineHeight: lineHeight
        )
    }

    public static func canUseTextMirror(
        placement: OverlayPlacement,
        mirrorContext: TextMirrorOverlayContext?
    ) -> Bool {
        placement.mode == .mirror
            && placement.presentation == .inlineGhost
            && mirrorContext != nil
            && placement.fieldRect?.isEmpty == false
    }

    static func textMirrorLayout(for style: OverlayTextStyle, placement: OverlayPlacement) -> Layout {
        let font = style.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let fontLineHeight = ceil(font.ascender - font.descender + font.leading)
        let lineHeight = max(
            style.lineHeight.map { CGFloat($0) } ?? 0,
            fontLineHeight,
            trustedCaretHeight(for: placement, fallbackLineHeight: fontLineHeight)
        )
        let frame = placement.fieldRect ?? placement.cursorRect
        return Layout(frame: frame, lines: [], lineHeight: lineHeight)
    }

    /// Layout for the mid-line capsule: a rounded pill placed directly *below* the caret. It is
    /// horizontally centered on the caret, then clamped inside the field so that a caret near the
    /// trailing edge pins the pill to the trailing edge (and likewise for the leading edge). When the
    /// pill is wider than the field it is pinned to the leading edge. Coordinates are AppKit
    /// (bottom-left origin), so "below" the caret means a smaller Y.
    static func capsuleLayout(for text: String, font: NSFont, placement: OverlayPlacement) -> Layout {
        let caret = placement.cursorRect
        let fontLineHeight = ceil(font.ascender - font.descender)
        let lineHeight = max(trustedCaretHeight(for: placement, fallbackLineHeight: fontLineHeight), fontLineHeight)
        let textWidth = ceil(measuredWidth(text, font: font)) + 2
        let capsuleWidth = textWidth + capsuleHorizontalPadding * 2
        let capsuleHeight = lineHeight + capsuleVerticalPadding * 2

        var x = caret.midX - capsuleWidth / 2
        if let field = placement.fieldRect, !field.isEmpty {
            if capsuleWidth >= field.width {
                x = field.minX
            } else {
                x = min(max(x, field.minX), field.maxX - capsuleWidth)
            }
        }

        let y = caret.minY - capsuleGapBelowCaret - capsuleHeight

        return Layout(
            frame: CGRect(x: x, y: y, width: capsuleWidth, height: capsuleHeight),
            lines: [GhostTextLine(text: text, reservedHeight: capsuleHeight)],
            lineHeight: lineHeight
        )
    }

    static func correctionBadgeLayout(
        original: String,
        replacement: String,
        font: NSFont,
        placement: OverlayPlacement
    ) -> Layout {
        let caret = placement.cursorRect
        let fontLineHeight = ceil(font.ascender - font.descender)
        let lineHeight = max(trustedCaretHeight(for: placement, fallbackLineHeight: fontLineHeight), fontLineHeight)
        let arrowWidth = measuredWidth("→", font: font)
        let textWidth = ceil(measuredWidth(original, font: font) + measuredWidth(replacement, font: font) + arrowWidth)
        let badgeWidth = textWidth
            + correctionBadgeInterItemSpacing * 2
            + correctionBadgeHorizontalPadding * 2
            + 2
        let badgeHeight = lineHeight + correctionBadgeVerticalPadding * 2

        var x = placement.isRightToLeft ? caret.minX - badgeWidth : caret.maxX
        if let field = placement.fieldRect, !field.isEmpty {
            if badgeWidth >= field.width {
                x = field.minX
            } else {
                x = min(max(x, field.minX), field.maxX - badgeWidth)
            }
        }
        let y = caret.minY - correctionBadgeGapBelowCaret - badgeHeight
        return Layout(
            frame: CGRect(x: x, y: y, width: badgeWidth, height: badgeHeight),
            lines: [],
            lineHeight: lineHeight
        )
    }

    static func anchoredCorrectionLayout(
        replacement: String,
        wordRect: CGRect,
        font: NSFont,
        placement: OverlayPlacement
    ) -> AnchoredCorrectionLayout {
        let fontLineHeight = ceil(font.ascender - font.descender)
        let lineHeight = max(trustedCaretHeight(for: placement, fallbackLineHeight: fontLineHeight), fontLineHeight)
        let replacementWidth = ceil(measuredWidth(replacement, font: font)) + 3
        let replacementHeight = lineHeight
        let field = placement.fieldRect
        let gap = anchoredCorrectionGap

        var replacementRect = CGRect(
            x: placement.isRightToLeft ? wordRect.minX - gap - replacementWidth : wordRect.maxX + gap,
            y: wordRect.minY + (wordRect.height - replacementHeight) / 2,
            width: replacementWidth,
            height: replacementHeight
        )

        if let field, !field.isEmpty {
            let fitsInline = placement.isRightToLeft
                ? replacementRect.minX >= field.minX
                : replacementRect.maxX <= field.maxX
            if !fitsInline {
                let belowY = wordRect.minY - gap - replacementHeight
                let centeredX = wordRect.midX - replacementWidth / 2
                replacementRect.origin = CGPoint(
                    x: min(max(centeredX, field.minX), max(field.minX, field.maxX - replacementWidth)),
                    y: max(field.minY, belowY)
                )
            }
        }

        let lineHeightPixels: CGFloat = 1.5
        let strike = CGRect(
            x: wordRect.minX,
            y: wordRect.midY - lineHeightPixels / 2,
            width: wordRect.width,
            height: lineHeightPixels
        )
        let frame = strike.union(replacementRect).insetBy(dx: -anchoredCorrectionPadding, dy: -anchoredCorrectionPadding)
        return AnchoredCorrectionLayout(
            frame: frame,
            lineRect: strike.offsetBy(dx: -frame.minX, dy: -frame.minY),
            replacementRect: replacementRect.offsetBy(dx: -frame.minX, dy: -frame.minY),
            lineHeight: lineHeight
        )
    }

    static func wrappedLines(
        for text: String,
        font: NSFont,
        firstLineWidth: CGFloat,
        fullLineWidth: CGFloat,
        firstLineInset: CGFloat,
        lineHeight: CGFloat
    ) -> [GhostTextLine] {
        let tokens = wrappingTokens(in: text)
        guard !tokens.isEmpty else {
            return [GhostTextLine(text: "", leadingInset: firstLineInset, reservedHeight: lineHeight)]
        }

        var lines: [GhostTextLine] = []
        var current = ""
        var currentWidth: CGFloat = 0
        var capacity = max(1, firstLineWidth)

        func appendCurrent() {
            let lineText = lines.isEmpty
                ? current.trimmingTrailingWhitespace()
                : current.trimmingCharacters(in: .whitespaces)
            let inset = lines.isEmpty ? firstLineInset : 0
            lines.append(GhostTextLine(text: lineText, leadingInset: inset, reservedHeight: lineHeight))
            current = ""
            currentWidth = 0
            capacity = max(1, fullLineWidth)
        }

        for rawToken in tokens {
            var token = rawToken
            if current.isEmpty, !lines.isEmpty {
                token = token.trimmingCharacters(in: .whitespaces)
            }
            guard !token.isEmpty else { continue }

            let tokenWidth = measuredWidth(token, font: font)
            if current.isEmpty, tokenWidth > capacity, lines.isEmpty {
                lines.append(GhostTextLine(text: "", leadingInset: firstLineInset, reservedHeight: lineHeight))
                capacity = max(1, fullLineWidth)
                token = token.trimmingCharacters(in: .whitespaces)
            } else if !current.isEmpty, currentWidth + tokenWidth > capacity {
                appendCurrent()
                token = token.trimmingCharacters(in: .whitespaces)
            }

            guard !token.isEmpty else { continue }
            current += token
            currentWidth += measuredWidth(token, font: font)
        }

        if !current.isEmpty {
            appendCurrent()
        }

        return lines.isEmpty
            ? [GhostTextLine(text: "", leadingInset: firstLineInset, reservedHeight: lineHeight)]
            : lines
    }

    private static func wrappingTokens(in text: String) -> [String] {
        var tokens: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let start = index
            let isWhitespace = text[index].isWhitespace
            while index < text.endIndex, text[index].isWhitespace == isWhitespace {
                index = text.index(after: index)
            }
            tokens.append(String(text[start..<index]))
        }
        return tokens
    }

    private static func measuredWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}

private extension String {
    func trimmingTrailingWhitespace() -> String {
        var end = endIndex
        while end > startIndex {
            let previous = index(before: end)
            guard self[previous].isWhitespace else { break }
            end = previous
        }
        return String(self[..<end])
    }
}

/// Real `CompletionOverlayPresenting` backed by `GhostTextOverlayWindow`. The app resolves a
/// placement (via `OverlayPlacementResolver`) and the field font, then calls `show`; this presenter
/// owns the borderless panel and keeps it pinned to the caret.
@MainActor
public final class InlineGhostTextPresenter: CompletionOverlayPresenting {
    private let window: GhostTextOverlayWindow
    public private(set) var visibleCandidate: CompletionCandidate?
    private nonisolated static let fallbackFontSizeScale: CGFloat = 0.85

    public nonisolated init(window: GhostTextOverlayWindow = GhostTextOverlayWindow()) {
        self.window = window
    }

    public func show(candidate: CompletionCandidate, placement: OverlayPlacement, font: NSFont?, textColor: NSColor?) {
        show(
            candidate: candidate,
            placement: placement,
            style: OverlayTextStyle(font: font, textColor: textColor)
        )
    }

    public func show(
        candidate: CompletionCandidate,
        placement: OverlayPlacement,
        style: OverlayTextStyle?,
        mirrorContext: TextMirrorOverlayContext? = nil
    ) {
        let resolved = Self.resolveStyle(style, placement: placement)
        window.show(
            text: candidate.text,
            style: resolved,
            placement: placement,
            mirrorContext: mirrorContext
        )
        visibleCandidate = candidate
    }

    public func hide() {
        window.hide()
        visibleCandidate = nil
    }

    public func show(
        correction: CorrectionCandidate,
        placement: OverlayPlacement,
        style: OverlayTextStyle?,
        wordRect: CGRect? = nil
    ) {
        var correctionPlacement = placement
        correctionPlacement.mode = .correction
        let resolved = Self.resolveStyle(style, placement: correctionPlacement)
        if let wordRect, !wordRect.isEmpty {
            window.showAnchoredCorrection(
                replacement: correction.replacement,
                wordRect: wordRect,
                style: resolved,
                placement: correctionPlacement
            )
        } else {
            window.showCorrection(
                original: correction.original,
                replacement: correction.replacement,
                style: resolved,
                placement: correctionPlacement
            )
        }
        visibleCandidate = CompletionCandidate(text: correction.replacement, mode: .correction)
    }

    /// Advance the inline ghost text past an accepted `head`, redrawing `remainder` immediately
    /// rather than waiting for the next focused-field snapshot. See `GhostTextOverlayWindow`. Hides
    /// the overlay when nothing remains. No-op for capsule and text-mirror presentations.
    public func advanceAfterAccepting(head: String, remainder: CompletionCandidate?) {
        window.advanceAfterAccepting(head: head, remainder: remainder?.text ?? "")
        visibleCandidate = remainder
    }

    public var isVisible: Bool { window.isVisible }

    /// Resolve the ghost-text font. We keep the field's **typeface** (family) from AX, but size it
    /// from the **caret height** rather than AX's reported point size: several apps report the
    /// correct family but a default/stale size, which made the ghost text too small. The caret rect
    /// height ≈ the glyph box (ascent+descent) at the rendered size, so we scale the typeface by the
    /// font's own metric ratio — when AX's size is already correct this reproduces it, and when it's
    /// wrong the caret height corrects it. Falls back to a system font when no field font is known.
    public static func resolveFont(_ font: NSFont?, placement: OverlayPlacement) -> NSFont {
        let factor = CGFloat(placement.fontSizeAdjustmentFactor)
        let fallbackLineHeight = font.map { ceil($0.ascender - $0.descender) } ?? ceil(NSFont.systemFont(ofSize: NSFont.systemFontSize).ascender - NSFont.systemFont(ofSize: NSFont.systemFontSize).descender)
        let caretHeight = GhostTextOverlayWindow.trustedCaretHeight(
            for: placement,
            fallbackLineHeight: fallbackLineHeight
        )

        if let font {
            let metricsHeight = font.ascender - font.descender // ascent+descent at font.pointSize
            let derived = (caretHeight > 0 && metricsHeight > 0)
                ? caretHeight * font.pointSize / metricsHeight
                : font.pointSize
            let size = max(1, derived * factor)
            return NSFont(descriptor: font.fontDescriptor, size: size) ?? font
        }

        // No field font: estimate the point size from the caret height (≈1.2× the point size for
        // typical UI fonts), then keep it slightly conservative because web-app caret geometry
        // tends to overstate the rendered text size when AX does not expose font attributes.
        let estimated = caretHeight > 0 ? caretHeight * 0.83 : NSFont.systemFontSize
        return .systemFont(ofSize: max(8, min(96, estimated * Self.fallbackFontSizeScale * factor)))
    }

    public static func resolveStyle(_ style: OverlayTextStyle?, placement: OverlayPlacement) -> OverlayTextStyle {
        var resolved = style ?? OverlayTextStyle()
        let font = resolveFont(resolved.font, placement: placement)
        resolved.font = font
        if resolved.lineHeight == nil {
            resolved.lineHeight = font.ascender - font.descender + font.leading
        }
        return resolved
    }
}
