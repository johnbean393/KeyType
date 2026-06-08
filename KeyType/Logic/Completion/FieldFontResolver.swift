//
//  FieldFontResolver.swift
//  KeyType
//
//  Best-effort read of the focused text field's font via Accessibility, so the ghost-text overlay
//  can match the field (M6 / ADR-016). Returns nil whenever the app doesn't surface a font through
//  AX; the overlay presenter then falls back to a system font sized from the caret height.
//

import AppKit
import ApplicationServices
import CompletionUI

/// The text attributes read from the focused field, so the ghost-text overlay can match it. Values
/// may be `nil` when the app does not surface them through AX.
struct ResolvedFieldStyle {
    var font: NSFont?
    var color: NSColor?
    var paragraphStyle: NSParagraphStyle?
    var baselineOffset: CGFloat
    var lineHeight: CGFloat?

    nonisolated init(
        font: NSFont? = nil,
        color: NSColor? = nil,
        paragraphStyle: NSParagraphStyle? = nil,
        baselineOffset: CGFloat = 0,
        lineHeight: CGFloat? = nil
    ) {
        self.font = font
        self.color = color
        self.paragraphStyle = paragraphStyle
        self.baselineOffset = baselineOffset
        self.lineHeight = lineHeight
    }

    var overlayTextStyle: OverlayTextStyle {
        OverlayTextStyle(
            font: font,
            textColor: color,
            paragraphStyle: paragraphStyle,
            baselineOffset: baselineOffset,
            lineHeight: lineHeight
        )
    }
}

@MainActor
enum FieldFontResolver {
    // AX attributed strings describe their font with these keys (HIServices `AXConstants`), not the
    // AppKit `NSFont` attribute — the value is a dictionary, not an NSFont. We read both forms.
    private static let axFontAttribute = NSAttributedString.Key("AXFont")
    private static let axFontNameKey = "AXFontName" // PostScript name, usable by NSFont(name:size:)
    private static let axFontSizeKey = "AXFontSize"
    // AX foreground color: the attribute value is a `CGColor` (CFType), not an `NSColor`.
    private static let axForegroundColorAttribute = NSAttributedString.Key("AXForegroundColor")

    /// The text attributes around the insertion point of the system-wide focused element.
    /// Reads `AXAttributedStringForRange` over a 1-character probe at the caret once, then extracts
    /// the attributes relevant to overlay alignment. Missing attributes come back nil/defaulted.
    static func currentStyle() -> ResolvedFieldStyle {
        guard let string = attributedProbe() else { return ResolvedFieldStyle() }
        let resolvedFont = font(from: string)
        let resolvedParagraphStyle = paragraphStyle(from: string)
        return ResolvedFieldStyle(
            font: resolvedFont,
            color: color(from: string),
            paragraphStyle: resolvedParagraphStyle,
            baselineOffset: baselineOffset(from: string),
            lineHeight: lineHeight(font: resolvedFont, paragraphStyle: resolvedParagraphStyle)
        )
    }

    /// Back-compat convenience for callers that only need the font.
    static func currentFont() -> NSFont? {
        currentStyle().font
    }

    /// The attributed string for a 1-character range at the caret of the focused element, or nil.
    private static func attributedProbe() -> NSAttributedString? {
        let systemWide = AXUIElementCreateSystemWide()

        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return nil }
        let field = textElement(for: element as! AXUIElement)

        guard var probe = probeRange(for: field) else { return nil }

