//
//  AXCaretGeometryResolver.swift
//  MacContextCapture
//
//  Ported from the sibling Red Dot project (see docs/01-architecture.md and ADR-004).
//  Resolves the on-screen caret CGRect for a focused AXUIElement across native, Chromium,
//  and Google-Docs-style web text fields. Preserves the exact -> derived -> estimated
//  quality ranking and the multi-display CG <-> AppKit coordinate conversion intact.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Resolved caret geometry with provenance for diagnostics.
public struct AXCaretGeometryResult: Equatable {
    public let rect: CGRect
    public let source: String
    let quality: AXCaretGeometryQuality

    public var qualityLabel: String { quality.label }
}

enum AXCaretGeometryQuality: Int, Comparable {
    case estimated = 0
    case derived = 1
    case exact = 2

    var label: String {
        switch self {
        case .exact: "exact"
        case .derived: "derived"
        case .estimated: "estimated"
        }
    }

    static func < (lhs: AXCaretGeometryQuality, rhs: AXCaretGeometryQuality) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum AXCaretGeometryStrategy: Equatable {
    case full
    case primary
    case nonInvasive
}

@MainActor
public struct AXCaretGeometryResolver {
    public nonisolated init() {}

    func resolveCaretRect(
        for element: AXUIElement,
        strategy: AXCaretGeometryStrategy = .full
    ) -> AXCaretGeometryResult? {
        switch strategy {
        case .nonInvasive:
            return resolveNonInvasiveCaretRect(for: element)
        case .primary:
            return resolvePrimaryCaretRect(for: element)
        case .full:
            break
        }

        let primaryResult = resolvePrimaryCaretRect(for: element)

        if primaryResult?.quality == .exact {
            return primaryResult
        }

        let anchorFrame = AXCaretHelper.rectValue(for: "AXFrame" as CFString, on: element)
            .map(AXCaretHelper.cocoaRect(fromAccessibilityRect:))
        let deepResult = resolveDeepChromiumGeometrySource(
            focusedElement: element,
            cocoaAnchorFrame: anchorFrame
        )

        if let deepResult, deepResult.quality == .exact {
            return deepResult
        }

        if let primaryResult, primaryResult.quality == .derived {
            return primaryResult
        }

        if let deepResult {
            return deepResult
        }

        return primaryResult
    }

    private func resolveNonInvasiveCaretRect(for element: AXUIElement) -> AXCaretGeometryResult? {
        guard let selection = AXCaretHelper.rangeValue(for: kAXSelectedTextRangeAttribute as CFString, on: element),
              let textValue = AXCaretHelper.stringValue(for: kAXValueAttribute as CFString, on: element),
              let anchorFrame = AXCaretHelper.rectValue(for: "AXFrame" as CFString, on: element)
                .map(AXCaretHelper.cocoaRect(fromAccessibilityRect:)),
              !textValue.isEmpty,
              anchorFrame.width > 10,
              anchorFrame.height > 0 else {
            return nil
        }

        return AXCaretGeometryResult(
            rect: conservativeEstimatedCaretRect(in: anchorFrame, text: textValue, selection: selection),
            source: "AXFrameEstimateNonInvasive",
            quality: .estimated
        )
    }

