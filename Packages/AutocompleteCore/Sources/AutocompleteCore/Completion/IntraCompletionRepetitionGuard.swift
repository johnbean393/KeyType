import Foundation

/// Detects within-completion token-repetition degeneration — a model failure mode where the
/// same word repeats three or more times inside a single candidate ("text 1 1 1", "since 1 1 1"),
/// distinct from the across-prefix loop that `PrefixRepetitionGuard` targets.
///
/// Words are identified as contiguous runs of alphanumeric characters (case-insensitive,
/// punctuation stripped), so both "1 1 1" and "1, 1, 1" are reliably detected.
/// Fires only when a single word appears ≥ 3 times; normal prose completions never have this shape.
public enum IntraCompletionRepetitionGuard {

    /// `true` when `completion` contains a degenerate within-completion repetition loop
    /// (any single word appearing ≥ 3 times).
    public static func isDegenerate(_ completion: String) -> Bool {
        let words = contentWords(completion)
        guard words.count >= 3 else { return false }
        var counts: [Substring: Int] = [:]
        for word in words {
            let n = (counts[word, default: 0]) + 1
            counts[word] = n
            if n >= 3 { return true }
        }
        return false
    }

    /// Lowercase alphanumeric runs in `text` (punctuation and whitespace discarded).
    /// "1, 1, 1" → ["1","1","1"]; " text 1 1 1" → ["text","1","1","1"].
    static func contentWords(_ text: String) -> [Substring] {
        var words: [Substring] = []
        var start: String.Index? = nil
        let lowered = text.lowercased()
        for idx in lowered.indices {
            let ch = lowered[idx]
            if ch.isLetter || ch.isNumber {
                if start == nil { start = idx }
            } else if let s = start {
                words.append(lowered[s..<idx])
                start = nil
            }
        }
        if let s = start {
            words.append(lowered[s...])
        }
        return words
    }
}
