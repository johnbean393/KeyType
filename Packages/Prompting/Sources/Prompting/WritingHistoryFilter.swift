import Foundation

/// Quality gates applied to writing-history samples before they reach the prompt.
///
/// **Junk filter** (`isProse`): history samples can contain non-prose entries — URLs captured
/// from browser address bars, UUID-bearing file references, or hex blobs. These waste prompt
/// token budget without aiding style personalization and can mislead the model.
///
/// **Relevance filter** (`filterByRelevance`): a topically-unrelated history sample (e.g. a
/// user's professional bio stored from a previous Gmail session) can cause the model to
/// paraphrase it into an unrelated draft. Applied at **generation time** with the live
/// `beforeCursor` — not inside the 2-second frozen side-context cache — so the judgment always
/// reflects what the user is currently typing.
///
/// Trade-off: `filterByRelevance` will occasionally drop stock closing phrases ("Kind regards")
/// when the email body has zero topical overlap with the sign-off. This is accepted because
/// (a) the threshold is conservative (Jaccard ≥ 0.10), (b) once the user has typed the opening
/// word of the sign-off ("Kind") the phrase is kept, and (c) preventing biography bleed into
/// unrelated emails is a higher-priority correctness concern.
public enum WritingHistoryFilter {

    // MARK: - Junk filter

    /// Returns `false` for clearly non-prose entries: bare URLs, UUID blobs, filesystem paths,
    /// or text where fewer than 65 % of characters are letters or spaces.
    public static func isProse(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Bare URL (entire text is a single URL, no surrounding prose)
        if !trimmed.contains(" ") {
            if trimmed.range(of: #"^\S+://\S+"#, options: .regularExpression) != nil {
                return false
            }
            if trimmed.hasPrefix("www.") { return false }
        }

        // Filesystem path (starts with "/" and has ≥ 3 slashes)
        if trimmed.hasPrefix("/") && trimmed.filter({ $0 == "/" }).count >= 3 {
            return false
        }

        // Low letter+space ratio catches UUID blobs, hex strings, mostly-numeric entries.
        // Example: "uuid=EF757712-3FDF-48F4-B026-DB0AEF04AC2B.jpeg" → ~38 % → rejected.
        let total = trimmed.unicodeScalars.count
        let lettersAndSpaces = trimmed.unicodeScalars.filter {
            CharacterSet.letters.contains($0) || $0 == " "
        }.count
        guard Double(lettersAndSpaces) / Double(total) >= 0.65 else { return false }

        return true
    }

    // MARK: - Relevance filter

    /// Common English function words excluded when measuring topical overlap. These are
    /// ubiquitous across writing contexts and carry no topic signal.
    public static let commonEnglishStopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for", "of", "with",
        "by", "from", "as", "is", "are", "was", "were", "be", "been", "being", "have", "has",
        "had", "do", "does", "did", "will", "would", "could", "should", "may", "might", "can",
        "it", "its", "this", "that", "these", "those", "i", "you", "he", "she", "we", "they",
        "my", "your", "his", "her", "our", "their", "which", "who", "what", "when", "where",
        "how", "all", "not", "more", "some", "about", "up", "out", "if", "no", "so", "than",
        "very", "just", "also", "there", "here", "then", "too", "into", "through",
        "even", "new", "get", "go", "first", "because", "over", "see", "know",
        "me", "him", "us", "them", "am"
    ]

    /// Filters `samples` to those with non-trivial topical overlap with `beforeCursor`.
    ///
    /// The first `recencyFloor` samples are always kept regardless of relevance — they act as
    /// style anchors: the user's most-recent writing establishes their current tone and recurring
    /// phrases even when the topic differs. Only samples beyond that floor are subject to the
    /// Jaccard gate.
    ///
    /// Returns all samples unchanged when `beforeCursor` has fewer than `minimumContentWords`
    /// non-stopword words (short openers lack enough signal to judge topic relevance).
    ///
    /// A sample is kept if the stopword-filtered, digit-filtered Jaccard similarity between its
    /// word set and `beforeCursor`'s word set is ≥ `jaccardThreshold`.
    public static func filterByRelevance(
        _ samples: [String],
        beforeCursor: String,
        jaccardThreshold: Double = 0.10,
        minimumContentWords: Int = 2,
        recencyFloor: Int = 2
    ) -> [String] {
        guard !samples.isEmpty else { return samples }
        let floor = min(recencyFloor, samples.count)
        let anchors = Array(samples.prefix(floor))
        let candidates = Array(samples.dropFirst(floor))
        guard !candidates.isEmpty else { return anchors }

        let cursorWords = contentWordSet(beforeCursor)
        guard cursorWords.count >= minimumContentWords else { return samples }

        let filtered = candidates.filter { sample in
            let sampleWords = contentWordSet(sample)
            guard !sampleWords.isEmpty else { return false }
            let intersection = cursorWords.intersection(sampleWords).count
            let union = cursorWords.union(sampleWords).count
            guard union > 0 else { return false }
            return Double(intersection) / Double(union) >= jaccardThreshold
        }
        return anchors + filtered
    }

    /// Stopword-filtered, digit-filtered lowercase content words (≥ 2 characters) in `text`.
    /// Pure-digit tokens ("25", "2024") are excluded — they are weak topic signals and cause
    /// false matches between topically unrelated samples that share a bare number.
    static func contentWordSet(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter {
                    $0.count >= 2
                        && !commonEnglishStopwords.contains($0)
                        && !$0.allSatisfy({ $0.isNumber })
                }
        )
    }
}
