import AppCompatibility
import AppKit
import AutocompleteCore
import CoreGraphics
import Foundation
import SwiftUI

public enum OverlayMode: Equatable {
    case inline
    case mirror
    case suggestionTable
    case correction
    case smartInsertWarning
}

/// How the completion is drawn near the caret. `inlineGhost` is the default dimmed continuation that
/// sits on the typing line. `capsule` is a self-contained rounded pill rendered *below* the caret —
/// used for mid-line (fill-in-the-middle) completions so the suggestion doesn't overlap the existing
/// suffix text on the same line. See ADR-016 / the mid-line capsule decision.
public enum OverlayPresentation: Equatable {
    case inlineGhost
    case capsule
}

public struct OverlayPlacement: Equatable {
    public var cursorRect: CGRect
    public var fieldRect: CGRect?
    public var mode: OverlayMode
    public var presentation: OverlayPresentation
    public var isRightToLeft: Bool
    public var cursorRectQuality: CaretGeometryQuality
    public var horizontalOffset: Double
    public var verticalOffset: VerticalAlignmentOffsetResolver
    public var fontSizeAdjustmentFactor: Double

    public init(
        cursorRect: CGRect,
        fieldRect: CGRect? = nil,
        mode: OverlayMode = .inline,
        presentation: OverlayPresentation = .inlineGhost,
        isRightToLeft: Bool = false,
        cursorRectQuality: CaretGeometryQuality = .unknown,
        horizontalOffset: Double = 0,
        verticalOffset: @escaping VerticalAlignmentOffsetResolver = { _ in 0 },
        fontSizeAdjustmentFactor: Double = 1
    ) {
        self.cursorRect = cursorRect
        self.fieldRect = fieldRect
        self.mode = mode
        self.presentation = presentation
        self.isRightToLeft = isRightToLeft
        self.cursorRectQuality = cursorRectQuality
        self.horizontalOffset = horizontalOffset
        self.verticalOffset = verticalOffset
        self.fontSizeAdjustmentFactor = fontSizeAdjustmentFactor
    }

    public static func == (lhs: OverlayPlacement, rhs: OverlayPlacement) -> Bool {
        lhs.cursorRect == rhs.cursorRect
            && lhs.fieldRect == rhs.fieldRect
            && lhs.mode == rhs.mode
            && lhs.presentation == rhs.presentation
            && lhs.isRightToLeft == rhs.isRightToLeft
            && lhs.cursorRectQuality == rhs.cursorRectQuality
            && lhs.horizontalOffset == rhs.horizontalOffset
            && lhs.verticalOffset(0) == rhs.verticalOffset(0)
            && lhs.verticalOffset(12) == rhs.verticalOffset(12)
            && lhs.verticalOffset(24) == rhs.verticalOffset(24)
            && lhs.fontSizeAdjustmentFactor == rhs.fontSizeAdjustmentFactor
    }
}

/// Field text attributes used by overlay renderers. `font` may be nil before presenter resolution;
/// `InlineGhostTextPresenter` derives a rendered font from the caret height when AX does not expose
/// one or exposes a stale point size.
public struct OverlayTextStyle {
    public var font: NSFont?
    public var textColor: NSColor?
    public var paragraphStyle: NSParagraphStyle?
    public var baselineOffset: CGFloat
    public var lineHeight: CGFloat?

    public init(
        font: NSFont? = nil,
        textColor: NSColor? = nil,
        paragraphStyle: NSParagraphStyle? = nil,
        baselineOffset: CGFloat = 0,
        lineHeight: CGFloat? = nil
    ) {
        self.font = font
        self.textColor = textColor
        self.paragraphStyle = paragraphStyle
        self.baselineOffset = baselineOffset
        self.lineHeight = lineHeight
    }
}

/// Source text surrounding the live caret for a TextKit mirror overlay. The mirror renderer lays out
/// this hidden surrounding text together with the visible completion so wrapping is determined by the
/// same text system primitives used by native text views.
public struct TextMirrorOverlayContext: Equatable {
    public var beforeCursor: String
    public var afterCursor: String

    public init(beforeCursor: String, afterCursor: String) {
        self.beforeCursor = beforeCursor
        self.afterCursor = afterCursor
    }
}

