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
    /// (top-to-bottom, then left-to-right). Uses `.fast` recognition with language correction off
    /// for latency — this feeds an LLM prompt, not a transcription, so perfect accuracy isn't needed.
    ///
    /// `minimumConfidence` is the primary guard against *corrupted* OCR reaching the prompt: Vision
    /// reports a per-candidate confidence, and a low value is the signal of a mangled recognition
    /// (the kind that produces "Ilne wilh real 5ulfix" gibberish the model then parrots). Feeding
    /// nothing is better than feeding garbage, so low-confidence lines are dropped here. (See ADR-049.)
    public static func recognizeLines(in image: CGImage, minimumConfidence: Float = 0.4) async throws -> [String] {
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
