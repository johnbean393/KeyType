import Foundation

public struct CorrectionTarget: Equatable, Sendable {
    public var original: String
    public var range: TextRangeDescriptor
    public var prefixBeforeWord: String
    public var suffixAfterWord: String

    public init(
        original: String,
        range: TextRangeDescriptor,
        prefixBeforeWord: String,
        suffixAfterWord: String
    ) {
        self.original = original
        self.range = range
        self.prefixBeforeWord = prefixBeforeWord
        self.suffixAfterWord = suffixAfterWord
    }
}

public enum CorrectionEligibilityFailure: String, Error, Equatable, Sendable {
    case selectionActive
    case unsafeField
    case noClosedWord
    case wordTooShort
    case wordTooLong
    case nonAlphabetic
    case number
    case codeIdentifier
    case urlOrEmail
    case camelCase
    case acronym
    case scriptMismatch
}

public enum CorrectionTargeting {
    public static let minimumWordLength = 3
    public static let maximumWordLength = 24

    public static func currentWordBeforeCaret(in context: TextFieldContext) -> Result<CorrectionTarget, CorrectionEligibilityFailure> {
        if let commonFailure = commonEligibilityFailure(in: context) {
            return .failure(commonFailure)
        }

        let before = context.beforeCursor
        guard !before.isEmpty else { return .failure(.noClosedWord) }
        guard context.afterCursor.first.map({ !isWordCharacter($0) }) ?? true else {
            return .failure(.noClosedWord)
        }

        var wordStart = before.endIndex
        while wordStart > before.startIndex {
            let previous = before.index(before: wordStart)
            guard isWordCharacter(before[previous]) else { break }
            wordStart = previous
        }
        guard wordStart < before.endIndex else { return .failure(.noClosedWord) }

        let original = String(before[wordStart..<before.endIndex])
        let startOffset = before.distance(from: before.startIndex, to: wordStart)
        let endOffset = before.distance(from: before.startIndex, to: before.endIndex)
        let target = CorrectionTarget(
            original: original,
            range: TextRangeDescriptor(
                container: .beforeCursor,
                startOffset: startOffset,
                endOffset: endOffset
            ),
            prefixBeforeWord: String(before[..<wordStart]),
            suffixAfterWord: context.afterCursor
        )

        if let failure = eligibilityFailure(for: target, context: context) {
            return .failure(failure)
        }
        return .success(target)
    }

    public static func closedWordBeforeCaret(in context: TextFieldContext) -> Result<CorrectionTarget, CorrectionEligibilityFailure> {
        if let commonFailure = commonEligibilityFailure(in: context) {
            return .failure(commonFailure)
        }

        let before = context.beforeCursor
        guard !before.isEmpty else { return .failure(.noClosedWord) }

        var scan = before.endIndex
        var sawCloser = false
        while scan > before.startIndex {
            let previous = before.index(before: scan)
            if isWordCloser(before[previous]) {
                sawCloser = true
                scan = previous
            } else {
                break
            }
        }
        guard sawCloser else { return .failure(.noClosedWord) }

        let wordEnd = scan
        var wordStart = wordEnd
        while wordStart > before.startIndex {
            let previous = before.index(before: wordStart)
            guard isWordCharacter(before[previous]) else { break }
            wordStart = previous
        }
        guard wordStart < wordEnd else { return .failure(.noClosedWord) }

        let original = String(before[wordStart..<wordEnd])
        let startOffset = before.distance(from: before.startIndex, to: wordStart)
        let endOffset = before.distance(from: before.startIndex, to: wordEnd)
        let target = CorrectionTarget(
            original: original,
            range: TextRangeDescriptor(
                container: .beforeCursor,
                startOffset: startOffset,
                endOffset: endOffset
            ),
            prefixBeforeWord: String(before[..<wordStart]),
            suffixAfterWord: String(before[wordEnd...]) + context.afterCursor
        )

        if let failure = eligibilityFailure(for: target, context: context) {
            return .failure(failure)
        }
        return .success(target)
    }