    private func resolvePrimaryCaretRect(for element: AXUIElement) -> AXCaretGeometryResult? {
        let selection = AXCaretHelper.rangeValue(for: kAXSelectedTextRangeAttribute as CFString, on: element)
        let textValue = AXCaretHelper.stringValue(for: kAXValueAttribute as CFString, on: element)
        let parameterizedAttributes = AXCaretHelper.parameterizedAttributeNames(on: element)
        let supportsBoundsForRange = parameterizedAttributes.contains(kAXBoundsForRangeParameterizedAttribute as String)
        let anchorFrame = AXCaretHelper.rectValue(for: "AXFrame" as CFString, on: element)
            .map(AXCaretHelper.cocoaRect(fromAccessibilityRect:))

        if let selection,
           supportsBoundsForRange,
           let rawRect = AXCaretHelper.parameterizedRectValue(
                for: kAXBoundsForRangeParameterizedAttribute as CFString,
                range: NSRange(location: selection.location, length: 0),
                on: element
           ),
           !rawRect.isEmpty {
            let cocoaRect = AXCaretHelper.validatedCocoaTextRect(
                fromAccessibilityRect: rawRect,
                anchorFrame: anchorFrame
            )
            if rectIsUsableCaretRect(cocoaRect, anchor: anchorFrame) {
                return AXCaretGeometryResult(
                    rect: normalizedCaretRect(fromZeroLengthRangeRect: cocoaRect),
                    source: "AXBoundsForRange",
                    quality: .exact
                )
            }
        }

        if let rawMarkerRect = AXCaretHelper.textMarkerCaretRect(on: element), !rawMarkerRect.isEmpty {
            let cocoaRect = AXCaretHelper.validatedCocoaTextRect(
                fromAccessibilityRect: rawMarkerRect,
                anchorFrame: anchorFrame
            )
            if rectIsUsableCaretRect(cocoaRect, anchor: anchorFrame) {
                return AXCaretGeometryResult(
                    rect: normalizedCaretRect(fromZeroLengthRangeRect: cocoaRect),
                    source: "AXTextMarker",
                    quality: .exact
                )
            }
        }

        if let selection,
           supportsBoundsForRange,
           selection.location > 0,
           let rawRect = AXCaretHelper.parameterizedRectValue(
                for: kAXBoundsForRangeParameterizedAttribute as CFString,
                range: NSRange(location: selection.location - 1, length: 1),
                on: element
           ),
           !rawRect.isEmpty {
            let cocoaRect = AXCaretHelper.validatedCocoaTextRect(
                fromAccessibilityRect: rawRect,
                anchorFrame: anchorFrame
            )
            if rectIsUsableCaretRect(cocoaRect, anchor: anchorFrame) {
                return AXCaretGeometryResult(
                    rect: CGRect(x: cocoaRect.maxX, y: cocoaRect.minY, width: 2, height: cocoaRect.height),
                    source: "AXBoundsForPreviousCharacter",
                    quality: .derived
                )
            }
        }

        if let selection,
           let textValue,
           !textValue.isEmpty,
           let result = resolveCaretFromChildTextRuns(
                element: element,
                parentSelection: selection,
                parentText: textValue
           ) {
            return result
        }

        if let selection,
           let textValue,
           !textValue.isEmpty,
           let anchorFrame,
           anchorFrame.width > 10,
           anchorFrame.height > 0 {
            return AXCaretGeometryResult(
                rect: conservativeEstimatedCaretRect(in: anchorFrame, text: textValue, selection: selection),
                source: "AXFrameEstimate",
                quality: .estimated
            )
        }

        return nil
    }

    private func resolveDeepChromiumGeometrySource(
        focusedElement: AXUIElement,
        cocoaAnchorFrame: CGRect?
    ) -> AXCaretGeometryResult? {
        var roots: [AXUIElement] = []
        var seenRoots = Set<String>()

        func appendRoot(_ element: AXUIElement?) {
            guard let element else { return }
            let identity = AXCaretHelper.elementIdentity(for: element)
            guard seenRoots.insert(identity).inserted else { return }
            roots.append(element)
        }

        appendRoot(focusedElement)

        var current = focusedElement
        for _ in 0..<2 {
            guard let parent = AXCaretHelper.parentElement(of: current) else { break }
            appendRoot(parent)
            current = parent
        }

        var bestResult: (result: AXCaretGeometryResult, depth: Int)?
        for root in roots {
            if let result = findDeepChromiumGeometrySource(
                from: root,
                cocoaAnchorFrame: cocoaAnchorFrame
            ), shouldPreferDeepResult(result.result, depth: result.depth, over: bestResult) {
                bestResult = result
            }
        }

        return bestResult?.result
    }

    private func findDeepChromiumGeometrySource(
        from root: AXUIElement,
        cocoaAnchorFrame: CGRect?
    ) -> (result: AXCaretGeometryResult, depth: Int)? {
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        let maxDepth = 10
        let maxNodes = 200
        var visited = 0
        var seen = Set<String>()
        var bestResult: (result: AXCaretGeometryResult, depth: Int)?

        while !queue.isEmpty, visited < maxNodes {
            let (element, depth) = queue.removeFirst()
            let identity = AXCaretHelper.elementIdentity(for: element)
            guard seen.insert(identity).inserted else { continue }
            visited += 1

            if let range = AXCaretHelper.rangeValue(
                for: kAXSelectedTextRangeAttribute as CFString,
                on: element
            ), range.length == 0 {
                let result = resolvePrimaryCaretRect(for: element)
                if let result, result.quality == .exact || result.quality == .derived,
                   rectIsNearAnchor(result.rect, anchor: cocoaAnchorFrame),
                   shouldPreferDeepResult(result, depth: depth, over: bestResult) {
                    bestResult = (result, depth)
                }
            }

            guard depth < maxDepth else { continue }
            for child in AXCaretHelper.childElements(of: element) {
                queue.append((child, depth + 1))
            }
        }

        return bestResult
    }

