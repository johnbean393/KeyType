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
    public var mode: OverlayMode
    public var isRightToLeft: Bool
    public var verticalOffset: Double
    public var fontSizeAdjustmentFactor: Double

    public init(
        cursorRect: CGRect,
        mode: OverlayMode = .inline,
        isRightToLeft: Bool = false,
        verticalOffset: Double = 0,
        fontSizeAdjustmentFactor: Double = 1
    ) {
        self.cursorRect = cursorRect
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

        let policy = compatibilityStore.policy(for: context.target)
        return OverlayPlacement(
            cursorRect: cursorRect,
            mode: mode,
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
public struct GhostTextView: View {
    public var text: String
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
        self.text = text
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
        Text(text)
            .font(Font(font as CTFont))
            .foregroundStyle(foregroundStyle)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isRightToLeft ? .trailing : .leading)
            .environment(\.layoutDirection, isRightToLeft ? .rightToLeft : .leftToRight)
    }
}
