import AppKit
import ApplicationServices
import AutocompleteCore
import CoreGraphics
import Foundation

public struct TextRangeGeometry: Equatable, Sendable {
    public var rect: CGRect
    public var source: String
    public var quality: CaretGeometryQuality

    public init(rect: CGRect, source: String, quality: CaretGeometryQuality) {
        self.rect = rect
        self.source = source
        self.quality = quality
    }
}

@MainActor
public struct TextRangeGeometryResolver {
    private let systemElement: AXUIElement
    private let webAppClassifier: AppBundleWebAppClassifier

    public init(
        systemElement: AXUIElement = AXUIElementCreateSystemWide(),
        webAppClassifier: AppBundleWebAppClassifier = .shared
    ) {
        self.systemElement = systemElement
        self.webAppClassifier = webAppClassifier
    }

    public func resolve(
        range descriptor: TextRangeDescriptor,
        context: TextFieldContext
    ) -> TextRangeGeometry? {
        guard let focused = AXCaretHelper.focusedElement(systemElement: systemElement) else {
            return estimate(range: descriptor, context: context)
        }
        let preferDescendant = webAppClassifier.isWebBacked(bundleIdentifier: context.target.bundleIdentifier)
        guard let element = FocusedFieldReader.textElement(
            for: focused,
            preferDescendantTextElement: preferDescendant
        ) else {
            return estimate(range: descriptor, context: context)
        }
        guard let nsRange = Self.utf16Range(for: descriptor, context: context),
              nsRange.length > 0 else {
            return nil
        }

        let attributes = AXCaretHelper.parameterizedAttributeNames(on: element)
        if attributes.contains(kAXBoundsForRangeParameterizedAttribute as String),
           let rawRect = AXCaretHelper.parameterizedRectValue(
                for: kAXBoundsForRangeParameterizedAttribute as CFString,
                range: nsRange,
                on: element
           ),
           let rect = validated(rawRect, context: context) {
            return TextRangeGeometry(rect: rect, source: "AXBoundsForRange", quality: .exact)
        }

        if attributes.contains("AXBoundsForTextMarkerRange"),
           let rect = textMarkerBoundsApproximation(on: element, range: nsRange, context: context) {
            return TextRangeGeometry(rect: rect, source: "AXTextMarkerRange", quality: .derived)
        }

        return estimate(range: descriptor, context: context)
    }

    static func utf16Range(for descriptor: TextRangeDescriptor, context: TextFieldContext) -> NSRange? {
        let fullText = context.beforeCursor + context.afterCursor
        switch descriptor.container {
        case .beforeCursor:
            guard descriptor.endOffset <= context.beforeCursor.count,
                  let start = fullText.index(fullText.startIndex, offsetBy: descriptor.startOffset, limitedBy: fullText.endIndex),
                  let end = fullText.index(fullText.startIndex, offsetBy: descriptor.endOffset, limitedBy: fullText.endIndex),
                  start <= end else { return nil }
            return NSRange(start..<end, in: fullText)
        case .afterCursor:
            let base = context.beforeCursor.count
            guard descriptor.endOffset <= context.afterCursor.count,
                  let start = fullText.index(fullText.startIndex, offsetBy: base + descriptor.startOffset, limitedBy: fullText.endIndex),
                  let end = fullText.index(fullText.startIndex, offsetBy: base + descriptor.endOffset, limitedBy: fullText.endIndex),
                  start <= end else { return nil }
            return NSRange(start..<end, in: fullText)
        }
    }

    private func validated(_ accessibilityRect: CGRect, context: TextFieldContext) -> CGRect? {
        let cocoa = AXCaretHelper.cocoaRect(fromAccessibilityRect: accessibilityRect)
        guard !cocoa.isEmpty,
              cocoa.width > 0,
              cocoa.height > 0,
              cocoa.width < 4_000,
              cocoa.height < 500 else {
            return nil
        }
        if let field = context.geometry.fieldRect, !field.isEmpty {
            let intersection = cocoa.intersection(field.insetBy(dx: -12, dy: -12))
            guard !intersection.isNull, !intersection.isEmpty else { return nil }
        }
        return cocoa
    }

    private func textMarkerBoundsApproximation(
        on element: AXUIElement,
        range: NSRange,
        context: TextFieldContext
    ) -> CGRect? {
        guard let first = AXCaretHelper.parameterizedRectValue(
            for: kAXBoundsForRangeParameterizedAttribute as CFString,
            range: NSRange(location: range.location, length: min(1, range.length)),
            on: element
        ) else {
            return nil
        }
        return validated(first, context: context)
    }

    private func estimate(
        range descriptor: TextRangeDescriptor,
        context: TextFieldContext
    ) -> TextRangeGeometry? {
        guard let field = context.geometry.fieldRect,
              !field.isEmpty,
              let caret = context.geometry.cursorRect,
              !caret.isEmpty,
              let range = descriptor.range(in: descriptor.container == .beforeCursor ? context.beforeCursor : context.afterCursor)
        else {
            return nil
        }

        let container = descriptor.container == .beforeCursor ? context.beforeCursor : context.afterCursor
        let word = String(container[range])
        let lineStart = container[..<range.lowerBound].lastIndex(where: \.isNewline)
            .map { container.index(after: $0) } ?? container.startIndex
        let linePrefix = String(container[lineStart..<range.lowerBound])
        guard !linePrefix.contains("\n"), !word.contains("\n") else { return nil }

        let font = NSFont.systemFont(ofSize: max(11, min(28, caret.height * 0.83)))
        let prefixWidth = Self.measuredWidth(linePrefix, font: font)
        let wordWidth = max(ceil(Self.measuredWidth(word, font: font)), caret.width + 8)
        let lineHeight = max(caret.height, ceil(font.ascender - font.descender))
        let x = context.geometry.isRightToLeft
            ? max(field.minX, caret.maxX - prefixWidth - wordWidth)
            : min(field.maxX - wordWidth, field.minX + prefixWidth)
        let y = min(max(caret.minY, field.minY), field.maxY - lineHeight)
        let rect = CGRect(x: x, y: y, width: wordWidth, height: lineHeight)
        return TextRangeGeometry(rect: rect, source: "TextKitEstimate", quality: .estimated)
    }

    private static func measuredWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}
