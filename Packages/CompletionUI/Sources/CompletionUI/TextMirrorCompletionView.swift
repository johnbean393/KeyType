//
//  TextMirrorCompletionView.swift
//  CompletionUI
//
//  TextKit-backed mirror renderer for `.textMirror` overlay placements. The surrounding field text is
//  laid out invisibly so the visible completion uses TextKit line fragments instead of KeyType's
//  simpler word-width wrapping path.
//

import AppKit
import CoreGraphics
import SwiftUI

public struct TextMirrorCompletionView: NSViewRepresentable {
    public var mirrorContext: TextMirrorOverlayContext
    public var completion: String
    public var style: OverlayTextStyle
    public var placement: OverlayPlacement

    public init(
        mirrorContext: TextMirrorOverlayContext,
        completion: String,
        style: OverlayTextStyle,
        placement: OverlayPlacement
    ) {
        self.mirrorContext = mirrorContext
        self.completion = completion
        self.style = style
        self.placement = placement
    }

    public func makeNSView(context: Context) -> TextMirrorCompletionNSView {
        let view = TextMirrorCompletionNSView(frame: .zero)
        view.configure(
            mirrorContext: mirrorContext,
            completion: completion,
            style: style,
            placement: placement
        )
        return view
    }

    public func updateNSView(_ nsView: TextMirrorCompletionNSView, context: Context) {
        nsView.configure(
            mirrorContext: mirrorContext,
            completion: completion,
            style: style,
            placement: placement
        )
    }
}

struct TextMirrorSnippet: Equatable {
    var before: String
    var after: String

    static func currentParagraph(
        beforeCursor: String,
        afterCursor: String,
        maxBeforeCharacters: Int = 2_000,
        maxAfterCharacters: Int = 2_000
    ) -> TextMirrorSnippet {
        let paragraphBefore = beforeCursor
            .split(separator: "\n", omittingEmptySubsequences: false)
            .last
            .map(String.init) ?? beforeCursor
        let paragraphAfter = afterCursor
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? afterCursor

        return TextMirrorSnippet(
            before: String(paragraphBefore.suffix(maxBeforeCharacters)),
            after: String(paragraphAfter.prefix(maxAfterCharacters))
        )
    }
}

enum TextMirrorGeometry {
    static func localCaretRect(cursorRect: CGRect, fieldRect: CGRect) -> CGRect {
        CGRect(
            x: cursorRect.minX - fieldRect.minX,
            y: fieldRect.maxY - cursorRect.maxY,
            width: cursorRect.width,
            height: cursorRect.height
        )
    }

    static func drawOrigin(targetCaret: CGRect, mirrorCaret: CGRect) -> CGPoint {
        CGPoint(
            x: targetCaret.minX - mirrorCaret.minX,
            y: targetCaret.minY - mirrorCaret.minY
        )
    }
}

