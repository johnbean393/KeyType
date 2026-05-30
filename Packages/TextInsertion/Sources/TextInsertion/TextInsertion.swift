import AppCompatibility
import AppKit
import AutocompleteCore
import Foundation

public enum InsertionStrategy: Equatable {
    case pasteboardPaste
    case pasteAndMatchStyle
    case characterInjection
    case chunkedStringInjection(size: Int)
    case firstWordOnly
}

public struct InsertionPlan: Equatable {
    public var text: String
    public var strategy: InsertionStrategy
    public var restorePasteboard: Bool
    public var useNonBreakingSpaceWorkaround: Bool
    public var backspaceAfterPaste: Bool

    public init(
        text: String,
        strategy: InsertionStrategy = .pasteboardPaste,
        restorePasteboard: Bool = true,
        useNonBreakingSpaceWorkaround: Bool = false,
        backspaceAfterPaste: Bool = false
    ) {
        self.text = text
        self.strategy = strategy
        self.restorePasteboard = restorePasteboard
        self.useNonBreakingSpaceWorkaround = useNonBreakingSpaceWorkaround
        self.backspaceAfterPaste = backspaceAfterPaste
    }
}

public protocol CompletionInserting {
    func planInsertion(candidate: CompletionCandidate, context: TextFieldContext) -> InsertionPlan
    func insert(plan: InsertionPlan) async throws
}

public struct InsertionPlanner {
    private let compatibilityStore: AppCompatibilityStore

    public init(compatibilityStore: AppCompatibilityStore = AppCompatibilityStore()) {
        self.compatibilityStore = compatibilityStore
    }

    public func plan(candidate: CompletionCandidate, context: TextFieldContext) -> InsertionPlan {
        let policy = compatibilityStore.policy(for: context)

        let strategy: InsertionStrategy
        if let chunkSize = policy.stringInjectionChunkSize {
            strategy = .chunkedStringInjection(size: chunkSize)
        } else if policy.insertionRequiresPasteAndMatchStyle {
            strategy = .pasteAndMatchStyle
        } else {
            strategy = .pasteboardPaste
        }

        let text = policy.insertionRequiresNonBreakingSpace
            ? candidate.text.replacingOccurrences(of: " ", with: "\u{00a0}")
            : candidate.text

        return InsertionPlan(
            text: text,
            strategy: strategy,
            restorePasteboard: true,
            useNonBreakingSpaceWorkaround: policy.insertionRequiresNonBreakingSpace,
            backspaceAfterPaste: policy.insertionRequiresBackspaceAfterPaste
        )
    }
}

// MARK: - Synthesis seams

/// Keyboard-synthesis seam so insertion logic is unit-testable with a recording mock — the real
/// implementation fires `CGEvent`s, which can't run headlessly in `swift test`.
public protocol KeystrokeSynthesizing {
    /// ⌘V.
    func paste()
    /// ⌘⌥⇧V (Paste and Match Style).
    func pasteAndMatchStyle()
    /// Inject `string` directly as Unicode keyboard input (no pasteboard).
    func type(_ string: String)
    /// One backspace / forward-delete keystroke.
    func deleteBackward()
}

/// Pasteboard seam. The implementation owns its own saved snapshot so callers only sequence
/// `save()` → `write(_:)` → `restore()`; a mock can record that order.
public protocol CompletionPasteboard: AnyObject {
    func save()
    func write(_ string: String)
    func restore()
}

// MARK: - Real implementations

/// Synthesises real keystrokes via `CGEvent`. Requires Accessibility permission (granted at
/// onboarding) and App Sandbox disabled (ADR-005).
public final class CGEventKeystrokeSynthesizer: KeystrokeSynthesizing {
    private let source = CGEventSource(stateID: .combinedSessionState)
    private static let keyV: CGKeyCode = 9
    private static let keyDelete: CGKeyCode = 51

    public init() {}

    public func paste() { sendShortcut(Self.keyV, flags: .maskCommand) }

    public func pasteAndMatchStyle() {
        sendShortcut(Self.keyV, flags: [.maskCommand, .maskAlternate, .maskShift])
    }

    public func deleteBackward() { sendShortcut(Self.keyDelete, flags: []) }

