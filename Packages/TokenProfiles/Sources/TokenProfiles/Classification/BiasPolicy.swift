import AutocompleteCore
import Foundation

/// Conservative starting bias policy described in `docs/03-token-profiles.md` and the
/// implementation brief (PDF §6). The model logits carry the real probability signal;
/// the profile just removes bad autocomplete behaviour and gently nudges towards short
/// insertable continuations. Numbers live as `public static let` constants so M5 can
/// tune them without changing call sites — and so the writer/reader/tests all share
/// the same source of truth.
///
/// `staticBias` is the per-token base bias stamped into the on-disk record. The runtime
/// adds a small per-mode delta on top (`delta(...)`) — only modes where the value
/// differs from `static_bias` are materialised in the on-disk BIAS_TABLES section, so
/// the typical lookup is a single load with no override pair.
public enum BiasPolicy {

    // MARK: - Tunables

    public static let infiniteNeg: Float = -Float.infinity

    public static let longTokenWidthThreshold: Int = 32
    public static let longTokenStaticPenalty: Float = -2.0

    public static let repeatedWhitespaceLength: Int = 4
    public static let repeatedWhitespaceStaticPenalty: Float = -1.0
    public static let repeatedWhitespaceCodeBonus: Float = 0.5
    public static let repeatedWhitespaceTerminalBonus: Float = 0.5

    public static let wordStartSpacePrefixStaticBonus: Float = 0.2
    public static let wordStartProseBonus: Float = 0.1

    public static let punctuationProseBonus: Float = 0.1

    public static let sentenceEndStaticBonus: Float = 0.1
    public static let sentenceEndProseBonus: Float = 0.2

    public static let emojiStaticPenalty: Float = -3.0
    /// Re-enables emoji tokens in emoji mode (cancels `emojiStaticPenalty`).
    public static let emojiEmojiModeDelta: Float = 3.0

    /// Whole-tag markup tokens (Gemma's `<b>`/`</code>` block) leak into prose when the context is
    /// thin: observed shown `</code>` at logprob −0.35 with legitimate runners-up at −1.7…−3.8, so
    /// the emoji-sized −3 would not cover the gap. −6 pushes a tag below any plausible prose token
    /// while staying finite (the output-stage `MarkupTagGuard` is context-aware; this is not).
    public static let markupTagStaticPenalty: Float = -6.0
    /// Re-enables markup-tag tokens where markup is working material (cancels the static penalty):
    /// HTML/Markdown in editors (code mode) and editors running inside a terminal.
    public static let markupTagCodeModeDelta: Float = 6.0
    public static let markupTagTerminalModeDelta: Float = 6.0

    public static let newlineProseDelta: Float = -2.0

    // MARK: - Static bias

    /// The bias stamped into `TokenProfileRecordRaw.staticBias` for the token. This is
    /// the *default* the engine sees when no per-mode override is present.
    public static func staticBias(flags: TokenProfileFlags, displayWidth: Int, bytes: [UInt8]) -> Float {
        if flags.contains(.excluded) || flags.contains(.chatMarker) {
            return infiniteNeg
        }
        if flags.contains(.invalidUTF8) && !flags.contains(.stop) {
            return infiniteNeg
        }
        if flags.contains(.stop) {
            // Stops aren't displayed — the `stopBehavior` is what the engine consults.
            // Setting their bias to 0 (rather than −∞) means a tokenizer-declared EOG can
            // still be sampled if the engine explicitly asks for it.
            return 0
        }

        var bias: Float = 0
        if flags.contains(.emoji) {
            bias += emojiStaticPenalty
        }
        if flags.contains(.markupTag) {
            bias += markupTagStaticPenalty
        }
        if isRepeatedWhitespace(flags: flags, bytes: bytes) {
            bias += repeatedWhitespaceStaticPenalty
        }
        if flags.contains(.wordStart) && flags.contains(.whitespace) {
            bias += wordStartSpacePrefixStaticBonus
        }
        if flags.contains(.sentenceEnd) {
            bias += sentenceEndStaticBonus
        }
        if displayWidth > longTokenWidthThreshold {
            bias += longTokenStaticPenalty
        }
        return bias
    }

    // MARK: - Per-mode delta

    /// Delta on top of `staticBias` for the given mode. Returns `0` when there is no
    /// per-mode adjustment for this class — those entries are *not* materialised in the
    /// on-disk BIAS_TABLES section (the reader returns 0 when the (id, Δ) pair is
    /// missing for a given mode).
    public static func delta(
        flags: TokenProfileFlags,
        mode: BiasMode,
        bytes: [UInt8]
    ) -> Float {
        if flags.contains(.excluded) || flags.contains(.chatMarker) {
            return 0
        }
        if flags.contains(.invalidUTF8) && !flags.contains(.stop) {
            return 0
        }

        switch mode {
        case .prose:
            var delta: Float = 0
            if flags.contains(.newline) { delta += newlineProseDelta }
            if flags.contains(.wordStart) && flags.contains(.whitespace) { delta += wordStartProseBonus }
            if flags.contains(.punctuation) && !flags.contains(.sentenceEnd) { delta += punctuationProseBonus }
            if flags.contains(.sentenceEnd) { delta += sentenceEndProseBonus }
            return delta
        case .code:
            var delta: Float = 0
            if isRepeatedWhitespace(flags: flags, bytes: bytes) { delta += repeatedWhitespaceCodeBonus }
            if flags.contains(.markupTag) { delta += markupTagCodeModeDelta }
            return delta
        case .terminal:
            var delta: Float = 0
            if isRepeatedWhitespace(flags: flags, bytes: bytes) { delta += repeatedWhitespaceTerminalBonus }
            if flags.contains(.markupTag) { delta += markupTagTerminalModeDelta }
            return delta
        case .emoji:
            if flags.contains(.emoji) { return emojiEmojiModeDelta }
            return 0
        case .correction:
            return 0
        case .singleLine:
            if flags.contains(.newline) { return infiniteNeg }
            return 0
        }
    }

    // MARK: - Helpers

    /// `true` iff the token is whitespace-only of at least `repeatedWhitespaceLength`
    /// bytes — used to down-bias visually noisy whitespace runs (and to *up*-bias them
    /// in code/terminal where indentation is meaningful).
    static func isRepeatedWhitespace(flags: TokenProfileFlags, bytes: [UInt8]) -> Bool {
        guard flags.contains(.whitespace), !flags.contains(.wordStart) else { return false }
        guard bytes.count >= repeatedWhitespaceLength else { return false }
        // Stripping a single leading Ġ/Ċ/▁ marker (each 2 bytes in UTF-8) leaves the
        // residual whitespace bytes; we count the raw byte length as a fast approximation.
        for b in bytes {
            // ASCII whitespace bytes (space, tab, CR, LF) or marker continuation bytes.
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0xC4 || b == 0xA0 || b == 0x8A {
                continue
            }
            return false
        }
        return true
    }
}