    private func shouldPreferDeepResult(
        _ candidate: AXCaretGeometryResult,
        depth: Int,
        over best: (result: AXCaretGeometryResult, depth: Int)?
    ) -> Bool {
        guard let best else { return true }

        if candidate.quality != best.result.quality {
            return candidate.quality.rawValue > best.result.quality.rawValue
        }

        return depth > best.depth
    }

    private func resolveCaretFromChildTextRuns(
        element: AXUIElement,
        parentSelection: NSRange,
        parentText: String
    ) -> AXCaretGeometryResult? {
        let parentTextLength = (parentText as NSString).length
        guard parentSelection.location <= parentTextLength else {
            return nil
        }

        let textRuns = collectStaticTextRuns(from: element)
        guard !textRuns.isEmpty else { return nil }

        let caretOffset = parentSelection.location
        var cumulative = 0
        for run in textRuns {
            let runLength = (run.text as NSString).length
            if caretOffset <= cumulative + runLength {
                let localOffset = caretOffset - cumulative
                let fraction = runLength > 0 ? CGFloat(localOffset) / CGFloat(runLength) : 1
                let cocoaFrame = AXCaretHelper.cocoaRect(fromAccessibilityRect: run.frame)
                let caretX = cocoaFrame.minX + fraction * cocoaFrame.width
                return AXCaretGeometryResult(
                    rect: CGRect(x: caretX, y: cocoaFrame.minY, width: 2, height: cocoaFrame.height),
                    source: "AXStaticTextRuns",
                    quality: .derived
                )
            }
            cumulative += runLength
        }

        guard let lastFrame = textRuns.last?.frame else { return nil }
        let cocoaFrame = AXCaretHelper.cocoaRect(fromAccessibilityRect: lastFrame)
        return AXCaretGeometryResult(
            rect: CGRect(x: cocoaFrame.maxX, y: cocoaFrame.minY, width: 2, height: cocoaFrame.height),
            source: "AXStaticTextRunsTrailingEdge",
            quality: .derived
        )
    }

    private func collectStaticTextRuns(from root: AXUIElement) -> [(text: String, frame: CGRect)] {
        let maxDepth = 8
        let maxNodes = 300
        var visitedNodes = 0
        var seen = Set<String>()
        var runs: [(text: String, frame: CGRect)] = []

        func walk(_ element: AXUIElement, depth: Int) {
            guard depth <= maxDepth, visitedNodes < maxNodes else { return }

            let identity = AXCaretHelper.elementIdentity(for: element)
            guard seen.insert(identity).inserted else { return }

            visitedNodes += 1

            let role = AXCaretHelper.stringValue(for: kAXRoleAttribute as CFString, on: element)
            if role == kAXStaticTextRole as String,
               let text = AXCaretHelper.stringValue(for: kAXValueAttribute as CFString, on: element),
               !text.isEmpty,
               let frame = AXCaretHelper.rectValue(for: "AXFrame" as CFString, on: element),
               !frame.isEmpty {
                runs.append((text, frame))
            }

            guard depth < maxDepth else { return }
            for child in AXCaretHelper.childElements(of: element) {
                walk(child, depth: depth + 1)
            }
        }

        for child in AXCaretHelper.childElements(of: root) {
            walk(child, depth: 1)
        }

        return runs
    }

