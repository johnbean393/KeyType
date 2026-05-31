# KeyType — Token Profiles (ACPF format)

A **token profile** is a tokenizer-specific, memory-mappable companion file that stores stable
token facts (raw bytes, flags, display width, static bias), a prefix trie, and special-token
lists. It lets the runtime sampler turn raw next-token logits into autocomplete-suitable
candidates **without rebuilding expensive structures or calling the tokenizer in the hot loop**.

KeyType uses its own format, **`ACPF` ("Autocomplete Profile")**. This is an original,
clean-room design — **do not implement Cotypist's `FEBI` format or reuse its layout.**

> Profiles are generated artifacts. They are **gitignored** (`*.bin`) and must be reproducible by
> running the builder against an openly-licensed tokenizer. Never commit a profile or a model.

## What it is / isn't
- ✅ Vocabulary intelligence tied to one tokenizer family + vocab size (e.g. `qwen3-v151936`,
  `gemma-vNNNN`). Read-only at runtime, validated by tokenizer hash.
- ❌ Not a model adapter, not user training data, not a model replacement.
- Regenerate whenever the tokenizer vocabulary changes.

## Current code state — shipped

`Packages/TokenProfiles` implements both the runtime contract and the on-disk format:
- `AutocompleteProfile` protocol: `record(for:)`, `isExcluded(_:mode:)`, `bias(for:mode:)`,
  `displayWidth(for:)`, `stopBehavior(for:)`, `tokenAllowed(_:afterRequiredPrefix:)`, with
  `TokenProfileRecord`, `TokenProfileFlags` (OptionSet), `TokenStopBehavior`, and
  `InMemoryAutocompleteProfile` (used in tests).
- The on-disk **`ACPF`** binary format with a memory-mapped reader
  (`MmapAutocompleteProfile: AutocompleteProfile`) and an **offline builder** that produces the file
  from a GGUF tokenizer (ADR-009). Profiles are generated in-app per model family during model
  download (ADR-034).

The spec below documents that shipped format and its validation contract; treat it as the
reference when changing the schema or builder (bump the schema version on any layout change).

## What to store

| Section | Contents |
|---|---|
| Header | Magic `ACPF`, version, endianness, vocab size, tokenizer hash, model-family string, section offsets/lengths, build timestamp, feature flags. |
| Token table | One fixed-size record per token id: bytes offset/len, flags, display width, static bias, token type, first byte, UTF-8 validity. |
| Token bytes blob | Concatenated raw token bytes exactly as the tokenizer emits them (avoids tokenizer calls during filtering). |
| Prefix trie | Byte-level trie mapping partial required prefixes → admissible token ids / child nodes. |
| Prefix buckets | First-byte / short-prefix buckets for fast constraint + prefix expansion. |
| Special lists | Excluded, stop, newline, space, sentence-end, emoji, control/chat-template tokens. |
| Bias tables | Static per-token / per-class adjustments applied before top-k/top-p. |
| Validation metadata | Tokenizer digest, source GGUF metadata digest, generator version, schema version. |

## Token flags

These already exist in `TokenProfileFlags`; the builder must set them correctly:

`SPECIAL`, `EXCLUDED`, `STOP`, `WHITESPACE`, `NEWLINE`, `WORD_START`, `WORD_CONTINUATION`,
`PUNCTUATION`, `SENTENCE_END`, `EMOJI`, `CHAT_MARKER`, `INVALID_UTF8`.

Meaning highlights: `EXCLUDED` = never sample directly (BOS/PAD/UNK/control usually). `STOP` =
EOS/EOT/app-defined termination, allowed only as a stop condition, never displayed. `CHAT_MARKER`
= looks like assistant scaffolding (`<|assistant|>`, `<start_of_turn>`, `### Response`) — exclude;
base autocomplete must never emit it. `INVALID_UTF8` = raw bytes don't decode alone (may still be
valid mid multi-token byte sequence).

## Suggested binary schema

Use a simple, **versioned, offset-based, single-endianness** layout. Align sections to 64 bytes
for clean memory mapping. Optimize/compress only after the uncompressed version is correct and
benchmarked.

