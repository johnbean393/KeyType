//
//  AcceptanceShortcut.swift
//  KeyType
//
//  A small, persistable keyboard-shortcut value used for the completion acceptance hotkeys
//  (accept next word / accept full suggestion). Kept independent of SwiftUI's `KeyboardShortcut`
//  because acceptance is matched against a low-level `CGEvent` in the session tap, not a SwiftUI
//  command, so we need explicit key-code + modifier comparison.
//

import AppKit
import CoreGraphics

/// The four device-independent modifiers KeyType cares about, persistable as a single byte.
struct AcceptanceModifierMask: OptionSet, Sendable, Equatable {
    let rawValue: UInt8

    init(rawValue: UInt8) { self.rawValue = rawValue }

    static let shift = AcceptanceModifierMask(rawValue: 1 << 0)
    static let control = AcceptanceModifierMask(rawValue: 1 << 1)
    static let option = AcceptanceModifierMask(rawValue: 1 << 2)
    static let command = AcceptanceModifierMask(rawValue: 1 << 3)

    init(cgFlags: CGEventFlags) {
        var mask = AcceptanceModifierMask()
        if cgFlags.contains(.maskShift) { mask.insert(.shift) }
        if cgFlags.contains(.maskControl) { mask.insert(.control) }
        if cgFlags.contains(.maskAlternate) { mask.insert(.option) }
        if cgFlags.contains(.maskCommand) { mask.insert(.command) }
        self = mask
    }

    init(nsFlags: NSEvent.ModifierFlags) {
        var mask = AcceptanceModifierMask()
        let flags = nsFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift) { mask.insert(.shift) }
        if flags.contains(.control) { mask.insert(.control) }
        if flags.contains(.option) { mask.insert(.option) }
        if flags.contains(.command) { mask.insert(.command) }
        self = mask
    }

    /// Glyph string (⌃⌥⇧⌘) in Apple's canonical order, or empty for no modifiers.
    var displayString: String {
        var out = ""
        if contains(.control) { out += "\u{2303}" }
        if contains(.option) { out += "\u{2325}" }
        if contains(.shift) { out += "\u{21E7}" }
        if contains(.command) { out += "\u{2318}" }
        return out
    }
}

/// An acceptance shortcut: either unassigned, or a key code, its modifiers, and a cached display
/// label captured at record time (so we can show e.g. "A" or "⇥" without re-deriving it from the
/// keyboard layout).
struct AcceptanceShortcut: Sendable, Equatable {
    var keyCode: Int64
    var modifiers: AcceptanceModifierMask
    var label: String

    var isAssigned: Bool { keyCode >= 0 }

    var displayString: String {
        isAssigned ? modifiers.displayString + label : "Unassigned"
    }

    /// Whether `event` (a `CGEvent` key-down) matches this shortcut exactly, comparing the relevant
    /// modifier subset so e.g. a bare Tab does not also fire a Shift+Tab binding.
    func matches(keyCode eventKeyCode: Int64, flags: CGEventFlags) -> Bool {
        isAssigned && eventKeyCode == keyCode && AcceptanceModifierMask(cgFlags: flags) == modifiers
    }

    static let unassigned = AcceptanceShortcut(keyCode: -1, modifiers: [], label: "")
    static let defaultAcceptWord = AcceptanceShortcut(keyCode: 48, modifiers: [], label: "\u{21E5}")
    static let defaultAcceptFull = AcceptanceShortcut(keyCode: 48, modifiers: .shift, label: "\u{21E5}")
    static let defaultAcceptCorrection = AcceptanceShortcut(keyCode: 48, modifiers: [], label: "\u{21E5}")
}

/// Best-effort human label for a virtual key code, used by the key recorder when the pressed key
/// produces no printable character (arrows, Tab, Return, etc.).
enum KeyCodeLabels {
    private static let specials: [Int64: String] = [
        48: "\u{21E5}",   // Tab ⇥
        36: "\u{21A9}",   // Return ↩
        76: "\u{2305}",   // Enter (keypad) ⌅
        49: "Space",
        53: "\u{238B}",   // Escape ⎋
        51: "\u{232B}",   // Delete ⌫
        117: "\u{2326}",  // Forward delete ⌦
        123: "\u{2190}",  // ←
        124: "\u{2192}",  // →
        125: "\u{2193}",  // ↓
        126: "\u{2191}"   // ↑
    ]

    /// Label for a key code given the characters the key produced (may be empty for non-printing
    /// keys). Prefers the printed character (uppercased), then a known special glyph, then a
    /// numeric fallback.
    static func label(forKeyCode keyCode: Int64, characters: String?) -> String {
        if let special = specials[keyCode] { return special }
        if let characters, !characters.isEmpty {
            let trimmed = characters.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed.uppercased() }
        }
        return "Key \(keyCode)"
    }
}
