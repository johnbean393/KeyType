//
//  ScreenTextOCR.swift
//  MacContextCapture
//
//  Vision text recognition over a captured window image, plus a pure post-processor that turns the
//  recognised lines into a compact, length-capped block suitable for the prompt's `[Screen context]`
//  section. The post-processor is ScreenCaptureKit/Vision-free so it can be unit-tested directly.
//

import CoreGraphics
import Foundation
import Vision

public enum ScreenTextOCR {
    /// Recognise text in `image`, returning the recognised lines in natural reading order
    /// (top-to-bottom, then left-to-right). Uses `.fast` recognition with language correction
    /// **off** (ADR-076). Earlier revisions used `.accurate` + `usesLanguageCorrection = true`
    /// because the per-line corruption filter (`droppingCorruptedLines` below) had a non-trivial
    /// false-negative rate when fed `.fast`-tier mojibake (ADR-049/052). In practice — once the
    /// digit-substitution guard (ADR-050) and the symbol-density guard are in place — the
    /// surviving `.fast` lines are good enough for `[Screen context]` and the CPU win on a
    /// fanless M4 is measured in 5–10× per refresh. The OCR is still off the keystroke path,
    /// but the same CPU competes with everything else the user is doing, and a 4-second timer
    /// firing `.accurate` Vision passes was the dominant remaining draw after ADR-074/075.
    /// `.fast` routes through the Neural Engine where available, which is exactly what
    /// Apple's own Live Text / system text recognition uses for ambient capture.
    ///
    /// `minimumConfidence` is the first guard against *corrupted* OCR reaching the prompt: Vision
    /// reports a per-candidate confidence, and a low value is the signal of a mangled recognition.
    /// Feeding nothing is better than feeding garbage, so low-confidence lines are dropped here.
    /// The threshold is bumped slightly to compensate for `.fast`'s noisier candidates.
    public static func recognizeLines(in image: CGImage, minimumConfidence: Float = 0.45) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .sorted { lhs, rhs in
                        // Vision bounding boxes are normalised with a bottom-left origin (y up), so
                        // higher y is nearer the top of the window. Group roughly by line, then by x.
                        if abs(lhs.boundingBox.origin.y - rhs.boundingBox.origin.y) > 0.01 {
                            return lhs.boundingBox.origin.y > rhs.boundingBox.origin.y
                        }
                        return lhs.boundingBox.origin.x < rhs.boundingBox.origin.x
                    }
                let lines = observations.compactMap { observation -> String? in
                    guard let candidate = observation.topCandidates(1).first,
                          candidate.confidence >= minimumConfidence else { return nil }
                    return candidate.string
                }
                continuation.resume(returning: lines)
            }
            // ADR-076: trade some recognition accuracy for ~5–10× lower per-refresh CPU. The
            // downstream corruption filters (`droppingCorruptedLines`, `isPlausibleText`,
            // `containsDigitSubstitutedWord`) reject the additional mangled lines that `.fast`
            // produces, so the model still only sees plausible prose.
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Drop OCR lines that look *corrupted* — independent of Vision's confidence — so mangled
    /// recognitions never reach the prompt. A line is dropped when it contains the Unicode
    /// replacement character, has a high density of stray symbol glyphs (mojibake / decode noise),
    /// or has too few real word characters relative to its length. Tuned to leave ordinary prose and
    /// technical text untouched (model names, version numbers, code punctuation all pass). See ADR-049.
    public static func droppingCorruptedLines(
        _ lines: [String],
        maxSymbolRatio: Double = 0.2,
        minimumWordCharRatio: Double = 0.5
    ) -> [String] {
        lines.filter {
            isPlausibleText($0, maxSymbolRatio: maxSymbolRatio, minimumWordCharRatio: minimumWordCharRatio)
        }
    }

    /// Punctuation that legitimately appears in prose, code, and technical text — never counted as
    /// "symbol noise" by the corruption heuristic.
    private static let allowedPunctuation = CharacterSet(charactersIn: ".,!?;:'\"()[]{}-/&%$#@*+=<>`~_|\\…’“”—–•·…°^")

    static func isPlausibleText(
        _ line: String,
        maxSymbolRatio: Double,
        minimumWordCharRatio: Double
    ) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true } // blank lines are dropped downstream
        if trimmed.unicodeScalars.contains("\u{FFFD}") { return false }

        // Digit-substituted words ("qu81ity" for "quality", "h3llo") are a hallmark of OCR mangling
        // and are exactly what the model parrots. Drop the line on any such token. Trailing/leading
        // digit groups and ALL-CAPS+digit tokens are left alone, so "RTX 5070", "N1X", "utf8",
        // "20-core", and "macOS15" all pass. See ADR-050.
        if containsDigitSubstitutedWord(trimmed) { return false }

        var wordChars = 0
        var symbolChars = 0
        var total = 0
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.whitespaces.contains(scalar) { continue }
            total += 1
            if CharacterSet.alphanumerics.contains(scalar) {
                wordChars += 1
            } else if !allowedPunctuation.contains(scalar) {
                symbolChars += 1
            }
        }
        guard total > 0 else { return true }

        if Double(symbolChars) / Double(total) > maxSymbolRatio { return false }
        if Double(wordChars) / Double(total) < minimumWordCharRatio { return false }
        return true
    }

    /// `true` when any token in `text` looks like a word with a digit substituted *inside* it — a
    /// digit that has a lowercase letter somewhere before it and any letter somewhere after it
    /// (e.g. "qu81ity", "h3llo"). This is the signature of OCR confusing letters for digits
    /// (l→1, a→4/8, o→0, e→3, s→5). Trailing digits ("utf8", "v2"), leading digits ("3D", "5070"),
    /// and ALL-CAPS model names ("N1X", "RTX5070") are deliberately *not* flagged.
    static func containsDigitSubstitutedWord(_ text: String) -> Bool {
        for token in text.split(whereSeparator: { !($0.isLetter || $0.isNumber) }) {
            if isDigitSubstitutedWord(token) { return true }
        }
        return false
    }

    private static func isDigitSubstitutedWord(_ token: Substring) -> Bool {
        let characters = Array(token)
        for index in characters.indices where characters[index].isNumber {
            let hasLowercaseBefore = characters[..<index].contains { $0.isLowercase }
            let hasLetterAfter = characters[(index + 1)...].contains { $0.isLetter }
            if hasLowercaseBefore && hasLetterAfter { return true }
        }
        return false
    }

    /// Drop OCR lines that are just the focused field's own text — that content is already captured
    /// verbatim via Accessibility (`beforeCursor`/`afterCursor`), so re-feeding it as "screen context"
    /// is noise. Matching is whitespace-/case-normalised containment: a recognised visual line is
    /// dropped when its normalised form appears inside the normalised field text (soft-wrapping splits
    /// the field across several OCR lines, but each wrapped segment is still a contiguous substring of
    /// the field text). Short lines (below `minimumMatchLength` normalised chars) are kept, since a
    /// stray common word coinciding with the field text isn't worth the risk of over-stripping.
    public static func linesExcludingFieldText(
        _ lines: [String],
        fieldText: String,
        minimumMatchLength: Int = 4
    ) -> [String] {
        let normalizedField = normalizedForMatch(fieldText)
        guard !normalizedField.isEmpty else { return lines }
        return lines.filter { line in
            let normalized = normalizedForMatch(line)
            if normalized.count < minimumMatchLength { return true }
            return !normalizedField.contains(normalized)
        }
    }

    /// Lowercased, whitespace-collapsed form used only for substring comparison (never shown).
    private static func normalizedForMatch(_ string: String) -> String {
        string
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Collapse recognised lines into a trimmed, de-blanked block capped to `maxLines` lines and
    /// `maxChars` characters. The prompt builder's section budget trims further; this just keeps the
    /// raw payload bounded so a busy screen never balloons the prompt.
    public static func cleanedText(fromLines lines: [String], maxLines: Int, maxChars: Int) -> String {
        var kept: [String] = []
        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            kept.append(trimmed)
            if kept.count >= maxLines { break }
        }
        let joined = kept.joined(separator: "\n")
        guard joined.count > maxChars else { return joined }
        return String(joined.prefix(maxChars))
    }
}
