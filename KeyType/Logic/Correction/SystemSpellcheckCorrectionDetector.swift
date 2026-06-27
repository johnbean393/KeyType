import AppKit
import AutocompleteCore
import Foundation

struct SpellcheckCorrectionDetection {
    var target: CorrectionTarget
    var candidates: [CorrectionCandidate]
}

struct GrammarCorrectionDetection {
    var candidates: [CorrectionCandidate]
}

@MainActor
struct SystemSpellcheckCorrectionDetector: CorrectionDetecting {
    var maximumCandidates: Int = 5

    func correctionCandidates(for context: TextFieldContext) async throws -> [CorrectionCandidate] {
        try await detectCorrection(for: context)?.candidates ?? []
    }

    func detectCorrection(for context: TextFieldContext) async throws -> SpellcheckCorrectionDetection? {
        let targetResult = CorrectionTargeting.closedWordBeforeCaret(in: context)
        let currentResult = CorrectionTargeting.currentWordBeforeCaret(in: context)
        let target: CorrectionTarget
        switch (targetResult, currentResult) {
        case let (.success(closed), _):
            target = closed
        case let (.failure, .success(current)):
            target = current
        case (.failure, .failure):
            return nil
        }

        let checker = NSSpellChecker.shared
        let language = SystemCorrectionLanguage.resolve(context.detectedLanguage, checker: checker)
        checker.automaticallyIdentifiesLanguages = (language == nil)
        guard !Self.isRecognized(target.original, checker: checker, language: language) else {
            return nil
        }

        let guesses = checker.guesses(
            forWordRange: NSRange(location: 0, length: (target.original as NSString).length),
            in: target.original,
            language: language,
            inSpellDocumentWithTag: 0
        ) ?? []

        var seen = Set<String>()
        let candidates: [CorrectionCandidate] = guesses.prefix(maximumCandidates * 2).compactMap { (rawGuess: String) -> CorrectionCandidate? in
            let replacement = CorrectionTargeting.preservesCase(rawGuess, like: target.original)
            guard seen.insert(replacement.lowercased()).inserted else { return nil }
            guard replacement.caseInsensitiveCompare(target.original) != .orderedSame else { return nil }
            guard Self.requiresReplacement(original: target.original, replacement: replacement) else { return nil }
            guard Self.isRecognized(replacement, checker: checker, language: language) else { return nil }
            let distance = CorrectionTargeting.editDistance(target.original, replacement, maxDistance: maximumAllowedDistance(for: target.original))
            guard distance > 0, distance <= maximumAllowedDistance(for: target.original) else { return nil }
            let confidence = confidenceForSpellcheck(distance: distance, originalLength: target.original.count)
            return CorrectionCandidate(
                original: target.original,
                replacement: replacement,
                originalRange: target.range,
                confidence: confidence,
                source: .spellcheckOnly,
                validation: .spellcheckOnly
            )
        }
        .prefix(maximumCandidates)
        .map { $0 }
        guard !candidates.isEmpty else { return nil }
        return SpellcheckCorrectionDetection(target: target, candidates: candidates)
    }

    private func maximumAllowedDistance(for word: String) -> Int {
        return word.count <= 8 ? 2 : 3
    }

    private func confidenceForSpellcheck(distance: Int, originalLength: Int) -> Double {
        let base = 0.78
        let penalty = Double(max(0, distance - 1)) * 0.08
        let lengthBoost = min(0.08, Double(max(0, originalLength - 5)) * 0.01)
        return max(0.55, min(0.9, base + lengthBoost - penalty))
    }

    private static func isRecognized(_ word: String, checker: NSSpellChecker, language: String?) -> Bool {
        let misspelled = checker.checkSpelling(
            of: word,
            startingAt: 0,
            language: language,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        return misspelled.location == NSNotFound
    }

    private static func requiresReplacement(original: String, replacement: String) -> Bool {
        let normalizedOriginal = original.lowercased()
        let normalizedReplacement = replacement.lowercased()
        return !normalizedReplacement.hasPrefix(normalizedOriginal)
    }

}

@MainActor
struct SystemGrammarCorrectionDetector {
    var maximumCandidates: Int = 5

