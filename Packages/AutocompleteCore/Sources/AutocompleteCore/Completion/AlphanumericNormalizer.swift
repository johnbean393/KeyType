import Foundation

/// Shared text normalization for the content-overlap guards (`SuffixOverlapGuard`,
/// `PrefixRepetitionGuard`, `ContextEchoGuard`). Comparisons are done on case-folded alphanumeric
/// scalars only, so differences in whitespace, punctuation, and stray symbol glyphs the model
/// sometimes prepends ("**", "•") don't defeat a match.
enum AlphanumericNormalizer {
    /// Case-folded string of only the alphanumeric scalars in `text`.
    static func normalize(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            result.append(scalar)
        }
        return String(result)
    }
}
