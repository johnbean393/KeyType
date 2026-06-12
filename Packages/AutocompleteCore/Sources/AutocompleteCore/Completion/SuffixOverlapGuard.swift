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
        duplicationStart(
            completion: completion,
            beforeCursor: beforeCursor,
            afterCursor: afterCursor,
            minimumOverlap: minimumOverlap,
            minimumContainedOverlap: minimumContainedOverlap
        ) != nil
    }

    /// `true` when the completion exactly re-emits the start of `afterCursor`, including very short
    /// fills such as `"E."` before `"E. Havens"`. The broader overlap guard intentionally has a
    /// minimum length to avoid suppressing coincidental shared runs; this helper is only for the
    /// boundary-aligned exact-prefix case where accepting would visibly duplicate the suffix.
    public static func duplicatesExactSuffixPrefix(completion: String, afterCursor: String) -> Bool {
        let normalizedCompletion = normalizedAlphanumerics(completion)
        let normalizedSuffix = normalizedAlphanumerics(afterCursor)
        guard !normalizedCompletion.isEmpty, !normalizedSuffix.isEmpty else { return false }
        return normalizedSuffix.hasPrefix(normalizedCompletion)
    }

    /// Number of leading **characters of the original `completion`** to keep so that the kept text
    /// stops right where the completion begins reproducing `afterCursor`. Used to *salvage* a
    /// mid-line / FIM branch by truncating it at the suffix-overlap point instead of discarding it
    /// (see ADR-057). Return values:
    ///
    /// - `nil`  — no overlap; keep the whole completion (caller does not truncate).
    /// - `0`    — the completion is a suffix copy from the very start; nothing to keep (drop it).
    /// - `n > 0` — keep the first `n` characters (the genuine "middle"), drop the duplicating tail.
    ///
    /// The overlap is detected on case-folded alphanumerics (same as `duplicatesSuffix`); the
    /// alphanumeric offset is then mapped back to a whole-character count of the *original* string,
    /// rounding **down** so a truncation can never include part of the duplicated suffix.
    public static func nonDuplicatingPrefixLength(
        completion: String,
        beforeCursor: String,
        afterCursor: String,
        minimumOverlap: Int = 3,
        minimumContainedOverlap: Int = 8
    ) -> Int? {
        guard let normalizedStart = duplicationStart(
            completion: completion,
            beforeCursor: beforeCursor,
            afterCursor: afterCursor,
            minimumOverlap: minimumOverlap,
            minimumContainedOverlap: minimumContainedOverlap
        ) else { return nil }
        return originalPrefixCharacterCount(of: completion, keepingFirstAlphanumerics: normalizedStart)
    }

    // MARK: - Overlap detection (shared by both public entry points)

    /// The index, in **normalized-alphanumeric space**, at which `completion` starts reproducing
    /// `afterCursor`, or `nil` when there is no qualifying overlap. The three duplication shapes and
    /// their guards exactly mirror the original `duplicatesSuffix` logic, so its boolean result is
    /// unchanged; this just additionally surfaces *where* the duplication begins.
    static func duplicationStart(
        completion: String,
        beforeCursor: String,
        afterCursor: String,
        minimumOverlap: Int,
        minimumContainedOverlap: Int
    ) -> Int? {
        let normalizedCompletion = normalizedAlphanumerics(completion)
        let normalizedSuffix = normalizedAlphanumerics(afterCursor)
        guard normalizedCompletion.count >= minimumOverlap, !normalizedSuffix.isEmpty else {
            return nil
        }

        // 1. Boundary-aligned duplication: the whole completion copies the head of the suffix.
        if normalizedSuffix.hasPrefix(normalizedCompletion) { return 0 }

        // 2. Suffix-contained duplication: the completion already includes the entire upcoming
        //    suffix, so inserting it would re-type text the user already has. Requires a substantial
        //    suffix so a short common run can't trip it. The duplication begins where the suffix
        //    first appears inside the completion — everything before that is the genuine middle.
        if normalizedSuffix.count >= minimumContainedOverlap,
           let range = normalizedCompletion.range(of: normalizedSuffix) {
            return normalizedCompletion.distance(from: normalizedCompletion.startIndex, to: range.lowerBound)
        }

        // 3. Mid-word duplication. Only when the caret sits inside a word (the char before the caret
        //    and the char after it are both word characters) and the completion is substantial. Here
        //    the completion lies wholly within the suffix, so the entire thing is a copy.
        guard endsInWordCharacter(beforeCursor), normalizedCompletion.count >= 6 else { return nil }
        let straddleRemainder = normalizedAlphanumerics(leadingWordRun(afterCursor))
        guard !straddleRemainder.isEmpty else { return nil }
        if let range = normalizedSuffix.range(of: normalizedCompletion) {
            let offset = normalizedSuffix.distance(from: normalizedSuffix.startIndex, to: range.lowerBound)
            return offset <= straddleRemainder.count ? 0 : nil
        }
        return nil
    }

    /// Largest number of leading whole characters of `text` whose case-folded alphanumeric scalars
    /// number at most `count`. Mirrors `normalizedAlphanumerics` (lowercase first, count alphanumeric
    /// scalars) so the mapping from normalized-alphanumeric index back to original characters is
    /// exact, and rounds down at character boundaries.
    static func originalPrefixCharacterCount(of text: String, keepingFirstAlphanumerics count: Int) -> Int {
        guard count > 0 else { return 0 }
        var alphanumericSeen = 0
        var kept = 0
        for character in text {
            let contribution = character.lowercased().unicodeScalars.reduce(0) { partial, scalar in
                partial + (CharacterSet.alphanumerics.contains(scalar) ? 1 : 0)
            }
            if alphanumericSeen + contribution > count { break }
            alphanumericSeen += contribution
            kept += 1
        }
        return kept
    }

    // MARK: - Helpers

    /// Case-folded string of only the alphanumeric scalars — drops whitespace, punctuation, and any
    /// stray symbol glyphs the model prepends, so the comparison is on real content.
    static func normalizedAlphanumerics(_ text: String) -> String {
        AlphanumericNormalizer.normalize(text)
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
