import AppCompatibility
import AppKit
import ApplicationServices
import AutocompleteCore
import Foundation

public enum InsertionStrategy: Equatable {
    case pasteboardPaste
    case pasteAndMatchStyle
    case characterInjection
    case chunkedStringInjection(size: Int)
    case firstWordOnly
}

public enum TextInsertionError: Error, Equatable {
    case selectionReplacementUnavailable
}

public struct InsertionPlan: Equatable {
    public struct SelectionReplacement: Equatable {
        public var utf16Location: Int
        public var utf16Length: Int
        public var restoredCaretUTF16Location: Int?

        public init(
            utf16Location: Int,
            utf16Length: Int,
            restoredCaretUTF16Location: Int? = nil
        ) {
            self.utf16Location = max(0, utf16Location)
            self.utf16Length = max(0, utf16Length)
            self.restoredCaretUTF16Location = restoredCaretUTF16Location.map { max(0, $0) }
        }
    }

    public var text: String
    public var strategy: InsertionStrategy
    public var restorePasteboard: Bool
    public var useNonBreakingSpaceWorkaround: Bool
    public var backspaceAfterPaste: Bool
    public var deleteBackwardCount: Int
    public var selectionReplacement: SelectionReplacement?

    public init(
        text: String,
        strategy: InsertionStrategy = .pasteboardPaste,
        restorePasteboard: Bool = true,
        useNonBreakingSpaceWorkaround: Bool = false,
        backspaceAfterPaste: Bool = false,
        deleteBackwardCount: Int = 0,
        selectionReplacement: SelectionReplacement? = nil
    ) {
        self.text = text
        self.strategy = strategy
        self.restorePasteboard = restorePasteboard
        self.useNonBreakingSpaceWorkaround = useNonBreakingSpaceWorkaround
        self.backspaceAfterPaste = backspaceAfterPaste
        self.deleteBackwardCount = max(0, deleteBackwardCount)
        self.selectionReplacement = selectionReplacement
    }
}

public protocol CompletionInserting {
    func planInsertion(candidate: CompletionCandidate, context: TextFieldContext) -> InsertionPlan
    func planCorrection(candidate: CorrectionCandidate, context: TextFieldContext) -> InsertionPlan?
    func insert(plan: InsertionPlan) async throws
}

public struct InsertionPlanner {
    private let compatibilityStore: AppCompatibilityStore

    public init(compatibilityStore: AppCompatibilityStore = AppCompatibilityStore()) {
        self.compatibilityStore = compatibilityStore
    }

    public func plan(candidate: CompletionCandidate, context: TextFieldContext) -> InsertionPlan {
        basePlan(text: candidate.text, context: context)
    }

    public func planCorrection(candidate: CorrectionCandidate, context: TextFieldContext) -> InsertionPlan? {
        if let exact = exactSelectionReplacement(for: candidate, context: context) {
            return basePlan(
                text: candidate.replacement,
                context: context,
                selectionReplacement: exact
            )
        }

        guard candidate.originalRange.container == .beforeCursor,
              let range = candidate.originalRange.range(in: context.beforeCursor) else {
            return nil
        }
        let suffixToReplay = String(context.beforeCursor[range.upperBound...])
        let deleteCount = context.beforeCursor.distance(from: range.lowerBound, to: context.beforeCursor.endIndex)
        guard deleteCount >= candidate.original.count else { return nil }

        return basePlan(
            text: candidate.replacement + suffixToReplay,
            context: context,
            deleteBackwardCount: deleteCount
        )
    }

    private func basePlan(
        text rawText: String,
        context: TextFieldContext,
        deleteBackwardCount: Int = 0,
        selectionReplacement: InsertionPlan.SelectionReplacement? = nil
    ) -> InsertionPlan {
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
            ? rawText.replacingOccurrences(of: " ", with: "\u{00a0}")
            : rawText

        return InsertionPlan(
            text: text,
            strategy: strategy,
            restorePasteboard: true,
            useNonBreakingSpaceWorkaround: policy.insertionRequiresNonBreakingSpace,
            backspaceAfterPaste: policy.insertionRequiresBackspaceAfterPaste,
            deleteBackwardCount: deleteBackwardCount,
            selectionReplacement: selectionReplacement
        )
    }