    func correctionCandidates(for context: TextFieldContext) -> [CorrectionCandidate] {
        guard let window = Self.grammarWindow(for: context) else { return [] }
        let checker = NSSpellChecker.shared
        let language = SystemCorrectionLanguage.resolve(context.detectedLanguage, checker: checker)
        checker.automaticallyIdentifiesLanguages = (language == nil)

        var details: NSArray?
        let sentenceRange = checker.checkGrammar(
            of: window.text,
            startingAt: 0,
            language: language,
            wrap: false,
            inSpellDocumentWithTag: 0,
            details: &details
        )
        guard sentenceRange.location != NSNotFound,
              let details = details as? [[String: Any]],
              !details.isEmpty else {
            return []
        }

        var seen = Set<String>()
        var candidates: [CorrectionCandidate] = []
        for detail in details {
            guard candidates.count < maximumCandidates else { break }
            let localRange = (detail[NSGrammarRange] as? NSValue)?.rangeValue
                ?? NSRange(location: 0, length: sentenceRange.length)
            let issueNSRange = NSRange(
                location: sentenceRange.location + localRange.location,
                length: localRange.length
            )
            guard let issueRange = Range(issueNSRange, in: window.text),
                  issueRange.upperBound <= window.beforeWindowEnd else {
                continue
            }
            let original = String(window.text[issueRange])
            guard !original.isEmpty,
                  let replacements = detail[NSGrammarCorrections] as? [String],
                  !replacements.isEmpty else {
                continue
            }
            let startOffset = window.beforeStartOffset
                + window.text.distance(from: window.text.startIndex, to: issueRange.lowerBound)
            let endOffset = window.beforeStartOffset
                + window.text.distance(from: window.text.startIndex, to: issueRange.upperBound)
            guard endOffset <= context.beforeCursor.count,
                  Self.isNearCaret(endOffset: endOffset, context: context) else {
                continue
            }
            let confidence = Self.confidence(from: detail)
            for replacement in replacements {
                guard candidates.count < maximumCandidates else { break }
                let normalized = replacement.trimmingCharacters(in: .newlines)
                guard !normalized.isEmpty,
                      !normalized.contains("\n"),
                      normalized != original,
                      seen.insert("\(startOffset):\(endOffset):\(normalized)").inserted else {
                    continue
                }
                candidates.append(CorrectionCandidate(
                    original: original,
                    replacement: normalized,
                    originalRange: TextRangeDescriptor(
                        container: .beforeCursor,
                        startOffset: startOffset,
                        endOffset: endOffset
                    ),
                    confidence: confidence,
                    source: .systemGrammarOnly,
                    validation: .spellcheckOnly
                ))
            }
        }
        return candidates
    }

    func candidates(afterApplying spelling: CorrectionCandidate, in context: TextFieldContext) -> [CorrectionCandidate] {
        guard spelling.originalRange.container == .beforeCursor,
              let range = spelling.originalRange.range(in: context.beforeCursor) else {
            return []
        }
        var correctedContext = context
        correctedContext.beforeCursor.replaceSubrange(range, with: spelling.replacement)
        return correctionCandidates(for: correctedContext).compactMap { grammar in
            Self.compose(
                spelling: spelling,
                grammar: grammar,
                originalContext: context,
                correctedContext: correctedContext
            )
        }
    }

    private static func grammarWindow(for context: TextFieldContext) -> GrammarWindow? {
        if !(context.selection.selectedText ?? "").isEmpty { return nil }
        if context.traits.isSecureTextEntry
            || context.traits.isPasswordField
            || context.traits.isPasswordManagerContext
            || context.traits.isTerminalLike {
            return nil
        }
        if context.beforeCursor.contains("://") || context.beforeCursor.contains("@") {
            return nil
        }

        let before = context.beforeCursor
        let start = sentenceStart(in: before)
        let beforeSlice = String(before[start...])
        let beforeStartOffset = before.distance(from: before.startIndex, to: start)
        let afterSlice = sentenceSuffix(from: context.afterCursor, limit: 160)
        let text = beforeSlice + afterSlice
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4 else {
            return nil
        }
        let beforeWindowEnd = text.index(text.startIndex, offsetBy: beforeSlice.count)
        return GrammarWindow(
            text: text,
            beforeStartOffset: beforeStartOffset,
            beforeWindowEnd: beforeWindowEnd
        )
    }

    private static func sentenceStart(in text: String) -> String.Index {
        var start = text.startIndex
        var scan = text.endIndex
        while scan > text.startIndex {
            let previous = text.index(before: scan)
            if ".!?\n".contains(text[previous]) {
                start = scan
                break
            }
            scan = previous
        }
        while start < text.endIndex, text[start].isWhitespace {
            start = text.index(after: start)
        }
        return start
    }

    private static func sentenceSuffix(from text: String, limit: Int) -> String {
        var result = ""
        for character in text {
            guard result.count < limit else { break }
            result.append(character)
            if ".!?\n".contains(character) { break }
        }
        return result
    }

    private static func isNearCaret(endOffset: Int, context: TextFieldContext) -> Bool {
        max(0, context.beforeCursor.count - endOffset) <= 24
    }

    private static func confidence(from detail: [String: Any]) -> Double {
        let raw = (detail["NSGrammarConfidenceScore"] as? NSNumber)?.doubleValue ?? 0.82
        return max(0.72, min(0.92, raw))
    }

