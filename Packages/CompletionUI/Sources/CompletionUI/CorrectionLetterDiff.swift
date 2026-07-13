import Foundation

/// Letter-level split between a misspelled word and its correction, so the badge can strike
/// through only the letters that are actually wrong (ADR-119) instead of the whole word:
/// `definately → definitely` renders as defin~a~tely → defin**i**tely.
///
/// The split is the longest common prefix, then the longest common suffix of the remainders
/// (never overlapping the prefix). Either core may be empty — a pure insertion (`wich → which`)
/// has an empty original core and nothing to strike; a pure deletion has an empty replacement
/// core and nothing to embolden.
public struct CorrectionLetterDiff: Equatable, Sendable {
    public let prefix: String
    public let originalCore: String
    public let replacementCore: String
    public let suffix: String

    public static func between(_ original: String, _ replacement: String) -> CorrectionLetterDiff {
        let o = Array(original)
        let r = Array(replacement)

        var prefixLength = 0
        while prefixLength < o.count, prefixLength < r.count, o[prefixLength] == r[prefixLength] {
            prefixLength += 1
        }

        var suffixLength = 0
        while suffixLength < o.count - prefixLength,
              suffixLength < r.count - prefixLength,
              o[o.count - 1 - suffixLength] == r[r.count - 1 - suffixLength] {
            suffixLength += 1
        }

        return CorrectionLetterDiff(
            prefix: String(o.prefix(prefixLength)),
            originalCore: String(o[prefixLength..<(o.count - suffixLength)]),
            replacementCore: String(r[prefixLength..<(r.count - suffixLength)]),
            suffix: String(o.suffix(suffixLength))
        )
    }
}
