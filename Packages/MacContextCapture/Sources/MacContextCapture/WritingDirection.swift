//
//  WritingDirection.swift
//  MacContextCapture
//
//  Pure RTL detector based on the script of the first strong-directional character in the
//  inspected string. Used to populate `TextFieldGeometry.isRightToLeft`.
//

import Foundation

public enum WritingDirection {
    /// Returns true if the first scalar with a strong Unicode directionality in `text` belongs
    /// to a right-to-left script. Falls back to LTR if no strong character is present (e.g.
    /// empty text or only punctuation / whitespace / digits / emoji).
    public static func isRightToLeft(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch directionality(of: scalar) {
            case .leftToRight: return false
            case .rightToLeft: return true
            case .neutral: continue
            }
        }
        return false
    }

    private enum Directionality { case leftToRight, rightToLeft, neutral }

    /// Approximates the Unicode bidirectional category. Swift / Foundation don't expose
    /// `bidiClass` directly, so we cover the strong-LTR Basic Latin / Latin / Greek / Cyrillic
    /// ranges and the strong-RTL Hebrew / Arabic / Syriac / Thaana / N'Ko ranges. Everything
    /// else (digits, punctuation, whitespace, symbols, emoji) is treated as neutral so we
    /// fall through to the next strong scalar.
    private static func directionality(of scalar: Unicode.Scalar) -> Directionality {
        let v = scalar.value

        // Strong RTL ranges (Hebrew, Arabic, Syriac, Thaana, N'Ko, Arabic Presentation Forms).
        if (0x0590...0x05FF).contains(v)        // Hebrew
            || (0x0600...0x06FF).contains(v)    // Arabic
            || (0x0700...0x074F).contains(v)    // Syriac
            || (0x0750...0x077F).contains(v)    // Arabic Supplement
            || (0x0780...0x07BF).contains(v)    // Thaana
            || (0x07C0...0x07FF).contains(v)    // N'Ko
            || (0x0800...0x083F).contains(v)    // Samaritan
            || (0x0840...0x085F).contains(v)    // Mandaic
            || (0x08A0...0x08FF).contains(v)    // Arabic Extended-A
            || (0xFB1D...0xFB4F).contains(v)    // Hebrew Presentation Forms
            || (0xFB50...0xFDFF).contains(v)    // Arabic Presentation Forms-A
            || (0xFE70...0xFEFF).contains(v) {  // Arabic Presentation Forms-B
            return .rightToLeft
        }

        // Strong LTR ranges (Basic Latin letters, Latin-1 letters, extended Latin, Greek,
        // Cyrillic, Armenian, Georgian, common CJK). Use the unicodeScalar's general category
        // for the catch-all letter check.
        if (0x0041...0x005A).contains(v) || (0x0061...0x007A).contains(v) // ASCII letters
            || (0x00C0...0x024F).contains(v)    // Latin-1 Supplement / Extended-A / Extended-B
            || (0x0370...0x03FF).contains(v)    // Greek
            || (0x0400...0x04FF).contains(v)    // Cyrillic
            || (0x0530...0x058F).contains(v)    // Armenian
            || (0x10A0...0x10FF).contains(v)    // Georgian
            || (0x3040...0x309F).contains(v)    // Hiragana
            || (0x30A0...0x30FF).contains(v)    // Katakana
            || (0x4E00...0x9FFF).contains(v) {  // CJK Unified Ideographs
            return .leftToRight
        }

        // Everything else (digits, punctuation, whitespace, symbols, emoji, controls): neutral.
        return .neutral
    }
}