    private func conservativeEstimatedCaretX(
        in cocoaRect: CGRect,
        text: String,
        selection: NSRange
    ) -> CGFloat {
        let currentLinePrefix = currentLinePrefix(in: text, selection: selection)
        let line = currentLinePrefix as NSString

        let estimatedWidthBias: CGFloat = 1.1
        let measuredWidth = line.size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 15)
        ]).width * estimatedWidthBias
        let perCharacterCeiling: CGFloat = 13.3 * estimatedWidthBias
        let estimatedWidth = min(measuredWidth, CGFloat(line.length) * perCharacterCeiling)

        return cocoaRect.minX + estimatedWidth
    }

    private func conservativeEstimatedCaretRect(
        in cocoaRect: CGRect,
        text: String,
        selection: NSRange
    ) -> CGRect {
        let lineHeight = min(max(NSFont.systemFont(ofSize: 15).boundingRectForFont.height, 18), 24)
        let height = min(cocoaRect.height, lineHeight)

        guard cocoaRect.height > lineHeight * 2 else {
            let x = min(conservativeEstimatedCaretX(in: cocoaRect, text: text, selection: selection), cocoaRect.maxX)
            return CGRect(x: x, y: cocoaRect.minY, width: 2, height: height)
        }

        let wrapped = Self.estimatedSoftWrappedCaretLayout(
            in: text,
            selection: selection,
            availableWidth: cocoaRect.width
        )
        let x = min(cocoaRect.minX + wrapped.xOffset, cocoaRect.maxX)
        let lineIndex = CGFloat(wrapped.lineIndex)
        let topPadding: CGFloat = 2
        let estimatedY = cocoaRect.maxY - topPadding - ((lineIndex + 1) * lineHeight)
        let clampedY = min(max(estimatedY, cocoaRect.minY), cocoaRect.maxY - height)

        return CGRect(x: x, y: clampedY, width: 2, height: height)
    }

    nonisolated static func estimatedSoftWrappedCaretLayout(
        in text: String,
        selection: NSRange,
        availableWidth: CGFloat,
        font: NSFont = NSFont.systemFont(ofSize: 15),
        widthBias: CGFloat = 1.1
    ) -> (lineIndex: Int, xOffset: CGFloat) {
        let nsText = text as NSString
        let safeLocation = min(max(selection.location, 0), nsText.length)
        let prefix = nsText.substring(to: safeLocation)
        let logicalLines = prefix.components(separatedBy: .newlines)
        let width = max(1, availableWidth)

        var visualLineBase = 0
        for (index, line) in logicalLines.enumerated() {
            let wrapped = estimatedWrappedLineLayout(
                for: line,
                availableWidth: width,
                font: font,
                widthBias: widthBias
            )
            if index == logicalLines.count - 1 {
                return (
                    lineIndex: visualLineBase + wrapped.lineIndex,
                    xOffset: min(max(0, wrapped.xOffset), width)
                )
            }
            visualLineBase += wrapped.lineIndex + 1
        }

        return (lineIndex: 0, xOffset: 0)
    }

    private nonisolated static func estimatedWrappedLineLayout(
        for line: String,
        availableWidth: CGFloat,
        font: NSFont,
        widthBias: CGFloat
    ) -> (lineIndex: Int, xOffset: CGFloat) {
        guard !line.isEmpty else {
            return (lineIndex: 0, xOffset: 0)
        }

        let width = max(1, availableWidth)
        var lineIndex = 0
        var currentWidth: CGFloat = 0

        for rawToken in wrappingTokens(in: line) {
            var token = rawToken
            if currentWidth == 0 {
                token = token.trimmingCharacters(in: .whitespaces)
            }
            guard !token.isEmpty else { continue }

            var tokenWidth = estimatedTextWidth(token, font: font, widthBias: widthBias)
            if currentWidth > 0, currentWidth + tokenWidth > width {
                lineIndex += 1
                currentWidth = 0
                token = token.trimmingCharacters(in: .whitespaces)
                guard !token.isEmpty else { continue }
                tokenWidth = estimatedTextWidth(token, font: font, widthBias: widthBias)
            }

            if tokenWidth > width {
                let occupiedLines = floor(tokenWidth / width)
                lineIndex += Int(occupiedLines)
                currentWidth = tokenWidth - occupiedLines * width
                if currentWidth == 0, occupiedLines > 0 {
                    currentWidth = width
                }
            } else {
                currentWidth += tokenWidth
            }
        }

        return (lineIndex: lineIndex, xOffset: currentWidth)
    }

    private nonisolated static func wrappingTokens(in text: String) -> [String] {
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

    private nonisolated static func estimatedTextWidth(
        _ text: String,
        font: NSFont,
        widthBias: CGFloat
    ) -> CGFloat {
        let measuredWidth = (text as NSString).size(withAttributes: [.font: font]).width * widthBias
        let perCharacterCeiling: CGFloat = 13.3 * widthBias
        return min(measuredWidth, CGFloat((text as NSString).length) * perCharacterCeiling)
    }

    private func currentLinePrefix(in text: String, selection: NSRange) -> String {
        let nsText = text as NSString
        let safeLocation = min(selection.location, nsText.length)
        let prefix = nsText.substring(to: safeLocation)
        return prefix.components(separatedBy: .newlines).last ?? prefix
    }

    private func rectIsNearAnchor(_ cocoaRect: CGRect, anchor: CGRect?) -> Bool {
        guard let anchor, !anchor.isEmpty else {
            return true
        }

        let tolerance: CGFloat = 80
        let expanded = anchor.insetBy(dx: -tolerance, dy: -tolerance)
        return expanded.contains(CGPoint(x: cocoaRect.midX, y: cocoaRect.midY))
    }

    private func rectIsUsableCaretRect(_ cocoaRect: CGRect, anchor: CGRect?) -> Bool {
        guard rectIsNearAnchor(cocoaRect, anchor: anchor) else {
            return false
        }
        return !Self.rectLooksLikeTextContainer(cocoaRect, anchor: anchor)
    }

    nonisolated static func rectLooksLikeTextContainer(_ cocoaRect: CGRect, anchor: CGRect?) -> Bool {
        guard let anchor, !anchor.isEmpty, !cocoaRect.isEmpty else {
            return false
        }

        let multilineHeight: CGFloat = 40
        if anchor.height >= multilineHeight,
           cocoaRect.height >= anchor.height * 0.65 {
            return true
        }

        if anchor.height >= 60,
           cocoaRect.height > 32 {
            return true
        }

        if anchor.width >= 80,
           cocoaRect.width >= anchor.width * 0.5,
           cocoaRect.height >= min(anchor.height * 0.4, multilineHeight) {
            return true
        }

        return false
    }

    private func normalizedCaretRect(fromZeroLengthRangeRect rect: CGRect) -> CGRect {
        guard !rect.isEmpty else {
            return rect
        }

        return CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height)
    }
}

