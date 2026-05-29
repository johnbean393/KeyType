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
    func show(candidate: CompletionCandidate, placement: OverlayPlacement)
    func hide()
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

    public func show(candidate: CompletionCandidate, placement: OverlayPlacement) {
        visibleCandidate = candidate
    }

    public func hide() {
        visibleCandidate = nil
    }
}

public struct GhostTextView: View {
    public var text: String

    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
    }
}