        guard let axRange = AXValueCreate(.cfRange, &probe) else { return nil }
        var attributed: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            field,
            kAXAttributedStringForRangeParameterizedAttribute as CFString,
            axRange,
            &attributed
        ) == .success,
            let string = attributed as? NSAttributedString,
            string.length > 0
        else { return nil }
        return string
    }

    /// Font from a probed AX attributed string. Some apps expose a real `NSFont`; most expose the AX
    /// font dictionary.
    private static func font(from string: NSAttributedString) -> NSFont? {
        if let nsFont = string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
            return nsFont
        }
        if let info = string.attribute(axFontAttribute, at: 0, effectiveRange: nil) as? [String: Any] {
            return font(fromAXFontInfo: info)
        }
        return nil
    }

    /// Foreground color from a probed AX attributed string. AX provides a `CGColor`; AppKit-backed
    /// strings may provide an `NSColor`.
    private static func color(from string: NSAttributedString) -> NSColor? {
        if let nsColor = string.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor {
            return nsColor
        }
        if let raw = string.attribute(axForegroundColorAttribute, at: 0, effectiveRange: nil) {
            let cf = raw as CFTypeRef
            if CFGetTypeID(cf) == CGColor.typeID {
                return NSColor(cgColor: cf as! CGColor)
            }
        }
        return nil
    }

    private static func paragraphStyle(from string: NSAttributedString) -> NSParagraphStyle? {
        string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    }

    private static func baselineOffset(from string: NSAttributedString) -> CGFloat {
        cgFloatAttribute(.baselineOffset, from: string) ?? 0
    }

    private static func lineHeight(font: NSFont?, paragraphStyle: NSParagraphStyle?) -> CGFloat? {
        if let paragraphStyle {
            if paragraphStyle.maximumLineHeight > 0 {
                return paragraphStyle.maximumLineHeight
            }
            if paragraphStyle.minimumLineHeight > 0 {
                return paragraphStyle.minimumLineHeight
            }
        }

        guard let font else { return nil }
        let natural = ceil(font.ascender - font.descender + font.leading)
        return natural > 0 ? natural : nil
    }

    private static func cgFloatAttribute(
        _ key: NSAttributedString.Key,
        from string: NSAttributedString
    ) -> CGFloat? {
        let value = string.attribute(key, at: 0, effectiveRange: nil)
        if let value = value as? CGFloat { return value }
        if let value = value as? Double { return CGFloat(value) }
        if let value = value as? NSNumber { return CGFloat(truncating: value) }
        return nil
    }

    /// Build an `NSFont` from the AX font dictionary (`{AXFontName, AXFontSize, …}`).
    private static func font(fromAXFontInfo info: [String: Any]) -> NSFont? {
        let size = (info[axFontSizeKey] as? CGFloat)
            ?? (info[axFontSizeKey] as? Double).map { CGFloat($0) }
            ?? NSFont.systemFontSize
        if let name = info[axFontNameKey] as? String, let font = NSFont(name: name, size: size) {
            return font
        }
        return NSFont.systemFont(ofSize: size)
    }

    /// A length-1 range at (or just before) the caret. AX text APIs return nothing for a zero-length
    /// range, so when the caret is collapsed we probe the preceding character.
    private static func probeRange(for field: AXUIElement) -> CFRange? {
        var rangeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let value = rangeValue, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }

        var selected = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &selected) else { return nil }

        if selected.length > 0 {
            return CFRange(location: selected.location, length: 1)
        }
        if selected.location > 0 {
            return CFRange(location: selected.location - 1, length: 1)
        }
        return CFRange(location: 0, length: 1)
    }

    /// Browser accessibility trees often focus the page web area while the active editable element
    /// is a child. Probe style from the same child text control that context capture will read.
    private static func textElement(for element: AXUIElement) -> AXUIElement {
        if isUsableTextElement(element) {
            return element
        }

        var queue: [(element: AXUIElement, depth: Int)] = [(element, 0)]
        let rootIdentity = elementIdentity(for: element)
        let maxDepth = 8
        let maxNodes = 240
        var visited = 0
        var seen = Set<String>()
        var bestCandidate: (element: AXUIElement, score: Int, minY: CGFloat)?

        while !queue.isEmpty, visited < maxNodes {
            let (candidate, depth) = queue.removeFirst()
            let identity = elementIdentity(for: candidate)
            guard seen.insert(identity).inserted else { continue }
            visited += 1

            if identity != rootIdentity, isUsableTextElement(candidate) {
                let score = textElementCandidateScore(candidate)
                let minY = rectValue(for: "AXFrame" as CFString, on: candidate)
                    .map(cocoaRect(fromAccessibilityRect:))?
                    .minY ?? .greatestFiniteMagnitude
                if bestCandidate == nil
                    || score > bestCandidate!.score
                    || (score == bestCandidate!.score && minY < bestCandidate!.minY) {
                    bestCandidate = (candidate, score, minY)
                }
            }

            guard depth < maxDepth else { continue }
            for child in childElements(of: candidate) {
                queue.append((child, depth + 1))
            }
        }

        return bestCandidate?.element ?? element
    }

    private static func isUsableTextElement(_ element: AXUIElement) -> Bool {
        guard isTextRole(element) else { return false }
        if rangeValue(for: kAXSelectedTextRangeAttribute as CFString, on: element) != nil {
            return true
        }
        return stringValue(for: kAXValueAttribute as CFString, on: element) != nil
    }

    private static func isTextRole(_ element: AXUIElement) -> Bool {
        let role = stringValue(for: kAXRoleAttribute as CFString, on: element)
        let subrole = stringValue(for: kAXSubroleAttribute as CFString, on: element)
        let textRoles: Set<String> = [
            kAXTextAreaRole as String,
            kAXTextFieldRole as String,
            kAXComboBoxRole as String,
            "AXEditableText",
            "AXDocument"
        ]
        return role.map(textRoles.contains) == true || subrole.map(textRoles.contains) == true
    }

    private static func textElementCandidateScore(_ element: AXUIElement) -> Int {
        let role = stringValue(for: kAXRoleAttribute as CFString, on: element) ?? ""
        let subrole = stringValue(for: kAXSubroleAttribute as CFString, on: element) ?? ""
        let metadata = [
            stringValue(for: kAXTitleAttribute as CFString, on: element),
            stringValue(for: kAXDescriptionAttribute as CFString, on: element),
            stringValue(for: kAXPlaceholderValueAttribute as CFString, on: element)
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        var score = 0
        if boolValue(for: kAXFocusedAttribute as CFString, on: element) == true {
            score += 1_000
        }
        if rangeValue(for: kAXSelectedTextRangeAttribute as CFString, on: element) != nil {
            score += 300
        }
        if isAttributeSettable(kAXValueAttribute as CFString, on: element) {
            score += 120
        }
        if role == kAXTextAreaRole as String || role == kAXTextFieldRole as String || role == kAXComboBoxRole as String {
            score += 100
        }
        if subrole == kAXTextAreaRole as String || subrole == kAXTextFieldRole as String || subrole == kAXComboBoxRole as String {
            score += 80
        }
        if role == "AXEditableText" || subrole == "AXEditableText" {
            score += 60
        }
        if metadata.contains("send")
            || metadata.contains("message")
            || metadata.contains("follow-up")
            || metadata.contains("prompt") {
            score += 60
        }

        return score
    }

    private static func stringValue(for attribute: CFString, on element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success, let value else {
            return nil
        }
        if let string = value as? String {
            return string
        }
        if let attributed = value as? NSAttributedString {
            return attributed.string
        }
        return nil
    }

    private static func rangeValue(for attribute: CFString, on element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }
        return range
    }

    private static func boolValue(for attribute: CFString, on element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success, let value else {
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

    private static func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success
            && settable.boolValue
    }

    private static func rectValue(for attribute: CFString, on element: AXUIElement) -> CGRect? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgRect else {
            return nil
        }
        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else {
            return nil
        }
        return rect
    }

    private static func cocoaRect(fromAccessibilityRect rect: CGRect) -> CGRect {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main else {
            return rect
        }
        let displayHeight = screen.frame.height
        return CGRect(x: rect.minX, y: displayHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func childElements(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let values = value as? [AnyObject] else {
            return []
        }
        return values.compactMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return nil
            }
            return unsafeBitCast(value, to: AXUIElement.self)
        }
    }

    private static func elementIdentity(for element: AXUIElement) -> String {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return "\(pid)-\(CFHash(element))"
    }
}
