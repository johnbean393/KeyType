//
//  FocusedFieldReader.swift
//  MacContextCapture
//
//  Reads a focused AX element into a fully-populated `TextFieldContext`: text split,
//  selection, caret rect (via `AXCaretGeometryResolver`), EOL/RTL flags, app/window/domain,
//  labels, detected language. All work runs on the main actor; AX reads are bounded by
//  the resolver's depth/node caps so we never block the main thread arbitrarily.
//

import AppKit
import ApplicationServices
import AutocompleteCore
import CoreGraphics
import Foundation

/// Resolution metadata returned alongside the captured `TextFieldContext` so the tracker
/// can drive UI (e.g. the debug overlay) and diagnostics.
public struct FocusedFieldSnapshot: Equatable {
    public let context: TextFieldContext
    public let caretRect: CGRect?
    public let caretSource: String?
    public let caretQuality: String?
    public let windowID: CGWindowID?
    public let windowFrame: CGRect?

    public init(
        context: TextFieldContext,
        caretRect: CGRect?,
        caretSource: String?,
        caretQuality: String?,
        windowID: CGWindowID? = nil,
        windowFrame: CGRect? = nil
    ) {
        self.context = context
        self.caretRect = caretRect
        self.caretSource = caretSource
        self.caretQuality = caretQuality
        self.windowID = windowID
        self.windowFrame = windowFrame
    }
}

@MainActor
public struct FocusedFieldReader {
    private static let appCaretGeometryFallbacks: [any AppCaretGeometryFallback.Type] = [
        MessagesRichPreviewCaretGeometryFallback.self,
        CodeEditorCaretGeometryFallback.self
    ]

    private let resolver: AXCaretGeometryResolver
    private nonisolated let webAppClassifier: AppBundleWebAppClassifier

    public nonisolated init(
        resolver: AXCaretGeometryResolver = AXCaretGeometryResolver(),
        webAppClassifier: AppBundleWebAppClassifier = .shared
    ) {
        self.resolver = resolver
        self.webAppClassifier = webAppClassifier
    }