public protocol CompletionOverlayPresenting {
    /// Show `candidate` at `placement`. `font` is the resolved font of the target text field (so
    /// ghost text matches the field); pass `nil` to let the presenter fall back to a system font
    /// sized from the caret height. `textColor` is the field's foreground color, rendered dimmed so
    /// the ghost text reads as a continuation of the user's own text; pass `nil` to fall back to the
    /// system secondary color.
    func show(candidate: CompletionCandidate, placement: OverlayPlacement, font: NSFont?, textColor: NSColor?)
    func hide()
}

public extension CompletionOverlayPresenting {
    /// Convenience for callers that have no resolved field font/color.
    func show(candidate: CompletionCandidate, placement: OverlayPlacement) {
        show(candidate: candidate, placement: placement, font: nil, textColor: nil)
    }

    /// Convenience for callers that resolved a font but no explicit color.
    func show(candidate: CompletionCandidate, placement: OverlayPlacement, font: NSFont?) {
        show(candidate: candidate, placement: placement, font: font, textColor: nil)
    }
}

public struct OverlayPlacementResolver {
    private let compatibilityStore: AppCompatibilityStore

    public init(compatibilityStore: AppCompatibilityStore = AppCompatibilityStore()) {
        self.compatibilityStore = compatibilityStore
    }

    public func placement(for context: TextFieldContext, mode: OverlayMode = .inline) -> OverlayPlacement? {
        guard let cursorRect = context.geometry.cursorRect else {
            return nil
        }
        if Self.shouldSuppressUnreliableWebParagraphPlacement(context: context, cursorRect: cursorRect) {
            return nil
        }

        let policy = compatibilityStore.policy(for: context)
        if policy.overlayPreference == .hidden {
            return nil
        }

        let resolvedMode: OverlayMode
        switch policy.overlayPreference {
        case .inline:
            resolvedMode = mode
        case .textMirror:
            resolvedMode = .mirror
        case .hidden:
            return nil
        }

        return OverlayPlacement(
            cursorRect: cursorRect,
            fieldRect: context.geometry.fieldRect,
            mode: resolvedMode,
            isRightToLeft: context.geometry.isRightToLeft,
            cursorRectQuality: context.geometry.cursorRectQuality,
            horizontalOffset: policy.horizontalAlignmentOffset,
            verticalOffset: policy.verticalAlignmentOffset,
            fontSizeAdjustmentFactor: policy.fontSizeAdjustmentFactor
        )
    }

    private static func shouldSuppressUnreliableWebParagraphPlacement(
        context: TextFieldContext,
        cursorRect: CGRect
    ) -> Bool {
        guard context.traits.isWebField,
              let fieldRect = context.geometry.fieldRect,
              !fieldRect.isEmpty,
              fieldRect.height >= 80 else {
            return false
        }

        if context.beforeCursor.contains("\n") {
            return true
        }

        let lineHeight = max(12, min(24, max(18, cursorRect.height)))
        let distanceFromFieldTop = fieldRect.maxY - cursorRect.midY
        return distanceFromFieldTop > max(32, lineHeight * 1.75)
    }
}

public final class NoopCompletionOverlayPresenter: CompletionOverlayPresenting {
    public private(set) var visibleCandidate: CompletionCandidate?

    public init() {}

    public func show(candidate: CompletionCandidate, placement: OverlayPlacement, font: NSFont?, textColor: NSColor?) {
        visibleCandidate = candidate
    }

    public func hide() {
        visibleCandidate = nil
    }
}

/// Inline ghost-text view: the completion rendered as dimmed text in the field's font, left-aligned
/// and clipped, so it reads as a natural continuation of what the user typed. When the field's
/// foreground color is known it's used at `ghostOpacity` (so colored/inverted fields look right);
/// otherwise it falls back to the system secondary color.
public struct GhostTextLine: Equatable {
    public var text: String
    public var leadingInset: CGFloat
    public var reservedHeight: CGFloat?

    public init(text: String, leadingInset: CGFloat = 0, reservedHeight: CGFloat? = nil) {
        self.text = text
        self.leadingInset = leadingInset
        self.reservedHeight = reservedHeight
    }
}

public struct GhostTextView: View {
    public var lines: [GhostTextLine]
    public var font: NSFont
    public var isRightToLeft: Bool
    public var textColor: NSColor?