    private static func compose(
        spelling: CorrectionCandidate,
        grammar: CorrectionCandidate,
        originalContext: TextFieldContext,
        correctedContext: TextFieldContext
    ) -> CorrectionCandidate? {
        guard spelling.originalRange.container == .beforeCursor,
              grammar.originalRange.container == .beforeCursor,
              spelling.originalRange.range(in: originalContext.beforeCursor) != nil,
              grammar.originalRange.range(in: correctedContext.beforeCursor) != nil else {
            return nil
        }

        let replacementDelta = spelling.replacement.count - spelling.original.count
        let spellingStartOriginal = spelling.originalRange.startOffset
        let spellingEndOriginal = spelling.originalRange.endOffset
        let spellingEndCorrected = spellingStartOriginal + spelling.replacement.count
        func originalOffset(forCorrectedOffset offset: Int, isEnd: Bool) -> Int {
            if offset <= spellingStartOriginal { return offset }
            if offset >= spellingEndCorrected { return offset - replacementDelta }
            return isEnd ? spellingEndOriginal : spellingStartOriginal
        }

        let grammarStartOriginal = originalOffset(forCorrectedOffset: grammar.originalRange.startOffset, isEnd: false)
        let grammarEndOriginal = originalOffset(forCorrectedOffset: grammar.originalRange.endOffset, isEnd: true)
        let unionStartOriginal = min(spellingStartOriginal, grammarStartOriginal)
        let unionEndOriginal = max(spellingEndOriginal, grammarEndOriginal)
        let unionStartCorrected = min(spellingStartOriginal, grammar.originalRange.startOffset)
        let unionEndCorrectedBeforeGrammar = max(spellingEndCorrected, grammar.originalRange.endOffset)
        let grammarDelta = grammar.replacement.count - grammar.original.count
        let unionEndCorrected = unionEndCorrectedBeforeGrammar + grammarDelta

        guard unionStartOriginal >= 0,
              unionEndOriginal <= originalContext.beforeCursor.count,
              unionStartCorrected >= 0,
              unionEndCorrectedBeforeGrammar <= correctedContext.beforeCursor.count,
              let originalStart = originalContext.beforeCursor.index(originalContext.beforeCursor.startIndex, offsetBy: unionStartOriginal, limitedBy: originalContext.beforeCursor.endIndex),
              let originalEnd = originalContext.beforeCursor.index(originalContext.beforeCursor.startIndex, offsetBy: unionEndOriginal, limitedBy: originalContext.beforeCursor.endIndex),
              let grammarStart = correctedContext.beforeCursor.index(correctedContext.beforeCursor.startIndex, offsetBy: grammar.originalRange.startOffset, limitedBy: correctedContext.beforeCursor.endIndex),
              let grammarEnd = correctedContext.beforeCursor.index(correctedContext.beforeCursor.startIndex, offsetBy: grammar.originalRange.endOffset, limitedBy: correctedContext.beforeCursor.endIndex) else {
            return nil
        }

        var finalBeforeCursor = correctedContext.beforeCursor
        finalBeforeCursor.replaceSubrange(grammarStart..<grammarEnd, with: grammar.replacement)
        guard unionEndCorrected <= finalBeforeCursor.count,
              let correctedStart = finalBeforeCursor.index(finalBeforeCursor.startIndex, offsetBy: unionStartCorrected, limitedBy: finalBeforeCursor.endIndex),
              let correctedEnd = finalBeforeCursor.index(finalBeforeCursor.startIndex, offsetBy: unionEndCorrected, limitedBy: finalBeforeCursor.endIndex) else {
            return nil
        }

        return CorrectionCandidate(
            original: String(originalContext.beforeCursor[originalStart..<originalEnd]),
            replacement: String(finalBeforeCursor[correctedStart..<correctedEnd]),
            originalRange: TextRangeDescriptor(
                container: .beforeCursor,
                startOffset: unionStartOriginal,
                endOffset: unionEndOriginal
            ),
            confidence: min(0.96, max(spelling.confidence, grammar.confidence)),
            source: .spellcheckThenSystemGrammar,
            validation: spelling.validation
        )
    }

    private struct GrammarWindow {
        var text: String
        var beforeStartOffset: Int
        var beforeWindowEnd: String.Index
    }
}

private enum SystemCorrectionLanguage {
    static func resolve(_ requested: String?, checker: NSSpellChecker) -> String? {
        guard let requested, !requested.isEmpty else { return nil }
        let normalized = requested.replacingOccurrences(of: "-", with: "_")
        let available = checker.availableLanguages
        if available.contains(normalized) { return normalized }
        let base = String(normalized.prefix { $0 != "_" })
        if available.contains(base) { return base }
        return nil
    }
}
