import AutocompleteCore
import Foundation

/// Drops healed mid-word branches that would turn a model-started fresh word into a glued insert.
///
/// A healed request re-emits the user's partial word (`" Aga"`) and strips it before display. If the
/// model then emits a whitespace-separated proper noun (`" Aga Khan"`), stripping the heal and the
/// separator would show `"Khan"`; accepting it after the live `"Aga"` produces `"AgaKhan"`. The
/// branch is not an inline continuation of the word the user is typing, so remove it in-beam and let
/// a real continuation such as `" Against"` compete normally.
enum MidWordBoundaryGuard {
    static func violates(completion: String, request: CompletionRequest) -> Bool {
        guard request.mode == .prose || request.mode == .correction else { return false }

        let heal = String(decoding: request.requiredPrefixBytes, as: UTF8.self)
        guard !heal.isEmpty, completion.hasPrefix(heal) else { return false }

        let stem = CurrentWordTypoGuard.trailingWord(of: request.context.beforeCursor)
        guard !stem.isEmpty else { return false }

        var rest = completion.dropFirst(heal.count)
        guard let first = rest.first, first.isWhitespace else { return false }
        while let next = rest.first, next.isWhitespace {
            rest = rest.dropFirst()
        }
        guard let next = rest.first else { return false }

        return isUppercaseLetter(next)
    }

    private static func isUppercaseLetter(_ character: Character) -> Bool {
        let text = String(character)
        return text.rangeOfCharacter(from: .letters) != nil
            && text == text.uppercased()
            && text != text.lowercased()
    }
}
