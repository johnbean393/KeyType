import Foundation

/// Output-stage net for the markup-tag leak: Gemma's vocabulary carries whole HTML tags as single
/// NORMAL tokens (`<b>` = 200, `</code>` = 215, …), and in thin prose contexts the model surfaces
/// them as suggestions ("my name is" → "</code>"). The primary defence is sample-time demotion via
/// `BiasPolicy.markupTagStaticPenalty`; this guard is the context-aware mirror for finalised
/// candidates, applied by the candidate filter in prose/correction modes only.
///
/// Deliberately conservative in both directions:
/// - It fires only when the *entire* completion is markup tags (plus whitespace). A candidate that
///   continues the user's own angle-bracket text ("code> to format") has prose content and passes.
/// - It is silent whenever the surrounding field text already contains tag-like markup — a user
///   genuinely writing HTML in a prose-mode field (chat box, CMS textarea) keeps tag completions.
public enum MarkupTagGuard {

    /// Matches a completion consisting solely of one or more whole tags separated by whitespace:
    /// `"</code>"`, `" <b>"`, `"</td></tr>"`. Tag shape mirrors `TokenClassifier.matchesMarkupTag`.
    private static let pureMarkupRegex = try? NSRegularExpression(
        pattern: #"^\s*(</?[a-zA-Z][a-zA-Z0-9]*( ?/)?>\s*)+$"#,
        options: []
    )

    /// Loose tag detector for the *surrounding* text — attributes allowed (`<a href="…">`), since
    /// real markup contexts contain them. Used only for the exemption, where a false positive
    /// merely means we keep showing tag completions.
    private static let contextMarkupRegex = try? NSRegularExpression(
        pattern: #"</?[a-zA-Z][^<>]{0,80}>"#,
        options: []
    )

    /// `true` when `completion` should be suppressed: it is pure markup and neither side of the
    /// caret shows the user working with markup.
    public static func violates(
        completion: String,
        beforeCursor: String,
        afterCursor: String
    ) -> Bool {
        guard isPureMarkup(completion) else { return false }
        if containsMarkup(beforeCursor) || containsMarkup(afterCursor) { return false }
        return true
    }

    static func isPureMarkup(_ text: String) -> Bool {
        guard !text.isEmpty, let regex = pureMarkupRegex else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    static func containsMarkup(_ text: String) -> Bool {
        guard !text.isEmpty, let regex = contextMarkupRegex else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}
