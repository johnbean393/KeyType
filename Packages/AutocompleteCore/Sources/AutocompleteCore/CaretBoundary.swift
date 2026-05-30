import Foundation

/// Reconciles a model-produced completion with the text already to the left of the caret.
///
/// The generator is fed a *trailing-whitespace-trimmed* prefix (e.g. `"The capital of France is"`
/// rather than the live `"…is "`), because base models continue a clean word boundary far better
/// than one that ends in a dangling space — they then emit a leading separator space (`" Paris."`).
/// But the real field still contains the space the user just typed, so inserting `" Paris."` after
/// `"…is "` would produce a double space. This helper drops the redundant leading whitespace in that
/// case, and always strips a leading newline that fill-in-the-middle decoding tends to prepend at
/// the caret. See ADR-017 and `PromptStrategyProbeTests`.
public enum CaretBoundary {
    /// Returns `candidate` adjusted so it inserts cleanly at the caret given `beforeCursor`
    /// (the *original*, untrimmed text immediately left of the cursor).
    public static func reconcile(_ candidate: String, beforeCursor: String) -> String {
        var result = Substring(candidate)

        // Leading newline/carriage-return run is a decode artifact at the insertion point — never
        // wanted directly after the caret for a short inline completion.
        while let first = result.first, first == "\n" || first == "\r" {
            result = result.dropFirst()
        }

        // If the caret already sits after whitespace, the model's separator space would double it.
        // Strip every kind of leading whitespace (regular space, tab, non-breaking space, …) so an
        // unusual separator can't slip through and double up.
        if let last = beforeCursor.last, last.isWhitespace {
            while let first = result.first, first.isWhitespace {
                result = result.dropFirst()
            }
        }

        return String(result)
    }
}