    private func exactSelectionReplacement(
        for candidate: CorrectionCandidate,
        context: TextFieldContext
    ) -> InsertionPlan.SelectionReplacement? {
        let policy = compatibilityStore.policy(for: context)
        guard !policy.autocorrectDisabled else { return nil }

        let fullText = context.beforeCursor + context.afterCursor
        let charStart: Int
        let charEnd: Int
        switch candidate.originalRange.container {
        case .beforeCursor:
            charStart = candidate.originalRange.startOffset
            charEnd = candidate.originalRange.endOffset
        case .afterCursor:
            charStart = context.beforeCursor.count + candidate.originalRange.startOffset
            charEnd = context.beforeCursor.count + candidate.originalRange.endOffset
        }
        guard charStart >= 0,
              charEnd > charStart,
              charEnd <= fullText.count,
              let start = fullText.index(fullText.startIndex, offsetBy: charStart, limitedBy: fullText.endIndex),
              let end = fullText.index(fullText.startIndex, offsetBy: charEnd, limitedBy: fullText.endIndex) else {
            return nil
        }

        let nsRange = NSRange(start..<end, in: fullText)
        let caretLocation = (context.beforeCursor as NSString).length
        let replacementLength = (candidate.replacement as NSString).length
        let delta = replacementLength - nsRange.length
        let restoredCaret = nsRange.location < caretLocation ? caretLocation + delta : caretLocation
        return InsertionPlan.SelectionReplacement(
            utf16Location: nsRange.location,
            utf16Length: nsRange.length,
            restoredCaretUTF16Location: restoredCaret
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
    /// Select an exact AX text range in the currently focused field.
    func selectTextRange(location: Int, length: Int) -> Bool
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

    public init() {
        // Tag every event posted from this source so KeyType's own key taps can tell our synthesized
        // paste/typing keystrokes apart from the user's keys and ignore them. See ADR-039.
        source?.userData = SynthesizedEventMarker.userData
    }

    public func paste() { sendShortcut(Self.keyV, flags: .maskCommand) }

    public func pasteAndMatchStyle() {
        sendShortcut(Self.keyV, flags: [.maskCommand, .maskAlternate, .maskShift])
    }

    public func deleteBackward() { sendShortcut(Self.keyDelete, flags: []) }

    public func selectTextRange(location: Int, length: Int) -> Bool {
        guard let field = Self.focusedTextElement() else { return false }
        var range = CFRange(location: location, length: length)
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        let result = AXUIElementSetAttributeValue(
            field,
            kAXSelectedTextRangeAttribute as CFString,
            value
        )
        return result == .success
    }

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

    private static func focusedTextElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(focusedValue, to: AXUIElement.self)
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

    public func planCorrection(candidate: CorrectionCandidate, context: TextFieldContext) -> InsertionPlan? {
        planner.planCorrection(candidate: candidate, context: context)
    }

    public func insert(plan: InsertionPlan) async throws {
        guard !plan.text.isEmpty || plan.deleteBackwardCount > 0 else { return }

        if let selection = plan.selectionReplacement {
            guard synthesizer.selectTextRange(
                location: selection.utf16Location,
                length: selection.utf16Length
            ) else {
                throw TextInsertionError.selectionReplacementUnavailable
            }
        } else {
            for _ in 0..<plan.deleteBackwardCount {
                synthesizer.deleteBackward()
            }
        }

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

        if let location = plan.selectionReplacement?.restoredCaretUTF16Location {
            _ = synthesizer.selectTextRange(location: location, length: 0)
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
