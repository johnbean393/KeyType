//
//  LanguageDetector.swift
//  MacContextCapture
//
//  Thin wrapper around `NLLanguageRecognizer` so the rest of KeyType can stay
//  framework-free and so the detector is unit-testable.
//

import Foundation
import NaturalLanguage

public enum LanguageDetector {
    /// Returns a BCP-47 language code (e.g. `"en"`, `"fr"`, `"ja"`) for `text`, or nil when
    /// the recognizer cannot make a confident-enough guess (short / mixed-script strings).
    public static func detectLanguage(in text: String, minimumConfidence: Double = 0.5) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else {
            return nil
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)

        guard let language = recognizer.dominantLanguage else { return nil }
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        if let confidence = hypotheses[language], confidence < minimumConfidence {
            return nil
        }
        return language.rawValue
    }
}
