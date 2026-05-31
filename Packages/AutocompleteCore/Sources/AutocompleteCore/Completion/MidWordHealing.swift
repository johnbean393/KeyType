import Foundation

/// Token healing for a caret sitting *inside* a word the user is typing.
///
/// A base model continues a clean token boundary far better than one that ends mid-token. When the
/// prefix is `"The weather is gre"` the model is stuck in a subword state — the natural whole-word
/// token `" great"` is unreachable because `gre` has already been committed — so a cheaper subword
/// (`"asy"` → *greasy*) can outscore the right one (`"at"` → *great*). This is a *ranking* defect,
/// not a display one (see ADR-019).
///
/// The fix: back the prompt up to the last clean token boundary (`plan().head`) and constrain
/// regeneration to the removed bytes (`plan().heal`, e.g. `" gre"`) using the decoder's
/// `requiredPrefixBytes` machinery. The model then ranks `" great"` by its natural distribution.
/// The re-emitted stem is removed from what is shown/inserted via `strip(_:heal:)`.
public enum MidWordHealing {
    /// The split for a mid-word caret, or `nil` when healing does not apply.
    ///
    /// - `head`: everything up to (and including) the last whitespace — the clean prefix to prompt.
    /// - `heal`: the last whitespace plus the partial word (`" gre"`) — the bytes regeneration must
    ///   begin with, and the slice stripped back off the completion before display.
    ///
    /// Fires only when (a) there is nothing after the cursor (an end-of-line append — mid-line
    /// mid-word is left to native fill-in-the-middle), (b) the prefix ends in a letter or number
    /// (the user is actively typing a word, not sitting on punctuation/whitespace), and (c) there is
    /// non-empty context before the word, so the model has something to continue from.
    public static func plan(for context: TextFieldContext) -> (head: String, heal: String)? {
        guard context.afterCursor.isEmpty else { return nil }
        let before = context.beforeCursor
        guard let last = before.last, last.isLetter || last.isNumber else { return nil }
        guard let wsIndex = before.lastIndex(where: { $0.isWhitespace }) else { return nil }

        let head = String(before[..<wsIndex])
        guard !head.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let heal = String(before[wsIndex...]) // the separating whitespace + the partial word
        return (head, heal)
    }

    /// Removes the healed stem from a completion so only the genuinely new text remains. The decoder
    /// guarantees a finalised completion begins with the full `heal` bytes (the required prefix was
    /// satisfied), so the stem removal is a plain prefix drop; it is defensive against a mismatch.
    ///
    /// Any whitespace immediately following the stem is also dropped. Healing only fires mid-word (the
    /// caret sits inside the word being typed), so the continuation must attach directly to the partial
    /// word — a leading separator means the model treated the forced stem as a *complete* word and
    /// started a new one (e.g. forced `" aft"` then emitted `" aft ernoon"`). Keeping that space would
    /// insert it verbatim after the partial word (`"aft" + " ernoon"` → `"aft ernoon"`); `CaretBoundary`
    /// can't catch it because the live prefix ends in a letter, not whitespace. See ADR-055.
    public static func strip(_ completion: String, heal: String) -> String {
        guard completion.hasPrefix(heal) else { return completion }
        var rest = Substring(completion.dropFirst(heal.count))
        while let first = rest.first, first.isWhitespace { rest = rest.dropFirst() }
        return String(rest)
    }
}

public extension TextFieldContext {
    /// A copy of this context with `beforeCursor` replaced — used to prompt the model from a healed
    /// token boundary (`MidWordHealing`) while the original context still describes the live caret.
    func replacingBeforeCursor(_ newBeforeCursor: String) -> TextFieldContext {
        var copy = self
        copy.beforeCursor = newBeforeCursor
        return copy
    }
}
