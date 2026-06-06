import AppKit
import AutocompleteCore
import CoreGraphics
import Foundation

enum DiscordComposeTextContext: AppCaretGeometryFallback {
    static let bundleIdentifier = "com.hnc.Discord"

    private enum ComposerMetrics {
        static let font = NSFont.systemFont(ofSize: 15)
        static let lineHeight: CGFloat = 22
        static let cursorHeight: CGFloat = 22
        static let topPadding: CGFloat = 17
        static let widthBias: CGFloat = 1.1
        static let minimumMultilineHeight: CGFloat = 40
        static let minimumUsableWidth: CGFloat = 80
    }

    static func caretGeometry(
        target: AppTarget,
        beforeCursor: String,
        fieldRect: CGRect?,
        current: CapturedCaretGeometry
    ) -> CapturedCaretGeometry? {
        guard shouldEstimateCaret(target: target, current: current, fieldRect: fieldRect),
              let fieldRect else {
            return nil
        }

        return CapturedCaretGeometry(
            rect: estimatedCursorRect(beforeCursor: beforeCursor, in: fieldRect),
            source: "discordSoftWrapEstimate",
            quality: .estimated
        )
    }

    private static func shouldEstimateCaret(
        target: AppTarget,
        current: CapturedCaretGeometry,
        fieldRect: CGRect?
    ) -> Bool {
        guard target.bundleIdentifier == bundleIdentifier,
              current.quality != .exact,
              let fieldRect,
              fieldRect.height >= ComposerMetrics.minimumMultilineHeight,
              fieldRect.width > ComposerMetrics.minimumUsableWidth else {
            return false
        }
        return true
    }

    static func estimatedCursorRect(beforeCursor: String, in fieldRect: CGRect) -> CGRect {
        let layout = AXCaretGeometryResolver.estimatedSoftWrappedCaretLayout(
            in: beforeCursor,
            selection: NSRange(location: (beforeCursor as NSString).length, length: 0),
            availableWidth: max(1, fieldRect.width),
            font: ComposerMetrics.font,
            widthBias: ComposerMetrics.widthBias
        )

        let x = min(max(fieldRect.minX + layout.xOffset, fieldRect.minX), fieldRect.maxX)
        let estimatedY = fieldRect.maxY
            - ComposerMetrics.topPadding
            - (CGFloat(layout.lineIndex + 1) * ComposerMetrics.lineHeight)
        let y = min(max(estimatedY, fieldRect.minY), fieldRect.maxY - ComposerMetrics.cursorHeight)
        return CGRect(x: x, y: y, width: 2, height: ComposerMetrics.cursorHeight)
    }
}