public final class TextMirrorCompletionNSView: NSView {
    private let layoutManager = NSLayoutManager()
    private let textContainer = NSTextContainer(size: .zero)
    private let textStorage = NSTextStorage()
    private var completionRange = NSRange(location: 0, length: 0)
    private var cursorLocation = 0
    private var targetCaretRect = CGRect.zero
    private var isRightToLeft = false
    private var resolvedFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { false }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTextSystem()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTextSystem()
    }

    func configure(
        mirrorContext: TextMirrorOverlayContext,
        completion: String,
        style: OverlayTextStyle,
        placement: OverlayPlacement
    ) {
        guard !completion.isEmpty else {
            textStorage.setAttributedString(NSAttributedString())
            completionRange = NSRange(location: 0, length: 0)
            needsDisplay = true
            return
        }

        let snippet = TextMirrorSnippet.currentParagraph(
            beforeCursor: mirrorContext.beforeCursor,
            afterCursor: mirrorContext.afterCursor
        )
        let font = style.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let paragraphStyle = Self.paragraphStyle(
            from: style,
            font: font,
            isRightToLeft: placement.isRightToLeft
        )
        let attributed = Self.attributedMirrorText(
            before: snippet.before,
            completion: completion,
            after: snippet.after,
            style: style,
            font: font,
            paragraphStyle: paragraphStyle
        )

        resolvedFont = font
        isRightToLeft = placement.isRightToLeft
        cursorLocation = (snippet.before as NSString).length
        completionRange = NSRange(location: cursorLocation, length: (completion as NSString).length)
        if let fieldRect = placement.fieldRect, !fieldRect.isEmpty {
            targetCaretRect = TextMirrorGeometry.localCaretRect(
                cursorRect: placement.cursorRect,
                fieldRect: fieldRect
            )
        } else {
            targetCaretRect = CGRect(x: 0, y: 0, width: placement.cursorRect.width, height: placement.cursorRect.height)
        }
        textStorage.setAttributedString(attributed)
        updateContainerSize()
        needsDisplay = true
    }

    public override func layout() {
        super.layout()
        updateContainerSize()
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard completionRange.length > 0, textStorage.length > 0 else { return }
        updateContainerSize()
        layoutManager.ensureLayout(for: textContainer)

        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: completionRange,
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0 else { return }

        let origin = alignedDrawOrigin()
        layoutManager.drawBackground(forGlyphRange: glyphRange, at: origin)
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: origin)
    }

    func alignedDrawOrigin() -> CGPoint {
        TextMirrorGeometry.drawOrigin(
            targetCaret: targetCaretRect,
            mirrorCaret: caretRect(utf16Location: cursorLocation)
        )
    }

    func caretRect(utf16Location: Int) -> CGRect {
        guard textStorage.length > 0 else {
            return CGRect(
                x: 0,
                y: 0,
                width: 1,
                height: resolvedFont.ascender - resolvedFont.descender + resolvedFont.leading
            )
        }

        updateContainerSize()
        layoutManager.ensureLayout(for: textContainer)

        let location = max(0, min(utf16Location, textStorage.length))
        let characterIndex = location == 0
            ? 0
            : min(location - 1, textStorage.length - 1)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let characterGlyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: characterIndex, length: 1),
            actualCharacterRange: nil
        )
        let glyphRect = characterGlyphRange.length > 0
            ? layoutManager.boundingRect(forGlyphRange: characterGlyphRange, in: textContainer)
            : lineRect

        let x: CGFloat
        if location == 0 {
            x = isRightToLeft ? glyphRect.maxX : glyphRect.minX
        } else {
            x = isRightToLeft ? glyphRect.minX : glyphRect.maxX
        }
        let mirroredCaretHeight = mirroredCaretHeight(lineRect: lineRect)
        return CGRect(
            x: x,
            y: lineRect.minY + mirroredCaretVerticalInset(lineRect: lineRect),
            width: 1,
            height: mirroredCaretHeight
        )
    }

    private func mirroredCaretVerticalInset(lineRect: CGRect) -> CGFloat {
        let targetHeight = targetCaretRect.height
        guard targetHeight > 0 else { return 0 }
        return max(0, (lineRect.height - targetHeight) / 2)
    }

    private func mirroredCaretHeight(lineRect: CGRect) -> CGFloat {
        let targetHeight = targetCaretRect.height
        let fallback = resolvedFont.ascender - resolvedFont.descender + resolvedFont.leading
        guard targetHeight > 0 else {
            return max(1, fallback)
        }
        return max(1, min(lineRect.height, targetHeight))
    }

    private func setupTextSystem() {
        wantsLayer = true
        layer?.masksToBounds = true
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
    }

    private func updateContainerSize() {
        textContainer.containerSize = CGSize(
            width: max(1, bounds.width),
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    private static func attributedMirrorText(
        before: String,
        completion: String,
        after: String,
        style: OverlayTextStyle,
        font: NSFont,
        paragraphStyle: NSParagraphStyle
    ) -> NSAttributedString {
        let hiddenAttributes = textAttributes(
            font: font,
            color: .clear,
            paragraphStyle: paragraphStyle,
            baselineOffset: style.baselineOffset
        )
        let ghostAttributes = textAttributes(
            font: font,
            color: GhostTextView.visibleGhostColor(from: style.textColor),
            paragraphStyle: paragraphStyle,
            baselineOffset: style.baselineOffset
        )

        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: before, attributes: hiddenAttributes))
        result.append(NSAttributedString(string: completion, attributes: ghostAttributes))
        result.append(NSAttributedString(string: after, attributes: hiddenAttributes))
        return result
    }

    private static func textAttributes(
        font: NSFont,
        color: NSColor,
        paragraphStyle: NSParagraphStyle,
        baselineOffset: CGFloat
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle,
            .baselineOffset: baselineOffset
        ]
    }

    private static func paragraphStyle(
        from style: OverlayTextStyle,
        font: NSFont,
        isRightToLeft: Bool
    ) -> NSParagraphStyle {
        let paragraph = (style.paragraphStyle?.mutableCopy() as? NSMutableParagraphStyle)
            ?? NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        if paragraph.baseWritingDirection == .natural {
            paragraph.baseWritingDirection = isRightToLeft ? .rightToLeft : .leftToRight
        }
        if let lineHeight = style.lineHeight, lineHeight > 0 {
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
        } else if paragraph.minimumLineHeight == 0, paragraph.maximumLineHeight == 0 {
            paragraph.minimumLineHeight = font.ascender - font.descender + font.leading
            paragraph.maximumLineHeight = paragraph.minimumLineHeight
        }
        return paragraph
    }
}
