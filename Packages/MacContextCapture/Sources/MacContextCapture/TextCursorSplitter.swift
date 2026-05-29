//
//  TextCursorSplitter.swift
//  MacContextCapture
//
//  Pure helpers that turn a (text, selection) pair from AX into the slices and flags the
//  rest of KeyType consumes. Kept side-effect-free so they can be unit-tested without a
//  live AX tree.
//

import Foundation

/// The result of splitting a text-field value around an AX selection.
public struct CursorSplit: Equatable {
    public var beforeCursor: String
    public var afterCursor: String
    public var selectedText: String
    public var range: Range<String.Index>?
    public var isAtEndOfLine: Bool

    public init(
        beforeCursor: String,
        afterCursor: String,
        selectedText: String,
        range: Range<String.Index>?,
        isAtEndOfLine: Bool
    ) {
        self.beforeCursor = beforeCursor
        self.afterCursor = afterCursor
        self.selectedText = selectedText
        self.range = range
        self.isAtEndOfLine = isAtEndOfLine
    }
}

public enum TextCursorSplitter {
    /// Split `text` at an AX `NSRange` (UTF-16 offsets, as returned by
    /// `kAXSelectedTextRangeAttribute`) into the slices KeyType needs at the caret.
    ///
    /// Selection location/length are clamped into the valid UTF-16 range; out-of-bounds
    /// inputs produce a best-effort split rather than crashing.
    public static func split(text: String, axRange: NSRange?) -> CursorSplit {
        let nsText = text as NSString
        let length = nsText.length

        let clampedLocation: Int
        let clampedLength: Int
        if let axRange, axRange.location != NSNotFound {
            clampedLocation = max(0, min(axRange.location, length))
            let remaining = length - clampedLocation
            clampedLength = max(0, min(axRange.length, remaining))
        } else {
            clampedLocation = length
            clampedLength = 0
        }

        let before = nsText.substring(to: clampedLocation)
        let afterStart = clampedLocation + clampedLength
        let after = nsText.substring(from: afterStart)
        let selected = clampedLength > 0
            ? nsText.substring(with: NSRange(location: clampedLocation, length: clampedLength))
            : ""

        let range = Range(NSRange(location: clampedLocation, length: clampedLength), in: text)

        // End-of-line if the caret sits at the very end of the field, or the next character is a
        // newline. Use the after-cursor slice (already clamped) to keep this Unicode-correct.
        let nextScalar = after.unicodeScalars.first
        let isEOL = after.isEmpty
            || (nextScalar.map { CharacterSet.newlines.contains($0) } ?? false)

        return CursorSplit(
            beforeCursor: before,
            afterCursor: after,
            selectedText: selected,
            range: range,
            isAtEndOfLine: isEOL
        )
    }
}
