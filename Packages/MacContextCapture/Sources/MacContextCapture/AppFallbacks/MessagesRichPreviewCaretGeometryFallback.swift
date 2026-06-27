import AppKit
import ApplicationServices
import AutocompleteCore
import CoreGraphics
import Foundation

enum MessagesRichPreviewCaretGeometryFallback: AppCaretGeometryFallback {
    private static let bundleIdentifier = "com.apple.MobileSMS"

    static func caretGeometry(
        target: AppTarget,
        beforeCursor: String,
        afterCursor: String,
        element: AXUIElement?,
        fieldRect: CGRect?,
        current: CapturedCaretGeometry
    ) -> CapturedCaretGeometry? {
        guard target.bundleIdentifier == bundleIdentifier,
              afterCursor.isEmpty,
              let fieldRect,
              !fieldRect.isEmpty,
              let currentRect = current.rect,
              !currentRect.isEmpty else {
            return nil
        }

        let lineHeight = max(12, min(48, currentRect.height))
        guard fieldRect.width > 120,
              fieldRect.height >= max(96, lineHeight * 4),
              currentRect.width <= 8,
              currentRect.height <= max(36, lineHeight * 1.5),
              currentRect.minY > fieldRect.midY,
              currentLineIsSingleVisualLineAfterAttachment(
                  beforeCursor,
                  availableWidth: fieldRect.width
              ) else {
            return nil
        }

        let mediaStackHeight = element.flatMap {
            capturedAttachmentStackHeight(
                from: $0,
                fieldRect: fieldRect,
                lineHeight: lineHeight
            )
        }
        let corrected = correctedCaretRect(
            currentRect,
            fieldRect: fieldRect,
            lineHeight: lineHeight,
            mediaStackHeight: mediaStackHeight
        )

        guard let corrected else {
            return nil
        }

        return CapturedCaretGeometry(
            rect: corrected.rect,
            source: "\(corrected.source)(\(current.source ?? "unknown"))",
            quality: .estimated
        )
    }

    static func correctedCaretRect(
        _ currentRect: CGRect,
        fieldRect: CGRect,
        lineHeight: CGFloat,
        mediaStackHeight: CGFloat?
    ) -> (rect: CGRect, source: String)? {
        if let mediaStackHeight,
           mediaStackHeight >= max(48, lineHeight * 2),
           mediaStackHeight <= fieldRect.height - max(34, lineHeight * 1.5) {
            let correctedY = currentRect.minY - mediaStackHeight
            if correctedY >= fieldRect.minY,
               correctedY <= fieldRect.maxY - currentRect.height,
               currentRect.minY > correctedY + max(24, lineHeight * 1.25) {
                return (
                    CGRect(
                        x: currentRect.minX,
                        y: correctedY,
                        width: currentRect.width,
                        height: currentRect.height
                    ),
                    "MessagesAttachmentStackOffset"
                )
            }
        }

        let correctedY = bottomComposeLineY(in: fieldRect)
        guard currentRect.minY > correctedY + max(24, lineHeight * 1.5) else {
            return nil
        }
        return (
            CGRect(
                x: currentRect.minX,
                y: correctedY,
                width: currentRect.width,
                height: currentRect.height
            ),
            "MessagesAttachmentBottomLineEstimate"
        )
    }

    static func capturedAttachmentStackHeight(
        from element: AXUIElement,
        fieldRect: CGRect,
        lineHeight: CGFloat
    ) -> CGFloat? {
        let roots = attachmentSearchRoots(from: element)
        var candidates: [CGRect] = []
        var seen = Set<String>()

        for root in roots {
            var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
            var visited = 0

            while !queue.isEmpty, visited < 240 {
                let (candidate, depth) = queue.removeFirst()
                let identity = AXCaretHelper.elementIdentity(for: candidate)
                guard seen.insert(identity).inserted else { continue }
                visited += 1

                if depth > 0,
                   let frame = AXCaretHelper.rectValue(for: "AXFrame" as CFString, on: candidate),
                   isAttachmentFrameCandidate(
                       candidate,
                       frame: frame,
                       fieldRect: fieldRect,
                       lineHeight: lineHeight
                   ) {
                    candidates.append(frame)
                }

                guard depth < 6 else { continue }
                queue.append(contentsOf: AXCaretHelper.childElements(of: candidate).map { ($0, depth + 1) })
            }
        }

        let topLevel = topLevelFrames(from: candidates)
        guard !topLevel.isEmpty else {
            return nil
        }

        return mergedVerticalHeight(of: topLevel)
    }