    /// Ghost text follows the field's own text color when it is trustworthy, but browser AX
    /// occasionally reports a foreground color that is effectively the page background. Keep the
    /// final color semi-muted while forcing near-white/near-black extremes back toward visible gray.
    private static let ghostOpacity: CGFloat = 0.62

    public init(
        text: String,
        font: NSFont = .systemFont(ofSize: NSFont.systemFontSize),
        isRightToLeft: Bool = false,
        textColor: NSColor? = nil
    ) {
        self.lines = [GhostTextLine(text: text)]
        self.font = font
        self.isRightToLeft = isRightToLeft
        self.textColor = textColor
    }

    public init(
        lines: [GhostTextLine],
        font: NSFont = .systemFont(ofSize: NSFont.systemFontSize),
        isRightToLeft: Bool = false,
        textColor: NSColor? = nil
    ) {
        self.lines = lines.isEmpty ? [GhostTextLine(text: "")] : lines
        self.font = font
        self.isRightToLeft = isRightToLeft
        self.textColor = textColor
    }

    private var foregroundColor: Color {
        Color(nsColor: Self.visibleGhostColor(from: textColor))
    }

    private var shadowColor: Color {
        Color(nsColor: Self.contrastShadowColor(for: textColor))
    }

    public var body: some View {
        VStack(alignment: isRightToLeft ? .trailing : .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.text)
                    .font(Font(font as CTFont))
                    .foregroundStyle(foregroundColor)
                    .shadow(color: shadowColor, radius: 0.6, x: 0, y: 0)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.leading, isRightToLeft ? 0 : line.leadingInset)
                    .padding(.trailing, isRightToLeft ? line.leadingInset : 0)
                    .frame(height: line.reservedHeight, alignment: .top)
            }
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isRightToLeft ? .trailing : .leading)
            .clipped()
            .environment(\.layoutDirection, isRightToLeft ? .rightToLeft : .leftToRight)
    }

    static func visibleGhostColor(from color: NSColor?) -> NSColor {
        guard let color = color?.usingColorSpace(.sRGB) else {
            return NSColor(calibratedWhite: 0.42, alpha: 0.85)
        }

        let luminance = relativeLuminance(color)
        if luminance > 0.9 {
            return NSColor(calibratedWhite: 0.36, alpha: 0.85)
        }
        if luminance < 0.08 {
            return NSColor(calibratedWhite: 0.36, alpha: 0.85)
        }

        return color.withAlphaComponent(Self.ghostOpacity)
    }

    private static func contrastShadowColor(for color: NSColor?) -> NSColor {
        guard let color = color?.usingColorSpace(.sRGB) else {
            return NSColor.white.withAlphaComponent(0.45)
        }
        return relativeLuminance(color) > 0.5
            ? NSColor.black.withAlphaComponent(0.4)
            : NSColor.white.withAlphaComponent(0.35)
    }

    private static func relativeLuminance(_ color: NSColor) -> CGFloat {
        0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
    }
}

/// Capsule completion view: the completion rendered as opaque, fully-readable text inside a rounded
/// pill. Unlike `GhostTextView` this is a self-contained surface (its own background + border) drawn
/// *below* the caret, so it never overlaps the existing suffix text on the typing line. It therefore
/// uses system label/surface colors rather than the (dimmed) field foreground color, since it isn't
/// meant to blend into the field's own text.
public struct CapsuleCompletionView: View {
    public var text: String
    public var font: NSFont
    public var horizontalPadding: CGFloat
    public var verticalPadding: CGFloat

    public init(
        text: String,
        font: NSFont = .systemFont(ofSize: NSFont.systemFontSize),
        horizontalPadding: CGFloat = CapsuleCompletionView.defaultHorizontalPadding,
        verticalPadding: CGFloat = CapsuleCompletionView.defaultVerticalPadding
    ) {
        self.text = text
        self.font = font
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
    }

    public static let defaultHorizontalPadding: CGFloat = 10
    public static let defaultVerticalPadding: CGFloat = 4

    public var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
            Text(text)
                .font(Font(font as CTFont))
                .foregroundStyle(Color(nsColor: .labelColor))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, horizontalPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