    public static func eligibilityFailure(for target: CorrectionTarget, context: TextFieldContext) -> CorrectionEligibilityFailure? {
        let word = target.original
        if word.count < minimumWordLength { return .wordTooShort }
        if word.count > maximumWordLength { return .wordTooLong }
        if word.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) {
            return .number
        }
        if !word.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) {
            return .nonAlphabetic
        }
        if hasURLOrEmailContext(target: target, context: context) { return .urlOrEmail }
        if looksLikeAcronym(word) { return .acronym }
        if looksLikeCamelCase(word) { return .camelCase }
        if hasCodeIdentifierBoundary(target: target, context: context) { return .codeIdentifier }
        if hasCJKLatinMismatch(target: target) { return .scriptMismatch }
        return nil
    }

    private static func commonEligibilityFailure(in context: TextFieldContext) -> CorrectionEligibilityFailure? {
        if !(context.selection.selectedText ?? "").isEmpty {
            return .selectionActive
        }
        if context.traits.isSecureTextEntry
            || context.traits.isPasswordField
            || context.traits.isPasswordManagerContext
            || context.traits.isTerminalLike {
            return .unsafeField
        }
        return nil
    }

    public static func editDistance(_ lhs: String, _ rhs: String, maxDistance: Int = Int.max) -> Int {
        let a = Array(lhs.lowercased())
        let b = Array(rhs.lowercased())
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        if abs(a.count - b.count) > maxDistance { return maxDistance + 1 }

        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMinimum = current[0]
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
                rowMinimum = min(rowMinimum, current[j])
            }
            if rowMinimum > maxDistance { return maxDistance + 1 }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    public static func preservesCase(_ replacement: String, like original: String) -> String {
        guard !replacement.isEmpty else { return replacement }
        if original.allSatisfy({ !$0.isLetter || $0.isUppercase }) {
            return replacement.uppercased()
        }
        if let first = original.first,
           first.isUppercase,
           original.dropFirst().allSatisfy({ !$0.isLetter || $0.isLowercase }) {
            return replacement.prefix(1).uppercased() + replacement.dropFirst().lowercased()
        }
        return replacement.lowercased()
    }

    private static func isWordCloser(_ character: Character) -> Bool {
        character.isWhitespace || ",.;:!?)]}\"'".contains(character)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            (CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0))
                && !TextScriptProfile.containsCJK(in: String($0))
        }
    }

    private static func looksLikeAcronym(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        return letters.count > 1 && letters.allSatisfy(\.isUppercase)
    }

    private static func looksLikeCamelCase(_ word: String) -> Bool {
        var hasLowercase = false
        for character in word.dropFirst() {
            if character.isLowercase { hasLowercase = true }
            if hasLowercase && character.isUppercase { return true }
        }
        return false
    }

    private static func hasCodeIdentifierBoundary(target: CorrectionTarget, context: TextFieldContext) -> Bool {
        let before = target.prefixBeforeWord
        let after = target.suffixAfterWord
        if before.last == "_" || after.first == "_" { return true }
        if before.last == "." || before.last == "/" || before.last == "\\" { return true }
        if after.first == "." || after.first == "/" || after.first == "\\" { return true }
        let linePrefix = before.split(whereSeparator: \.isNewline).last.map(String.init) ?? before
        let codeMarkers = ["let ", "var ", "func ", "class ", "struct ", "enum ", "import ", "return ", "const "]
        return codeMarkers.contains { linePrefix.trimmingCharacters(in: .whitespaces).hasPrefix($0) }
    }

    private static func hasURLOrEmailContext(target: CorrectionTarget, context: TextFieldContext) -> Bool {
        let around = context.beforeCursor + context.afterCursor.prefix(64)
        let lower = around.lowercased()
        if lower.contains("://") || lower.contains("www.") { return true }
        if lower.contains("@") { return true }
        let word = target.original.lowercased()
        return lower.contains("\(word).com")
            || lower.contains("\(word).org")
            || lower.contains("\(word).net")
    }

    private static func hasCJKLatinMismatch(target: CorrectionTarget) -> Bool {
        guard TextScriptProfile.containsLatinLetter(in: target.original) else { return false }
        let left = target.prefixBeforeWord.last.map(String.init) ?? ""
        let right = target.suffixAfterWord.first.map(String.init) ?? ""
        return TextScriptProfile.containsCJK(in: left) || TextScriptProfile.containsCJK(in: right)
    }
}