    /// Read the focused AX element into a snapshot. Returns nil if the element has no AX
    /// value (likely not a text-bearing field).
    public func snapshot(of element: AXUIElement) -> FocusedFieldSnapshot? {
        let initialBundleIdentifier = AppTargetResolver.bundleIdentifier(for: element)
        let isKnownWebBackedApp = webAppClassifier.isWebBacked(
            bundleIdentifier: initialBundleIdentifier
        )
        guard let textElement = Self.textElement(
            for: element,
            preferDescendantTextElement: isKnownWebBackedApp
        ) else {
            return nil
        }
        let target = AppTargetResolver.resolveAppTarget(for: textElement)

        let rawValue = AXCaretHelper.stringValue(for: kAXValueAttribute as CFString, on: textElement) ?? ""
        let axRange = AXCaretHelper.rangeValue(for: kAXSelectedTextRangeAttribute as CFString, on: textElement)
        let selectedTextAttr = AXCaretHelper.stringValue(for: kAXSelectedTextAttribute as CFString, on: textElement)

        // Selectable text fields almost always expose either AXValue or AXSelectedTextRange.
        // If neither is present, fall back to whatever we can glean (still produces a
        // bundle-id-only context so the rest of the pipeline can decide).
        let split = TextCursorSplitter.split(text: rawValue, axRange: axRange)

        // Selection: prefer the explicit AXSelectedText, fall back to the slice from the split.
        let effectiveSelected: String? = {
            if let selectedTextAttr, !selectedTextAttr.isEmpty { return selectedTextAttr }
            return split.selectedText.isEmpty ? nil : split.selectedText
        }()

        let selection = TextSelection(
            selectedText: effectiveSelected,
            range: split.range
        )

        let placeholder = AXCaretHelper.stringValue(for: kAXPlaceholderValueAttribute as CFString, on: textElement)
        let labels = AppTargetResolver.collectLabels(for: textElement)
        let traits = AppTargetResolver.collectTraits(
            for: textElement,
            target: target,
            placeholder: placeholder,
            labels: labels,
            webAppClassifier: webAppClassifier
        )
        let role = AXCaretHelper.stringValue(for: kAXRoleAttribute as CFString, on: textElement)
        let subrole = AXCaretHelper.stringValue(for: kAXSubroleAttribute as CFString, on: textElement)
        let caretGeometry = resolver.resolveCaretRect(
            for: textElement,
            strategy: Self.caretGeometryStrategy(
                isWebField: traits.isWebField,
                role: role,
                subrole: subrole
            )
        )

        if let mailSnapshot = MailComposeTextContext.snapshot(
            of: textElement,
            target: target,
            caretGeometry: caretGeometry
        ) {
            return mailSnapshot
        }

        let fieldRect = Self.fieldRect(for: textElement)
        let windowFrame = AXWindowIDResolver.windowFrame(for: textElement)
        let windowID = AXWindowIDResolver.windowID(
            for: textElement,
            target: target,
            fieldRect: fieldRect
        )
        let resolvedCaret = Self.resolvedCaretGeometry(
            element: textElement,
            target: target,
            beforeCursor: split.beforeCursor,
            afterCursor: split.afterCursor,
            fieldRect: fieldRect,
            current: CapturedCaretGeometry(caretGeometry),
            repairLineMismatchedCaret: traits.isWebField
        )

        let language = LanguageDetector.detectLanguage(in: split.beforeCursor)
        let geometry = TextFieldGeometry(
            cursorRect: resolvedCaret.rect,
            fieldRect: fieldRect,
            isAtEndOfLine: split.isAtEndOfLine,
            isRightToLeft: WritingDirection.isRightToLeft(split.beforeCursor.isEmpty ? rawValue : split.beforeCursor),
            cursorRectQuality: resolvedCaret.quality
        )

        let context = TextFieldContext(
            beforeCursor: split.beforeCursor,
            afterCursor: split.afterCursor,
            selection: selection,
            geometry: geometry,
            target: target,
            placeholder: placeholder,
            labels: labels,
            detectedLanguage: language,
            typingContext: nil,
            traits: traits
        )

        return FocusedFieldSnapshot(
            context: context,
            caretRect: resolvedCaret.rect,
            caretSource: resolvedCaret.source,
            caretQuality: resolvedCaret.quality.rawValue,
            windowID: windowID,
            windowFrame: windowFrame
        )
    }

    func canProduceTextSnapshot(from element: AXUIElement) -> Bool {
        let bundleIdentifier = AppTargetResolver.bundleIdentifier(for: element)
        if webAppClassifier.isWebBacked(bundleIdentifier: bundleIdentifier) {
            return true
        }
        return Self.isUsableTextElement(element)
    }

    /// Chromium/Safari often expose the focused node as the whole `AXWebArea` while the editable
    /// control is a descendant. Use the focused node when it already has a selection range; otherwise
    /// pick the first bounded descendant that looks like the active text control.
    nonisolated static func shouldSearchDescendantTextElement(
        rootIsUsable: Bool,
        rootIsWebContainer: Bool,
        preferDescendantTextElement: Bool
    ) -> Bool {
        preferDescendantTextElement && (rootIsWebContainer || !rootIsUsable)
    }

    nonisolated static func caretGeometryStrategy(
        isWebField: Bool,
        role: String?,
        subrole: String?
    ) -> AXCaretGeometryStrategy {
        if isWebField {
            return .full
        }
        if isNativeMultilineTextRole(role) || isNativeMultilineTextRole(subrole) {
            return .primary
        }
        return .nonInvasive
    }

    private nonisolated static func isNativeMultilineTextRole(_ role: String?) -> Bool {
        role == kAXTextAreaRole as String
            || role == "AXDocument"
    }

