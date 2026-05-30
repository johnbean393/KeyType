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

    public init(
        context: TextFieldContext,
        caretRect: CGRect?,
        caretSource: String?,
        caretQuality: String?
    ) {
        self.context = context
        self.caretRect = caretRect
        self.caretSource = caretSource
        self.caretQuality = caretQuality
    }
}

@MainActor
public struct FocusedFieldReader {
    private let resolver: AXCaretGeometryResolver

    public nonisolated init(resolver: AXCaretGeometryResolver = AXCaretGeometryResolver()) {
        self.resolver = resolver
    }

    /// Read the focused AX element into a snapshot. Returns nil if the element has no AX
    /// value (likely not a text-bearing field).
    public func snapshot(of element: AXUIElement) -> FocusedFieldSnapshot? {
        let rawValue = AXCaretHelper.stringValue(for: kAXValueAttribute as CFString, on: element) ?? ""
        let axRange = AXCaretHelper.rangeValue(for: kAXSelectedTextRangeAttribute as CFString, on: element)
        let selectedTextAttr = AXCaretHelper.stringValue(for: kAXSelectedTextAttribute as CFString, on: element)

        // Selectable text fields almost always expose either AXValue or AXSelectedTextRange.
        // If neither is present, fall back to whatever we can glean (still produces a
        // bundle-id-only context so the rest of the pipeline can decide).
        let split = TextCursorSplitter.split(text: rawValue, axRange: axRange)

        // Caret rect (may be nil for elements without supported geometry attributes).
        let caretGeometry = resolver.resolveCaretRect(for: element)

        // Selection: prefer the explicit AXSelectedText, fall back to the slice from the split.
        let effectiveSelected: String? = {
            if let selectedTextAttr, !selectedTextAttr.isEmpty { return selectedTextAttr }
            return split.selectedText.isEmpty ? nil : split.selectedText
        }()

        let selection = TextSelection(
            selectedText: effectiveSelected,
            range: split.range
        )

        let geometry = TextFieldGeometry(
            cursorRect: caretGeometry?.rect,
            fieldRect: Self.fieldRect(for: element),
            isAtEndOfLine: split.isAtEndOfLine,
            isRightToLeft: WritingDirection.isRightToLeft(split.beforeCursor.isEmpty ? rawValue : split.beforeCursor),
            cursorRectQuality: Self.caretQuality(from: caretGeometry?.qualityLabel)
        )

        let target = AppTargetResolver.resolveAppTarget(for: element)

        let placeholder = AXCaretHelper.stringValue(for: kAXPlaceholderValueAttribute as CFString, on: element)
        let labels = AppTargetResolver.collectLabels(for: element)
        let language = LanguageDetector.detectLanguage(in: split.beforeCursor)
        let traits = AppTargetResolver.collectTraits(
            for: element,
            target: target,
            placeholder: placeholder,
            labels: labels
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
            caretRect: caretGeometry?.rect,
            caretSource: caretGeometry?.source,
            caretQuality: caretGeometry?.qualityLabel
        )
    }

    private static func caretQuality(from label: String?) -> CaretGeometryQuality {
        switch label {
        case "exact": .exact
        case "derived": .derived
        case "estimated": .estimated
        default: .unknown
        }
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
        labels: [String]
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
            isWebField: findAncestorWebArea(of: element) != nil,
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
