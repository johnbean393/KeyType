import AppKit
import ApplicationServices
import AutocompleteCore
import CoreGraphics
import Foundation

enum CodeEditorCaretGeometryFallback: AppCaretGeometryFallback {
    private static let bundleIdentifiers: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92"
    ]

    static func caretGeometry(
        target: AppTarget,
        beforeCursor: String,
        afterCursor: String,
        element: AXUIElement?,
        fieldRect: CGRect?,
        current: CapturedCaretGeometry
    ) -> CapturedCaretGeometry? {
        guard bundleIdentifiers.contains(target.bundleIdentifier),
              let fieldRect,
              let currentRect = current.rect,
              let currentLine = currentLinePrefix(in: beforeCursor),
              !currentLine.isEmpty,
              fieldRect.width > 80,
              fieldRect.height >= 16,
              fieldRect.height <= 44,
              currentRect.width <= 8,
              currentRect.height <= max(36, fieldRect.height * 1.5),
              abs(currentRect.minX - fieldRect.minX) <= 6 else {
            return nil
        }

        let estimatedX = min(
            fieldRect.maxX,
            fieldRect.minX + estimatedCodeLineWidth(currentLine)
        )
        guard estimatedX > currentRect.minX + 16 else {
            return nil
        }

        return CapturedCaretGeometry(
            rect: CGRect(
                x: estimatedX,
                y: currentRect.minY,
                width: currentRect.width,
                height: min(max(18, currentRect.height), max(18, fieldRect.height))
            ),
            source: "CodeEditorLineOriginEstimate(\(current.source ?? "unknown"))",
            quality: .estimated
        )
    }

    private static func currentLinePrefix(in text: String) -> String? {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .last
            .map(String.init)
    }

    private static func estimatedCodeLineWidth(_ text: String) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }
}