    static func textElement(
        for element: AXUIElement,
        preferDescendantTextElement: Bool = false
    ) -> AXUIElement? {
        let rootIsUsable = isUsableTextElement(element)
        let shouldSearchDescendants = shouldSearchDescendantTextElement(
            rootIsUsable: rootIsUsable,
            rootIsWebContainer: isWebContainerRole(element),
            preferDescendantTextElement: preferDescendantTextElement
        )
        if rootIsUsable, !shouldSearchDescendants {
            return element
        }
        guard shouldSearchDescendants else {
            return nil
        }

        var queue: [(element: AXUIElement, depth: Int)] = [(element, 0)]
        let maxDepth = shouldSearchDescendants ? 32 : 8
        let maxNodes = shouldSearchDescendants ? 2_500 : 240
        var visited = 0
        var seen = Set<String>()
        var bestCandidate: (element: AXUIElement, score: Int, tieBreaker: CGFloat)?

        let rootIdentity = AXCaretHelper.elementIdentity(for: element)

        while !queue.isEmpty, visited < maxNodes {
            let (candidate, depth) = queue.removeFirst()
            let identity = AXCaretHelper.elementIdentity(for: candidate)
            guard seen.insert(identity).inserted else { continue }
            visited += 1

            if identity != rootIdentity, isUsableTextElement(candidate) {
                let score = textElementCandidateScore(candidate)
                let frame = fieldRect(for: candidate)
                let tieBreaker = shouldSearchDescendants
                    ? (frame?.maxY ?? -.greatestFiniteMagnitude)
                    : -(frame?.minY ?? .greatestFiniteMagnitude)
                if bestCandidate == nil
                    || score > bestCandidate!.score
                    || (score == bestCandidate!.score && tieBreaker > bestCandidate!.tieBreaker) {
                    bestCandidate = (candidate, score, tieBreaker)
                }
            }

            guard depth < maxDepth else { continue }
            for child in AXCaretHelper.childElements(of: candidate) {
                queue.append((child, depth + 1))
            }
        }

        return bestCandidate?.element ?? (rootIsUsable ? element : nil)
    }

    private static func isWebContainerRole(_ element: AXUIElement) -> Bool {
        let role = AXCaretHelper.stringValue(for: kAXRoleAttribute as CFString, on: element)
        let subrole = AXCaretHelper.stringValue(for: kAXSubroleAttribute as CFString, on: element)
        return role == "AXWebArea"
            || role == "AXDocument"
            || subrole == "AXWebArea"
            || subrole == "AXDocument"
    }

    private static func isUsableTextElement(_ element: AXUIElement) -> Bool {
        guard isTextRole(element) else { return false }
        if AXCaretHelper.rangeValue(for: kAXSelectedTextRangeAttribute as CFString, on: element) != nil {
            return true
        }
        return AXCaretHelper.stringValue(for: kAXValueAttribute as CFString, on: element) != nil
    }