```c
struct Header {
    char     magic[4];          // "ACPF"
    uint16_t version;           // schema version
    uint16_t endian;            // 0x0102 sentinel
    uint32_t header_size;
    uint32_t vocab_size;
    uint64_t tokenizer_hash_lo;
    uint64_t tokenizer_hash_hi;
    uint32_t model_family_len;
    uint32_t flags;
    Section  sections[SECTION_COUNT];
};
struct Section { uint64_t offset; uint64_t length; uint32_t item_size; uint32_t item_count; };
struct TokenProfileRecord {     // one per token id
    uint64_t bytes_offset;
    uint32_t bytes_len;
    uint32_t flags;
    float    static_bias;
    uint16_t display_width;
    uint16_t token_type;
    uint16_t first_byte;        // 0..255, or 256 = empty/unset
    uint16_t reserved;
};
```

## Build pipeline (offline CLI — slow is fine; runtime must be fast)

Implement as a SwiftPM **executable** target (or a sub-tool) that runs once per
tokenizer/model-family:

```
Load GGUF tokenizer → extract token bytes → classify (flags) → measure display width →
assign static bias → build trie + buckets → serialize sections → validate
```

```
for token_id in 0..<vocab_size:
    raw   = tokenizer.token_to_bytes(token_id)
    text  = try_decode_utf8(raw)
    flags = classify(raw, text, token_id, metadata)
    width = display_width(text)
    bias  = static_bias(flags, text, policy="general_text")
    token_table[token_id] = record(bytes_offset=blob.append(raw), len, flags, bias, width, type, first_byte)
    if not flags & EXCLUDED:
        trie.insert(raw, token_id)
        first_byte_buckets[raw[0]].append(token_id)
write header + all sections
```

## Bias policy (start conservative)

The model logits carry the real probability signal; the profile only removes bad autocomplete
behavior and nudges toward short insertable continuations.

| Token class | Default |
|---|---|
| BOS/PAD/UNK/raw control | −∞ or exclude entirely |
| EOS/EOT | don't display; allow as stop condition |
| Chat/template markers | exclude |
| Very long tokens (width > limit) | down-bias or block |
| Newline | neutral in code/terminal, negative in prose, blocked in single-line fields |
| Repeated whitespace | down-bias unless field implies indentation |
| Space-prefixed word starts | slight positive (natural continuations) |
| Punctuation | neutral / slight positive when it cleanly finishes a phrase |
| Sentence-end punctuation | allowed, then prefer stop for short completions |
| Emoji | only in emoji mode / when context strongly supports it |

## Runtime use (between logits and sampling)

```
logits = runtime.logitsForNextToken()
for token_id in 0..<vocab_size:
    p = profile.record(token_id)
    if profile.isExcluded(token_id, mode): logits[token_id] = -inf; continue
    if single_line_field and p.flags.NEWLINE: logits[token_id] = -inf; continue
    if required_prefix and not profile.tokenAllowed(token_id, afterRequiredPrefix): logits[id] = -inf; continue
    logits[token_id] += profile.bias(token_id, mode)
sample top_k=64, top_p≈0.9–0.95, then advance trie state
```

The profile does **not** replace output filtering — the app still validates each candidate against
text-field state and UI policy (`AutocompleteCore.SuppressionReason`).

## Downstream integration contract (maps to `AutocompleteProfile`)

`open(path, tokenizer)` (mmap + validate header/vocab/hash) · `record(id)` · `bytes(id)` ·
`isExcluded(id, mode)` · `bias(id, mode)` · `prefixStart(requiredBytes)` ·
`tokenAllowed(state, id)` · `prefixAdvance(state, id)` · `displayWidth(id)` · `stopBehavior(id)`.

## Validation tests (write these before using a profile in the sampler)
- Header rejects wrong magic / version / vocab size / tokenizer hash.
- Every token id has exactly one record with a valid bytes range.
- Round-trip: `bytes(id)` matches `tokenizer.token_to_bytes(id)` for sampled ids.
- Every non-excluded token appears in the prefix trie.
- Known special tokens are excluded or stop-only.
- Known word-start / whitespace / newline / emoji / punctuation tokens get expected flags.
- Required-prefix queries return only tokens whose bytes can satisfy the prefix.
- Fuzz required byte prefixes → no invalid memory access / impossible trie state.
- Golden prompts produce identical candidate sets before/after serialization (round-trip stable).

## Practical defaults

`max_completion_tokens`: 4 prose / 8 code / 1–3 correction-emoji · `top_k` 64 · `top_p` 0.90–0.95 ·
`temperature` 0.7–1.0 (tune by acceptance) · small `branch_width` (4–16) · `relative_cutoff` to
drop branches far below the best · newline blocked single-line, down-biased prose, allowed
code/terminal · exclude all special tokens except explicit stops · exclude UNK / standalone
invalid UTF-8 unless byte fallback requires it.