enum AXCaretHelper {
    static func focusedElement(systemElement: AXUIElement) -> AXUIElement? {
        if let focused = focusedElement(on: systemElement) {
            return focused
        }
        return focusedElementInFrontmostApplication()
    }

    static func focusedElementInFrontmostApplication() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        return focusedElement(on: appElement)
    }

    static func focusedElement(on element: AXUIElement) -> AXUIElement? {
        guard let value = copyAttributeValue(kAXFocusedUIElementAttribute as CFString, on: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    @discardableResult
    static func enableEnhancedUserInterface(on appElement: AXUIElement) -> Bool {
        guard let value = kCFBooleanTrue else {
            return false
        }
        let result = AXUIElementSetAttributeValue(
            appElement,
            "AXEnhancedUserInterface" as CFString,
            value as CFTypeRef
        )
        // Chromium sometimes applies the value while still returning kAXErrorCannotComplete.
        return result == .success
            || boolValue(for: "AXEnhancedUserInterface" as CFString, on: appElement) == true
    }

    static func parameterizedAttributeNames(on element: AXUIElement) -> [String] {
        var names: CFArray?
        let result = AXUIElementCopyParameterizedAttributeNames(element, &names)
        guard result == .success, let names else {
            return []
        }

        return names as? [String] ?? []
    }

    static func stringValue(for attribute: CFString, on element: AXUIElement) -> String? {
        guard let value = copyAttributeValue(attribute, on: element) else {
            return nil
        }

        if let string = value as? String {
            return string
        }

        if let attributedString = value as? NSAttributedString {
            return attributedString.string
        }

        return nil
    }

    static func boolValue(for attribute: CFString, on element: AXUIElement) -> Bool? {
        guard let value = copyAttributeValue(attribute, on: element) else {
            return nil
        }

        if let bool = value as? Bool {
            return bool
        }

        if let number = value as? NSNumber {
            return number.boolValue
        }

        return nil
    }

    static func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success
            && settable.boolValue
    }

    static func rangeValue(for attribute: CFString, on element: AXUIElement) -> NSRange? {
        guard let value = axValue(from: copyAttributeValue(attribute, on: element)) else {
            return nil
        }
        guard AXValueGetType(value) == .cfRange else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else {
            return nil
        }

        return NSRange(location: range.location, length: range.length)
    }

    static func rectValue(for attribute: CFString, on element: AXUIElement) -> CGRect? {
        guard let value = axValue(from: copyAttributeValue(attribute, on: element)) else {
            return nil
        }
        guard AXValueGetType(value) == .cgRect else {
            return nil
        }

        var rect = CGRect.zero
        guard AXValueGetValue(value, .cgRect, &rect) else {
            return nil
        }

        return rect
    }

    static func parameterizedRectValue(
        for attribute: CFString,
        range: NSRange,
        on element: AXUIElement
    ) -> CGRect? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else {
            return nil
        }

        var value: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(element, attribute, parameter, &value)
        guard result == .success, let axValue = axValue(from: value) else {
            return nil
        }
        guard AXValueGetType(axValue) == .cgRect else {
            return nil
        }

        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else {
            return nil
        }

        return rect
    }

    static func textMarkerCaretRect(on element: AXUIElement) -> CGRect? {
        var markerRangeValue: CFTypeRef?
        var result = AXUIElementCopyAttributeValue(
            element,
            "AXSelectedTextMarkerRange" as CFString,
            &markerRangeValue
        )

        guard result == .success, let markerRangeValue else {
            return nil
        }

        var boundsValue: CFTypeRef?
        result = AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXBoundsForTextMarkerRange" as CFString,
            markerRangeValue,
            &boundsValue
        )

        guard result == .success, let axBounds = axValue(from: boundsValue) else {
            return nil
        }
        guard AXValueGetType(axBounds) == .cgRect else {
            return nil
        }

        var rect = CGRect.zero
        guard AXValueGetValue(axBounds, .cgRect, &rect) else {
            return nil
        }

        return rect
    }

    static func copyAttributeValue(_ attribute: CFString, on element: AXUIElement) -> AnyObject? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else {
            return nil
        }

        return value as AnyObject?
    }

    static func childElements(of element: AXUIElement) -> [AXUIElement] {
        guard let values = copyAttributeValue(kAXChildrenAttribute as CFString, on: element) as? [AnyObject] else {
            return []
        }

        return values.compactMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return nil
            }

            return unsafeBitCast(value, to: AXUIElement.self)
        }
    }

    static func parentElement(of element: AXUIElement) -> AXUIElement? {
        guard let value = copyAttributeValue(kAXParentAttribute as CFString, on: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeBitCast(value, to: AXUIElement.self)
    }

    static func elementIdentity(for element: AXUIElement) -> String {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return "\(pid)-\(CFHash(element))"
    }

    static func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        let result = AXUIElementGetPid(element, &pid)
        guard result == .success else { return nil }
        return pid
    }

    @MainActor
    static func cocoaRect(fromAccessibilityRect rect: CGRect) -> CGRect {
        guard !rect.isNull, rect != .zero else {
            return rect
        }

        let displays = displayGeometries()
        if let converted = DisplayCoordinateConverter.appKitRect(
            fromCoreGraphicsRect: rect,
            displays: displays
        ) {
            return converted
        }

        return legacyDesktopUnionFlip(rect)
    }

    @MainActor
    static func validatedCocoaTextRect(
        fromAccessibilityRect textRect: CGRect,
        anchorFrame cocoaAnchorFrame: CGRect?
    ) -> CGRect {
        guard !textRect.isNull, textRect != .zero else {
            return textRect
        }

        let displays = displayGeometries()
        guard !displays.isEmpty else {
            return textRect
        }

        let flipped = DisplayCoordinateConverter.appKitRect(
            fromCoreGraphicsRect: textRect,
            displays: displays
        ) ?? legacyDesktopUnionFlip(textRect)

        guard let anchor = cocoaAnchorFrame, !anchor.isEmpty else {
            return flipped
        }

        let tolerance: CGFloat = 80
        let expandedAnchor = anchor.insetBy(dx: -tolerance, dy: -tolerance)

        if expandedAnchor.contains(CGPoint(x: flipped.midX, y: flipped.midY)) {
            return flipped
        }

        for scaledFlipped in DisplayCoordinateConverter.appKitRectsFromPixelRect(
            textRect,
            displays: displays
        ) where expandedAnchor.contains(CGPoint(x: scaledFlipped.midX, y: scaledFlipped.midY)) {
            return scaledFlipped
        }

        return flipped
    }

    private static func axValue(from value: AnyObject?) -> AXValue? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        return unsafeBitCast(value, to: AXValue.self)
    }

    @MainActor
    private static func displayGeometries() -> [DisplayGeometry] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }

            let displayID = CGDirectDisplayID(number.uint32Value)
            return DisplayGeometry(
                appKitFrame: screen.frame,
                visibleFrame: screen.visibleFrame,
                coreGraphicsBounds: CGDisplayBounds(displayID),
                backingScaleFactor: screen.backingScaleFactor
            )
        }
    }

    @MainActor
    private static func legacyDesktopUnionFlip(_ rect: CGRect) -> CGRect {
        let desktopBounds = NSScreen.screens
            .map(\.frame)
            .reduce(into: CGRect.null) { $0 = $0.union($1) }

        guard !desktopBounds.isNull else {
            return rect
        }

        return CGRect(
            x: rect.origin.x,
            y: desktopBounds.maxY - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}

/// Pure description of a display in both CG (top-left, points, global) and AppKit (bottom-left,
/// points, global) coordinate spaces. Exposed publicly so that `DisplayCoordinateConverter` can
/// be tested without touching `NSScreen`.
public struct DisplayGeometry: Equatable {
    public let appKitFrame: CGRect
    public let visibleFrame: CGRect
    public let coreGraphicsBounds: CGRect
    public let backingScaleFactor: CGFloat

    public init(
        appKitFrame: CGRect,
        visibleFrame: CGRect,
        coreGraphicsBounds: CGRect,
        backingScaleFactor: CGFloat
    ) {
        self.appKitFrame = appKitFrame
        self.visibleFrame = visibleFrame
        self.coreGraphicsBounds = coreGraphicsBounds
        self.backingScaleFactor = backingScaleFactor
    }
}

/// Pure CG <-> AppKit coordinate conversion against a set of synthetic or real
/// `DisplayGeometry` values. Kept side-effect-free so unit tests don't need `NSScreen`.
public enum DisplayCoordinateConverter {
    public static func appKitRect(
        fromCoreGraphicsRect rect: CGRect,
        displays: [DisplayGeometry]
    ) -> CGRect? {
        guard let display = bestDisplay(for: rect, displays: displays, keyPath: \.coreGraphicsBounds) else {
            return nil
        }

        return appKitRect(fromCoreGraphicsRect: rect, on: display)
    }

    public static func appKitRectsFromPixelRect(
        _ rect: CGRect,
        displays: [DisplayGeometry]
    ) -> [CGRect] {
        displays.compactMap { display in
            guard display.backingScaleFactor > 0 else { return nil }

            let pixelBounds = CGRect(
                x: display.coreGraphicsBounds.minX * display.backingScaleFactor,
                y: display.coreGraphicsBounds.minY * display.backingScaleFactor,
                width: display.coreGraphicsBounds.width * display.backingScaleFactor,
                height: display.coreGraphicsBounds.height * display.backingScaleFactor
            )

            let midpoint = CGPoint(x: rect.midX, y: rect.midY)
            guard pixelBounds.intersects(rect) || pixelBounds.contains(midpoint) else {
                return nil
            }

            let pointRect = CGRect(
                x: display.coreGraphicsBounds.minX + (rect.minX - pixelBounds.minX) / display.backingScaleFactor,
                y: display.coreGraphicsBounds.minY + (rect.minY - pixelBounds.minY) / display.backingScaleFactor,
                width: rect.width / display.backingScaleFactor,
                height: rect.height / display.backingScaleFactor
            )

            return appKitRect(fromCoreGraphicsRect: pointRect, on: display)
        }
    }

    private static func appKitRect(
        fromCoreGraphicsRect rect: CGRect,
        on display: DisplayGeometry
    ) -> CGRect {
        let localX = rect.minX - display.coreGraphicsBounds.minX
        let localY = rect.minY - display.coreGraphicsBounds.minY

        return CGRect(
            x: display.appKitFrame.minX + localX,
            y: display.appKitFrame.maxY - localY - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    private static func bestDisplay(
        for rect: CGRect,
        displays: [DisplayGeometry],
        keyPath: KeyPath<DisplayGeometry, CGRect>
    ) -> DisplayGeometry? {
        let midpoint = CGPoint(x: rect.midX, y: rect.midY)

        if let containingDisplay = displays.first(where: { $0[keyPath: keyPath].contains(midpoint) }) {
            return containingDisplay
        }

        return displays
            .filter { $0[keyPath: keyPath].intersects(rect) }
            .max { lhs, rhs in
                intersectionArea(lhs[keyPath: keyPath], rect) < intersectionArea(rhs[keyPath: keyPath], rect)
            }
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }
}
