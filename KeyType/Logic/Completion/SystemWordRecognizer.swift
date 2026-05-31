//
//  SystemWordRecognizer.swift
//  KeyType
//
//  `WordRecognizing` backed by the macOS system dictionary (`NSSpellChecker`). Feeds the
//  constrained decoder's current-word typo guard (see ADR-015).
//

import AppKit
import AutocompleteCore
import ConstrainedGeneration

/// Recognises words against the system dictionary via `NSSpellChecker`.
///
/// Deliberately conservative so the typo guard never produces a false positive: any word the
/// checker cannot evaluate — an empty string, or a language with no installed dictionary — is
/// reported as *recognised*. `NSSpellChecker` is main-thread affine, so each lookup hops to the
/// main actor; the guard only calls this when a word closes, which is rare relative to per-token
/// decode work.
///
/// Conforms to both seams: the `async` `WordRecognizing` used by the in-beam guard (ADR-015), and
/// the synchronous `SynchronousWordRecognizing` used by the output `DefaultCandidateFilter` when it
/// already runs on the main actor (ADR-024).
struct SystemWordRecognizer: WordRecognizing, SynchronousWordRecognizing {
    func recognizes(_ word: String, language: String?) async -> Bool {
        guard !word.isEmpty else { return true }
        return await MainActor.run { Self.isRecognized(word, language: language) }
    }

    /// Synchronous lookup for the main-actor output filter (ADR-024). `NSSpellChecker` is main-thread
    /// affine, so off the main thread we stay conservative and report the word as recognised rather
    /// than touching the shared checker from the wrong thread.
    func recognizes(_ word: String, language: String?) -> Bool {
        guard !word.isEmpty else { return true }
        guard Thread.isMainThread else { return true }
        return Self.isRecognized(word, language: language)
    }

    /// `false` only when the system dictionary has **no** completion for the partial word `prefix`
    /// — the signal that a mid-word stem could never resolve to a real word (ADR-052). Conservative:
    /// returns `true` for an empty prefix, off the main thread, or whenever the checker can't answer
    /// (a `nil` result), so a legitimate in-progress word is never suppressed.
    func canCompleteWord(prefix: String, language: String?) -> Bool {
        guard !prefix.isEmpty else { return true }
        guard Thread.isMainThread else { return true }
        let checker = NSSpellChecker.shared
        let resolved = Self.resolveLanguage(language, checker: checker)
        checker.automaticallyIdentifiesLanguages = (resolved == nil)
        let range = NSRange(location: 0, length: (prefix as NSString).length)
        guard let completions = checker.completions(
            forPartialWordRange: range,
            in: prefix,
            language: resolved,
            inSpellDocumentWithTag: 0
        ) else {
            return true // checker couldn't evaluate → assume viable
        }
        return !completions.isEmpty
    }

    /// The shared `NSSpellChecker` lookup. Must run on the main thread (the shared checker is
    /// main-thread affine); both seams above guarantee that before calling.
    private static func isRecognized(_ word: String, language: String?) -> Bool {
        let checker = NSSpellChecker.shared
        let resolved = resolveLanguage(language, checker: checker)
        checker.automaticallyIdentifiesLanguages = (resolved == nil)
        let misspelled = checker.checkSpelling(
            of: word,
            startingAt: 0,
            language: resolved,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        // No misspelled range found → the word is recognised.
        return misspelled.location == NSNotFound
    }

    /// Map a detected-language tag (BCP-47 `"en-US"` or NSSpellChecker `"en_US"`) onto an installed
    /// dictionary, falling back to the base language and then to `nil` (auto-detect) so we never
    /// force a checker into a language it can't handle.
    private static func resolveLanguage(_ requested: String?, checker: NSSpellChecker) -> String? {
        guard let requested, !requested.isEmpty else { return nil }
        let normalized = requested.replacingOccurrences(of: "-", with: "_")
        let available = checker.availableLanguages
        if available.contains(normalized) { return normalized }
        let base = String(normalized.prefix { $0 != "_" })
        if available.contains(base) { return base }
        return nil
    }
}
