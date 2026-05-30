//
//  SuggestionAnchor.swift
//  AutocompleteCore
//
//  Keeps a shown completion consistent with the live caret as the user keeps typing.
//
//  A suggestion is generated for one caret position (the *anchor*) but stays on screen while the
//  user types. If we treat it as static, two failures appear:
//    1. The overlay is left dangling at the old caret (it looks like it "didn't update").
//    2. Accepting it re-inserts characters the user already typed — a suggestion of "excited."
//       generated for "…be more " becomes "…be more eexcited." once the user has typed the "e".
//
//  `SuggestionAnchor.remaining` resolves this by treating the anchor as a fixed point and returning
//  only the portion of the completion still *ahead* of the live caret: as the user types the
//  suggested characters it shrinks, and the moment they diverge (or delete, or move the caret, or
//  the text after the cursor changes) it returns `nil` so the caller drops the suggestion.
//

import Foundation

public enum SuggestionAnchor {
    /// The portion of `anchorText` still ahead of the live caret, or `nil` when the suggestion no
    /// longer applies.
    ///
    /// - Parameters:
    ///   - anchorText: the caret-reconciled completion exactly as produced for the anchor context.
    ///   - anchorBefore: text before the caret when the suggestion was generated.
    ///   - anchorAfter: text after the caret when the suggestion was generated.
    ///   - liveBefore: text before the caret right now.
    ///   - liveAfter: text after the caret right now.
    ///
    /// Returns `anchorText` unchanged when nothing has moved. Returns a shorter suffix when the user
    /// has typed a leading run of `anchorText`. Returns `nil` when the text after the cursor changed,
    /// the caret moved backward / elsewhere (live prefix no longer extends the anchor prefix), or the
    /// user typed something other than the suggested characters.
    public static func remaining(
        anchorText: String,
        anchorBefore: String,
        anchorAfter: String,
        liveBefore: String,
        liveAfter: String
    ) -> String? {
        guard liveAfter == anchorAfter else { return nil }
        guard liveBefore.hasPrefix(anchorBefore) else { return nil }
        let typedSince = String(liveBefore.dropFirst(anchorBefore.count))
        if typedSince.isEmpty { return anchorText }
        guard anchorText.hasPrefix(typedSince) else { return nil }
        return String(anchorText.dropFirst(typedSince.count))
    }

    /// Convenience over `TextFieldContext` values.
    public static func remaining(
        anchorText: String,
        anchor: TextFieldContext,
        live: TextFieldContext
    ) -> String? {
        remaining(
            anchorText: anchorText,
            anchorBefore: anchor.beforeCursor,
            anchorAfter: anchor.afterCursor,
            liveBefore: live.beforeCursor,
            liveAfter: live.afterCursor
        )
    }
}
