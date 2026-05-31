//
//  SuffixOverlapGuard.swift
//  AutocompleteCore
//
//  Detects mid-line / fill-in-the-middle completions that merely reproduce text the user already
//  has *after* the caret.
//
//  On a small model, FIM decoding (`<|fim_prefix|>…<|fim_suffix|>…<|fim_middle|>`) frequently
//  degenerates into copying the suffix back out as the "middle" — e.g. with the caret at
//  "…level of per|formance to the RTX 5070…" the model emits "formance to the RTX 5070, so it's",
//  which is exactly the text already to the right of the cursor. Showing (and inserting) that would
//  duplicate the user's own words. Per the product principle "prefer suppression to a wrong
//  suggestion", such candidates are dropped.
//
//  The comparison is on alphanumerics only (case-folded, punctuation/whitespace/garbage glyphs
//  removed) so a stray leading "**"/"•" the model sometimes prepends doesn't defeat the match.
//

import Foundation

public enum SuffixOverlapGuard {
    /// `true` when inserting `completion` at the caret would just duplicate text already present in
    /// `afterCursor`.
    ///
    /// Three duplication shapes are caught:
    /// 1. **Boundary-aligned** — the completion reproduces the head of the suffix verbatim
    ///    (`afterCursor` normalised starts with the completion normalised).
    /// 2. **Suffix-contained** — the completion *contains* the whole upcoming suffix (e.g. the
    ///    completion finishes the straddled word and then re-types the rest: "ithub repo for KeyType."
    ///    when the suffix is "hub repo for KeyType."). Inserting it always duplicates that text.
    /// 3. **Mid-word** — the caret split a word, so the suffix opens with the remainder of that
    ///    word; the completion's copy of the downstream text then starts a few characters into the
    ///    suffix. The allowed start offset is bounded by that straddled word remainder, so this can
    ///    only fire when the caret is genuinely inside a word.
    ///
    /// Conservative by construction: it never fires when there is no suffix, and requires a
    /// meaningful overlap length, so it cannot suppress an ordinary end-of-line continuation.
    public static func duplicatesSuffix(
        completion: String,
        beforeCursor: String,
        afterCursor: String,
        minimumOverlap: Int = 3,
        minimumContainedOverlap: Int = 8
    ) -> Bool {
        let normalizedCompletion = normalizedAlphanumerics(completion)
        let normalizedSuffix = normalizedAlphanumerics(afterCursor)
        guard normalizedCompletion.count >= minimumOverlap, !normalizedSuffix.isEmpty else {
            return false
        }

        // 1. Boundary-aligned duplication.
        if normalizedSuffix.hasPrefix(normalizedCompletion) { return true }

        // 2. Suffix-contained duplication: the completion already includes the entire upcoming
        //    suffix, so inserting it would re-type text the user already has. Requires a substantial
        //    suffix so a short common run can't trip it.
        if normalizedSuffix.count >= minimumContainedOverlap, normalizedCompletion.contains(normalizedSuffix) {
            return true
        }

        // 3. Mid-word duplication. Only when the caret sits inside a word (the char before the caret
        //    and the char after it are both word characters) and the completion is substantial.
        guard endsInWordCharacter(beforeCursor), normalizedCompletion.count >= 6 else { return false }
        let straddleRemainder = normalizedAlphanumerics(leadingWordRun(afterCursor))
        guard !straddleRemainder.isEmpty else { return false }
        if let range = normalizedSuffix.range(of: normalizedCompletion) {
            let offset = normalizedSuffix.distance(from: normalizedSuffix.startIndex, to: range.lowerBound)
            return offset <= straddleRemainder.count
        }
        return false
    }

    // MARK: - Helpers

    /// Case-folded string of only the alphanumeric scalars — drops whitespace, punctuation, and any
    /// stray symbol glyphs the model prepends, so the comparison is on real content.
    static func normalizedAlphanumerics(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            result.append(scalar)
        }
        return String(result)
    }

    /// Whether the last scalar of `text` is a word character (letter or digit) — i.e. the caret is
    /// at the trailing edge of a word rather than after a space/punctuation.
    static func endsInWordCharacter(_ text: String) -> Bool {
        guard let last = text.unicodeScalars.last else { return false }
        return CharacterSet.alphanumerics.contains(last)
    }

    /// The leading run of word characters in `text` (the remainder of a word the caret split).
    static func leadingWordRun(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            guard CharacterSet.alphanumerics.contains(scalar) else { break }
            result.append(scalar)
        }
        return String(result)
    }
}
