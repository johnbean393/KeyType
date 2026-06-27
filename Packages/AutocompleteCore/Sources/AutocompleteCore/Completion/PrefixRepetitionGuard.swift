import Foundation

/// Detects completions that would create a verbatim repetition loop by reproducing a phrase already
/// present in the recent text before the cursor.
///
/// The failure mode this guards against: the model predicts " i want to write about" after
/// "...AI meetup." because that exact phrase already appeared earlier in the text. If the user
/// accepts it, the sentence repeats — and the model will predict the same continuation again,
/// looping indefinitely.
///
/// Two repetition shapes are caught, both on case-folded alphanumerics within the last
/// `lookbackCharacters` of `beforeCursor`:
///
/// 1. **Whole-completion** — the entire suggestion already appears verbatim in the recent text. A
///    strong signal, so a short match (`minimumAlphanumericLength`) is enough.
/// 2. **Leading** — the suggestion *begins* by reproducing a recent phrase and then diverges
///    ("…access the OpenAI" + " API to do X"). The whole string is no longer a substring, so shape 1
///    misses it; this catches it when the repeated leading run is long enough
///    (`minimumLeadingRepeat`) to be a genuine loop rather than a chance word collision.
///
/// The minimum lengths keep short common phrases ("the", "and") from triggering false positives.
public enum PrefixRepetitionGuard {

    /// `true` when `completion` reproduces a phrase that already appears in the recent prefix,
    /// meaning accepting it would create a repetition.
    public static func repeatsPrefix(
        completion: String,
        beforeCursor: String,
        lookbackCharacters: Int = 300,
        minimumAlphanumericLength: Int = 8,
        minimumLeadingRepeat: Int = 16
    ) -> Bool {
        let normalizedCompletion = AlphanumericNormalizer.normalize(completion)

        // Only look back a bounded window — we don't want to suppress completions that share a
        // common phrase with text written hours ago in a very long document.
        let lookback = String(beforeCursor.suffix(lookbackCharacters))
        let normalizedPrefix = AlphanumericNormalizer.normalize(lookback)

        // Shape 1 (whole) catches a short verbatim repeat; shape 2 (leading) catches a repeat that
        // then diverges. See `RepeatedSpanDetector`.
        return RepeatedSpanDetector.reproduces(
            normalizedCompletion: normalizedCompletion,
            within: normalizedPrefix,
            minimumWhole: minimumAlphanumericLength,
            minimumLeading: minimumLeadingRepeat
        )
    }
}