    private static func isTextRole(_ element: AXUIElement) -> Bool {
        let role = AXCaretHelper.stringValue(for: kAXRoleAttribute as CFString, on: element)
        let subrole = AXCaretHelper.stringValue(for: kAXSubroleAttribute as CFString, on: element)
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
        let role = AXCaretHelper.stringValue(for: kAXRoleAttribute as CFString, on: element) ?? ""
        let subrole = AXCaretHelper.stringValue(for: kAXSubroleAttribute as CFString, on: element) ?? ""
        let metadata = [
            AXCaretHelper.stringValue(for: kAXTitleAttribute as CFString, on: element),
            AXCaretHelper.stringValue(for: kAXDescriptionAttribute as CFString, on: element),
            AXCaretHelper.stringValue(for: kAXPlaceholderValueAttribute as CFString, on: element)
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        var score = 0
        if AXCaretHelper.boolValue(for: kAXFocusedAttribute as CFString, on: element) == true {
            score += 1_000
        }
        if AXCaretHelper.rangeValue(for: kAXSelectedTextRangeAttribute as CFString, on: element) != nil {
            score += 300
        }
        if AXCaretHelper.isAttributeSettable(kAXValueAttribute as CFString, on: element) {
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

    nonisolated static func caretQuality(from label: String?) -> CaretGeometryQuality {
        switch label {
        case "exact": .exact
        case "derived": .derived
        case "estimated": .estimated
        default: .unknown
        }
    }

    private static func resolvedCaretGeometry(
        element: AXUIElement,
        target: AppTarget,
        beforeCursor: String,
        afterCursor: String,
        fieldRect: CGRect?,
        current: CapturedCaretGeometry,
        repairLineMismatchedCaret: Bool
    ) -> CapturedCaretGeometry {
        var resolved = current
        for fallback in appCaretGeometryFallbacks {
            if let override = fallback.caretGeometry(
                target: target,
                beforeCursor: beforeCursor,
                afterCursor: afterCursor,
                element: element,
                fieldRect: fieldRect,
                current: current
            ) {
                resolved = override
                break
            }
        }
        return Self.repairedCaretGeometry(
            beforeCursor: beforeCursor,
            fieldRect: fieldRect,
            current: resolved,
            repairLineMismatchedCaret: repairLineMismatchedCaret
        )
    }

    nonisolated static func repairedCaretGeometry(
        beforeCursor: String,
        fieldRect: CGRect?,
        current: CapturedCaretGeometry,
        repairLineMismatchedCaret: Bool = false
    ) -> CapturedCaretGeometry {
        guard let fieldRect,
              !fieldRect.isEmpty,
              fieldRect.width > 10,
              fieldRect.height >= 40,
              let rect = current.rect,
              !rect.isEmpty else {
            return current
        }

        let caretLocation = (beforeCursor as NSString).length
        let selection = NSRange(location: caretLocation, length: 0)
        let estimatedLayout = AXCaretGeometryResolver.estimatedSoftWrappedCaretLayout(
            in: beforeCursor,
            selection: selection,
            availableWidth: fieldRect.width
        )
        let hasWrappedContinuation = estimatedLayout.lineIndex > 0
        guard hasWrappedContinuation else {
            return current
        }

        let estimatedRect = AXCaretGeometryResolver.conservativeEstimatedCaretRect(
            in: fieldRect,
            text: beforeCursor,
            selection: selection,
            blankLineHeightBias: repairLineMismatchedCaret ? 1 : 0,
            paragraphBreakSpacingLineHeightMultiplier: repairLineMismatchedCaret ? 1.5 : 0
        )

        let looksLikeContainer = AXCaretGeometryResolver.rectLooksLikeTextContainer(
            rect,
            anchor: fieldRect
        )
        let trailingEdgeTolerance = max(8, min(24, fieldRect.width * 0.03))
        let estimatedAwayFromTrailingEdge = estimatedRect.minX < fieldRect.maxX - max(48, fieldRect.width * 0.10)
        let stuckAtTrailingEdge = rect.maxX >= fieldRect.maxX - trailingEdgeTolerance
            && estimatedAwayFromTrailingEdge
        let verticalTolerance = max(10, estimatedRect.height * 0.75)
        let verticallyCompatible = abs(rect.midY - estimatedRect.midY) <= verticalTolerance
        let caretSized = rect.width <= max(8, estimatedRect.width * 4)
            && rect.height <= max(32, estimatedRect.height * 1.8)
        let horizontallyNearField = rect.maxX >= fieldRect.minX - 8
            && rect.minX <= fieldRect.maxX + 8
        let lineMismatchedCaret = repairLineMismatchedCaret
            && current.quality != .estimated
            && caretSized
            && horizontallyNearField
            && !verticallyCompatible
        let estimatedFrameCaretNeedsParagraphRepair = repairLineMismatchedCaret
            && current.quality == .estimated
            && Self.canRepairEstimatedFrameSource(current.source)
            && caretSized
            && horizontallyNearField
            && !verticallyCompatible

        guard looksLikeContainer
            || (stuckAtTrailingEdge && verticallyCompatible)
            || lineMismatchedCaret
            || estimatedFrameCaretNeedsParagraphRepair else {
            return current
        }

        return CapturedCaretGeometry(
            rect: estimatedRect,
            source: "AXFrameEstimateAfterInvalidCaret(\(current.source ?? "unknown"))",
            quality: .estimated
        )
    }

    private nonisolated static func canRepairEstimatedFrameSource(_ source: String?) -> Bool {
        guard let source else { return true }
        return source.hasPrefix("AXFrameEstimate")
    }

    private static func fieldRect(for element: AXUIElement) -> CGRect? {
        guard let axFrame = AXCaretHelper.rectValue(for: "AXFrame" as CFString, on: element),
              !axFrame.isEmpty else {
            return nil
        }
        return AXCaretHelper.cocoaRect(fromAccessibilityRect: axFrame)
    }
}

/// Helpers that walk up the AX tree to populate the environment-level fields on `AppTarget`.
@MainActor
enum AppTargetResolver {
    static func bundleIdentifier(for element: AXUIElement) -> String {
        AXCaretHelper.pid(of: element)
            .flatMap { NSRunningApplication(processIdentifier: $0) }?
            .bundleIdentifier
            ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            ?? "unknown"
    }

    static func resolveAppTarget(for element: AXUIElement) -> AppTarget {
        let pid = AXCaretHelper.pid(of: element)
        let runningApp: NSRunningApplication? = pid
            .flatMap { NSRunningApplication(processIdentifier: $0) }
            ?? NSWorkspace.shared.frontmostApplication

        let bundleId = runningApp?.bundleIdentifier ?? "unknown"
        let appName = runningApp?.localizedName ?? "Unknown"

        let window = findAncestorWindow(of: element)
        let windowTitle = window.flatMap {
            AXCaretHelper.stringValue(for: kAXTitleAttribute as CFString, on: $0)
        }

        let domain = resolveBrowserDomain(for: element, window: window, windowTitle: windowTitle)

        return AppTarget(
            bundleIdentifier: bundleId,
            appName: appName,
            windowTitle: windowTitle,
            domain: domain
        )
    }

    static func collectLabels(for element: AXUIElement) -> [String] {
        var labels: [String] = []

        if let title = AXCaretHelper.stringValue(for: kAXTitleAttribute as CFString, on: element),
           !title.isEmpty {
            labels.append(title)
        }
        if let description = AXCaretHelper.stringValue(for: kAXDescriptionAttribute as CFString, on: element),
           !description.isEmpty {
            labels.append(description)
        }
        if let help = AXCaretHelper.stringValue(for: kAXHelpAttribute as CFString, on: element),
           !help.isEmpty {
            labels.append(help)
        }
        // Resolve `AXTitleUIElement` -> its title/value (common in macOS forms).
        if let titleElement = AXCaretHelper.copyAttributeValue(kAXTitleUIElementAttribute as CFString, on: element),
           CFGetTypeID(titleElement) == AXUIElementGetTypeID() {
            let labelElement = unsafeBitCast(titleElement, to: AXUIElement.self)
            if let label = AXCaretHelper.stringValue(for: kAXValueAttribute as CFString, on: labelElement)
                ?? AXCaretHelper.stringValue(for: kAXTitleAttribute as CFString, on: labelElement),
               !label.isEmpty {
                labels.append(label)
            }
        }
        return labels
    }

    static func collectTraits(
        for element: AXUIElement,
        target: AppTarget,
        placeholder: String?,
        labels: [String],
        webAppClassifier: AppBundleWebAppClassifier = .shared
    ) -> TextFieldTraits {
        let role = AXCaretHelper.stringValue(for: kAXRoleAttribute as CFString, on: element) ?? ""
        let subrole = AXCaretHelper.stringValue(for: kAXSubroleAttribute as CFString, on: element) ?? ""
        let isSecure = role == "AXSecureTextField"
            || subrole == "AXSecureTextField"
            || AXCaretHelper.boolValue(for: "AXProtectedContent" as CFString, on: element) == true
        let metadata = ([placeholder] + labels.map(Optional.some))
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        return TextFieldTraits(
            isSecureTextEntry: isSecure,
            isPasswordField: fieldMetadataLooksPasswordLike(metadata),
            isPasswordManagerContext: passwordManagerBundleIDs.contains(target.bundleIdentifier),
            isWebField: findAncestorWebArea(of: element) != nil
                || webAppClassifier.isWebBacked(bundleIdentifier: target.bundleIdentifier),
            isTerminalLike: terminalBundleIDs.contains(target.bundleIdentifier)
        )
    }

    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "com.mitchellh.ghostty.debug",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm"
    ]

    private static let passwordManagerBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.apple.Passwords",
        "com.bitwarden.desktop",
        "com.callpod.keepermac.lite",
        "com.dashlane.Dashlane",
        "com.dashlane.dashlanephonefinal",
        "com.keepersecurity.passwordmanager",
        "com.lastpass.LastPass",
        "com.lastpass.lastpassmacdesktop"
    ]

    private static func fieldMetadataLooksPasswordLike(_ metadata: String) -> Bool {
        guard !metadata.isEmpty else { return false }
        let terms = [
            "password", "passcode", "passphrase", "master key", "secret key",
            "security code", "verification code", "one-time code", "one time code",
            "totp", "2fa", "mfa", "cvv", "cvc"
        ]
        return terms.contains { metadata.contains($0) }
    }

    private static func findAncestorWindow(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        var depth = 0
        while let node = current, depth < 12 {
            let role = AXCaretHelper.stringValue(for: kAXRoleAttribute as CFString, on: node)
            if role == kAXWindowRole as String {
                return node
            }
            current = AXCaretHelper.parentElement(of: node)
            depth += 1
        }
        return nil
    }

    private static func findAncestorWebArea(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        var depth = 0
        while let node = current, depth < 12 {
            let role = AXCaretHelper.stringValue(for: kAXRoleAttribute as CFString, on: node)
            if role == "AXWebArea" {
                return node
            }
            current = AXCaretHelper.parentElement(of: node)
            depth += 1
        }
        return nil
    }

    /// Best-effort browser domain extraction:
    /// 1. Walk up to the nearest `AXWebArea`; read its `AXURL` attribute (returned as `NSURL`).
    /// 2. Fall back to parsing the trailing component of the window title.
    private static func resolveBrowserDomain(
        for element: AXUIElement,
        window: AXUIElement?,
        windowTitle: String?
    ) -> String? {
        if let url = findWebAreaURL(from: element) {
            return url.host
        }
        if let window, let url = findWebAreaURL(from: window) {
            return url.host
        }
        // Fallback: try a final token of the window title; many browsers append the domain.
        if let title = windowTitle,
           let lastToken = title
            .split(separator: " ")
            .last
            .map(String.init),
           lastToken.contains("."),
           let url = URL(string: lastToken.hasPrefix("http") ? lastToken : "https://\(lastToken)") {
            return url.host
        }
        return nil
    }

    private static func findWebAreaURL(from element: AXUIElement) -> URL? {
        // Walk up to find an AXWebArea; bounded so we don't roam the full tree.
        var current: AXUIElement? = element
        var depth = 0
        while let node = current, depth < 12 {
            let role = AXCaretHelper.stringValue(for: kAXRoleAttribute as CFString, on: node)
            if role == "AXWebArea" {
                if let value = AXCaretHelper.copyAttributeValue("AXURL" as CFString, on: node) {
                    if let url = value as? URL { return url }
                    if let nsURL = value as? NSURL { return nsURL as URL }
                    if let urlString = value as? String, let url = URL(string: urlString) { return url }
                }
                return nil
            }
            current = AXCaretHelper.parentElement(of: node)
            depth += 1
        }
        return nil
    }
}