    private static func attachmentSearchRoots(from element: AXUIElement) -> [AXUIElement] {
        var roots: [AXUIElement] = []
        var seen = Set<String>()

        func append(_ candidate: AXUIElement?) {
            guard let candidate else { return }
            let identity = AXCaretHelper.elementIdentity(for: candidate)
            guard seen.insert(identity).inserted else { return }
            roots.append(candidate)
        }

        append(element)
        append(AXCaretHelper.parentElement(of: element))
        append(AXCaretHelper.parentElement(of: AXCaretHelper.parentElement(of: element) ?? element))
        return roots
    }

    private static func isAttachmentFrameCandidate(
        _ element: AXUIElement,
        frame: CGRect,
        fieldRect: CGRect,
        lineHeight: CGFloat
    ) -> Bool {
        guard !frame.isEmpty,
              frame.width >= max(72, lineHeight * 4),
              frame.height >= max(48, lineHeight * 2),
              frame.height <= fieldRect.height - max(34, lineHeight * 1.5),
              frame.width <= fieldRect.width + 80 else {
            return false
        }

        let role = AXCaretHelper.stringValue(for: kAXRoleAttribute as CFString, on: element) ?? ""
        let subrole = AXCaretHelper.stringValue(for: kAXSubroleAttribute as CFString, on: element) ?? ""
        let textRoles: Set<String> = [
            kAXStaticTextRole as String,
            kAXTextAreaRole as String,
            kAXTextFieldRole as String,
            "AXEditableText"
        ]
        if textRoles.contains(role) || textRoles.contains(subrole) {
            return false
        }
        if role == kAXButtonRole as String || subrole == kAXButtonRole as String {
            return false
        }

        return true
    }

    private static func topLevelFrames(from frames: [CGRect]) -> [CGRect] {
        frames.filter { candidate in
            !frames.contains { other in
                other != candidate
                    && other.contains(CGPoint(x: candidate.minX, y: candidate.minY))
                    && other.contains(CGPoint(x: candidate.maxX, y: candidate.maxY))
                    && other.height >= candidate.height
            }
        }
    }

    private static func mergedVerticalHeight(of frames: [CGRect]) -> CGFloat {
        let intervals = frames
            .map { (min($0.minY, $0.maxY), max($0.minY, $0.maxY)) }
            .sorted { $0.0 < $1.0 }
        guard var current = intervals.first else { return 0 }

        var total: CGFloat = 0
        for interval in intervals.dropFirst() {
            if interval.0 <= current.1 + 6 {
                current.1 = max(current.1, interval.1)
            } else {
                total += current.1 - current.0
                current = interval
            }
        }
        total += current.1 - current.0
        return total
    }

    private static func currentLineIsSingleVisualLineAfterAttachment(
        _ beforeCursor: String,
        availableWidth: CGFloat
    ) -> Bool {
        guard !beforeCursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let logicalLines = beforeCursor.components(separatedBy: .newlines)
        let currentLine = logicalLines.last ?? ""
        guard !currentLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              leadingLinesStartWithAttachmentMarker(logicalLines.dropLast()) else {
            return false
        }

        let selection = NSRange(location: (currentLine as NSString).length, length: 0)
        let layout = AXCaretGeometryResolver.estimatedSoftWrappedCaretLayout(
            in: currentLine,
            selection: selection,
            availableWidth: availableWidth,
            widthBias: 1,
            unwrappedLineWidthBias: 1
        )
        return layout.lineIndex == 0
    }

    private static func leadingLinesStartWithAttachmentMarker(
        _ lines: ArraySlice<String>
    ) -> Bool {
        guard let firstLine = lines.first else {
            return false
        }
        return firstLine.unicodeScalars.contains { $0.value == 0xFFFC }
            && firstLine.unicodeScalars.allSatisfy { scalar in
                scalar.properties.isWhitespace || scalar.value == 0xFFFC
            }
    }

    private static func bottomComposeLineY(in fieldRect: CGRect) -> CGFloat {
        fieldRect.minY
    }
}
