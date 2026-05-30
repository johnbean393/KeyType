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

public struct OverlayPlacement: Equatable {
    public var cursorRect: CGRect
    public var fieldRect: CGRect?
    public var mode: OverlayMode
    public var isRightToLeft: Bool
    public var verticalOffset: Double
    public var fontSizeAdjustmentFactor: Double

    public init(
        cursorRect: CGRect,
        fieldRect: CGRect? = nil,
        mode: OverlayMode = .inline,
        isRightToLeft: Bool = false,
        verticalOffset: Double = 0,
        fontSizeAdjustmentFactor: Double = 1
    ) {
        self.cursorRect = cursorRect
        self.fieldRect = fieldRect
        self.mode = mode
        self.isRightToLeft = isRightToLeft
        self.verticalOffset = verticalOffset
        self.fontSizeAdjustmentFactor = fontSizeAdjustmentFactor
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

        let policy = compatibilityStore.policy(for: context)
        if policy.overlayPreference == .hidden {
            return nil
        }

        let resolvedMode: OverlayMode
        switch policy.overlayPreference {
        case .inline:
            resolvedMode = context.geometry.cursorRectQuality == .estimated ? .mirror : mode
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
            verticalOffset: policy.verticalAlignmentOffset,
            fontSizeAdjustmentFactor: policy.fontSizeAdjustmentFactor
        )
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

    /// Ghost text follows the field's own text color, dimmed to read as a suggestion.
    private static let ghostOpacity: Double = 0.6

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

    private var foregroundStyle: AnyShapeStyle {
        if let textColor {
            return AnyShapeStyle(Color(nsColor: textColor).opacity(Self.ghostOpacity))
        }
        return AnyShapeStyle(.secondary)
    }

    public var body: some View {
        VStack(alignment: isRightToLeft ? .trailing : .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.text)
                    .font(Font(font as CTFont))
                    .foregroundStyle(foregroundStyle)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.leading, isRightToLeft ? 0 : line.leadingInset)
                    .padding(.trailing, isRightToLeft ? line.leadingInset : 0)
                    .frame(height: line.reservedHeight, alignment: .top)
            }
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isRightToLeft ? .trailing : .leading)
            .environment(\.layoutDirection, isRightToLeft ? .rightToLeft : .leftToRight)
    }
}
