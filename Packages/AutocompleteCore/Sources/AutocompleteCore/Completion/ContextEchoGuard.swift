import Foundation

/// Shared "does this completion reproduce a phrase from some text" test, used by both
/// `PrefixRepetitionGuard` (against the recent typed prefix) and `ContextEchoGuard` (against injected
/// side context). Two shapes are detected on case-folded alphanumerics:
///
/// 1. **Whole** — the entire (normalized) completion is a substring of the text. A strong signal, so
///    a short match (`minimumWhole`) is enough.
/// 2. **Leading** — the completion *begins* with a run that appears in the text and then diverges, so
///    shape 1 misses it. A leading run of length ≥ `minimumLeading` exists iff the leading slice of
///    exactly that length is a substring (any longer contained run has it as a prefix), so one
///    `contains` decides it. The larger floor keeps chance word collisions from firing.
enum RepeatedSpanDetector {
    static func reproduces(
        normalizedCompletion: String,
        within normalizedText: String,
        minimumWhole: Int,
        minimumLeading: Int
    ) -> Bool {
        guard !normalizedCompletion.isEmpty, !normalizedText.isEmpty else { return false }

        if normalizedCompletion.count >= minimumWhole,
           normalizedText.contains(normalizedCompletion) {
            return true
        }

        guard normalizedCompletion.count >= minimumLeading else { return false }
        return normalizedText.contains(String(normalizedCompletion.prefix(minimumLeading)))
    }
}

/// Detects completions that merely parrot injected side context — clipboard contents or on-screen
/// OCR text the prompt carries but the user did not type. The small model frequently copies such
/// context verbatim instead of using it as background (e.g. text copied from a localhost page in
/// one browser surfacing as a suggestion in a different app's compose field).
///
/// Writing-history samples are intentionally NOT passed here: they are already scoped to the same
/// app/domain, and reproducing the user's own recurring phrases (a signature, a stock reply) is the
/// purpose of that personalization — suppressing it would be a regression.
public enum ContextEchoGuard {

    /// `true` when `completion` verbatim-reproduces a span of any string in `injectedContext`.
    ///
    /// `minimumWhole` is a touch higher than `PrefixRepetitionGuard`'s because the injected corpus is
    /// larger (more chance of an incidental short match); `minimumLeading` matches it.
    public static func echoesInjectedContext(
        completion: String,
        injectedContext: [String],
        minimumWhole: Int = 12,
        minimumLeading: Int = 16
    ) -> Bool {
        guard !injectedContext.isEmpty else { return false }
        let normalizedCompletion = AlphanumericNormalizer.normalize(completion)
        guard !normalizedCompletion.isEmpty else { return false }

        for sample in injectedContext {
            let normalizedSample = AlphanumericNormalizer.normalize(sample)
            if RepeatedSpanDetector.reproduces(
                normalizedCompletion: normalizedCompletion,
                within: normalizedSample,
                minimumWhole: minimumWhole,
                minimumLeading: minimumLeading
            ) {
                return true
            }
        }
        return false
    }
}
