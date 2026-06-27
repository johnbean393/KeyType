//
//  CompletionAcceptanceController.swift
//  KeyType
//
//  Global acceptance hotkeys (M6 / ADR-016). A session-level CGEvent tap consumes the configured
//  accept keys only while a completion is visible and the app's CompletionPolicy allows Tab
//  acceptance; otherwise every key passes straight through so native behaviour is untouched.
//
//  The accept-word and accept-full hotkeys are user-configurable (SettingsStore), can be
//  unassigned, and default to Tab and Shift+Tab respectively.
//

import AppKit
import AutocompleteCore
import CoreGraphics
import os

@MainActor
final class CompletionAcceptanceController {
    weak var completionController: CompletionController?
    /// Source of the configurable acceptance hotkeys. Read on every matching key-down.
    weak var settings: SettingsStore?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let log = Logger(subsystem: "com.pattonium.KeyType", category: "acceptance")

    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<CompletionAcceptanceController>.fromOpaque(refcon).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    controller.process(type: type, event: event)
                }
            },
            userInfo: refcon
        ) else {
            log.error("Failed to create acceptance event tap (Accessibility not granted?)")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        isRunning = true
        log.debug("Completion acceptance tap installed")
    }

    func stop() {
        guard isRunning else { return }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isRunning = false
    }

    /// Decide whether to consume (return nil) or pass through (return the event). Runs on the main
    /// run loop, so `MainActor.assumeIsolated` at the call site is valid.
    private func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that times out or is interrupted; re-enable and pass through.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        // Ignore the keystrokes KeyType synthesizes for insertion (⌘V / injected text). They flow back
        // up through this session tap and would otherwise look like the user diverging — dismissing the
        // held suggestion mid word-by-word acceptance. See ADR-039.
        if event.getIntegerValueField(.eventSourceUserData) == SynthesizedEventMarker.userData {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Screen capture is observation, not editing. Let macOS handle the reserved shortcuts and
        // preserve the visible suggestion for the capture instead of treating the command as a
        // divergent non-text key. This check intentionally runs before user-configurable accept
        // shortcuts so KeyType can never steal Shift-Command-3/4/5 from the system.
        if Self.isScreenCaptureShortcut(keyCode: keyCode, flags: flags) {
            completionController?.prepareForScreenCaptureShortcut()
            return Unmanaged.passUnretained(event)
        }

        if settings?.developerOverrideTuningEnabled == true,
           Self.isDeveloperPlacementProbeShortcut(keyCode: keyCode, flags: flags) {
            _ = completionController?.showDeveloperPlacementProbeAtLatestSnapshot()
            return nil
        }

        let acceptWord = settings?.acceptWordShortcut ?? .defaultAcceptWord
        let acceptFull = settings?.acceptFullShortcut ?? .defaultAcceptFull

        // Match the full-acceptance hotkey first: it is typically the same key as accept-word plus a
        // modifier (Shift+Tab vs Tab), so checking the more specific binding first is required.
        let matchesFull = acceptFull.matches(keyCode: keyCode, flags: flags)
        let matchesWord = acceptWord.matches(keyCode: keyCode, flags: flags)

        if matchesFull || matchesWord,
           let controller = completionController, controller.canAcceptCompletion {
            if matchesFull {
                controller.acceptFullCompletion()
            } else {
                controller.acceptNextWord()
            }
            return nil // consume — the key accepted the completion instead of its native action
        }

        // Any other key-down (including an accept key with nothing to accept) is about to mutate the
        // field text or move the caret, which makes a visible suggestion stale. Dismiss it now rather
        // than waiting for the slower AX value-changed snapshot — unless the user is typing the
        // suggested characters, in which case the controller keeps it and lets the pipeline shrink it
        // in place. See ADR-037.
        completionController?.dismissStaleCompletion(
            mutation: textMutation(keyCode: keyCode, flags: flags, event: event)
        )
        return Unmanaged.passUnretained(event)
    }

    private func textMutation(keyCode: Int64, flags: CGEventFlags, event: CGEvent) -> CompletionTextMutation {
        if let text = typedText(keyCode: keyCode, flags: flags, event: event) {
            return .inserted(text)
        }
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            return .nonText
        }
        switch keyCode {
        case 51:
            return .deleteBackward
        case 117:
            return .deleteForward
        default:
            return .nonText
        }
    }

    /// The plain text a key inserts, used to tell "the user is typing the suggestion" from a divergent
    /// key. Returns `nil` for keys that don't insert plain text — ⌘/⌃-modified combos and control or
    /// navigation keys (return, tab, delete, escape, arrows/function keys) — so those always dismiss
    /// rather than accidentally matching the suggestion's first character.
    private func typedText(keyCode: Int64, flags: CGEventFlags, event: CGEvent) -> String? {
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            return nil
        }
        var chars = [UniChar](repeating: 0, count: 8)
        var length = 0
        event.keyboardGetUnicodeString(
            maxStringLength: chars.count,
            actualStringLength: &length,
            unicodeString: &chars
        )
        guard length > 0 else { return nil }
        let text = String(utf16CodeUnits: chars, count: length)
        guard let scalar = text.unicodeScalars.first else { return nil }
        // C0 controls (return, tab, delete, escape…), the DEL byte, and AppKit's private-use range for
        // arrow/function keys are not real text input.
        if scalar.value < 0x20 || scalar.value == 0x7F || (0xF700...0xF8FF).contains(scalar.value) {
            return nil
        }
        return text
    }

    nonisolated static func isScreenCaptureShortcut(keyCode: Int64, flags: CGEventFlags) -> Bool {
        ReservedSystemShortcut.isScreenCapture(
            keyCode: keyCode,
            shift: flags.contains(.maskShift),
            control: flags.contains(.maskControl),
            option: flags.contains(.maskAlternate),
            command: flags.contains(.maskCommand)
        )
    }

    nonisolated static func isDeveloperPlacementProbeShortcut(keyCode: Int64, flags: CGEventFlags) -> Bool {
        keyCode == 5 // G
            && flags.contains(.maskCommand)
            && flags.contains(.maskControl)
            && flags.contains(.maskAlternate)
            && !flags.contains(.maskShift)
    }
}