    public func type(_ string: String) {
        guard !string.isEmpty else { return }
        var utf16 = Array(string.utf16)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            event.post(tap: .cghidEventTap)
        }
    }

    private func sendShortcut(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }
}

/// `CompletionPasteboard` over `NSPasteboard.general`. Snapshots every item by copying its data
/// per type into fresh `NSPasteboardItem`s, so restore survives the system having read the items
/// during paste (re-adding the original item objects after a read is unreliable).
public final class SystemPasteboard: CompletionPasteboard {
    private let pasteboard: NSPasteboard
    private var saved: [NSPasteboardItem] = []

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public func save() {
        saved = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    public func write(_ string: String) {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    public func restore() {
        pasteboard.clearContents()
        if !saved.isEmpty {
            pasteboard.writeObjects(saved)
        }
        saved = []
    }
}

// MARK: - Inserter

/// Executes an `InsertionPlan`: pasteboard-based strategies save the clipboard, write the
/// completion, synthesise the paste keystroke, optionally backspace, then restore the clipboard
/// after a short delay (so the target app reads the pasteboard before we put the user's content
/// back — see ADR-016 for the timing trade-off). Injection strategies type the text directly and
/// never touch the pasteboard.
public final class PasteboardCompletionInserter: CompletionInserting {
    private let planner: InsertionPlanner
    private let synthesizer: KeystrokeSynthesizing
    private let pasteboard: CompletionPasteboard
    private let restoreDelayNanoseconds: UInt64

    public init(
        planner: InsertionPlanner = InsertionPlanner(),
        synthesizer: KeystrokeSynthesizing = CGEventKeystrokeSynthesizer(),
        pasteboard: CompletionPasteboard = SystemPasteboard(),
        restoreDelayNanoseconds: UInt64 = 120_000_000
    ) {
        self.planner = planner
        self.synthesizer = synthesizer
        self.pasteboard = pasteboard
        self.restoreDelayNanoseconds = restoreDelayNanoseconds
    }

    public func planInsertion(candidate: CompletionCandidate, context: TextFieldContext) -> InsertionPlan {
        planner.plan(candidate: candidate, context: context)
    }

    public func insert(plan: InsertionPlan) async throws {
        guard !plan.text.isEmpty else { return }

        switch plan.strategy {
        case .pasteboardPaste:
            try await pasteThenRestore(plan.text, matchStyle: false, plan: plan)
        case .pasteAndMatchStyle:
            try await pasteThenRestore(plan.text, matchStyle: true, plan: plan)
        case .firstWordOnly:
            try await pasteThenRestore(Self.firstWord(of: plan.text), matchStyle: false, plan: plan)
        case .characterInjection:
            for character in plan.text {
                synthesizer.type(String(character))
            }
            finishInjection(plan: plan)
        case let .chunkedStringInjection(size):
            for chunk in Self.chunks(of: plan.text, size: size) {
                synthesizer.type(chunk)
            }
            finishInjection(plan: plan)
        }
    }

    // MARK: - Strategy execution

    private func pasteThenRestore(_ text: String, matchStyle: Bool, plan: InsertionPlan) async throws {
        guard !text.isEmpty else { return }
        pasteboard.save()
        pasteboard.write(text)

        if matchStyle {
            synthesizer.pasteAndMatchStyle()
        } else {
            synthesizer.paste()
        }

        if plan.backspaceAfterPaste {
            synthesizer.deleteBackward()
        }

        if plan.restorePasteboard {
            if restoreDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: restoreDelayNanoseconds)
            }
            pasteboard.restore()
        }
    }

    private func finishInjection(plan: InsertionPlan) {
        if plan.backspaceAfterPaste {
            synthesizer.deleteBackward()
        }
    }

    // MARK: - Helpers

    static func firstWord(of text: String) -> String {
        // Leading whitespace + the first run up to (but not including) the next whitespace.
        var result = ""
        var seenNonSpace = false
        for character in text {
            if character.isWhitespace {
                if seenNonSpace { break }
                result.append(character)
            } else {
                seenNonSpace = true
                result.append(character)
            }
        }
        return result
    }

    static func chunks(of text: String, size: Int) -> [String] {
        guard size > 0 else { return [text] }
        var result: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[index..<end]))
            index = end
        }
        return result
    }
}
