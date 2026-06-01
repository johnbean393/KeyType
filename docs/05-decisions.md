# KeyType — Decision Log

Append-only record of meaningful decisions (lightweight ADR style). Newest at the bottom.
Add an entry whenever you make a non-obvious architectural, dependency, or product choice so the
next session (human or agent) has the context. **Do not rewrite history; only append.**

Template:

```
## ADR-NNN — <short title>
- Date: YYYY-MM-DD
- Status: proposed | accepted | superseded by ADR-XXX
- Context: what problem / constraint prompted this.
- Decision: what we chose.
- Consequences: trade-offs, follow-ups, what this rules out.
```

---

## Index

Newest at the bottom of the file. **When you add an ADR, use the next sequential number and add a
row here.**

| #   | Title | Area |
| --- | ----- | ---- |
| 001 | Reconstruction, MIT license | project |
| 002 | Modular SwiftPM package architecture | architecture |
| 003 | Flatten the nested repository structure | project |
| 004 | Reuse Red Dot caret-tracking code | context-capture |
| 005 | Background menu-bar app shell; App Sandbox disabled | app |
| 006 | Notification-driven context capture | context-capture |
| 007 | llama.cpp via prebuilt xcframework `binaryTarget` | model-runtime |
| 008 | Tokenizer-backed prompt budgeting / `maxPromptTokens` | prompting |
| 009 | ACPF on-disk token-profile schema | token-profiles |
| 010 | Constrained multi-branch decoding | generation |
| 011 | Real-model generation fixes (digest, exclusion, recurrent KV) | generation |
| 012 | Decoder latency: measure in release; beam tuning | performance |
| 013 | Context-aware sentence-boundary stop | generation |
| 014 | Multilingual robustness of the pipeline | generation |
| 015 | Current-word typo guard inside the beam | generation |
| 016 | Filtering, inline overlay, insertion, Tab accept → MVP | ui/insertion |
| 017 | Caret boundary, FIM, environment-context policy | prompting |
| 018 | KV branch reuse — prefill once, snapshot/restore | model-runtime |
| 019 | Mid-word token healing | generation |
| 020 | Suggestion anchoring against the live caret | ui |
| 021 | Confirm-and-tear-down on quit (ggml-metal abort) | app |
| 022 | Context-aware app-compatibility policies | app-compatibility |
| 023 | Personalization & polish (history, telemetry, Settings) | personalization |
| 024 | Prediction-log quality fixes | generation |
| 025 | Required-prefix decoding bypasses raw-logit pre-selection | generation |
| 026 | Typo net sees through the heal | generation |
| 027 | Resolve browser web-area focus to editable descendant | context-capture |
| 028 | Estimated browser carets stay inline | ui |
| 029 | Browser ghost text: defensive color, multiline estimates | ui |
| 030 | Treat Cursor as a code editor target | app-compatibility |
| 031 | Treat WeChat as an explicit chat surface | app-compatibility |
| 032 | Read Apple Mail compose bodies from focused HTML | app-compatibility |
| 033 | Reject container-sized caret bounds in multiline web | context-capture |
| 034 | In-app model download + auto ACPF + family resolution | model-runtime |
| 035 | Catalog artifacts pinned to base GGUFs | model-runtime |
| 036 | Import an arbitrary user-supplied GGUF | model-runtime |
| 037 | Dismiss stale completions from the key tap | generation |
| 038 | Trailing punctuation is a separate Tab unit | insertion |
| 039 | Tag synthesized insertion events so key taps ignore them | insertion |
| 040 | On-screen text (OCR) context via focused-window capture | context-capture |
| 041 | Guided drag-and-drop permission flow | app |
| 042 | KeyType app icon direction | app |
| 043 | Batched beam-frontier decoding | performance |
| 044 | Detailed component profile — snapshot capture is next lever | performance |
| 045 | The "20 ms capture" was a sync artifact | performance |
| 046 | Incremental beam decoding | performance |
| 047 | Group source files by responsibility inside targets | architecture |
| 048 | Mid-line (FIM) completions render in a capsule | ui |
| 049 | Suppress suffix-duplicating completions; OCR guard | generation |
| 050 | The separator leads the next word, not the previous one | insertion |
| 051 | Release & distribution: Developer-ID DMG + Sparkle appcast | distribution |
| 052 | A failed profile build must not leave a usable artifact | model-runtime |
| 053 | Hide completion latency without changing candidate quality | performance |
| 054 | Redraw the remaining ghost text eagerly on Tab acceptance | ui |
| 055 | Drop a word break the model emits after a healed stem | generation |
| 056 | Mid-word quality: accurate OCR, dead-end + charset guards | generation |
| 057 | Mid-line FIM quality: truncate-at-overlap, suffix rerank, windowing | generation |
| 059 | Trie self-check tolerates duplicate-byte tokens (Gemma) | token-profiles |
| 063 | Preserve visible completions for macOS screen capture shortcuts | keyboard/ui |

---

## ADR-001 — Reconstruction, MIT license

- Date: 2026-05-29
- Status: accepted
- Context: KeyType is an open-source alternative to the closed-source Cotypist.
- Decision: Build from behavior-level research (`docs/01–03`). Use our own `ACPF` profile  
format (not Cotypist's `FEBI`).  
License under MIT.

## ADR-002 — Modular SwiftPM package architecture

- Date: 2026-05-29
- Status: accepted
- Context: A system-wide autocomplete spans AX capture, model runtime, prompting, decoding, UI,
and insertion. These need independent testing and clear boundaries.
- Decision: Keep the existing 9-package graph under `Packages/`, with `AutocompleteCore` as the
dependency-free shared contract. The app target is the only wiring layer.
- Consequences: Cross-module types go in `AutocompleteCore`. Packages stay decoupled and unit-
testable; the app composes concrete implementations in `KeyTypeModuleGraph.swift`.

## ADR-003 — Flatten the nested repository structure

- Date: 2026-05-29
- Status: accepted
- Context: The project was triple-nested: the Cursor workspace root (with `.cursor/` and the
`.xcworkspace`) sat one level *above* the git root + Xcode project, so rules/workspace files
were outside version control and an agent's commits wouldn't capture them.
- Decision: Move the `.git` directory and all project folders up so the workspace root == git root
== Xcode project root. Update the `.xcworkspace` reference from `group:KeyType/KeyType.xcodeproj`
to `group:KeyType.xcodeproj`. Local SwiftPM package references were unaffected (relative paths
preserved). Working tree verified clean afterward.
- Consequences: `.cursor/rules`, `docs/`, and the workspace file are now versioned. App-target
sources remain at `KeyType/KeyType/` (standard Xcode layout). The `.xcworkspace` and
`.gitignore` should be committed (the user controls when commits happen).

## ADR-004 — Reuse Red Dot caret-tracking code

- Date: 2026-05-29
- Status: accepted
- Context: Robust on-screen caret location across native/Chromium/web fields is the hardest part
of context capture and is already solved in the sibling `Red Dot` project.
- Decision: Port `AXCaretGeometryResolver`, the caret tracker, and the overlay panel from Red Dot
into `MacContextCapture` / `CompletionUI` rather than rewriting. Convert 30 fps polling to
AX-notification-driven refresh with a poll fallback.
- Consequences: Preserves the proven exact/derived/estimated quality ranking and multi-display
coordinate conversion. Keeps placement feeling native; reduces risk in M1.

## ADR-005 — Background menu-bar app shell; App Sandbox disabled

- Date: 2026-05-29
- Status: accepted
- Context: The Xcode template shipped a windowed SwiftData app with `ENABLE_APP_SANDBOX = YES`.
KeyType is a system-wide utility: it must read the focused text field across any app (AX) and
later synthesize keystrokes (`CGEvent`). Both are blocked by App Sandbox, and the product needs
no dock window — only a menu-bar presence plus an onboarding window.
- Decision:
  - App shell uses SwiftUI `MenuBarExtra` for the status item plus a single named `Window`
  scene (`id: "onboarding"`) for first-run / settings UI. `NSApplicationDelegateAdaptor`
  sets `NSApp.setActivationPolicy(.accessory)` and posts a notification observed by the
  `MenuBarExtra` content to open the onboarding window with `@Environment(\.openWindow)`.
  - `INFOPLIST_KEY_LSUIElement = YES` suppresses the dock icon.
  - `ENABLE_APP_SANDBOX = NO`; `ENABLE_HARDENED_RUNTIME = YES` stays on. KeyType is distributed
  outside the Mac App Store (Developer ID), so this trade-off is acceptable.
  - First-run onboarding (`OnboardingView`) explains why each permission is needed, shows live
  granted / not-granted status from `PermissionsManager`, calls
  `AXIsProcessTrustedWithOptions([prompt: true])` / `CGRequestScreenCaptureAccess()` to
  trigger the system prompt, and deep-links to the right Privacy & Security pane via
  `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` /
  `Privacy_ScreenCapture`. Accessibility is required; Screen Recording is optional.
  - The SwiftData template files (`Item.swift`, `ContentView.swift`, `ModelContainer`) were
  removed.
- Consequences:
  - Cannot ship via the Mac App Store; must notarize via Developer ID — fine for the product.
  - Need to keep an eye on hardened-runtime entitlements as we add capabilities
  (e.g. `com.apple.security.cs.disable-library-validation` if we ever load third-party
  dylibs for llama.cpp; revisit when M2 lands).
  - The activation policy is `.accessory`, so `NSApp.activate(...)` is needed before showing
  the onboarding window to bring focus to KeyType.

## ADR-006 — Notification-driven context capture (replaces Red Dot's 30 fps poll)

- Date: 2026-05-29
- Status: accepted
- Context: Red Dot's `AccessibilityCaretTracker` ran a 30 fps `Timer` that always re-resolved the
focused element + caret, regardless of user activity. KeyType is keystroke-driven, must feel
instant, and must not burn battery while no one is typing.
- Decision:
  - Port `AXCaretGeometryResolver`, `AXCaretHelper`, and the multi-display
    `DisplayGeometry` / `DisplayCoordinateConverter` into `MacContextCapture` verbatim in
    behavior, preserving the exact -> derived -> estimated quality ranking.
  - Replace the 30 fps poll with `AccessibilityContextTracker`: an `AXObserver` registered on
    the frontmost app's pid for
    `kAXFocusedUIElementChanged`, `kAXFocusedWindowChanged`,
    `kAXSelectedTextChanged`, `kAXValueChanged`, `kAXUIElementDestroyed`,
    and `kAXWindowMiniaturized`, plus an `NSWorkspace.didActivateApplicationNotification`
    listener to re-target the observer on app switches. Refreshes are debounced (~20 ms) so
    bursts of `AXValueChanged` / `AXSelectedTextChanged` coalesce, and a low-frequency
    (2 Hz) safety poll catches apps that under-report notifications. All AX reads happen on
    the main actor, bounded by the resolver's existing depth/node caps.
  - Field reading is centralized in a pure `FocusedFieldReader` plus small helpers
    (`TextCursorSplitter`, `WritingDirection`, `LanguageDetector`) so they can be unit-tested
    without a live AX tree. `MacContextCaptureService` (the pull-style `ContextProviding`
    entry) shares the same reader, so both push and pull paths emit identical
    `TextFieldContext` values.
  - Port `RedDotOverlayWindow` into `CompletionUI` as `CaretDebugOverlayWindow` — same
    borderless, non-activating, all-spaces, click-through `NSPanel` recipe, but with a thin
    caret-aligned marker. M1 ships this as a **debug overlay only**; M6 swaps the marker for
    real ghost-text.
  - Wiring lives in the app target (`KeyType/ContextCaptureController.swift`): it owns the
    tracker + overlay, logs each emitted context via `os.Logger`, and is gated on the
    Accessibility permission. This keeps `MacContextCapture` (no AppCompatibility / overlay
    dependency) and `CompletionUI` decoupled.
- Consequences:
  - CPU/energy near zero when the user is idle; latency to first context is bounded by
    `debounceInterval` (~20 ms) rather than the 33 ms polling tick.
  - The `safetyPollInterval` (0.5 s) is the worst-case staleness on apps that swallow AX
    notifications; tunable per-app via `AppCompatibility` in a later milestone.
  - Browser domain extraction is best-effort (`AXWebArea` -> `AXURL`, fallback to the trailing
    token of the window title). Sites that don't surface `AXURL` will report a nil domain;
    M7 (per-app overrides) is the place to add web-specific fallbacks if needed.
  - Initializers across the new types are `nonisolated` so they can be referenced from default
    parameter values in either Swift 5 (SPM packages) or the Xcode app's Swift 6-mode strict
    isolation defaults; their methods stay `@MainActor`.

## ADR-007 — llama.cpp integration via prebuilt xcframework `binaryTarget`

- Date: 2026-05-29
- Status: accepted (amended 2026-05-29 to use a local-path binding)
- Context: M2 needs a real `LocalModelRuntime` backed by llama.cpp. Three integration paths were
  considered: (A) a third-party SwiftPM wrapper (`mattt/llama.swift`, `StanfordBDHG/llama.cpp`)
  that re-exports the full C++ API and forces `.interoperabilityMode(.Cxx)` to propagate through
  every consumer of `ModelRuntime`; (B) the official llama.cpp prebuilt **xcframework** consumed
  directly as a SwiftPM `binaryTarget`, using only the C API; (C) building llama.cpp from source
  inside this repo (vendors a large ggml/Metal tree, slow + fragile, high maintenance).
- Decision: Take option **B**. Use the official llama.cpp xcframework (current target build
  `b9402`, produced by `build-xcframework.sh`) and wrap only the C surface (`llama.h`) in a new
  isolated target `LlamaModelRuntime` inside the `ModelRuntime` package. The pre-existing
  `ModelRuntime` library target (with the `LocalModelRuntime` / `ModelTokenizing` protocols,
  `StubModelRuntime`, `UTF8FallbackTokenizer`) stays dependency-free and untouched so
  `ConstrainedGeneration`, `Prompting`, and existing tests keep compiling and running with the
  stub. The Xcode app and other packages depend on the protocol target; only the eventual
  concrete wiring point links the llama target.
- Binding form (amended): the binary is consumed as `binaryTarget(path:)` pointing at a vendored
  copy under `Packages/ModelRuntime/Vendor/llama.xcframework`. The Vendor directory is
  gitignored, so the binary is never committed. The original plan was `binaryTarget(url:checksum:)`
  against `https://github.com/ggml-org/llama.cpp/releases/download/b9402/llama-b9402-xcframework.zip`,
  but the GitHub release CDN was practically unusable for our network during M2 implementation;
  we switched to a locally-supplied build of the same `b9402` tag. The url+checksum form remains
  the preferred shape once we have a reliable mirror — only the `Package.swift` line changes;
  the wrapping target stays identical. The vendored framework's macOS slice is
  `macos-arm64_x86_64/llama.framework` (~9.6 MB binary, universal arm64+x86_64) with Metal
  acceleration on Apple Silicon and a module map that exposes `import llama` directly.
- Consequences:
  - The binary is never committed (gitignored under `Packages/ModelRuntime/Vendor/`). A
    fresh clone must drop a matching `llama.xcframework` into that directory before
    `swift build` for the `LlamaModelRuntime` target will succeed — `ModelRuntime` (protocols
    + stub) and every other package keep building without the framework present.
  - The `LocalModelRuntime` protocol surface is unchanged — KV prefix reuse is an internal detail
    of `LlamaModelRuntime.prepare(promptTokens:)`. No consumer changes.
  - Because the framework is dynamic, when the **app target** eventually links it (out of scope
    for M2, which is package-test acceptance only), the hardened runtime will need
    `com.apple.security.cs.disable-library-validation`. ADR-005 already flagged this as a
    follow-up; document it here as the trigger.
  - Pin updates are explicit: bumping the build tag means replacing the vendored framework
    (or, once we move to url+checksum, recomputing the checksum) — reproducible and auditable.
  - If a future upstream change forces C++ interop at the Swift import boundary, the wrap is
    already isolated to one target — we can interpose a thin C-only shim target without touching
    `AutocompleteCore` / `ConstrainedGeneration`.

## ADR-008 — Tokenizer-backed prompt budgeting and latency-derived `maxPromptTokens`

- Date: 2026-05-29
- Status: accepted
- Context: M3's acceptance bar is that the rendered prompt "stays within `maxPromptTokens`
  measured by the real counter" and that oversized `before-/after-cursor` truncate toward the
  caret. Before this milestone `Prompting` used `ApproximatePromptTokenCounter`
  (`ceil(chars/4)`), `truncate(...)` worked in characters (`budget * 4`), `allocate(...)` charged
  only the content (not headings or `\n\n` separators) against the running budget, and
  `PromptBuilder.maxPromptTokens` defaulted to a hand-picked `4096`. None of those are real
  guarantees with a tokenizer like Qwen3.5's: BPE merges, whitespace, and per-token byte ranges
  mean character-count approximations drift, and the unaccounted heading/separator overhead can
  push the final prompt past `maxPromptTokens` even when each section looks within budget. The
  ceiling itself also needs an empirical basis: it is fundamentally a latency budget (cold
  `llama_decode` of the whole prompt with an empty KV cache), not a free parameter.
- Decision:
  - **Tokenizer-backed counter.** Introduced `TokenizerPromptTokenCounter` in `Prompting` that
    wraps any `ModelTokenizing` (in production: `LlamaTokenizer`) and falls back to the
    approximate counter on throw. `PromptTokenCounting` itself is unchanged so existing call
    sites and tests stay green; `ApproximatePromptTokenCounter` remains the default for
    no-runtime contexts (early-init, unit tests).
  - **Truncation by measured tokens.** `truncate(_:toTokens:mode:)` now binary-searches the
    largest `Character`-aligned `prefix`/`suffix` slice whose `tokenCount(...)` is `<= budget`.
    `preserveEnd` keeps the tail (text nearest the caret, used by `beforeCursor`),
    `preserveStart` keeps the head (used by `afterCursor`). Character-boundary cuts mean
    multi-byte content (emoji, CJK) splits safely.
  - **Budget model now accounts for rendering overhead.** `allocate(...)` charges each section's
    rendered heading (`[Heading]\n`) plus the `\n\n` separator before it against the remaining
    budget, and reserves the chatML wrapper overhead up front in `buildPrompt(...)`. A final-fit
    pass walks lowest-priority sections first (and `beforeCursor` last) to absorb any residual
    tokenizer non-linearity, so the rendered prompt is guaranteed to measure
    `<= maxPromptTokens` under the real counter. `estimatedTokenCount` is computed against the
    rendered string with the real counter.
  - **Empirical cold-prefill curve.** Added `PrefillLatencyBenchmarkTests` (skippable when the
    GGUF is missing) measuring cold-prefill p90 for prompts of `[64, 128, 256, 512, 768, 1024,
    1536, 2048, 3072, 4096]` tokens against the M2 `LlamaModelRuntime` with the local
    `Qwen3.5-2B-Base-Q4_K_M` GGUF on Apple Silicon (Metal, debug build). Measured curve on the
    reference machine:

    | tokens | p50 ms | p90 ms |
    | -----: | -----: | -----: |
    |     64 |   17.7 |   29.3 |
    |    128 |   20.8 |   21.0 |
    |    256 |   30.2 |   30.6 |
    |    512 |   50.7 |   50.8 |
    |    768 |   81.4 |  100.9 |
    |   1024 |  102.2 |  102.5 |
    |   1536 |  155.1 |  155.4 |
    |   2048 |  209.1 |  209.7 |
    |   3072 |  325.5 |  335.9 |
    |   4096 |  473.1 |  482.4 |

    Cold-prefill p90 fits the 200 ms budget up to **1536 tokens**; **2048 just busts it
    (209 ms)** and **4096 takes ~482 ms** to cold-prefill.

  - **Default `maxPromptTokens` = 4096 (steady-state-sized, not cold-sized).** Despite the
    cold cliff above, we ship `PromptBuilder.defaultMaxPromptTokens = 4096`. The reasoning is
    that with KV prefix reuse, the cold cost is paid **once per stable context** (focus change,
    or whenever the suffix the user is typing into stops sharing a prefix with the previous
    prompt), while every subsequent keystroke only re-decodes the changed suffix:
      - Identical re-`prepare` (full prefix reuse): ~0.01 ms — a measured no-op.
      - Extend by one token on top of a 512-token prefix: ~52 ms (hybrid attention; pure-
        attention models would be cheaper).
    For autocomplete UX the per-keystroke cost is what matters, and the per-keystroke cost is
    independent of `maxPromptTokens` once the prefix stabilises. The cold ~480 ms at 4096
    is a noticeable but rare cost (and is over a debug build — release will be faster). The
    `LlamaModelRuntime` default `contextLength` is bumped to **4096** to match so the runtime
    can hold a full-budget prompt without reslicing the KV cache. If we ever decide the cold
    cost is too painful on slower hardware, the right knob is to lower `defaultMaxPromptTokens`
    back toward `1536` (the cold-budget-respecting ceiling); the benchmark stays the source of
    truth.
  - **Writing-history seam.** `Prompting` gained `WritingHistoryProviding` /
    `InMemoryWritingHistoryStore` / `WritingHistoryQuery` (selection dimensions from
    `docs/02-prompting.md`: bundle, domain, typingContext, language, recency/longest mixing,
    same-app-only flag, fetch/budget caps). The store is empty by default and lives entirely
    in-memory; persisted history is M8. The app wires it via a new
    `KeyTypeModuleGraph.makePrompt(for:)` assembler that also threads
    `CompletionPolicy.customInstructions` from `AppCompatibility` so `Prompting` stays
    `AppCompatibility`-free.
- Consequences:
  - `Prompting` now depends on `ModelRuntime` (protocols + stub, no llama). Mirrors the edge
    `ConstrainedGeneration` already had, so the package graph stays acyclic and llama stays
    isolated to the `LlamaModelRuntime` target.
  - Tests under `Packages/Prompting/Tests/PromptingTests` use `UTF8FallbackTokenizer` so the
    golden-prompt snapshot and budget math are deterministic (1 ASCII byte = 1 token). They
    cover golden snapshots (base + chatML body), preserve-end/preserve-start truncation, stable
    section ordering with `beforeCursor` last in base mode, clean omission of empty optional
    sections, and the budget guarantee under tight `maxPromptTokens`.
  - `defaultMaxPromptTokens = 4096` is a *steady-state* decision: justified by KV prefix reuse,
    not by the cold-prefill curve. If we change the model family/size, or ship release builds,
    or want to weight the cold path more (e.g. on slower hardware where ~480 ms feels bad), the
    right move is to re-run the benchmark and adjust the constant rather than guess. The
    benchmark is intentionally `XCTSkipUnless`-gated so it stays opt-in but is trivial to
    re-run. The cold-budget-respecting ceiling on this hardware is `1536`; the original M3
    target was `1024`; bumping to `4096` consciously trades cold-prefill latency for context
    room.
  - Truncation uses a binary search calling `tokenCounter.tokenCount(for:)` `O(log N)` times per
    section. For `LlamaTokenizer` (sync C API, thread-safe per llama.h) this is on the order of
    a dozen tokenize calls per oversized section, which is well inside the prefill budget.

## ADR-009 — ACPF on-disk token-profile schema (M4)

- Date: 2026-05-29
- Status: accepted
- Context: M4 needs a clean-room, on-device, memory-mappable token profile so the sampler
  can apply tokenizer-specific suppression, biasing, and prefix walking without ever
  going back to the GGUF. Cotypist's `FEBI` is closed-source; we have to ship our own
  format and decide every detail (layout, hashing, classifier rules, packaging).
- Decision:
  - **One little-endian image, offset-based.** Every reference into the file is an
    absolute file offset (never a pointer), so the file can be `Data(contentsOf:options:
    .alwaysMapped)`'d and dereferenced through `UnsafeRawBufferPointer.loadUnaligned(...)`
    without a decode pass. Apple Silicon + Intel are both little-endian; we still funnel
    every load/store through `.littleEndian` so the format is correct on a hypothetical
    big-endian host.
  - **64-byte section alignment.** Every section starts on a 64-byte boundary so the
    file maps cleanly onto cache lines. The header carries a fixed `(offset, length,
    item_size, item_count) × SectionKind.count` table; the reader bounds-checks once at
    `open(...)` time and never again.
  - **Stable `SectionKind` ordinals.** `tokenTable = 0, tokenBytes = 1, prefixTrie = 2,
    prefixBuckets = 3, specialLists = 4, biasTables = 5, validation = 6`. Once assigned
    an ordinal cannot be reused for a different purpose; the schema version (`UInt16` in
    the header) bumps when the meaning of any section changes.
  - **Token table is fixed-size 32-byte records.** `TokenProfileRecordRaw` packs
    `bytes_offset/len`, `flags`, `static_bias`, `display_width`, `token_type`,
    `first_byte`, and a trie-terminal back-link in 32 bytes. Indexed directly by token
    id (no hash table at runtime). `first_byte = 256` is the empty-bytes sentinel;
    `trieTerminal = UInt16.max` is the "no terminal in trie" sentinel.
  - **Tokenizer identity = SHA-256 over `LE(vocabSize) || foreach id: LE(len) || bytes`,
    low 128 bits packed into `tokenizer_hash_lo/hi`.** Recomputed by
    `MmapAutocompleteProfile.open(at:tokenizerVocabSize:tokenizerBytes:)` and compared
    to the header; a mismatch throws `ACPFOpenError.tokenizerDigestMismatch`. 128 bits
    is overkill for drift detection and keeps the digest field at 16 bytes inside the
    header. We deliberately do **not** also embed a checksum of the bytes blob — a
    corrupted blob will fail the open-time digest recompute, so a separate CRC would be
    redundant.
  - **Trie layout: flat `TrieNodeRaw + TrieEdge[]` in one section.** Nodes hold
    `terminal_token_id`, `first_edge_index`, `byte_edge_count`. Edges are 8 bytes each
    (byte + 3 bytes padding + UInt32 child index), sorted by byte so the runtime can
    binary-search children in O(log k). Terminal id is also cached in the per-token
    record's `trieTerminal` field so frequent lookups skip the walk from root. The
    fuzz test (`testRandomPrefixesNeverTrap`) asserts the cursor never traps regardless
    of input bytes.
  - **Per-mode bias model.** `static_bias` is per-token. Per-mode adjustments live in
    BIAS_TABLES as sparse `(token_id, Δ)` pairs, sorted by id within each mode, so the
    default lookup is one load (and the override lookup is one dictionary hit which the
    reader pre-materialises). Six modes: `prose / code / terminal / emoji / correction /
    singleLine` (`BiasMode.allCases`). Encoding `singleLine` as a *mode*, even though
    the API surface treats it as a per-request flag, keeps the on-disk table layout
    uniform; the reader applies it on top of the chosen `CompletionMode` when
    `isSingleLine == true`.
  - **`isSingleLine` is a flag, not a `CompletionMode`.** `CompletionMode` stays in
    `AutocompleteCore` unchanged (no source breakage downstream); `MmapAutocompleteProfile`
    exposes `isExcluded(_:mode:isSingleLine:)` and `bias(for:mode:isSingleLine:)`
    overloads on top of the existing protocol so the sampler can opt in without forcing
    every consumer to think about newline policy.
  - **Packaging: classifier/format pure in `TokenProfiles`; builder in its own package.**
    `TokenProfiles` depends only on `AutocompleteCore` — every validation test runs
    against a synthetic vocab without llama. The offline CLI lives in
    `Packages/ProfileBuilder` and depends on `TokenProfiles` + `LlamaModelRuntime`; the
    seam is `VocabIntrospecting` (declared in `LlamaModelRuntime`) so the protocol
    itself never escapes the llama-aware module boundary.
  - **Validation surface.** `ProfileSelfCheck` is the single source of truth shared
    between unit tests and the CLI's post-write check. Header / section bounds /
    alignment / digest match are tested as distinct `ACPFOpenError` cases so failures
    name the exact mode. `RoundTripStabilityTests` proves the encoder is deterministic
    and that re-decoded profiles produce the same engine ranking for the same logits.
  - **Storage = Application Support, not the repo.** Generated profiles live at
    `~/Library/Application Support/KeyType/Models/<family>.acpf.bin`, side-by-side with
    the GGUFs. No `.gitignore` rule needed (they're outside the repo by construction).
    `ModelContainer.profileURL(family:)` is the single resolver; `Scripts/build-acpf-
    profile.sh` and `KeyTypeModuleGraph.makeProfile(runtime:family:)` both go through
    it.
  - **First profile: Qwen3.5/3.6 shared tokenizer.** Family label `qwen3-v151936`
    (kept as the script's default even though the locally-installed GGUF clocks a
    larger vocab; the label is a tokenizer-family identifier, not a vocab size). The
    builder produces ~24 MB for ~248 k tokens, which is well under the steady-state
    memory ceiling and maps lazily — actual resident bytes are bounded by what the
    runtime touches.
- Consequences:
  - The runtime can validate any profile at open time in O(vocab × avg-token-bytes) for
    the digest, then O(1) per token-id lookup afterwards. No JSON, no Codable, no
    runtime parsing.
  - `MmapAutocompleteProfile.tokenAllowed(_:in:)` requires walking the token's bytes
    from the cursor's `nodeIndex` to a node whose terminal id matches — this is the
    M5-friendly "is this token a legal next emit" semantics. The writer-correctness
    invariant ("token T's terminal lives at the node reached by walking T's bytes from
    the root") is exposed through `terminalTokenID(at: TrieState)` and used by the
    self-check + tests.
  - Adding a new tokenizer family is now: run `Scripts/build-acpf-profile.sh` with a
    different `FAMILY` and `GGUF`; the rest of the system already supports it.
  - The classifier rules + bias policy are starting points; they live as named
    constants inside `BiasPolicy.swift` so M5/M6 can tune them without changing call
    sites.
  - Future schema bumps revise `currentSchemaVersion`. The reader rejects any other
    value, so a stale `.acpf.bin` from an old build is detected before any field is
    used.

## ADR-010 — Constrained multi-branch decoding (M5)

- Date: 2026-05-30
- Status: accepted
- Context: M5 replaces the greedy single-branch loop in `ConstrainedGenerationEngine` with
  real constrained decoding: a multi-branch search honouring `branchWidth` /
  `relativeCutoff` / `minBranchProbability`, top-k / top-p / temperature shaping with
  cumulative log-probability scoring, required-prefix + byte/trie admissibility from the
  ACPF profile, incremental UTF-8-validated detokenization, the full stop-condition set,
  and prompt cancellation. The central tension is that beam search wants to evaluate logits
  at *many* token paths, while the `LocalModelRuntime` protocol (ADR-007) is deliberately
  **linear** (`prepare` / `decodeNext` / `logitsForNextToken`, one KV cache) and must stay
  stable so `StubModelRuntime` keeps working for tests.
- Decision:
  - **Drive the search over the existing protocol via re-`prepare`.** To score a frontier
    branch the engine calls `runtime.prepare(promptTokens: basePrompt + branchTokens)` then
    `logitsForNextToken()`. No protocol change; the stub stays usable; `LlamaModelRuntime`'s
    documented KV prefix-reuse (ADR-008) means the common prefix is not re-decoded. The
    cost is extra decodes when sibling branches don't share a suffix; with the autocomplete
    defaults (`maxCompletionTokens` 4, small `branchWidth`, branches dying early on stop /
    admissibility / pruning) this is acceptable for M5's *functional* acceptance bar.
    Efficient KV-fork (`llama_memory_seq_cp` to clone a sequence and decode one extra token
    per branch) is the obvious follow-up optimization and is the reason M2 listed the seq
    ops; it can be added later behind an optional capability without touching the protocol
    or `AutocompleteCore`. (Update: ADR-012 prototyped and **rejected** this — once measured in
    a release build the loop is already ~162 ms, so the fork isn't worth its memory/complexity.)
  - **Deterministic best-first beam, not stochastic sampling.** Expansion keeps the
    highest cumulative-logprob branches; `temperature` / `topK` / `topP` only *shape the
    per-step candidate pool* (`TokenSampler.rank`). No RNG — autocomplete must be
    reproducible and testable, and "prefer suppression to a wrong suggestion" argues against
    sampling noise. `relativeCutoff` is a cumulative-logprob **margin** (drop a branch when
    `bestScore − branchScore > relativeCutoff`); `minBranchProbability` is a per-step
    probability floor on which tokens may extend a branch (always keeping at least the best
    so a sharp distribution still yields a candidate).
  - **Profile-agnostic admissibility.** Required-prefix + byte/trie admissibility use the
    `AutocompleteProfile` protocol method `tokenAllowed(_:afterRequiredPrefix:)`
    (`bytes.starts(with: prefix) || prefix.starts(with: bytes)`), which the
    `MmapAutocompleteProfile` backs with its byte blob / trie. A per-branch
    `remainingPrefix` is advanced as tokens are emitted (`GenerationBranch.consumePrefix`),
    so a required prefix can be satisfied across several tokens, and only prefix-satisfied
    branches are ever finalized. Keeping the engine on the protocol (not the concrete mmap
    type) means every search test runs against `InMemoryAutocompleteProfile` with no model
    or profile file.
  - **Incremental, byte-level UTF-8 validation.** Branches accumulate raw token bytes;
    `UTF8Scanner` distinguishes a genuinely malformed sequence (`.invalid` → drop the
    branch) from a merely incomplete trailing multi-byte sequence (`.pending` → keep
    accumulating, decode only the valid prefix). A branch is finalized only when its bytes
    are fully valid (`.valid`), so no candidate ever ends mid-scalar.
  - **Stop conditions.** A branch stops when (a) the model's single most likely raw next
    token is a hard stop — EOS/EOT (`ModelMetadata`) or a `.stopAndSuppress` (`STOP`-flag)
    token — in which case the text so far is kept; (b) an emitted token is `.stopAndDisplay`
    (sentence-end) — the token is appended then the branch finalized; (c) the candidate
    would exceed `maxDisplayWidth`; (d) `maxCompletionTokens` is reached; or (e) there is no
    admissible / in-policy continuation. Hard-stop tokens are never displayed.
  - **Cancellation via cooperative `Task` cancellation.** The engine calls
    `Task.checkCancellation()` at each depth and before each branch's decode, so the app can
    cancel an in-flight completion by cancelling its `Task` when a newer keystroke arrives;
    generation then throws `CancellationError` promptly rather than running to completion.
  - **Testing seam: `TreeScriptedModelRuntime`.** Added a public, path-keyed runtime to the
    `ModelRuntime` package (sibling to `StubModelRuntime`) that returns logits as a function
    of the full token sequence — the step-based stub cannot represent the path-dependent
    logits multi-branch search needs. An optional per-call delay makes generation observably
    in-flight for the cancellation test. The protocol surface is unchanged.
- Consequences:
  - `ConstrainedGeneration` keeps its constructor and `CompletionGenerating` conformance;
    `DecodingConfiguration` gains `minBranchProbability` and `maxCandidates`. The engine is
    split into `DecodingConfiguration`, `TokenSampler`, `GenerationBranch`, and the
    orchestrating `ConstrainedGenerationEngine`.
  - A `ConstrainedGenerationTests` target was added (the package had none). Deterministic
    tests cover multi-branch ranking, the three pruning knobs, single/multi-token required
    prefix, invalid-UTF8 and over-width dropping, EOS / suppress / sentence-end stops,
    cancellation, and policy gates. A `XCTSkipUnless`-gated integration test exercises a real
    `LlamaModelRuntime` + `MmapAutocompleteProfile`.
  - The re-`prepare` strategy trades per-branch decode cost for protocol stability. (Update:
    ADR-012 measured this in a release build — ~162 ms warm per completion — and rejected the
    KV-fork follow-up as unnecessary; the re-`prepare` cost is fine in release.)

## ADR-011 — Real-model generation fixes uncovered by M5 (digest, exclusion, recurrent KV)

- Date: 2026-05-30
- Status: accepted
- Context: Running M5's multi-branch decoder against the real Qwen3.5 GGUF + a freshly built
  ACPF profile surfaced three latent issues from the M2/M4 boundary that the previous
  single-path greedy loop never exercised. None are visible without a real (hybrid) model
  plus a profile whose tokenizer digest is validated at open time.
- Decision:
  - **Tokenizer digest must be computed from identical bytes on both sides.**
    `LlamaVocabIntrospector.bytes(for:)` (used by the builder to stamp the profile's
    tokenizer hash) called `llama_token_to_piece(..., special: true)`, while
    `LlamaTokenizer.rawBytes(for:)` (used by the runtime to *recompute* and validate that
    hash at `MmapAutocompleteProfile.open`) used `special: false`. They diverge on control /
    special tokens, so every profile failed `tokenizerDigestMismatch` against its own model.
    Fixed by making `bytes(for:)` use `special: false`, honoring its documented contract
    ("same as `ModelTokenizing.rawBytes(for:)`"). Special tokens are excluded by
    attribute/role regardless of byte content, so emptying their bytes is harmless.
  - **Special-token exclusion is role/attribute-driven, not text-driven.** With special
    tokens now yielding empty bytes, the classifier could no longer recognise a PAD/BOS-style
    token by its rendered text via the chat-marker regex. A real PAD token that llama reports
    as end-of-generation (`isEOG`) therefore slipped past the old `excluded = isSpecial &&
    !isStop` rule. The classifier now excludes every special token except a genuine
    *displayable stop* (`role == .eos || .eot`); EOG specials without an eos/eot role
    (PAD/SEP/NL and EOG chat markers) are both `.stop` and `.excluded`. This matches the
    existing classifier-flag tests and the `03` bias policy ("BOS/PAD/UNK → exclude
    entirely; EOS/EOT → stop, don't display").
  - **KV prefix reuse is restricted to pure appends (recurrent-safe).** The multi-branch
    decoder re-`prepare`s divergent branch paths, which drove `LlamaModelRuntime.prepare`
    down its `llama_memory_seq_rm` rollback path. On this Qwen3.5 GGUF — which mixes
    attention with Gated Delta Net / SSM (recurrent) layers — the recurrent state can't be
    partially rewound, so the subsequent decode collides with a position the memory still
    holds and `llama_decode` fails M-RoPE's `X < Y` requirement. `prepare` now reuses the
    resident KV cache only when the previous tokens are a strict prefix of the new prompt (a
    pure append, no rollback); every divergence or shrink clears and fully re-decodes, which
    is correct on both attention-only and hybrid models. The seq_rm rollback path was never
    covered by a test; a new `testKVReuseDivergentPathMatchesFreshDecode` locks the new
    behavior in.
  - **Fixed a missing `import ModelRuntime`** in `QwenProfileBuilderTests` (it referenced
    `ModelContainer` without importing the module that defines it — the target dependency was
    already declared).
- Consequences:
  - Profiles built by `Scripts/build-acpf-profile.sh` now validate against the live runtime;
    the M5 on-device integration tests run (not skip) and pass.
  - The append-only KV reuse keeps the per-keystroke fast path (typing extends the prompt)
    while making branch exploration and backspace/divergence safe. Efficient *branch* reuse
    (cloning a resident sequence with `seq_cp` and decoding one extra token) remains the
    future optimization noted in ADR-010; it must be validated against the recurrent layers
    before use.
  - Special tokens store empty bytes in the profile and the tokenizer digest is over
    `rawBytes` (special:false). Drift detection is marginally weaker for special-token-only
    changes, but `vocabSize` is also hashed and the digest now matches what the runtime can
    actually recompute — the property that matters.

## ADR-012 — Decoder latency: measure in release; per-branch work and beam tuning (M5)

- Date: 2026-05-30
- Status: accepted
- **Measurement caveat (read first).** All performance numbers must be taken from a
  **release build** (`swift test -c release` / `swift build -c release`). The Swift package
  test suite builds **debug** by default, where bounds checks, ARC, and the lack of inlining
  inflate the per-token Swift work by **1–2 orders of magnitude** and produce wildly
  misleading latency. Example, same code, same machine (M5 Max), 151,936-token vocab:

  | phase (per branch expansion) | debug | release |
  | --- | --- | --- |
  | raw decode throughput | ~28 tok/s | **~213 tok/s** |
  | `logitsForNextToken` (vocab-wide copy) | ~17 ms | **~0.04 ms** |
  | `TokenSampler.rank` | ~16 ms | **~0.16 ms** |
  | `llama_decode` (clear + re-decode short prompt) | ~16 ms | ~16 ms |

  Only `llama_decode` (Metal compute) is build-mode-independent. The release decode rate
  (~213 tok/s) matches/exceeds a standalone `llama.cpp` host (LM Studio) on the same model.
- Context: The first end-to-end timing of the M5 decoder against the real model
  (Qwen3.5-2B-Base Q4_K_M — a hybrid attention + Gated Delta Net model, fully Metal-offloaded)
  measured **~12.3 s per 4-token completion** *in a debug build*. A phase breakdown attributed
  it to per-branch work repeated across the ~`1 + 3·branchWidth` branch expansions of a depth-4
  beam — chiefly `TokenSampler.rank` (485 ms debug) sweeping the whole vocabulary. The model
  was never the bottleneck (GPU offload confirmed via `load_tensors: ... assigned to device
  MTL0`); the apparent disaster was dominated by debug-mode Swift overhead.
- Decision (algorithmic, behaviour-preserving): kept because they are good practice and cut the
  worst debug-mode cost, even though release makes them nearly free.
  - **Pre-select before ranking.** `TokenSampler.rank` no longer runs softmax + a full
    150k-element sort + 150k `log()` over the whole vocabulary. It first takes the top
    `max(topK·4, 256)` tokens by raw logit via a bounded min-heap (O(n log k), no profile
    lookups), then applies exclusion / admissibility / bias / softmax / top-k / top-p only to
    that pool. For the small vocabularies in the deterministic unit tests the pool is the
    whole vocab, so behaviour there is unchanged. Pre-selection ignores per-token static bias
    (small, relative to the logit spread on the real profile), which cannot realistically lift
    a token from outside the top few hundred into the top-k. (Debug: 485 ms → ~16 ms.)
  - **Fold the hard-stop argmax into the sampler.** `rank` now returns a `SamplerResult`
    carrying the global argmax (tracked in its single candidate scan, before exclusion), so
    the engine no longer does its own `logits.max(by:)` full-vocab pass to detect "the model
    wants to stop here."
  - **Build the logits vector in one pass** (`Array(unsafeUninitializedCapacity:)`).
- Decision (tuning, latency/quality trade-off):
  - **`branchWidth` 8 → 4, `relativeCutoff` 8 → 6** as `DecodingConfiguration` defaults.
    Per-completion latency scales nearly linearly with the number of branch expansions (each is
    one ~16 ms `llama_decode`; the Swift work around it is negligible in release). A release
    `branchWidth` sweep (`testBranchWidthSweep`) showed warm means of **239 / 164 / 107 / 75 /
    43 ms** at width 8/5/3/2/1, with the **top-ranked candidate identical at every width** —
    extra beams only add lower-ranked alternates. Width 4 keeps a genuine multi-candidate
    ranked set at **~162 ms warm mean** (release). The tighter cutoff prunes weak branches in
    confident cases without affecting the dominant continuation.
- Consequences:
  - **Release warm per-completion latency is ~162 ms** (p90 ~233 ms) at the tuned defaults,
    with a one-time ~0.34 s model+profile load. That is already in the interactive range for
    pause-triggered, cancellable autocomplete — no further structural work was required.
  - The `[TokenLogit]` shape of `LocalModelRuntime.logitsForNextToken()` is kept: the test
    stubs return *sparse* token lists (explicit ids, not dense vocab-indexed buffers), so the
    sampler cannot assume `tokenID == bufferIndex`. A raw-buffer accessor is unnecessary in
    release anyway (the readback is ~0.04 ms).
  - Benchmarks live as skip-gated tests in `QualitativeDemoTests` (`testPhaseBreakdown`,
    `testCompletionLatency`, `testBranchWidthSweep`); run them with `-c release` for meaningful
    numbers.
- KV-fork investigation (rejected). The deferred idea — keep `basePrompt` resident once and
  expand a whole beam frontier in one multi-sequence `llama_decode` (via `llama_memory_seq_cp`)
  instead of re-`prepare`-ing each branch — was prototyped and measured, then **rolled back**:
  - The fork is *correct enough*: a `seq_cp` fork reproduces a fresh decode to the same
    accuracy as plain incremental (split-batch) decode (max-abs logit diff ~0.12, **top-5
    tokens unchanged**); `seq_cp` adds no error beyond the split. The ~0.12 divergence is the
    hybrid model's split-vs-unified batch behaviour in its recurrent layers, not a fork bug.
    (`llama_model_is_recurrent` returns `false` for this hybrid model even though it allocates a
    `llama_memory_recurrent` buffer — don't trust that flag.)
  - But it is **not worth it**: in release we are already at ~162 ms. Batching would cut decode
    calls (~13 → ~5 for a depth-4 width-4 beam) for maybe ~80 ms more, at the cost of
    ~300 MB of resident recurrent-state buffers (`n_seq_max` × ~19 MB/seq on this model), a
    behavioural change (the 0.12 split/fork divergence vs today's exact full re-decode), and
    significant sequence-management complexity. Revisit only if a future model/host needs it.

## ADR-013 — Context-aware sentence-boundary stop (M5)

- Date: 2026-05-30
- Status: accepted
- Context: Qualitative testing of longer completions showed the `.stopAndDisplay` sentence-end
  stop truncating useful continuations: `"To make a good cup of coffee, you"` returned
  `" need 1."` — the model had started a numbered list and the period after `1` was taken as a
  sentence end. The `.sentenceEnd` flag is set per-token by `TokenClassifier.containsSentenceEnd`
  on any token whose text contains `.`/`?`/`!`/`…`/closing quote, which is inherently
  context-free and so fires on decimals, list markers (`1.`), and abbreviations (`Mr.`, `e.g.`).
- Decision: keep the per-token flag (the profile can't see context), but disambiguate in the
  engine, which has the generated text. New `SentenceBoundary.isTerminal(_:)` is consulted only
  for tokens the profile flagged as sentence ends; when it judges the boundary *false*, the
  engine treats the step as `continueGeneration` instead of `stopAndDisplay`, so the branch keeps
  going. It rejects: a digit immediately before the period (decimals / numbered lists), a small
  abbreviation set (`Mr./Dr./e.g./i.e./etc./U.S./a.m.` …, plus month/day abbreviations), and a
  single uppercase initial (`J.`). `?`, `!`, `…` stay unambiguous. It is deliberately
  conservative — anything it can't confidently reject stays a real boundary, preserving the
  decoder's bias toward stopping early. The engine passes `prompt.suffix(32) + branch.text` so a
  boundary can be judged against context that began in the prompt.
- Consequences:
  - The coffee prompt now completes `" need 2 cups of water and 1 cup of coffee grounds."`;
    genuine sentence ends (`"…named Lily."`) still stop, and all other example completions are
    unchanged.
  - Pure, table-driven logic with unit tests (`SentenceBoundaryTests`); no model dependency.

### Multilingual compatibility (revisited 2026-05-30)

The first cut handled only the ASCII terminators, which meant two distinct gaps for non-English
text. Both are now closed:

1. **The flag never fired for non-Latin scripts.** `TokenClassifier.containsSentenceEnd` only
   matched `.?!…` and closing quotes, so a Japanese `。`, a Chinese `！/？`, a Hindi danda `।/॥`,
   an Arabic `۔/؟`, or an Armenian/Ethiopic full stop (`։`/`።`) was never flagged — those
   languages got *no* sentence-end stop at all (only EOS / width / max-tokens). The terminator set
   now includes the CJK ideographic + fullwidth/halfwidth stops, Devanagari danda, Arabic stop /
   question mark, Armenian/Ethiopic stops, Myanmar section marks, and the Greek question mark. The
   ideographic comma `、` and Arabic comma `،` are deliberately excluded (clause separators, not
   terminators). This required a **profile rebuild** (flags are baked in at build time); the
   tokenizer-bytes digest is unchanged, so the M4/M5 digest gate still matches.
2. **The disambiguator only needs to special-case the Latin `.`.** The non-Latin terminators
   above are not overloaded with a decimal/abbreviation meaning, so `SentenceBoundary` now treats
   them (and `?`/`!`/`…`) as unambiguous *terminal* via `isUnambiguousTerminator`. Only `.`
   gets context analysis. That analysis already generalises well:
   - the digit-before-period rule uses Unicode-aware `isNumber`, so it also covers German/European
     ordinals (`am 3.`), Arabic-Indic / Devanagari / fullwidth digits, and decimals;
   - the abbreviation set was extended with the common German/French/Spanish/Italian abbreviations
     (`z.B.`, `usw.`, `d.h.`, `p.ex.`, `cf.`, `Sr.` …) that share the Latin period;
   - the uppercase-initial rule only fires for cased scripts, which is correct — CJK / Arabic /
     Hebrew / Devanagari have no case and never write an abbreviation as `<letters>.` mid-sentence.

   Trailing-wrapper trimming also learned the CJK/fullwidth closers (`」』）］`, ideographic
   space) so a terminator hidden behind them is still seen.

   The abbreviation list stays best-effort: a missed abbreviation only falls back to the prior
   "treat as a real boundary" behaviour (an early stop), never a wrong suggestion, which matches
   the product's *prefer suppression to a wrong completion* principle. Covered by new
   `SentenceBoundaryTests` (CJK/Hindi/Arabic/Urdu terminals, German ordinals, non-English
   abbreviations) and `ClassifierFlagTests` (non-Latin terminators flagged, `、` not).

## ADR-014 — Multilingual robustness of the completion pipeline (M5)

- Date: 2026-05-30
- Status: accepted
- Context: After fixing the sentence-boundary stop (ADR-013) the rest of the live completion path
  was audited end-to-end for Latin/ASCII assumptions. Most of it is already script-neutral —
  `PromptBuilder` truncates on grapheme boundaries with binary search; `TokenClassifier` word
  detection uses Unicode `isAlphabetic`/`isNumber` (so CJK ideographs are word characters);
  `UTF8Scanner` already distinguishes a *pending* multi-byte tail from a malformed one; the trie /
  required-prefix logic is byte-level; `BiasPolicy` only adds small nudges that the model logits
  dominate. Two real defects surfaced in the constrained decoder's `GenerationBranch`, plus one
  inherent unit mismatch worth recording.
- Decision:
  1. **Display width is now the grapheme-cluster delta of the decoded text, not a per-token width
     sum.** The old code preferred the profile's per-token `displayWidth` (a grapheme count of the
     token's *own* text). Summed across tokens that share a cluster this over-counts and trips the
     `maxDisplayWidth` cap early for non-Latin text in three ways: (a) combining marks
     (Arabic/Hebrew/Devanagari/Thai vowel signs & tone marks) attach to the previous cluster and
     should add 0 columns; (b) bytes that only partially complete a multi-byte character should add
     0 until the cluster closes; (c) a byte-fallback CJK/Indic character split across several
     single-byte tokens should count once, not once per byte. `extending(...)` now adds
     `max(charDelta, 0)` where `charDelta = newText.count - text.count`, which is correct for all
     three. The `profileWidth` parameter was dropped.
  2. **A branch with a merely *pending* trailing multi-byte sequence is now emittable** (it emits
     its maximal valid-UTF-8 prefix). Previously `isCompleteAndValid` required fully-valid bytes,
     so a byte-fallback character that straddled the token-depth cap caused the *entire* branch to
     be dropped — for some scripts that meant no completion at all. We only ever insert `text`
     (complete characters); the partial tail is silently discarded. A genuinely malformed
     (`.invalid`) sequence is still rejected.
- Consequences:
  - Non-Latin completions are no longer truncated or suppressed by width/finalization artefacts.
    English behaviour is unchanged (whole-character tokens always have `charDelta == profileWidth`
    and never finalize on a pending tail). Covered by new `ConstrainedGenerationEngineTests`
    (byte-fallback CJK width, combining-mark zero width, pending-prefix emission).
  - **Known, deliberately-unpatched limitation:** `maxCompletionTokens` (default 4) is a *token*
    budget, and tokens-per-character varies hugely by script (Latin ≈ a few chars/token, CJK ≈ 1
    char/token, byte-fallback scripts ≈ ⅓ char/token). So "4 tokens" is several words of English
    but only ~1 character of an uncovered script. Reinterpreting the cap as graphemes would break
    the product's stated token contract for Latin text, so the cap stays a token count; choosing a
    script-appropriate value belongs at request-construction time (future app wiring, once
    language detection feeds the request) rather than in the decoder.
  - Languages whose sentences are delimited by spacing rather than punctuation (e.g. Thai) still
    only stop via EOS / width / max-tokens — there is no terminator to key the sentence-end stop
    on. Left as-is to avoid false stops (see ADR-013).

## ADR-015 — Current-word typo guard inside the beam (M5)

- Date: 2026-05-30
- Status: accepted
- Context: Qualitative testing of a mid-word completion (`"…see you tom"`) surfaced a ranking defect:
  the misspelled `"orow."` (→ *tomorow*) out-scored the correct `"orrow."` (→ *tomorrow*) because
  the typo splits into commoner sub-tokens whose summed log-probability beats the single rarer
  `"orrow"` token. Length/score normalisation cannot fix this — the typo wins on raw, per-token,
  and per-character probability — so the fix has to be a *quality* gate, not a re-weighting. The
  architecture already reserved a slot for it (`SuppressionReason.currentWordLooksLikeTypo`, the
  "typo guard" output filter in `docs/01`).
- Decision: a `CurrentWordTypoGuard` that drops a branch the moment the word the user is completing
  *closes* into a misspelling. It is consulted **inside the beam**, not as an end-of-run filter, for
  two reasons that map directly to the requirement "when the typo is fixed, the following
  predictions must adjust":
  1. An end filter would let the typo branch spend beam budget generating its *continuation*
     tokens, all conditioned on the wrong word; and
  2. the correctly-spelled branch could be pruned by the typo's higher score before it is ever
     finalised.
  Judging the word the instant it closes discards the typo branch then and there, so every later
  token is only ever explored from correctly-spelled context. We never rewrite letters in a
  finished string — we keep the alternative branch whose tokens were generated under the correct
  spelling.
  - Dictionary lookups go through a new `WordRecognizing` protocol in `AutocompleteCore` (kept
    AppKit-free); the concrete `SystemWordRecognizer` wraps `NSSpellChecker` in the app target and
    is wired via `KeyTypeModuleGraph.makeCompletionEngine`. With no recogniser injected the guard is
    inert, so existing behaviour/tests are unchanged.
- No-false-positive posture (the explicit requirement): the guard only ever flags a word when **all**
  of these hold, and is otherwise silent —
  - the word is *closed* (a boundary follows it); a still-growing word is a valid prefix and is
    never judged;
  - the user actually typed a stem at the cursor and the model added letters to it (a completion
    that starts a fresh word after a space is the model's own and is left alone);
  - the word is all-lowercase and letters-only (with intra-word `'`/`-`), which skips proper nouns,
    sentence-initial capitals, ACRONYMS, camelCase identifiers, and anything with digits;
  - the mode is `.prose`/`.correction` (never `.code`/`.terminal`);
  - the word does **not** already appear verbatim in the surrounding prefix/suffix — a term the
    user is already using is a personal-dictionary entry, not a typo (requirement 3);
  - and the recogniser, which is itself conservative (returns "recognised" for unknown languages /
    scripts without a dictionary), reports it misspelled. The recogniser is language-aware
    (`context.detectedLanguage`), consistent with ADR-013/014.
- Consequences:
  - The reported case now returns `"orrow."`; the misspelling is dropped before it can be ranked
    or before its continuation is explored. Covered by `ConstrainedGenerationEngineTests`
    (typo dropped vs. the no-guard control, context-term kept, open-word-at-cap not flagged, code
    mode skipped, capitalised word not flagged).
  - Lookups are cached per generation and only happen when a word closes (rare vs. per-token
    decode), and hop to the main actor for `NSSpellChecker`; negligible against decode cost.
  - Scope is intentionally the *current* (cursor-anchored) word — the one fused with the user's
    typed stem and the most error-prone under required-prefix constraints. Words generated entirely
    within the completion are left to the model (extending the guard to them is possible but raises
    false-positive surface for little gain).

## ADR-016 — Candidate filtering, inline overlay, real insertion, Tab acceptance → MVP (M6)

- Date: 2026-05-30
- Status: accepted
- Context: M5 produced ranked on-device candidates but nothing reached the screen or the field. M6 is
  the gated MVP: assemble the first end-to-end Tab-accept slice in TextEdit — output filtering over
  the full `SuppressionReason` taxonomy, an inline ghost-text overlay at the caret, real keystroke
  insertion with clipboard preservation, and a global Tab/Shift+Tab hotkey — wired against the
  already-working Qwen runtime + ACPF profile. Prioritised a working vertical slice over breadth.
- Decisions:
  - **Filter placement.** `DefaultCandidateFilter: CandidateFiltering` lives in `ConstrainedGeneration`,
    not a new package, because it needs the `AppCompatibility` policy table and the `AutocompleteCore`
    contract — both already linked there — and adding a package would mean new `.pbxproj` references
    for no isolation benefit. It returns the first matching `SuppressionReason`, checking, in order:
    app/policy gates (`completionsDisabled`, `midLineCompletionDisabled` when text follows the cursor,
    `tabShortcutsDisabled`), `noCandidate` (empty), `invalidUTF8` (residual U+FFFD — a `String` is
    already well-formed, the decoder drops malformed bytes upstream), `requiredPrefixNotSatisfied`
    (consistency with the demanded prefix bytes, mirroring the decoder's admissibility invariant),
    `displayWidthExceeded`, `maxCompletionLengthExceeded`, `insertionUnsafe` (whitespace-only or any
    C0/DEL control char), and finally `currentWordLooksLikeTypo`. Most reasons are *also* enforced
    in-beam; the filter is a cheap, deterministic, independently-tested last gate so the UI stays dumb.
  - **Synchronous typo seam.** `CandidateFiltering` is synchronous but `WordRecognizing` (ADR-015) is
    `async` (main-actor `NSSpellChecker`). Rather than make the filter async, a `SynchronousWordRecognizing`
    seam can be injected; `NSSpellChecker`'s check is itself synchronous so a main-actor app could supply
    it. In the live app the seam is left nil — the in-beam guard (ADR-015) is the primary, sufficient
    typo defence and wiring it twice would only double spell-checks. The output net is fully covered by
    tests regardless.
  - **Overlay.** Reuse the proven Red Dot `NSPanel` recipe (already ported in `CaretDebugOverlayWindow`):
    borderless `.nonactivatingPanel`, `.canJoinAllSpaces`, `ignoresMouseEvents`, `.screenSaver` level,
    clear background. `GhostTextOverlayWindow` hosts `GhostTextView` (`.secondary` text in the field's
    font, single line) sized to the measured string and pinned **inline at the caret** (LTR starts at
    the caret's right edge, RTL ends at its left edge; vertical extent matches the caret, shifted by the
    policy `verticalOffset`). `InlineGhostTextPresenter` owns the window. `OverlayPlacement` stays
    AppKit-free; the resolved `NSFont` is passed on the `show` path (protocol gained a `font:` parameter
    with a nil-defaulting convenience overload). Font is read best-effort from AX
    (`kAXAttributedStringForRange` over a 1-char probe at the caret in `FieldFontResolver`), falling back
    to a system font sized from the caret height.
  - **Insertion.** `PasteboardCompletionInserter.insert(plan:)` is real, behind two testable seams:
    `KeystrokeSynthesizing` (the real `CGEventKeystrokeSynthesizer` posts ⌘V / ⌘⌥⇧V / Unicode strings /
    backspace) and `CompletionPasteboard` (the real `SystemPasteboard` snapshots items by copying their
    per-type data — re-adding read item objects is unreliable). Order for pasteboard strategies:
    `save → write → paste[/match-style] → optional backspace → restore`. The clipboard is restored after
    a short delay (default 120 ms) so the target app reads it before we put the user's content back —
    a heuristic timing trade-off (tunable; injection strategies skip the pasteboard entirely). Strategy
    dispatch: `pasteboardPaste`/`pasteAndMatchStyle` (clipboard), `chunkedStringInjection`/`characterInjection`
    (direct Unicode keystrokes, per chunk/char), `firstWordOnly` (truncate then paste). The non-breaking-space
    workaround is applied by the planner before dispatch.
  - **Tab acceptance.** `CompletionAcceptanceController` installs a `CGEvent.tapCreate` **session** tap on
    keyDown. It consumes Tab *only* when a completion is visible **and** `policy.allowsTabAcceptance`; Tab
    accepts the **next word**, Shift+Tab the **full** string, and everything else (no completion,
    ⌘/⌥/⌃-Tab, non-Tab keys, a disabled tap) passes straight through so native Tab is untouched. The C
    callback re-enters the main actor via `MainActor.assumeIsolated` (the tap is on the main run loop).
    Multilingual "next word" is `NextWordSplitter` (in `AutocompleteCore`): ICU word boundaries via
    `enumerateSubstrings(.byWords)` — head = up to the *second* word's start, so leading/trailing space
    travels with the accepted word; space-less scripts (CJK/Thai) the system segments are walked
    correctly, and a single-word string is accepted wholesale.
  - **Orchestration & linking.** `CompletionController` (`@MainActor @Observable`) loads the runtime +
    profile + engine **off the main actor** (a `nonisolated` builder `await`ed from a `Task`; the actor
    `LlamaModelRuntime` keeps decode off-main) and degrades gracefully (status shown, completions off)
    when assets are missing. It subscribes to the shared `AccessibilityContextTracker`, and on each change
    cancels the in-flight generation `Task`, builds the prompt + request, generates, filters, and
    shows/hides the overlay; it also exposes the acceptance API. The `LlamaModelRuntime` product is now
    linked into the app target and a `KeyType.entitlements` adds
    `com.apple.security.cs.disable-library-validation` (hardened runtime is on and the llama framework is
    dynamic). A "Completions enabled" toggle + model status were added to the menu bar.
- Consequences:
  - End-to-end works in TextEdit: typing shows ghost text in the field's font; Tab inserts the next word
    and restores the clipboard; wrong/long/mid-line-colliding candidates show nothing.
  - New tests, all green and deterministic (no model/AppKit needed): `CandidateFilterTests` (every
    taxonomy case + pass-through), `CompletionUITests` (placement nil-rect, presenter visible-state, font
    resolution), `TextInsertionTests` (planner selection + inserter dispatch/ordering via a recording
    mock), `NextWordSplitterTests` (multilingual).
  - Watch-items: embedding/signing the dynamic `llama.framework` under hardened runtime (first link may
    need a clean build); the Tab tap must never swallow Tab with no completion visible; the pasteboard
    restore delay is a heuristic — tune per app if a target misses the paste.

## ADR-017: Production completion quality — caret boundary, FIM, environment-context policy

- Status: accepted
- Context: After M6 shipped end-to-end, live quality lagged far behind the deterministic suite.
  `PromptStrategyProbeTests` (an on-device A/B/C harness added this round, with
  `LlamaTokenizer.tokenizeAllowingSpecial` for native FIM tokens) located the gap. Crucially it
  **overturned** the initial hypothesis that the bracketed prompt scaffolding was at fault: the
  scaffolding actually *stabilizes* the small base model on prose (bare inputs produced garbage).
  The real causes were (1) trailing whitespace at the caret — the live prefix ends in the space the
  user just typed, which makes the model wander and also yields double spaces on insertion; (2)
  mid-line suffix collisions — base continuation duplicates `afterCursor`; (3) code-editor metadata
  bias — the Xcode window title etc. pushed prose toward code/numbers; and (4) tests that only
  sampled ideal inputs, so "green" never reflected production.
- Decision:
  - **Keep the scaffolding** (it helps); fix the boundary instead. `PromptBuilder` trims trailing
    whitespace from the `beforeCursor` section so the base model continues a clean word boundary.
    A pure `AutocompleteCore.CaretBoundary.reconcile(_:beforeCursor:)` re-aligns the candidate
    against the *original* prefix — strips a leading newline artifact, and drops the model's leading
    separator space when the live text already ends in whitespace (kills the double space).
    `CompletionController.present` stores the **reconciled** candidate so overlay and Tab/Shift+Tab
    insertion agree; an empty-after-reconcile result is suppressed.
  - **Native fill-in-the-middle** for mid-line. `DecodingConfiguration.enableFillInMiddle` gates it;
    `ModelTokenizing` gains `tokenizeAllowingSpecial` (default = `tokenize`). When enabled,
    `afterCursor` is non-empty, and the three FIM markers each resolve to a single token on the
    loaded model, `ConstrainedGenerationEngine` decodes
    `<|fim_prefix|>{trimmed prefix}<|fim_suffix|>{suffix}<|fim_middle|>` built from the raw context
    (not the scaffolded prompt); otherwise it falls back to base continuation. Markers are control
    tokens (suppressed by the ACPF profile) so they never leak. Enabled in the app **only after**
    the probe confirmed it beats the base path on the mid-line cases (clean `"France."` / `"a + b"`
    vs colliding `" France is Paris."` / `" a + b + 1"`; weak only on the `Please/let` case).
  - **Reduce metadata for code editors/terminals.** `TargetOverride.environmentContextDisabled` →
    `CompletionPolicy.includesEnvironmentContext`; `PromptBuilder.buildPrompt(includeEnvironmentContext:)`
    omits `generalInfo` + `textFieldProperties` when false. Seeded for Xcode, VS Code, iTerm, and
    Terminal. Cursor-local text and the instruction header are always kept.
  - **Representative tests.** `CaretBoundaryTests` + a deterministic `FillInMiddleAssemblyTests`
    (stub tokenizer, recording runtime) asserting FIM token order and all fallback paths;
    `PromptBuilder` assertions for trailing-whitespace trimming and env-context omission;
    `QualitativeDemoTests.testPrintProductionLikeInputs` and the extended probe exercise
    trailing-space, mid-line, and suffix-collision inputs (and print the reconciled "field" result).
- Consequences:
  - Prose trailing-space cases insert cleanly (no double space); mid-line completions stop
    duplicating the suffix; code editors no longer get prose nudged toward numbers.
  - FIM is measurement-gated, not assumed — if a future model lacks single-token FIM markers the
    engine silently uses base continuation.
  - Watch-items: the `Please/let`-style mid-line case is still weak under FIM (model-dependent);
    the trailing-whitespace trim is intentionally aggressive (drops trailing newlines too) — revisit
    if a target needs newline-preserving continuations.

## ADR-018: KV branch reuse — prefill once, snapshot/restore per branch + across keystrokes

- Status: accepted
- Context: Profiling (`LatencyProfileTests`) showed ~95% of completion latency is model forward
  passes, and **12 of 13 passes per completion re-decoded the entire prompt**: the multi-branch
  decoder (ADR-010) scores each beam branch by `prepare(basePrompt + branchTokens)`, and
  `LlamaModelRuntime.prepare` only reuses the KV cache on a *pure append* (any divergent branch did
  `llama_memory_clear` + full re-decode, because partial rollback via `seq_rm` is unsafe on this
  model's hybrid memory). For a medium prompt that was ~1140 decoded tokens and ~246 ms per
  completion; latency scaled linearly with branch width.
- Decision: decode the base prompt **once** per completion, then cheaply derive each branch from it.
  - New stateless API on `LocalModelRuntime`: `anchoredLogits(anchor:suffix:)` returns the
    next-token logits for `anchor + suffix`. A default protocol extension implements it as
    `prepare(anchor + suffix) + logitsForNextToken()`, so every stub runtime — and thus all
    deterministic engine/FIM tests — is byte-for-byte unchanged. The engine passes the base prompt
    as `anchor` and `branch.tokenIDs` as `suffix`.
  - `LlamaModelRuntime` keeps the `anchor` resident in seq 0, captures its post-decode sequence
    state once (`llama_state_seq_get_data`) plus the anchor-end logits, then for each branch
    **restores** that snapshot (`llama_state_seq_set_data`) and decodes only the branch's suffix.
    The empty-suffix root returns the cached anchor-end logits (no decode). Across keystrokes the
    next base prompt is the prior anchor plus the typed tokens — a pure append — so `ensureAnchor`
    restores the prior snapshot and decodes only the typed delta (the cross-keystroke win).
  - **Mechanism chosen by an on-device gate, not assumption.** The plan's first choice was a
    near-free metadata fork (`llama_memory_seq_cp` into a scratch sequence). The gating probe
    (`AnchoredLogitsCorrectnessTests`) found that `seq_cp` **aborts** on Qwen3.5's hybrid recurrent
    memory (`llama_memory_recurrent`), so the mechanism was switched to `state_seq` snapshot/restore
    within a single sequence, which the same probe validates produces logits **identical** (top-5)
    to a from-scratch `anchor + suffix` decode. An `enableKVFork` init flag (default on) falls back
    to the full-decode path if ever needed.
- Consequences:
  - Measured on the medium-append case: full prefills **12 → 1**, decoded tokens **1140 → 115
    (9.9×)**, latency **246 ms → 87 ms (2.8×)** — past the halving goal. `branchWidth` remains an
    independent lever (the sweep test now pins fork off to show the legacy scaling).
  - Snapshot/restore copies the per-sequence state (attention KV up to the anchor + recurrent
    state) once per anchor and restores it per branch; this memcpy is far cheaper than the forward
    passes it replaces, but grows with anchor length — the context-length guard still applies.
  - The runtime now has two reuse paths: `prepare` (pure-append-or-clear, used by greedy/profiling
    callers) and `anchoredLogits` (snapshot/restore, used by the beam). They share seq 0 but
    `anchoredLogits` always restores from its own snapshot, so interleaving is self-correcting.

## ADR-019: Mid-word token healing (fix the ranking, not the symptom)

- Status: accepted
- Context: `predictions.log` showed the worst completions were *mid-word*: typing `"The weather is
  gre"` surfaced `"asy."` (greasy), `"I will see you tom"` surfaced `"orow."` (a misspelling),
  `"…the be"` surfaced `"ehive."` (beehive). The defect is **ranking**, not display: a good word
  (`great`, `tomorrow`, `beach`) loses to a worse one. The root cause is a tokenization-boundary
  artifact. The prompt ends *inside* a token (`"… gre"`), so the base model must continue from a
  subword state instead of choosing the natural whole-word token `" great"` — which is unreachable
  once `gre` has been committed. In that distorted state a cheaper subword (`"asy"`) can outscore
  the right one (`"at"`). A first attempt suppressed these via stem length / abandonment heuristics
  in the candidate filter; that only hides the symptom (shows nothing) and was rejected.
- Decision: **token healing.** When the caret sits mid-word at end-of-line, back the prompt up to
  the last clean token boundary and constrain regeneration to the removed bytes via the existing
  `requiredPrefixBytes` machinery, then strip the re-emitted stem from what is shown/inserted.
  - `AutocompleteCore.MidWordHealing.plan(for:)` splits `beforeCursor` into `head` (everything up to
    the last whitespace) and `heal` (that whitespace + the partial word, e.g. `" gre"`). It fires
    only when: `afterCursor` is empty, the prefix ends in a letter/number (actively typing a word),
    and `head` is non-empty (there is real context before the word). Whitespace is used as the
    boundary because BPE tokens begin at whitespace; capitalisation is preserved automatically since
    the constraint is byte-exact (so proper nouns like `" Wat"` → `" Waterloo"` heal correctly).
  - `CompletionController` builds the prompt from `head` and sets `requiredPrefixBytes = heal`. The
    decoder's admissibility (`tokenAllowed`/`GenerationBranch.remainingPrefix`,
    `tokenBytes.starts(with: prefix) || prefix.starts(with: tokenBytes)`) already constrains the
    beam to tokens consistent with the typed bytes, so `" great"` is reachable *and* ranked by the
    model's natural distribution. The completion (e.g. `" great today."`) has its `heal` prefix
    stripped (`MidWordHealing.strip`) before `CaretBoundary.reconcile`, yielding the ghost text
    `"at today."`. The token/width budgets are bumped by the heal length so the re-emitted stem does
    not eat the continuation's allowance.
- Consequences:
  - On-device probe (`PromptStrategyProbeTests.testMidWordHealingProbe`): healing reorders
    `greasy → great`, `tomorow → tomorrow`, `beehive → beach`, validating the root-cause fix.
  - Bonus latency win: while typing within a word the `head` (and thus the KV anchor of ADR-018) is
    **constant** across keystrokes — only `requiredPrefixBytes` grows — so the prompt is not
    re-prefilled per character.
  - Healing can occasionally find no admissible path (a stem whose bytes no token cleanly spells);
    that yields no candidate, which is safe (show nothing) and preferable to a wrong guess. Mid-line
    mid-word is left to native FIM (ADR-017); healing is scoped to end-of-line append.
  - The candidate filter keeps its taxonomy unchanged; no mid-word suppression heuristic remains.

## ADR-020: Suggestion anchoring — track the shown completion against the live caret

- Status: accepted
- Context: completions are generated for one caret position but stay on screen while the user keeps
  typing. The controller stored the completion as static state (`visibleRawText` + `visibleContext`)
  and, at acceptance, only re-reconciled its *leading whitespace* against the live prefix. It never
  accounted for the user having typed *into* the suggestion during the debounce/generation window.
  `predictions.log` showed the result as doubled characters: a suggestion of `"excited."` generated
  for `"…be more "` was inserted verbatim after the user had already typed the `e` (`"…be more e"`),
  producing `"…be more eexcited."` (likewise `"mmore"`, `"overlayyed"`). Visually the ghost text also
  sat at the stale caret — "the previous completion is still overlaid" as you type.
- Decision: treat the generated completion as a fixed **anchor** `(anchorText, anchorContext)` and
  re-derive what is actually shown/inserted from it against the *live* caret on every keystroke, via
  `AutocompleteCore.SuggestionAnchor.remaining`:
  - If nothing moved → the whole `anchorText`.
  - If the live prefix *extends* the anchor prefix by a run that is a prefix of `anchorText` (the user
    typed the suggested characters, including any leading separator space) → that run is consumed and
    the **remainder** is shown/inserted. This is type-through: the ghost shrinks and follows the
    cursor, and acceptance never re-inserts already-typed text.
  - Otherwise (deletion, caret jump, change to text after the cursor, or a divergent keystroke) →
    `nil`, and the suggestion is dropped immediately rather than left dangling.
  - `CompletionController` calls this from one render path (`renderSuggestion(for:)`) used by both a
    fresh generation (`present`) and every subsequent snapshot, so the overlay is always positioned at
    and consistent with the live caret. Acceptance (`insertionText`) uses the same derivation, so what
    is inserted is exactly what is shown.
- Consequences:
  - Fixes the doubled-character bug and the stale overlay; no separate live-prefix reconciliation hack
    is needed at acceptance (the anchor already absorbed any typed separator).
  - Pure string logic lives in `AutocompleteCore.SuggestionAnchor` (unit-tested in
    `SuggestionAnchorTests`); the `@MainActor` controller is a thin wiring layer.
  - Re-derivation only runs on real edits (identical-snapshot repolls are still deduped by
    `lastContextKey`), and `InlineGhostTextPresenter.show` updates the overlay in place, so advancing
    the suggestion does not reintroduce flicker.

## ADR-021: Confirm-and-tear-down on quit (fix ggml-metal abort at exit)

- Status: accepted
- Context: quitting KeyType (menu "Quit KeyType" / ⌘Q → `NSApp.terminate(nil)`) aborted instead of
  exiting cleanly. The crash is inside llama.cpp's Metal backend during process teardown:
  `NSApplication terminate:` → `exit()` → `__cxa_finalize_ranges` runs C++ static destructors, which
  free the process-global `ggml_metal_device`; its destructor asserts `[rsets->data count] == 0` and
  `ggml_abort`s. That assert holds only if every GPU residency set was already released — which is
  exactly what `llama_free`/`llama_model_free` do. Those are called from `LlamaModelRuntime.deinit`,
  but at `exit()` the Swift runtime objects are still alive (held by the `CompletionController`
  engine), so `deinit` never runs before the C++ destructors, and the assert fires. Separately, the
  product wants a confirmation before quitting (quitting stops completions).
- Decision: free the native model/context *deterministically before* termination, and gate quit
  behind a confirmation:
  - `LocalModelRuntime` gains `func shutdown() async` (default no-op for pure-Swift runtimes).
    `LlamaModelRuntime.shutdown()` calls `llama_free`/`llama_model_free` guarded by a
    `didFreeNativeResources` flag; `deinit` is guarded by the same flag so teardown happens exactly
    once whichever path runs first.
  - `ConstrainedGenerationEngine.shutdown()` forwards to the runtime; `CompletionController.shutdown()`
    stops the pipeline, cancels in-flight generation, frees the engine, and drops the reference.
  - `AppDelegate.applicationShouldTerminate(_:)` shows an `NSAlert` ("Quit KeyType?" with **Quit** as
    the default button and **Cancel**), returns `.terminateCancel` on Cancel, otherwise returns
    `.terminateLater`, `await`s `completion.shutdown()`, then `reply(toApplicationShouldTerminate:)`.
    Gating here (not just in the menu button) covers ⌘Q and any other termination path; an
    `isTerminating` flag prevents a second prompt.
- Consequences:
  - Clean exit: residency sets are released before ggml's static destructors run, so the assert no
    longer trips. The runtime is inert after `shutdown()` — no generation calls may follow.
  - The teardown is best-effort if the model is still mid-load when the user quits (the engine
    reference may not be set yet); the abort only reproduces with a loaded model, which by the time a
    user opens the menu and confirms is the live case.

## ADR-022: App compatibility policies are context-aware and suppress risky fields

- Status: accepted
- Context: milestone M7 moves compatibility from a small bundle/domain table into behavior that must
  decide whether completions are safe at the live focus target. Cotypist exposes the same broad knobs
  in its bundle (`tabShortcutsDisabled`, paste-and-match-style/backspace workarounds, font-size and
  vertical overlay offsets, terminal handling, and app/domain overrides), but KeyType must keep the
  decision clean-room and aligned with its product rule: suppress before showing a bad or unsafe
  completion. The risky cases are terminals/TUIs where Tab is often semantic, Google Docs-style web
  editors with unreliable inline AX geometry, and password or secret fields where suggestions must
  never appear.
- Decision: make `AppCompatibilityStore` compute policy from the full `TextFieldContext`, not just
  the app target:
  - `TextFieldContext` carries caret geometry quality plus field traits for secure/password,
    password-manager, web-field, and terminal-like contexts. `MacContextCapture` derives these from
    AX roles/subroles, labels/placeholders, ancestor web areas, and known terminal/password-manager
    bundle IDs.
  - Secure fields, password managers, and sensitive labels/placeholders hard-disable completion,
    Tab acceptance, training, environment context, and overlay display before generation or filtering.
  - Terminal-like contexts hard-disable Tab acceptance and mid-line completions, switch generation to
    terminal mode, and use a mirror overlay so native shell/TUI Tab behavior stays untouched.
  - Web fields with estimated caret geometry, plus Google Docs-style domain overrides, use a
    text-mirror overlay and paste-and-match-style insertion. Google Docs also enables the
    backspace-after-paste workaround.
  - App/domain overrides can tune overlay font size, vertical offset, insertion workarounds,
    completion gating, mid-line rules, Tab acceptance, and custom prompt instructions.
- Consequences:
  - Compatibility decisions now stack app/domain defaults with live field traits, so the same browser
    can allow normal fields, mirror Docs, and suppress password fields without special-case wiring in
    the controller.
  - Native Tab behavior wins over completion acceptance in terminals and excluded apps; this may
    suppress some useful continuations, but matches KeyType's "prefer suppression" rule.
  - Sensitive-field detection intentionally over-suppresses terms such as passcode, secret key, TOTP,
    2FA/MFA, CVV/CVC, and security code. That keeps private surfaces safe at the cost of occasional
    missed completions in benign support text.
  - The policy is unit-tested for native/default behavior, Chromium/Google Docs, terminal handling,
    and password exclusions; manual app-matrix validation should focus on AX traits and placement in
    real windows rather than policy branching.

## ADR-023: Personalization & polish — encrypted writing history, local telemetry, Settings (M8)

- Date: 2026-05-30
- Status: accepted
- Context: M8 personalizes completions and exposes user control. Four needs: (1) an opt-in, on-device
  writing-history store feeding `previousUserInputs`, selected by app/domain/typingContext/language/
  recency under a token budget (`docs/02-prompting.md`); (2) because that store can hold personal
  text, it must be **encrypted at rest**; (3) local-only telemetry (acceptance/suppression/latency)
  that can tune decoder thresholds; (4) a Settings UI for model selection, completion length, per-app
  toggles, and privacy switches. The product rule is on-device & private: sensitive context is
  opt-in and off by default, and all personal data must be clearable in one action. A separate
  autocorrect/typo mode was scoped as optional.
- Decision:
  - **New `Personalization` SwiftPM package** (kept free of AppKit and of the decoder package): it
    conforms to `Prompting.WritingHistoryProviding` so it drops in for the M3 in-memory stub. The
    app target owns recording, the Settings UI, and all wiring (packages stay decoupled).
  - **Encrypted store (`PersistentWritingHistoryStore`)** backed by **SQLCipher via GRDB**, using the
    `sqlcipher/GRDB.swift` managed fork (auto-enables SQLCipher without Swift package traits, so it
    resolves inside the Xcode workspace; the official `groue/GRDB.swift` + `GRDBCIPHER` trait is the
    alternative once Xcode supports traits cleanly). The DB lives at
    `~/Library/Application Support/KeyType/History/history.sqlcipher`. The 256-bit key is random,
    generated once, and stored in the **Keychain** (`KeychainPassphrase`,
    `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) — never on disk in the clear. Recording and
    queries swallow DB errors (best-effort, never break typing); a failed open falls back to a no-op
    `NullWritingHistoryStore`. Selection mixing (recent + longest same-app + a few cross-app recents,
    capped by an approximate token budget) is factored into a pure, unit-tested `WritingHistorySelection`.
  - **Recording (`WritingHistoryRecorder`, app target)** subscribes to the shared AX tracker and
    persists a field's text when focus moves / the app switches / typing goes idle, **only** when the
    user enabled history, the app/domain allows training-data collection, the field is not
    secure/sensitive, and the text clears a minimum length. Writes happen off the main actor.
  - **Telemetry (`CompletionTelemetryStore`)** records shown / suppressed(+reason) / accepted /
    latency at the controller's existing log points and computes acceptance rate, suppression rate,
    and latency p50/p95. Stored as plain JSON (non-PII counters + a bounded latency reservoir) in
    Application Support. `ThresholdTuner` maps the snapshot to a neutral, **clamped** `ThresholdAdjustments`
    (relative-cutoff delta + min-branch-probability scale) that the app applies onto
    `DecodingConfiguration` at engine build — widening the search when suppression is very high and
    acceptance very low, tightening slightly when acceptance is strong, and staying inert below a
    minimum sample count.
  - **Settings (`SettingsStore` + `SettingsView`)**: UserDefaults-backed model selection, completion
    length (→ token/width budget), per-app completion toggles, and privacy switches for history /
    clipboard / OCR — all three **off by default**. A single "Clear all personal data" action wipes
    the history rows and telemetry. Per-app disables layer onto `AppCompatibilityStore` (new
    `userDisabledBundleIdentifiers` initializer) and are also checked live in the controller so
    runtime toggles take effect immediately. Reachable from the menu bar; read-only local stats are
    surfaced in the window.
  - **Autocorrect/typo mode is deferred** (the existing in-beam typo guard, ADR-015, already covers
    the worst case). Logged here as future work; `CompletionMode.correction` already exists for it.
- Consequences:
  - Personal writing text is encrypted at rest and removable in one action; losing/deleting the
    Keychain key renders the DB unreadable, which is an acceptable hard backstop.
  - The `sqlcipher/GRDB.swift` dependency is a large git checkout and builds a SQLCipher amalgamation,
    so first resolution/build is slow; this is the cost of real encrypted SQLite. If the fork ever
    becomes unsuitable, the fallback is the official GRDB + `GRDBCIPHER` trait, or a CryptoKit
    AES-GCM encrypted file.
  - Threshold tuning is intentionally conservative and bounded; it nudges rather than reshapes the
    decoder, so a noisy session can't destabilize completions.
  - Tests: `PersonalizationTests` cover store record/query/dedup/clear, that stored text is not
    plaintext on disk, budget capping, telemetry aggregates/persistence, tuner direction + clamping,
    and Keychain round-trip (skipped if the environment has no keychain). `ConstrainedGenerationTests`
    gains a deterministic `HistoryAcceptanceTests` demonstrating that including the user's previous
    writing in the prompt measurably improves acceptance (0% → 100% on the fixture). `AppCompatibilityTests`
    cover the user per-app disable. On-device measurement of the live acceptance-rate lift relies on
    the Settings stats panel.

## ADR-024: Prediction-log quality fixes — trailing-space trim, synchronous typo seam wired

- Date: 2026-05-31
- Status: accepted
- Context: A qualitative pass over the on-device prediction log
  (`~/Library/Application Support/KeyType/Logs/predictions.log`, written by `PredictionLog`) surfaced
  two low-risk output-quality leaks: (a) several shown completions carried a trailing space
  (`"new GeForce RTX "`, `"SoC and "`, `"rsin core and "`), which renders as a phantom gap in the
  ghost text and inserts a stray separator on accept; and (b) the output `DefaultCandidateFilter`'s
  current-word typo net was inert in the live app because no `SynchronousWordRecognizing` was wired
  (ADR-016 deliberately left it nil to avoid double spell-checking with the in-beam guard).
- Decision:
  - **Trailing-whitespace trim (end-of-line only).** In `CompletionController.present`, after
    `CaretBoundary.reconcile`, drop trailing whitespace from the anchored completion when
    `afterCursor` is empty. Mid-line completions keep their trailing whitespace — there the space may
    be the genuine separator before the existing after-cursor text, so trimming it could merge words.
  - **Wire the synchronous typo seam.** `SystemWordRecognizer` now also conforms to
    `SynchronousWordRecognizing` (sharing one `NSSpellChecker` core, conservative + main-thread-gated),
    and the controller constructs its `DefaultCandidateFilter` with it. This supersedes the
    "leave the seam nil" sub-decision of ADR-016: the in-beam guard (ADR-015) judges *healed,
    pre-reconciliation* token paths, whereas the filter re-checks the *finalised* string actually
    shown — so the second check is genuine defense-in-depth, not a pure duplicate. It runs only on a
    closed current word and reports "recognised" whenever unsure, so it cannot false-positive.
- Consequences:
  - Ghost text no longer shows/inserts a dangling end-of-line space; word/full accepts are cleaner.
  - The output typo net now fires in production (a marginal extra `NSSpellChecker` call only when a
    word closes — negligible, and only on the main actor). The supersession of ADR-016's nil-seam
    note is intentional; the existing `CandidateFilterTests` typo cases now also reflect the live path.
  - Not addressed here (logged separately as findings): mid-word `noCandidate` cascades when an
    upstream grammatical error poisons the prompt, apostrophe-variant duplicate candidates consuming
    beam slots, and redundant re-shows of identical context. Those need decoder/ranking changes.

## ADR-025: Required-prefix decoding bypasses raw-logit pre-selection (fix mid-word `noCandidate`)

- Date: 2026-05-31
- Status: accepted
- Context: A prediction-log investigation found that typing an ordinary word mid-stream often produced
  a run of `SUPPRESS(noCandidate)` until a space was typed (e.g. "collaboration" → 8 straight
  suppressions; "MediaTek" mid-word). Root cause: `TokenSampler.rank` pre-selects the top
  `max(topK·4, 256)` tokens **by raw logit** (the ADR-012 perf optimization) and only *then* applies
  the required-prefix admissibility mask. Mid-word token healing (ADR-019) forces a continuation
  beginning with the typed bytes; when that continuation is locally improbable — a rare word, or a
  consonant word after "an" — none of its tokens are in the model's globally top-256, so the
  admissible pool is empty, the branch collapses with no emitted tokens, no branch ever satisfies the
  required prefix, and the engine returns zero candidates. The space-then-it-works asymmetry in the
  log is the fingerprint: a completed word has no required prefix, so all top-256 tokens are
  admissible. (Note: `docs/03` already specified masking over the *full* vector before top-k/top-p;
  the implementation applied the optimization in the wrong order for the constrained path.)
- Decision: Add a `constrained` flag to `TokenSampler.rank`; when set (a branch still has an
  unsatisfied `remainingPrefix`), skip raw-logit pre-selection and scan the full vocabulary through
  the admissibility predicate. `ConstrainedGenerationEngine` passes `constrained:
  !branch.remainingPrefix.isEmpty`. The admissible set for a specific byte-prefix is tiny and this
  path only runs while the user is actively completing a word, so ADR-012's steady-state perf concern
  (unconstrained decoding) is unaffected. Regression test `testRequiredPrefixSurvivesBelowPreselectionCutoff`
  drives an admissible token ranked below the 256-token window and asserts it is still found.
- Consequences:
  - Mid-word typing now yields completions at every keystroke instead of dead air; verified on-device
    ("collaboration" completes and was accepted; zero `noCandidate` across the session).
  - Trade-off: at very short stems (1–3 new chars) the forced continuation is often a hallucination
    ("colexed", "collvm") that self-corrects once more letters are typed. The existing typo nets do
    **not** catch these because a healed completion re-emits the heal's leading space, so
    `leadingWord(candidate)` is empty and `CurrentWordTypoGuard` / the output filter both bail. Logged
    as a follow-up: reconstruct the current word through the heal (stem + leadingWord of the
    heal-stripped completion) so nonsense mid-word continuations can be suppressed. (Resolved in ADR-026.)

## ADR-026: Typo net sees through the heal (suppress nonsense mid-word completions)

- Date: 2026-05-31
- Status: accepted
- Context: ADR-025 made mid-word token healing actually produce candidates, which exposed that
  neither typo net could judge a healed completion. A healed completion re-emits the typed stem with
  its leading separator space (`" collvm…"`), so `leadingWord(candidate)` is empty and both the
  in-beam `CurrentWordTypoGuard` and the output `DefaultCandidateFilter` bail before reconstructing
  the current word — letting nonsense like "collvm" / "colexed" through at short stems.
- Decision: Strip the heal before reconstructing the current word in both gates. The heal is the
  request's `requiredPrefixBytes` decoded as a string; `MidWordHealing.strip` removes it (a no-op
  when unhealed, or when a branch hasn't yet emitted the full stem — the remaining leading space is
  then safely treated as "not our word"). `CurrentWordTypoGuard` strips parent/child branch text;
  `DefaultCandidateFilter.looksLikeCurrentWordTypo` strips the candidate text. Reconstruction is then
  the existing `stem + leadingWord(stripped)`.
- Consequences:
  - Healed nonsense mid-word continuations are now dropped (in-beam, so a correctly-spelled branch
    can surface instead) and suppressed at the output gate; real words ("collaboration") still pass.
  - Unhealed behaviour is unchanged (`heal == ""` → strip is identity), so all existing typo-net
    tests stay green. New coverage: `testHealedMidWordTypoBranchDroppedThroughHeal` (engine, in-beam)
    and `testHealedMidWordTypoIsSuppressed` / `testHealedMidWordRealWordIsKept` (output filter).
  - The in-beam guard remains conservative (closed-word-only, eligible lowercase words, context-term
    exempt, recogniser reports "recognised" when unsure), so it cannot suppress a legitimate word.

## ADR-027: Resolve browser web-area focus to the editable descendant

- Date: 2026-05-31
- Status: accepted
- Context: Browser testing on Markdown Live Preview showed Chrome and Safari can report the focused
  Accessibility element as the whole `AXWebArea` even when an editable child owns the actual text,
  selection, caret geometry, and style. Reading the web area directly made context and placement
  unstable: the ghost text could be anchored against page/browser geometry instead of the editor.
- Decision: Before building a `TextFieldContext`, `FocusedFieldReader` now resolves the supplied AX
  element to a bounded descendant with a text role (`AXTextArea`, `AXTextField`, combo box, or known
  editable text roles) and a selected range or value. Text, selection, caret geometry, field rect,
  labels, target, and traits are read from that resolved element. The app's `FieldFontResolver`
  mirrors the same bounded search so font/color probing uses the same editable control.
- Consequences:
  - Browser editors whose focus lands on `AXWebArea` now use the child editor's geometry and style,
    keeping inline ghost text at the caret instead of drifting into browser chrome or page-level
    coordinates.
  - The search is deliberately capped (8 levels / 240 nodes) and only runs when the focused element
    itself is not already usable, preserving the existing native-app fast path.

## ADR-028: Estimated browser carets stay inline by default

- Date: 2026-05-31
- Status: accepted
- Context: Follow-up browser testing showed the overlay still appeared above the Markdown Live
  Preview editor even after context capture resolved the editable child. The prediction log proved
  generation was healthy; the remaining issue was placement. The generic web policy converted every
  estimated web caret to `textMirror`, and mirror mode intentionally positions ghost text above the
  caret (`caret.maxY + 2`). In ordinary browser textareas, the estimated caret was good enough for
  inline x/y, so the fallback caused the visible misplacement.
- Decision: Do not globally convert estimated web carets to `textMirror`. `OverlayPlacementResolver`
  now honors `.inline` policy regardless of caret quality, and `AppCompatibilityStore` no longer
  rewrites estimated web fields to mirror mode. Explicit overrides (for example Google Docs) can
  still choose `textMirror` where inline geometry is known to be unreliable.
- Consequences:
  - Normal browser editors keep ghost text on the same line as the caret instead of one line above.
  - Truly unreliable web surfaces need explicit compatibility overrides or suppression; the product
    should not penalize every estimated web caret with an above-line mirror.

## ADR-029: Browser ghost text uses defensive visible color and multiline estimates

- Date: 2026-05-31
- Status: accepted
- Context: Markdown Live Preview exposed two remaining browser overlay failures after ADR-027/028:
  Chrome could return an estimated field-frame caret for a tall editor, which anchored the ghost text
  to the field edge instead of the current line; and browser AX style probing could report a
  foreground color that was effectively the white editor background, making the ghost text appear
  invisible even when placement and generation were correct.
- Decision: Estimated caret fallback now derives a conservative line rect from the current line index
  and a bounded line height instead of using the full field height. `GhostTextView` also treats
  missing, near-white, and near-black AX foreground colors as untrustworthy and renders a muted,
  high-alpha gray with a subtle contrast shadow. Normal mid-tone field colors are still preserved at
  ghost opacity.
- Consequences:
  - Browser textarea-style editors keep inline ghost text on the typed line instead of near the top or
    bottom of the whole field.
  - Ghost text remains visible on white web editors even when AX reports unusable styling, while
    native fields and trustworthy colored text continue to inherit the field's own color.

## ADR-030: Treat Cursor as a code editor target

- Date: 2026-05-31
- Status: accepted
- Context: Computer Use testing against `/Applications/Cursor.app` showed Cursor's local bundle id is
  `com.todesktop.230313mzl4w4u92`, and its editor surface is a VS Code workbench
  (`vscode-file://.../workbench.html`). The existing code-editor compatibility rule covered Xcode
  and VS Code but not Cursor, so Cursor prompts could still include app/window metadata.
- Decision: Add Cursor's bundle id to the code-editor overrides with
  `environmentContextDisabled: true`. Keep completions, Tab acceptance, inline overlay preference,
  and prose mode unchanged.
- Consequences:
  - Cursor gets the same prompt-shaping protection as VS Code: cursor-local text remains the signal,
    while app/window metadata is omitted to avoid biasing base-model continuations toward unrelated
    code or title text.
  - The ToDesktop bundle id is now captured in a regression test so future compatibility work does
    not accidentally drop Cursor coverage.

## ADR-031: Treat WeChat as an explicit chat surface

- Date: 2026-05-31
- Status: accepted
- Context: Computer Use testing against `/Applications/WeChat.app` showed WeChat's local bundle id is
  `com.tencent.xinWeChat`. The app shell is visible, but the chat content and compose region are not
  exposed as normal accessibility text controls to Computer Use, which makes inline geometry and rich
  insertion more fragile than in standard native fields.
- Decision: Add WeChat's bundle id to the chat app overrides with chunked Unicode text injection,
  inline overlay preference, and message-only custom instructions. Add a WeChat-specific
  keystroke fallback in `MacContextCapture`: when the regular AX snapshot is sparse, KeyType keeps a
  short local prefix buffer from observed key events and emits an estimated compose-box
  `TextFieldContext` so the existing generation and Tab-acceptance pipeline can run. Keep
  completions and Tab acceptance enabled.
- Consequences:
  - WeChat suggestions are constrained to short conversational continuations for the current message.
  - The overlay uses the fallback caret inline with the composed text; mirror mode renders above
    WeChat's input box and is visually misaligned for this surface.
  - Accepting a suggestion types the completion into WeChat in small chunks instead of relying on a
    paste command that may not be supported by the custom editor.
  - The bundle id is covered by a regression test for future compatibility work.

## ADR-032: Read Apple Mail compose bodies from focused HTML content

- Date: 2026-05-31
- Status: accepted
- Context: Computer Use testing showed Mail's new-message body focuses an `HTML content` element
  with description `message body` and `about:blank` URL. The typed body text appears as child text,
  not as a normal `AXTextArea`/`AXTextField`, so `FocusedFieldReader` could emit an empty context or
  no usable caret and the completion pipeline suppressed suggestions.
- Decision: Add a Mail compose-body fallback in `MacContextCapture`. When the focused element belongs
  to `com.apple.mail` and matches the message body HTML surface, collect text from the element or its
  child text nodes, preserve the existing Mail policy instructions, and estimate the caret from the
  compose body frame when AX does not return an exact caret.
- Consequences:
  - New-message compose windows now produce a non-empty `TextFieldContext`, allowing normal prompt
    generation, overlay placement, and Tab acceptance.
  - The fallback is constrained to Mail's compose body (`message body` / `about:blank`) so viewing
    received HTML email does not become a completion target.

## ADR-033: Reject container-sized caret bounds in multiline web prompts

- Date: 2026-05-31
- Status: accepted
- Context: Computer Use testing against Cursor's multiline agent prompt showed Electron can report
  the focused element as the whole web area and can expose text-like transcript blocks before the
  actual prompt. It can also return an `AXBoundsForRange` rectangle that is effectively the whole
  multiline composer, which made ghost text render huge and wrap from the field edge instead of
  continuing after the active line.
- Decision: Rank web-area descendant candidates by focused/ranged/settable/editable signals before
  choosing the text element, mirrored in the app-side font probe. Reject AX caret rectangles that
  look like the text container and fall back to the conservative current-line estimate. In
  `CompletionUI`, bound the trusted caret height used for layout/font sizing so one bad rectangle
  cannot inflate the overlay.
- Consequences:
  - Cursor multiline prompts now capture the actual prompt text and active-line caret, with normal
    inline placement.
  - The overlay layer has a defensive cap for future web surfaces that briefly return field-sized
    caret bounds.

## ADR-034: In-app model download + automatic ACPF generation + per-model family resolution

- Date: 2026-05-31
- Status: accepted
- Context: Onboarding previously assumed the user had manually placed a GGUF in
  `Application Support/KeyType/Models`, and the constrained decoder hardcoded the tokenizer family
  `qwen3-v151936` in `CompletionController.buildEngine`. That made first-run setup opaque and made
  any non-Qwen model (e.g. Gemma) impossible because its profile filename/validation used the wrong
  family. The single-screen onboarding also lacked parity with the guided wizards users expect.
- Decision: Add a `ModelManagement` SwiftPM package with a fixed catalog of five base models, a
  `URLSessionDownloadDelegate`-backed `ModelDownloadManager` (progress, cancellation, staging-file +
  atomic move, size + SHA-256 validation), and a `ModelFamilyResolver` that is the single source of
  truth for a model's tokenizer family (catalog declaration, or `<base>-v<vocabSize>` derived for
  imported GGUFs). A separate `ModelProfileGeneration` target builds `<family>.acpf.bin` in-process
  via `ProfileBuilderCore.BuildProfile.run` over a `LlamaVocabIntrospector` once a GGUF lands. An
  app-level `ModelSetupCoordinator` chains download → profile build and exposes one combined state;
  a model is only `.ready` when both files exist. `CompletionController.buildEngine` now resolves the
  family from the model file instead of hardcoding it. The single onboarding screen is replaced by a
  stepped wizard (welcome → permissions → model → privacy → keybinds → disable macOS predictions →
  done) with a pinned footer and per-step gating, behind a versioned `onboardingCompletedVersion`
  gate. Acceptance hotkeys (`Tab` / `Shift+Tab`) become user-configurable via `SettingsStore`,
  matched against the `CGEvent` tap, with a reusable `KeyRecorderView`. Input Monitoring is now a
  required permission (the acceptance tap listens for key-downs).
- Consequences:
  - Keeping the default Qwen catalog entry's family equal to the legacy `qwen3-v151936` means an
    existing on-disk profile for the default model still loads without a rebuild.
  - The catalog's concrete Hugging Face URLs / byte sizes / SHA-256 are not yet pinned, so those
    entries are marked `.unverified` and cannot be downloaded (only a manually-installed GGUF can be
    prepared) until they are confirmed — we never fabricate a URL or checksum. Confirming the five
    base GGUFs (including whether base, non-instruct Gemma "E2B/E4B" variants exist) is an open
    follow-up.
    - **Amended 2026-05-31 (see ADR-035):** download URLs are now pinned for all five entries and
      they are `.available`; the base, non-instruct Gemma "E2B/E4B" question is resolved
      (`google/gemma-4-E2B`/`E4B` are base). Byte size + SHA-256 remain unpinned.
  - The macOS "Show inline predictive text" step relies on a Keyboard-settings deep link plus
    written instructions; there is no documented deep link to the exact toggle, and detection of its
    state is best-effort, so the step is always skippable.
  - Multi-gigabyte downloads are pausable: `pause` calls `URLSessionDownloadTask.cancel(byProducingResumeData:)`
    and surfaces a `DownloadPaused(resumeData:)` (distinct from a user cancel), which the manager stashes
    per filename and a later `resume` feeds to `downloadTask(withResumeData:)`. A `.paused(progress:)`
    state joins `ModelDownloadState`/`SetupState` so the wizard and Settings show a Pause/Resume/Cancel
    control next to the percentage progress bar. If a server rejects the resume blob, the fetch falls
    back to a fresh download (with the existing mirror fallback) rather than stranding the user.

## ADR-035 — Catalog artifacts pinned to base GGUFs; Gemma E2B/E4B confirmed base

- Date: 2026-05-31
- Status: accepted
- Context: ADR-034 shipped `RuntimeModelCatalog` with placeholder entries marked `.unverified`
  because no concrete GGUF URLs had been located, and it left open "whether base, non-instruct
  Gemma 'E2B/E4B' variants exist." Both the catalog header and that consequence bullet are now
  stale.
- Decision: Pin a real Hugging Face download URL for every catalog entry (via a new
  `huggingFaceURL(repo:file:)` helper) and mark all five `.available`:
  - Qwen3.5 0.8B / 2B / 4B Base → `mradermacher/Qwen3.5-*-Base-i1-GGUF`.
  - Gemma 4 E2B / E4B → `mradermacher/gemma-4-E{2,4}B-i1-GGUF`, which quantize the **base**
    `google/gemma-4-E{2,4}B` (no `-it`; "i1" is imatrix, not instruct). The base variants exist,
    resolving the ADR-034 follow-up. Both share the Gemma tokenizer (vocab 262144 → family
    `gemma-v262144`, the value already used by the catalog).
  - `ModelDownloadManager` transparently retries against `hf-mirror.com` when `huggingface.co` is
    unreachable, so the catalog is authored with `huggingface.co` only.
- Consequences:
  - `expectedSizeBytes` / `sha256` are still `nil`, so `ModelFileValidator`'s size + checksum checks
    are skipped — pinning those is the only remaining catalog-verification gap. The field stays `nil`
    until a real value is recorded; we never fabricate a checksum.
  - Gemma 4 E2B/E4B are multimodal (`gemma4`: text + vision + audio) edge/MatFormer variants;
    KeyType uses only the text GGUF (no `mmproj`). Arch support is in the vendored llama.cpp `b9402`
    (gemma4 landed ~2026-04-02), and the model loads standalone — KeyType's path. The known
    llama.cpp edge-variant issues are around speculative-draft use, which KeyType does not do; a real
    load + completion-quality check on `b9402` is still advisable before recommending them by default
    (the Per-Layer-Embeddings forward graph has had quality questions on these variants).
  - Gemma 4 is pure-attention with sliding-window + KV-shared layers (no recurrent/SSM state), so the
    recurrent-safe KV-reuse rules from ADR-011/ADR-018 stay correct here — they are stricter than this
    model needs.

## ADR-036 — Import an arbitrary user-supplied GGUF

- Date: 2026-05-31
- Status: accepted
- Context: Model selection only exposed the curated catalog (downloaded into the Models directory).
  Users who already have a GGUF on disk (downloaded via another tool, or a quant we don't ship) had
  no in-app way to use it, even though the pieces to support off-catalog models already existed:
  `ModelFamilyResolver.derivedFamily` produces a stable `<base>-v<vocabSize>` family for unknown
  GGUFs, `ProfileGenerator` builds the ACPF from the GGUF's own tokenizer for any filename, and
  `CompletionController.buildEngine` already resolves the family from the file rather than hardcoding.
- Decision: Add a Settings "Use your own model → Import a GGUF…" action. `ModelSetupCoordinator`
  gains `importModel(from:)` + an observable `ImportState`: it copies the chosen file into the Models
  directory (App Sandbox is disabled per the entitlements, so the open-panel URL is directly
  readable — no security-scoped bookmark), runs the same `ProfileGenerator` build the catalog path
  uses, and on success routes through the existing `onModelReady` callback to select the model and
  hot-reload the engine (ADR-021). The imported file then surfaces in the existing picker (which
  lists every `.gguf` in the Models directory); a `.onChange(of: importState)` refresh is needed
  because an off-catalog file does not move `modelSetupSignature`.
- Consequences:
  - Off-catalog models are unvetted: the import footer warns they may produce unexpected or
    low-quality completions, consistent with the product principle of preferring suppression to a
    wrong suggestion. Decode behavior still depends on the model's architecture being supported by the
    vendored llama.cpp build.
  - Re-importing the same filename replaces the on-disk copy and reuses the existing profile when the
    derived family already has one, so imports are idempotent.
  - **Compatibility gate (added 2026-05-31):** before copying anything, the import probes the file by
    loading it with the vendored llama.cpp build at a tiny (256-token) context and freeing it
    immediately. Loading is the authoritative check — `llama_model_load_from_file` returns NULL
    (`LlamaRuntimeError.modelLoadFailed`; likewise `.contextInitFailed` / `.vocabUnavailable`) for a
    GGUF whose architecture or format version the build doesn't support. On that signal the import is
    rejected with a clear "isn't compatible with this version of … (llama.cpp)" warning and **no file
    is copied** into the Models directory, so a bad pick can't leave a dangling, unselectable GGUF
    behind. Probing the source first (rather than copy-then-validate) also means rejection is fast and
    doesn't wait on a multi-gigabyte copy. The failure message prefers the typed error's
    `CustomStringConvertible` description over `localizedDescription`, which would otherwise flatten
    our llama/profile errors to a generic "operation couldn't be completed" string.
  - **Failures are modal, not inline (added 2026-05-31):** import errors are surfaced through a
    `ModelSetupCoordinator.onImportFailure` callback that `AppDelegate` renders as an app-modal
    `NSAlert` ("Can't Use This Model") the user must explicitly dismiss — not an inline Settings
    status line. The coordinator's `ImportState` therefore only carries `.idle`/`.preparing`
    (progress), keeping the logic layer free of presentation; the app activates first because it is an
    accessory (no dock icon) so the alert comes to the front.
  - **Open panel must quiesce AX first (added 2026-05-31):** the import open panel is presented from
    `AppDelegate.presentModelImportPanel()`, not the SwiftUI view, because it deadlocks otherwise. The
    `NSOpenPanel` is an out-of-process remote view, and KeyType's `AccessibilityContextTracker` makes
    *synchronous* `AXUIElementCopyAttributeValue` reads on every focus change — and the panel taking
    focus triggers exactly that. Those reads run on the main thread, which is also what services the
    panel, so they deadlock and the app hangs (reproduced as "hangs on the file picker"). The fix
    stops `contextCapture` / `completion` / `historyRecorder` / `acceptance` before showing the panel,
    presents it with `begin` (keeps the run loop turning) rather than `runModal`, and restores the
    pipeline via `syncContextCaptureWithPermission()` in the completion handler. Critically, an
    `isPresentingImportPanel` latch makes that sync a no-op while the panel is open: the AX pipeline is
    re-armed once a second by the permission-poll timer, which (running in `.common` run-loop modes)
    keeps firing while the panel is up and would otherwise restart the tracker mid-panel and re-trigger
    the deadlock — the reason an earlier "just stop the controllers" attempt still hung.

## ADR-037 — Dismiss stale completions from the key tap, not just the AX snapshot

- Date: 2026-05-31
- Status: accepted
- Context: A shown suggestion is only re-evaluated when the next focused-field snapshot arrives, which
  is driven by AX `kAXValueChangedNotification` → `refreshSoon()` (a 20 ms debounce) → `refreshNow()`
  → `CompletionController.handle`, where `SuggestionAnchor.remaining` clears it once the live caret
  diverges. That path is correct but *late*: AX value-changed notifications lag the keystroke by a
  variable amount (often tens to hundreds of ms depending on the app), so after the user types a
  character that diverges from the suggestion the now-outdated ghost text visibly lingers for a beat
  before the snapshot lands and clears it. The product principle is to prefer suppression to a wrong
  suggestion, and a stale completion reads as a wrong one.
- Decision: Reuse the existing global key tap (`CompletionAcceptanceController`, which already sees
  every `keyDown` synchronously) to dismiss eagerly. For any key-down that is not a consumed accept
  shortcut, it calls `CompletionController.dismissStaleCompletion(typedCharacters:)` *before* the AX
  snapshot for that key exists. The controller keeps the suggestion only when the typed text is a
  prefix of the visible ghost text (the user is typing the suggestion — let the AX pipeline shrink it
  in place, preserving the no-flicker "transition in place" behavior); for anything else it cancels
  the in-flight debounce/generation tasks and clears immediately. The tap derives the typed text via
  `keyboardGetUnicodeString`, returning `nil` (→ always dismiss) for ⌘/⌃ combos and control/navigation
  keys (return, tab, delete, escape, the 0xF700–0xF8FF private-use arrow/function range) so those
  never accidentally match the suggestion's first character.
- Consequences:
  - Divergent keystrokes, deletions, caret moves, and shortcuts drop the ghost text on the same run
    loop turn as the key, independent of how slowly the target app reports AX changes. The AX-driven
    `handle`/`SuggestionAnchor` path stays the source of truth and still runs afterward (regenerating a
    fresh suggestion), so this is a latency optimization layered on top, not a replacement.
  - Cancelling the in-flight generation on divergence also closes a small race where a result computed
    for the *previous* caret could `present()` and re-show a stale suggestion in the gap between the
    tap dismissal and the next snapshot.
  - The match check is a plain `hasPrefix` on the visible remainder, mirroring `SuggestionAnchor`'s
    own prefix-extension rule, so the keep/dismiss decision here can't disagree with what the snapshot
    pipeline would conclude a moment later.
  - `keyboardGetUnicodeString` is now called from the session tap as well as the WeChat fallback tap;
    both already existed, and the dead-key/composition caveat is unchanged.

## ADR-038 — Trailing punctuation is a separate Tab unit

- Date: 2026-05-31
- Status: accepted
- Context: `NextWordSplitter` (Tab word-by-word acceptance, ADR-016) defined the "next word" as
  everything up to where the *second* ICU word begins, so a word's trailing punctuation travelled with
  it. ICU's `.byWords` enumeration doesn't emit punctuation as its own substring, so a completion like
  `"esses."` segmented to a single word and was taken wholesale — one Tab inserted `"esses."` including
  the full stop. The user wants to confirm sentence/clause punctuation deliberately: the word first,
  the punctuation on a separate Tab.
- Decision: Make a run of separable punctuation its own accept unit. `split` now first checks whether
  the string begins (after any leading whitespace) with separable punctuation; if so the head is that
  punctuation run plus the whitespace trailing it (so the leftover `"."`, or `", today"`, is accepted
  as `"."` / `", "`). Otherwise it finds the first ICU word and extends the head through the word's
  trailing whitespace but stops at the first non-whitespace character — which is exactly the start of
  either the next word (unchanged behaviour) or a punctuation run (now split off). The separable set is
  `. , ; : ! ?` plus the common full-width CJK forms (`。，、；：！？`); a run of them (e.g. `"?!"`,
  `"…"`) is one unit, not one Tab per mark.
- Consequences:
  - `"esses."` → Tab inserts `"esses"`, then `"."`; `"world, today"` → `"world"`, then `", "`, then
    `"today"`. Plain whitespace separators are unaffected (a trailing space still travels with its
    word), so existing Latin/CJK word-walking is unchanged.
  - The change is isolated to `AutocompleteCore`; `CompletionController.acceptNextWord` already loops
    `split` over the shrinking remainder via the anchor, so it walks the new punctuation units with no
    controller change. ICU segments CJK character-by-character in practice, which is orthogonal — the
    punctuation still detaches because the head stops at the first non-whitespace, non-word boundary.
  - Apostrophes/hyphens inside words (e.g. `"don't"`, `"well-known"`) are deliberately *not* in the
    separable set, so contractions and hyphenated words are still accepted as one word.

## ADR-039 — Tag synthesized insertion events so our own key taps ignore them

- Date: 2026-05-31
- Status: accepted
- Context: ADR-037 made the acceptance key tap dismiss a visible suggestion on any non-accept
  key-down. But KeyType inserts an accepted word by synthesizing its own `CGEvent`s —
  `CGEventKeystrokeSynthesizer` posts `⌘V` for the pasteboard strategies and Unicode key events for
  the injection strategies, all via `post(tap: .cghidEventTap)`. Those events are injected below the
  session tap and therefore flow back up through it. The dismissal logic then saw them as the user
  pressing a divergent key (the `⌘V` carries a command modifier → treated as non-text → dismiss;
  injected characters don't prefix-match the held remainder → dismiss), so during Tab word-by-word
  acceptance the held remainder (e.g. `"I'm"` after accepting `"that"`) was cleared the instant the
  inserted word's keystroke arrived — Tab appeared to "dismiss" the completion instead of advancing
  through it.
- Decision: Stamp KeyType's synthesized events with a sentinel. `CGEventKeystrokeSynthesizer` sets
  `source.userData = SynthesizedEventMarker.userData` (a new shared constant in `AutocompleteCore`),
  so every event it posts carries that value in the `eventSourceUserData` field. The acceptance tap
  (`CompletionAcceptanceController.process`) checks that field first and passes such events straight
  through with no side effects — neither accept nor dismiss. The WeChat fallback key tap in
  `MacContextCapture` gets the same guard so our injected keystrokes aren't double-counted into its
  buffer (the AX field text already reflects them).
- Consequences:
  - Restores word-by-word Tab: pressing Tab inserts the next word, the AX-driven snapshot re-pins the
    shrinking remainder to the new caret, and the next Tab accepts the following word — exactly the
    pre-ADR-037 acceptance behaviour, now with ADR-037's eager dismissal still applying to *genuine*
    user keystrokes.
  - This is the canonical "ignore my own synthetic events" pattern; it relies on `eventSourceUserData`
    surviving from the synthesizer's `CGEventSource` to the tap, which it does for events posted from
    that source.
  - The marker constant lives in `AutocompleteCore` (a plain `Int64`, no AppKit/CoreGraphics
    dependency) so both the TextInsertion package and the app/key-tap layers share one definition.

## ADR-040 — On-screen text (OCR) context via focused-window capture

- Date: 2026-05-31
- Status: accepted
- Context: The prompt builder has always reserved a `[Screen context]` section and `makePrompt` plumbs
  a `screenText:` argument, but nothing produced it — `CompletionController` always passed `nil`
  ("OCR/screen is a future source"). The off-by-default `ocrEnabled` switch and the optional Screen
  Recording permission existed (ADR-023, M0) without a capture path. The remaining work was to
  actually capture and OCR on-screen text and feed it in, without regressing the per-keystroke
  latency budget or the privacy posture.
- Decision: Capture the **focused app window** (not the whole display, not a caret crop) via
  **ScreenCaptureKit** (`SCScreenshotManager.captureImage`, macOS 14+), OCR it with **Vision**
  (`VNRecognizeTextRequest`, `.fast`, language correction off), and feed the cleaned text into the
  existing `[Screen context]` section. The focused field's own text is already captured via AX, so
  window OCR adds the *surrounding* on-screen text (other panels, a referenced doc, headers).
  - **Cache, never on the typing path.** OCR costs tens-to-hundreds of ms, so it cannot run per
    keystroke. A new `ScreenTextProviding` protocol (in `AutocompleteCore`, mirroring
    `WritingHistoryProviding`) exposes a cheap synchronous read of the *last* OCR result.
    `WindowOCRCaptureEngine` (`MacContextCapture`, `@MainActor`) holds that cache and refreshes it
    out of band; the heavy capture+OCR runs off the main actor inside a `Sendable` capturer seam
    (`ScreenWindowTextCapturing`), so tests can inject a fake. `CompletionController` only reads
    `latestScreenText` when `ocrEnabled` — exactly the clipboard opt-in pattern.
  - **Refresh cadence:** on focus/window change (driven by the existing AX tracker, keyed on
    bundle id + window title so per-keystroke re-emits don't thrash OCR) plus a slow ~4 s periodic
    timer so a still-focused window tracks slow on-screen changes.
  - **Window selection** is a pure, SCK-free helper (`ScreenWindowSelector`) over a value-type
    `ScreenWindowCandidate`: match the focused app's pid, skip tiny windows, prefer on-screen /
    normal-layer / largest. Kept pure so it (and the OCR text cleanup/length cap) are unit-tested
    without a live display; the live SCK/Vision call needs permission and isn't unit-tested.
  - **Privacy gating** (the screen *read* is the sensitive act, gated at least as tightly as
    completion display): `ScreenContextController` (app target, owns lifecycle + triggers) captures
    only when `ocrEnabled` AND Screen Recording is granted AND the field is non-secure
    (`isSecureTextEntry`/`isPasswordField`/`isPasswordManagerContext`) AND the app's
    `CompletionPolicy.isCompletionEnabled` AND not user-disabled per-app AND not KeyType itself.
    `AppDelegate.syncContextCaptureWithPermission()` starts/stops it (1 Hz) so toggling the switch or
    granting permission takes effect within ~1 s; it is also paused around the GGUF import panel like
    the rest of the AX pipeline. Enabling OCR in Settings without Screen Recording now pops the system
    prompt and deep-links to the pane rather than silently doing nothing.
- Consequences:
  - Lives in the already-linked `MacContextCapture` package (it *is* the context-capture package and
    already imports AppKit/CoreGraphics), so no `.xcodeproj` package-product changes were needed;
    ScreenCaptureKit/Vision are auto-linked system frameworks. App Sandbox is already disabled
    (ADR-005) and Screen Recording is handled by TCC, so no new Info.plist usage key.
  - The field's own text is already captured verbatim via AX, so OCR lines matching it are stripped
    before assembly (`ScreenTextOCR.linesExcludingFieldText`): whitespace-/case-normalised containment
    against `beforeCursor + afterCursor`, dropping any recognised line whose normalised form appears in
    the normalised field text (soft-wrapped field segments are still contiguous substrings, so they're
    caught). Short lines (< 4 normalised chars) are kept to avoid over-stripping a coincidental common
    word. Screen context therefore carries the *surrounding* on-screen text, not an echo of the field.
    Raw OCR is capped (40 lines / 2000 chars) before the section's token budget trims it further.
  - New tests cover the pure pieces (`ScreenWindowSelectorTests`, `ScreenTextOCRTests`) and the
    engine's caching/clear via a fake capturer (`WindowOCRCaptureEngineTests`), plus the provider
    stubs in `AutocompleteCore` (`ScreenTextProvidingTests`). `swift build`/`swift test` stay green
    for both touched packages.

## ADR-041 — Guided drag-and-drop permission flow

- Date: 2026-05-31
- Status: accepted
- Context: Granting Accessibility / Input Monitoring / Screen Recording is the biggest first-run
  friction point. The onboarding "Open … Settings" buttons deep-linked to the right pane, but the
  user still had to find KeyType in a long, alphabetical privacy list and flip the switch — easy to
  get lost in. The sibling reconstruction effort (Cotabby) had already proven a smoother pattern, so
  we cloned it rather than reinventing.
- Decision: Add a guided overlay that opens System Settings and floats a borderless, non-activating
  `NSPanel` ("Drag KeyType to the list above to allow …") containing a real draggable app row. The
  user drags KeyType straight into the privacy table. New app-target files under `Logic/Permission/`:
  `PermissionKind` (metadata + guidance style), `PermissionHostApp` (bundle URL/icon/name),
  `SystemSettingsWindowLocator` (finds the live Settings window in AppKit coords, multi-monitor
  aware), `PermissionDragSourceView` (`NSDraggingSource` writing the bundle `NSURL` so TCC binds the
  grant to the running process's identity), `PermissionOverlayWindowController` (spring/Bezier launch
  animation + tracks the Settings window), and `PermissionGuidanceController` (`@MainActor`
  orchestrator: native prompt first, then overlay, 0.15 s reposition timer + activation observer,
  auto-dismiss on grant). `ScreenFrameReader` (Views) bridges the SwiftUI "Allow" button's screen
  rect so the overlay animates out of it. The existing `PermissionsManager` is *extended* (not
  rewritten) with kind-based `isGranted(_:)` / `requestSystemAccess(for:)` / `openSettings(for:)`
  helpers that dispatch to the existing per-permission methods. Onboarding's `PermissionCard` now
  takes a `PermissionKind` and calls `guidance.requestAccess(for:sourceFrameInScreen:)`; the
  controller is created once in `AppDelegate` and passed to `OnboardingView`.
- Consequences:
  - AppKit (not SwiftUI) for the drag/overlay because the flow needs `NSDraggingSession`, pasteboard
    item providers, a snapshot drag image, and a non-activating panel — all awkward in SwiftUI. The
    overlay uses `NSWindow.displayLink(target:selector:)` (macOS 14+); the app's deployment target is
    14.0 so this is in range.
  - All three permissions use `.guidedOverlay` (including the optional Screen Recording); the
    required/optional labelling stays a separate UI concern. The overlay is torn down when the user
    leaves the permissions step or closes onboarding so it can't linger over System Settings.
  - The new files are pure app-target wiring; no SwiftPM package or package-product changes, so only
    the `.xcodeproj` (`project.pbxproj`) gained the file refs + a `Logic/Permission` group. Build of
    the `KeyType` scheme stays green.

## ADR-042 — KeyType app icon direction

- Date: 2026-05-31
- Status: accepted
- Context: KeyType needs a macOS Tahoe/Liquid Glass-era app icon that works across the newer light,
  dark, and clear/tinted icon appearances while still reading at small Dock sizes. The product is
  about short cursor-local autocomplete, not a general AI chat surface.
- Decision: Use a translucent keyboard keycap as the container metaphor, with a vertical insertion
  caret and three short continuation bars as the glyph. The default/light appearance uses white glass
  with a graphite caret and cyan completion marks; the dark appearance uses a smoky charcoal glass
  tile with a bright caret and cyan completion marks to align with native dark Dock icon aesthetics;
  the clear/tinted source uses a neutral monochrome version of the same geometry.
- Consequences:
  - The icon avoids letters, app initials, chat bubbles, and full keyboard layouts so it remains
    language-independent and directly tied to "text at the cursor".
  - The Icon Composer package keeps separate light, dark, and clear/tinted raster sources rather than
    relying on automatic darkening of the light source, preserving contrast in dark mode.

## ADR-043: Batched beam-frontier decoding — one `llama_decode` per depth level

- Date: 2026-05-31
- Status: accepted
- Context: A fresh profile (`LatencyProfileTests` + a new `PrefillVsBranchMicroBench`) of the warm
  completion path (Qwen3.5-2B-Base Q4_K_M, release, M5 Max) showed ~97% of latency is model forward
  passes, and the cost is dominated by the **number of `llama_decode` round-trips**, not token
  compute. A depth-4 width-4 beam makes **13 decode calls** (`1 + 3·branchWidth`): one prefill plus
  one per branch expansion (ADR-018 already reuses the prompt KV). The micro-bench decomposed a
  single branch call (~4.5 ms) into restore ~0.32 ms, marginal compute ~0.6 ms/token, and a **~3.6 ms
  fixed cost per `llama_decode`** (Metal command-buffer submit/sync + the 151,936-wide LM-head
  projection). So the 12 per-branch calls were ~75% of latency, mostly fixed overhead — the snapshot
  restore from ADR-018 is *not* the bottleneck.
- Decision: expand the whole beam frontier in **one** `llama_decode` per depth level instead of one
  per branch.
  - New `LocalModelRuntime.anchoredLogitsBatch(anchor:suffixes:)` returns per-branch next-token
    logits in input order. A default protocol extension loops over `anchoredLogits`, so every stub
    runtime and all deterministic engine/FIM tests are byte-for-byte unchanged. The engine collects
    all live branches per level and calls it once.
  - `LlamaModelRuntime` seeds each branch into its own sequence with a fresh copy of the resident
    anchor snapshot (`llama_state_seq_set_data` into seq `0..<W` — ~0.32 ms each), then issues a
    single batched `llama_decode` carrying every branch's suffix tokens tagged to its sequence, and
    reads each branch's final-token logits via `llama_get_logits_ith`. `n_seq_max` is sized to exactly
    `branchWidth` (4) — the anchor is held as a serialized snapshot, not a concurrent live sequence,
    so peak concurrent sequences equals the branch count. An on-device sweep confirmed latency
    plateaus once `n_seq_max ≥ branchWidth` (1→88 ms, 4→64 ms, 5→65 ms, 8→66 ms): `n_seq_max` is a
    recurrent-buffer capacity bound, not the GPU matmul batch dimension (that's the token count per
    decode, driven by `branchWidth`), so there is **no power-of-two effect** and extra slots only
    waste ~19 MB each. `kv_unified = true` keeps the cache a single `n_ctx`-cell pool (the budget the
    group-size cap assumes) and suits the shared-anchor case. Frontiers wider than `n_seq_max`, or
    prompts too long to seed many copies within `n_ctx`, chunk into multiple batched decodes
    (graceful, still correct). `seq_cp` is still avoided (it aborts on this hybrid recurrent memory,
    ADR-018); cross-sequence seeding uses `state_seq_set_data`, which the gating tests validate.
  - **This is the default and only decode path.** `enableKVFork: false` remains as a debug fallback
    (sequential per-branch), but the shipped runtime always batches (`maxSequences` default 4).
- Consequences:
  - `llama_decode` calls drop **13 → 4** per completion. Warm cold-start latency falls from ~87 ms to
    **~65 ms (~1.3×)** on the medium case; the **displayed candidate set is byte-for-byte identical**
    to the per-branch path across the profile's four cases. The win is bounded below 2× because the
    LM-head projection (full 151,936 vocab) runs once **per branch** regardless of batching — only the
    command-buffer/sync fixed cost is amortized. Reaching the full 2× requires *also* cutting the
    number of branches (confidence-gated / adaptive beam width), which is the natural follow-up and
    stacks cleanly on this API.
  - **Quality envelope.** Decoding branches in parallel puts this hybrid model's recurrent layers on
    the split path, which reorders **near-tied** logits (ranks 3+) by ≤~0.12 vs a lone single-sequence
    decode — the same envelope ADR-012/018 already accepted. The argmax and top-k *set* are preserved
    (gated by `AnchoredLogitsCorrectnessTests.assertSameDistribution`: identical argmax + identical
    top-5 set), so the shown ghost text never changes; only the order of lower-ranked alternates may.
    Because raising `n_seq_max` perturbs even the single-branch path into this envelope, the prior
    exact-order assertions were relaxed to argmax + set across all KV-reuse tests.
  - Memory: ~one recurrent-state buffer per sequence (~19 MB × 4 ≈ ~76 MB resident), well under the
    ~300 MB ADR-012 flagged for `n_seq_max=16`.

## ADR-044: Detailed component profile — snapshot **capture**, not the LM head, is the next lever

> **Superseded in part by ADR-045.** The "~20 ms snapshot capture" headline below is a
> **measurement artifact** and is wrong: `prepare(N)` returns before the GPU finishes (it never
> reads logits / forces a sync), so the deferred prompt-decode compute leaked into the capture
> delta. With a properly-synced no-capture baseline the capture is **~0.3 ms**; the ~20 ms is the
> **cold prompt decode** itself. See ADR-045 for the correction and the real lever. The per-decode
> floor, bandwidth cross-check, restore (~1 ms), forward/token, and CPU numbers below all stand.

- Date: 2026-05-31
- Status: accepted (measurement only; no code/behavior change); capture finding corrected by ADR-045
- Context: Before optimizing the LM-head projection we profiled the warm completion in detail
  (`PrefillVsBranchMicroBench.testDetailedComponentProfile`, release, M5 Max, Qwen3.5-2B-Base
  Q4_K_M, 1.19 GiB on disk). Rather than algebraically guessing components, it times directly-
  measurable primitives and linear-fits the ones that scale, then reconciles against a real
  depth-4 width-4 completion. Method, so it can be re-run as the model/hardware change:
  - **Prefill scaling** (cold decode of N tokens, N∈{16…256}).
  - **Branch-depth scaling** (resident anchor → restore + decode K-token suffix, K∈{1…8}): fit
    intercept = floor + 1 restore; slope = small-batch forward/token.
  - **Batch-width scaling** (W branches × 1 token in one decode, W∈{1…4}): fit **intercept = the
    true per-`llama_decode` floor** (dispatch + full-model weight stream, no per-branch work);
    slope = per-added-branch (restore + forward + LM-head row).
  - **Capture isolation**: `prepare(N)` decodes **without** `llama_state_seq_get_data`; the anchored
    path decodes **and** captures. Same N ⇒ the difference is the capture cost.
  - CPU side: `logitsForNextToken` readback and `TokenSampler.rank` timed in isolation.
- Findings (min-of-N, warm):
  - **Per-`llama_decode` fixed floor ≈ 3.45 ms** = dispatch + streaming the **whole** 1.19 GiB model
    once. Cross-check: 1.19 GiB / 3.45 ms ⇒ ~344 GiB/s, i.e. the floor is HBM-bandwidth-bound on the
    full weight set. The 151,936-wide **LM head is only ~1/5 of that** (`output.weight` ≈ 230 MB of
    1.19 GiB), so it is **~0.7 ms/decode × 4 decodes ≈ 3 ms (~4%)** of the completion — *not* worth a
    custom kernel on its own.
  - **Snapshot CAPTURE (`llama_state_seq_get_data`) ≈ 20 ms** — the surprise. `prepare(128)` decode-
    only = 2.0 ms, but decode **+capture**(128) = 22.4 ms. It is essentially fixed (dominated by
    serializing this hybrid model's large recurrent SSM state, not the per-token attention KV), and
    happens **once per completion** (and once per keystroke in live typing, when `ensureAnchor`
    re-captures the grown prompt). At ~33% of the 65 ms completion this is now the single biggest
    lever — it is the hidden price of the ADR-018/043 snapshot/restore design (chosen because
    `seq_cp` aborts on hybrid memory).
  - Restore (`set_data`, per branch seed) ≈ 0.62 ms — cheap, confirming ADR-043. Forward/token:
    ~0.016 ms parallel (big prefill ubatch) vs ~0.50 ms small-batch. Readback ≈ 0.02 ms, sampler
    ≈ 0.14 ms — CPU is noise.
  - **Reconciliation** of the real 65.0 ms completion (modeled 61.5 ms, ~5%): prompt decode 15%,
    **snapshot capture 33%**, 3 batched frontier levels 48% (≈ 3 × 3.45 ms floor + 12 restores +
    branch forwards), readback+sampling 3%.
- Decision: **Do not** pursue an LM-head-specific optimization next; its ceiling is ~4%. Rank the
  real levers by the profile:
  1. **Kill / amortize the ~20 ms capture** (largest single cost). Options to investigate: re-check
     whether the current llama.cpp supports `seq_cp` on this hybrid memory (would replace one 20 ms
     `get_data` + N×`set_data` with cheap intra-graph copies); capture lazily only when a level
     actually branches; or avoid the snapshot entirely by keeping the anchor live and seeding
     branches another way. Quality envelope (ADR-012/018/043) must hold.
  2. **Fewer decodes** (already 13→4 via ADR-043): confidence-gated / adaptive beam width cuts the
     3.45 ms floor × levels further and stacks on the batched API.
  3. The per-decode floor itself is full-model bandwidth — only a smaller/more-quantized model moves
     it; out of scope for a no-quality-loss change.

## ADR-045: The "20 ms capture" was a sync artifact — capture is ~0.3 ms; 65 ms is a cold-cache number

- Date: 2026-05-31
- Status: accepted (measurement + analysis; the only code change is reverting a probe — see below)
- Context: Investigating ADR-044's top lever ("kill the ~20 ms snapshot capture") produced three
  results that overturn it. Probes added to `PrefillVsBranchMicroBench`
  (`testDetailedComponentProfile`, `testColdVsWarmCompletion`); the llama.cpp build now exposes the
  `llama_state_seq_*_ext` APIs with `LLAMA_STATE_SEQ_FLAGS_ON_DEVICE`.
  1. **ON_DEVICE snapshots give zero speedup.** Wiring capture/restore through the `_ext` APIs with
     `ON_DEVICE` (keep the serialized state in device buffers, skip the host round-trip) was gated
     on-device: it does **not** abort on this hybrid recurrent memory and keeps the candidate set
     byte-identical, but capture stayed ~20 ms (20.8 vs 20.7 ms). So there was no host round-trip to
     remove — the cost was not a serialize/transfer at all. The flag was reverted (no benefit, added
     surface); the proven `llama_state_seq_get_data`/`set_data` path is unchanged.
  2. **The "~20 ms capture" was a measurement artifact.** ADR-044 isolated capture as
     `anchoredLogits(N,[])` − `prepare(N)`. But `prepare(N)` returns **before the GPU finishes** — it
     never reads logits, so it never forces a sync — while `anchoredLogits` reads logits/captures and
     therefore *does* sync. The delta was the **deferred prompt-decode compute**, not capture. With a
     properly-synced no-capture baseline (`prepare(N)` **+ `logitsForNextToken()`**) the delta is
     **~0.3 ms**: capture (`llama_state_seq_get_data`) is cheap. Restore is ~1 ms/branch (confirms
     ADR-043). The ~20 ms is the **cold prompt decode** (clear + full forward + sync): the cold
     prefill floor is ~15 ms vs the warm batched per-decode floor of ~3.1 ms — a ~12 ms gap that is
     `llama_memory_clear(true)` + first-decode Metal graph/buffer reallocation.
  3. **The headline 65 ms is a cold-cache benchmark artifact.** Every bench (`LatencyProfileTests`,
     the sweeps) calls `resetKVCache()` each iteration, forcing the clear + full prompt re-decode.
     Real typing is a **pure ~1-token append** (verified: each keystroke's prompt shares all but its
     last token with the previous one, because `beforeCursor` is effectively the prompt tail), so
     ADR-018's append path decodes only the typed delta. Measured: **cold 64 ms vs warm/append best
     ~33 ms / mean ~46 ms** — steady-state per-keystroke latency is ~half the reported cold number.
     The ~31 ms `cold − warm` gap is exactly the full prompt re-decode that the append path already
     avoids after the first keystroke.
- Corrected component breakdown of the 65 ms **cold** completion (modeled 57.7 ms vs measured 65.3,
  ~12%): cold prompt decode+sync **~22 ms (38%)**, capture ~0.3 ms (1%), 3 batched frontier levels
  **~33 ms (58%)**, readback+sampling ~2 ms (4%).
- Decision / revised lever ranking for "halve latency, no quality loss":
  1. **Report and optimize the right number.** Steady-state typing is already ~33–46 ms, not 65 ms;
     the cold 65 ms hits only the first keystroke / on a cache miss (prefix rewrite, app/window
     change, large edit). Latency work should target the **warm** path.
  2. **Cut the 3 batched levels (~33 ms, 58% — now the dominant steady-state cost).** This is
     ADR-044's lever #2: confidence-gated / adaptive beam **width** and **depth** remove whole
     branches/levels, each saving a ~3.1 ms floor + ~1 ms/branch restore + branch forwards. Also
     worth probing: the per-level `llama_memory_clear(true)` + re-seed in `decodeBranchGroup` may
     itself pay part of the realloc tax 3× per completion.

### ADR-045 lever #2 follow-up — per-level profile points at incremental beam decoding

- `testBeamLevelProfile` records each beam level (one `anchoredLogitsBatch`) on the warm path. The
  level cost **grows with depth** — e.g. on the "tomorrow " case: level 2 (4 branches, 4 suffix tok)
  10.2 ms, level 3 (4, 8 tok) 11.8 ms, level 4 (4, 12 tok) 19.4 ms — because `decodeBranchGroup`
  reseeds the anchor snapshot and **re-decodes each branch's entire suffix from scratch every
  level**. A full depth-4 width-4 completion re-decodes ~24 suffix tokens where incremental decoding
  (one new token per live branch per level) needs ~12 — **~12 wasted token-forwards** (~6 ms) plus
  the ~11 anchor re-restores (~1 ms each) that carry them.
- The per-level `llama_memory_clear(true)` is **not** a villain in steady state: the warm batched
  per-decode floor is ~3.1 ms (vs the ~15 ms cold prefill floor), so the clear/realloc is a
  one-time post-`resetKVCache` cost, not paid per level once warm. Adaptive **width** is also largely
  already happening — `prune`/`relativeCutoff` collapses the beam to 1 branch when the model is
  confident (the "brown fox → lazy dog" case finishes in 2 levels); tightening the cutoff would drop
  real candidates (changes the set), so it is **not** a no-quality-loss lever.
- **Proposed fix: incremental beam decoding.** Keep each live branch resident in its own sequence
  and decode only its **one new token** per level, instead of reseeding the anchor and re-decoding
  the whole suffix. A branch with a single surviving child extends its sequence in place (no restore,
  no re-decode); a branch that forks into K>1 kept children copies its state (cheap now that capture
  is ~0.3 ms + restore ~1 ms) into K−1 free sequences. Prune to `branchWidth` *before* allocating
  sequences, so ≤ `branchWidth` live sequences are ever needed. Expected to cut the levels from
  ~33 ms toward ~18–22 ms with **identical** logits (same forward passes, just cached — within the
  ADR-012/018/043 split-recurrent envelope already accepted). Cost: a stateful branch-handle runtime
  API + sequence lifecycle management in `LlamaModelRuntime` (a milestone-sized, correctness-sensitive
  change), gated by `AnchoredLogitsCorrectnessTests` + a candidate-set equality test vs the reseed
  path.
  3. **Warm the first keystroke.** Pre-decode/seed the cache at session start (or on focus) so the
     first real completion isn't a cold ~22 ms clear+decode. Cheap, one-time, no quality impact.
  4. LM head (~4%) and capture (~0.5%) are **not** worth optimizing — both were dead ends.

## ADR-046: Incremental beam decoding — keep branches resident, decode one new token per level

- Date: 2026-05-31
- Status: accepted (implemented, default on)
- Context: ADR-045's lever #2 — the 3 batched frontier levels are the dominant steady-state cost
  (~33 ms / 58%), and `decodeBranchGroup` (ADR-043) wastes work by **reseeding the anchor and
  re-decoding each branch's entire suffix every level** (~12 redundant token-forwards + ~11 anchor
  re-restores per depth-4 width-4 completion).
- Decision: make `anchoredLogitsBatch` keep an **incremental beam frontier** in `LlamaModelRuntime`.
  When consecutive calls form a beam (each level's suffixes are one-token extensions of the previous
  level's), every live branch's KV stays resident in its own sequence and only the **new token** is
  decoded per level:
  - A map `frontier: [suffix → seq id]` records which sequence holds `anchor + suffix`. The empty
    (root) suffix is implicit — its state is `anchorSnapshot`.
  - For each pending branch, the parent is `suffix.dropLast()`. The **first** child of a parent
    **extends that parent's sequence in place** (no restore, no re-decode — just one token at
    `parentLen`); **additional** children (a fork/split) restore a snapshot of the parent into a free
    sequence (`seq_rm` + `set_data`) taken *before* any in-place token is appended, so copies are
    clean. Root children all fork from `anchorSnapshot` (seq 0 is never assumed to still hold the
    anchor, so the cross-keystroke append invariant is preserved). One `llama_decode` advances the
    whole frontier.
  - Slot accounting is exact: ≤ `branchWidth` ≤ `n_seq_max` live branches, in-place children reuse
    their parent's slot, forks take freed (non-surviving-parent or unused) slots — so a slot is never
    overcommitted.
  - **Fallback never removed:** any call whose parents aren't resident (the first level, an
    interleaved single-branch `anchoredLogits`, or a non-beam call pattern) drops to the proven
    ADR-043 reseed path, which then *registers* the resulting frontier so the next level can resume
    incrementally. Every non-beam decode path (`prepare`, single `anchoredLogits`, `resetKVCache`,
    anchor change/append, a root suffix) calls `invalidateFrontier()`, so a stale frontier is never
    reused after the cache is mutated underneath it. Gated by `enableIncrementalBeam` (default on).
- Quality (the hard part): incremental decodes a branch's tokens as **separate single-token
  recurrent updates across levels**, whereas reseed/full-decode process the suffix as **one chunk**.
  On this hybrid Gated-Delta-Net model the chunked-GDN math for chunk-size-1 is not bit-identical to
  chunk-size-N, so incremental is *not* bit-equal to reseed for non-root branches (root forks **are**
  bit-equal — identical batch). Measured drift on an adversarial 3-level frontier (`testIncremental…`
  diagnostic): `|incremental − full-decode| ≤ 0.074`, essentially **the same** as
  `|reseed − full-decode| ≤ 0.096`, and `|incremental − reseed| ≤ 0.036` — all inside the documented
  ADR-012/018/043 ≤~0.12 split-recurrent envelope. So incremental adds **no drift beyond what the
  shipped batched path already incurs**. (Lesson: a strict top-k-*set* assertion is too brittle for
  this envelope — adversarial near-ties reorder/re-set ranks 3+ and can flip a tied argmax for *both*
  reseed and incremental vs a sequential decode; the gate is now a quantitative max-|Δlogit| bound
  plus argmax-stability only for well-separated branches.)
- Gates: `AnchoredLogitsCorrectnessTests.testIncrementalFrontierWithinEnvelope` (root forks +
  in-place extend + mid-beam split, `|inc−truth| ≤ 0.12`, `|inc−reseed| ≤ 0.06`, well-separated
  argmax preserved) and `ConstrainedGenerationIntegrationTests.testIncrementalBeamPreservesTopCompletion`
  (the **displayed top completion is identical** with incremental on vs off across 5 realistic
  prose/code prompts). Full ModelRuntime + ConstrainedGeneration suites green in release.
- Result (`testIncrementalWarmSpeedup`, warm/append path, release): reseed mean **46.1 ms** → incremental
  mean **35.2 ms** (best 33 → 26 ms) — **1.31× / ~11 ms saved per keystroke**, no quality change.
  Combined with ADR-043's cold-start win, this is the second compounding cut to the per-keystroke
  steady-state cost.

## ADR-047 — Group source files by responsibility inside existing targets

- Date: 2026-05-31
- Status: accepted
- Context: Several app and SwiftPM target directories had grown into flat folders with many
  unrelated implementation files, making Xcode navigation and ownership boundaries harder to scan.
- Decision: Keep the existing module graph unchanged, but organize files into responsibility-based
  subdirectories inside each target. The app target now groups completion, context, settings,
  permissions, models, telemetry, controls, and settings-section views. SwiftPM targets now group
  dense source/test folders by local concern, such as context-capture accessibility/caret/screen/
  text-analysis, token-profile format/storage/classification/validation, generation engine/
  filtering/sampling/text, and model-management catalog/download/validation. The app target's
  `.pbxproj` groups mirror the physical layout; SwiftPM targets rely on recursive source discovery
  under `Sources/<Target>` and `Tests/<Target>`.
- Consequences: Future files should land in the nearest responsibility folder before creating a
  new package or widening a root target directory. This is a source organization change only; it
  does not alter module boundaries or public APIs.

## ADR-048 — Mid-line (FIM) completions render in a capsule below the caret

- Date: 2026-05-31
- Status: accepted
- Context: Inline ghost text is drawn starting at the caret's right edge and extending rightward.
  For end-of-line completions this reads naturally, but for **mid-line** (fill-in-the-middle)
  completions the ghost text is painted directly **on top of** the field's existing suffix text on
  the same line, producing an unreadable overlap (the user's "…center of my presentation…" with the
  suggestion smeared over it).
- Decision: When the live completion has visible (non-whitespace) suffix remaining on the *current*
  line, present it as a self-contained rounded **capsule below the caret** instead of inline ghost
  text. The capsule is horizontally centered on the caret and then clamped inside the field rect, so
  a caret near the trailing edge pins the capsule to the trailing edge (and likewise the leading
  edge); a capsule wider than the field pins to the leading edge. It sits a few points below the
  caret with its own surface (`controlBackgroundColor` fill, subtle border, window drop shadow) and
  uses opaque system label text rather than the dimmed field color, since it is a distinct popover
  surface rather than a continuation of the field's own text.
  - End-of-line, end-of-document, and **end-of-paragraph** completions (the remainder of the current
    line is empty/whitespace and the next character is a newline) keep the existing inline ghost-text
    form — there is no same-line suffix to overlap.
  - Implemented as `OverlayPresentation` (`inlineGhost` / `capsule`) on `OverlayPlacement`, a
    `CapsuleCompletionView`, and a `GhostTextOverlayWindow.capsuleLayout`. The presentation is chosen
    in `CompletionController.renderSuggestion` via `shouldUseCapsule(for:)`, only for `.inline`
    placement mode (text-mirror apps already render above the line). FIM generation is unchanged.
- Consequences: Mid-line suggestions are always legible regardless of the suffix behind them. The
  capsule decision is driven by the *live* after-cursor text, so a suggestion can switch between
  inline and capsule forms as the caret moves to/from the end of a line. Tab/Shift+Tab acceptance and
  the live shrink-as-you-type anchor are unaffected (only the presentation layer changed).

## ADR-049 — Suppress suffix-duplicating completions; guard against corrupted OCR context

- Date: 2026-05-31
- Status: accepted
- Context: A `predictions.log` review of mid-line completions showed two quality defects. (1) On a
  small model, fill-in-the-middle decoding routinely degenerates into **copying the suffix** back
  out as the "middle": with the caret at "…level of per|formance to the RTX 5070…" the model emitted
  "formance to the RTX 5070, so it's" — exactly the text already after the caret (often with a stray
  leading `**`/`•`). Accepting it duplicates the user's own words; nothing in the pipeline caught it.
  (2) The opt-in screen-OCR context fed **corrupted recognitions** into the prompt ("Ilne wilh real
  5ulfix 4 capsul•"), which the base model then parroted.
- Decision:
  - **Suffix-overlap suppression.** Added `SuffixOverlapGuard` (AutocompleteCore) which, comparing on
    alphanumerics only (so leading garbage glyphs don't defeat it), flags a completion that
    reproduces the head of `afterCursor` — both the boundary-aligned case (suffix starts with the
    completion) and the mid-word case (the caret split a word, so the copy starts a few chars into
    the suffix, bounded by the straddled word remainder). It is applied in the engine (drops such
    branches from the finalised set so a non-duplicative branch can surface) and re-checked in
    `DefaultCandidateFilter` as the documented last gate, with a new
    `SuppressionReason.duplicatesAfterCursor`. Conservative: never fires without a suffix or below a
    minimum overlap, so ordinary end-of-line continuations are untouched. Aligns with "prefer
    suppression to a wrong suggestion".
  - **Corrupted-OCR guard.** `ScreenTextOCR.recognizeLines` now drops Vision candidates below a
    confidence threshold (the primary signal of a mangled recognition), and a new
    `ScreenTextOCR.droppingCorruptedLines` removes lines with replacement characters, high symbol
    density, or too few real word characters — tuned to leave prose, model names, version numbers,
    and code punctuation intact. Wired into the capturer before field-text stripping.
- Consequences: Mid-line FIM no longer offers (or inserts) duplicates of the existing suffix — in the
  common "caret inside an already-complete sentence" case it now shows nothing, which is the intended
  behaviour. OCR context that reaches the prompt is higher quality; the cost is occasionally dropping
  low-confidence-but-real lines, which is acceptable for an optional context source. All affected
  package suites (AutocompleteCore, ConstrainedGeneration, MacContextCapture, CompletionUI) are green
  in release.

## ADR-050 — Catch suffix-containing duplicates and digit-substituted OCR words

- Date: 2026-05-31
- Status: accepted
- Context: A follow-up `predictions.log` review surfaced two gaps left by ADR-049. (1) A mid-word
  caret produced a completion that *finished the straddled word and then re-typed the rest of the
  line* — e.g. caret at "…create a Git|hub repo for KeyType." with completion
  "ithub repo for KeyType.". The completion is *longer* than the suffix (it prepends a word
  completion), so ADR-049's prefix/offset checks missed it; it rendered as a stale-looking mid-text
  capsule. (2) OCR still leaked digit-substituted words ("qu81ity" for "quality"), which the model
  parroted — ADR-049's symbol/confidence guards don't flag all-alphanumeric mojibake, and letter-digit
  mixes were deliberately spared to protect "RTX 5070"/"N1X".
- Decision:
  - **Suffix-contained duplication.** `SuffixOverlapGuard` now also suppresses a completion whose
    normalised form *contains* the whole normalised suffix (above a minimum length). Inserting such a
    completion always duplicates the existing suffix, so this is safe and covers the
    "complete-the-word-then-retype-the-rest" shape.
  - **Digit-substituted OCR words.** `ScreenTextOCR` now drops a line containing any token with a
    digit *substituted inside a lowercase word* — a digit that has a lowercase letter before it and
    any letter after it ("qu81ity", "h3llo"). Trailing digits ("utf8", "v2"), leading digits ("3D",
    "5070"), hyphen-split units ("20-core"), and ALL-CAPS model names ("N1X", "RTX5070") are left
    untouched, so legitimate technical text survives.
- Consequences: Stale/duplicate mid-word completions no longer appear (they suppress to nothing), and
  the most common OCR letter→digit corruption no longer reaches the prompt. The digit-substitution
  rule can drop developer jargon like "k8s"/"i18n" from *surrounding screen context* (never from the
  field's own AX text), an acceptable trade for an optional context source. Suites for the affected
  packages are green in release; the app target builds.

## ADR-050 — The separator leads the next word, not the previous one

- Date: 2026-05-31
- Status: accepted (refines ADR-038, which had the head *trail* through the word's whitespace)
- Context: `NextWordSplitter` (Tab word-by-word, ADR-016/038) bundled a word's **trailing** whitespace
  into the same accept unit, so `" word word word."` split into `[" word ", "word ", "word", "."]`.
  The desired segmentation puts the space **before** the word it separates: `[" word", " word",
  " word", "."]`, and `"word word word."` → `["word", " word", " word", "."]`. The leading separator
  belongs to the upcoming word, not the one just accepted.
- Decision: The word head now stops at the ICU word's `upperBound` (leading whitespace still travels
  with the word, trailing whitespace does not), and the leading-punctuation unit no longer swallows
  the whitespace after the punctuation run. In both cases the trailing whitespace stays in `rest` so
  it leads the next unit. The separable-punctuation set and run-as-one-unit behaviour from ADR-038 are
  unchanged.
- Consequences: `"world, today"` now walks as `["world", ",", " today"]` (the comma alone, then the
  space-led word) rather than `["world", ", ", "today"]`. Insertion is unchanged in aggregate — the
  walk still reconstructs the full string and `acceptNextWord` loops `split` over the shrinking
  remainder via the anchor — only the boundary at which the separator is inserted moved by one unit.

## ADR-051 — Release & distribution: Developer-ID DMG + Sparkle appcast

- Date: 2026-05-31
- Status: accepted
- Context: KeyType ships outside the Mac App Store (App Sandbox is off and it links a dynamic
  llama.cpp framework, ADR-005/007), so it had no way to deliver itself or push updates to users.
  We needed a repeatable, scripted release and an in-app auto-update path that doesn't compromise
  the on-device/private posture.
- Decision: Distribute a Developer-ID-signed, notarized, stapled `.dmg` attached to a GitHub
  release, and auto-update via **Sparkle 2** reading a signed appcast.
  - Sparkle is added as a remote SwiftPM dependency on the app target only (the `Packages/*` graph
    stays AppKit/Sparkle-free, per the module-graph rule). A small `@MainActor @Observable`
    `UpdaterController` wraps `SPUStandardUpdaterController`; the menu bar gains a
    "Check for Updates…" item. Scheduled background checks come for free.
  - The EdDSA **public** key and the feed URL live in the generated Info.plist via
    `INFOPLIST_KEY_SUPublicEDKey` / `INFOPLIST_KEY_SUFeedURL` (the target keeps
    `GENERATE_INFOPLIST_FILE = YES`). The private key stays in the developer's login keychain and
    is never committed.
  - `SUFeedURL` points at `https://johnbean393.github.io/KeyType/appcast.xml`, served by GitHub
    Pages from the repo's `docs/` folder. `docs/appcast.xml` is committed (skeleton + one `<item>`
    per release).
  - `Scripts/release.sh` (orchestration) + `Scripts/prepareRelease.sh` (DMG + notarize + Sparkle
    sign) + `Scripts/ExportOptions.plist` (developer-id) drive the whole flow: archive → export →
    notarize app → DropDMG → notarize/staple DMG → `sign_update` → prepend the appcast `<item>` →
    commit/push → `gh release create`. Mirrors the proven Hivecrew tooling; min OS 14.0, tag
    `v<version>.0`, DMG named `KeyType.<version>.dmg`.
- Consequences: Releasing is one command but depends on machine-local prerequisites (Developer-ID
  cert, a notarytool keychain profile named `development`, DropDMG with an "App Distribution"
  config, the Sparkle CLI at `SPARKLE_BIN`, an authenticated `gh`, and GitHub Pages enabled on
  `/docs`). Updates are only as trustworthy as the EdDSA private key, so it must be backed up and
  kept off the repo. Bumping `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` before a release is
  required; the script warns when metadata is unchanged since the last tag.

## ADR-052 — A failed profile build must not leave a usable artifact

- Date: 2026-06-01
- Status: accepted
- Context: A user reported (issue #1) that switching the active model to a Gemma GGUF surfaced
  "The operation couldn't be completed. (ProfileBuilderCore.ACPFCLIError error 1.)", and that
  clicking "Prepare" again and restarting appeared to fix it. Three problems combined here:
  (1) `ACPFCLIError` was only `CustomStringConvertible`, so the app's `error.localizedDescription`
  rendered the generic Foundation bridge string ("…error 1.") instead of the readable per-check
  detail — "error 1" is just the source-order index of `.selfCheckFailed`. (2) The catalog "Prepare"
  path (`ModelSetupCoordinator.startProfileGeneration`) used `localizedDescription` while the import
  path used a `message(for:)` helper that prefers the typed error's description — an inconsistency.
  (3) `BuildProfile.run` writes the profile **before** its post-write self-check, so a self-check
  failure left the written file on disk, and `ProfileGenerator.generateProfileIfNeeded` skips
  building whenever the output already exists — so the retry trusted the file that had just failed
  validation rather than rebuilding it, masking the failure (the actual fault was never reproduced
  and is most likely transient resource contention while a second `LlamaModelRuntime` is brought up).
- Decision: (1) `ACPFCLIError` now also conforms to `LocalizedError` (`errorDescription = description`)
  so the readable text surfaces through any `localizedDescription`. (2) `startProfileGeneration` uses
  the same `message(for:)` helper as the import path and logs that message. (3) `generateProfileIfNeeded`
  builds into a sibling temp file and only moves it into place after `BuildProfile.run` (including the
  self-check) succeeds, deleting the temp on failure; and before honoring the "already present" skip it
  validates the existing profile by opening it against the live tokenizer (the same check the runtime
  applies at load time), rebuilding if that validation fails.
- Consequences: Profile-build failures now show which self-check failed instead of an opaque error
  code, and a failed or interrupted build can no longer be silently "fixed" by reusing a bad file —
  a retry rebuilds. The validate-on-skip path adds one O(vocab) tokenizer-digest pass when a profile
  already exists, but only on the setup/import path (never the completion hot path), so the cost is
  negligible. Behaviour is unchanged on the success path.

## ADR-053 — Hide completion latency without changing candidate quality

- Date: 2026-06-01
- Status: accepted
- Context: Release profiling showed the shipped decoder was already usually in the 25-65 ms range
  for production-like prompts, while the app-level debounce and first-use prompt/model work could
  add visible latency before a suggestion appeared. The quality constraint is strict: latency work
  must not change model scoring, candidate filtering, or the final top-N suggestions.
- Decision: Add four latency-only changes:
  - Use an adaptive debounce in `CompletionController`: start at 50 ms, use 35 ms after a responsive
    generation (<= 70 ms), and back off to 90 ms after slow generations (> 140 ms).
  - Add `ConstrainedGenerationEngine.warmUp(for:)`, which runs the same policy gates and decodes the
    request anchor/root logits without sampling or displaying text. The app uses this once after model
    load and opportunistically for a new prompt side-context burst.
  - Freeze optional prompt side-context sections (history samples, pasteboard text, screen text) for
    two seconds per field/privacy key so auxiliary context does not rewrite the prompt prefix on every
    keystroke within the same burst.
  - Stop beam search early only when the unique, suffix-safe finalized top-N candidates strictly
    outscore every live branch's current score. Because future token log-probabilities are never
    positive, each live score is an upper bound on any continuation it can still produce; strict
    comparison preserves tie ordering.
- Consequences: Candidate generation still uses the same prompt ingredients, token sampler, policy
  gates, suffix guard, and final ranking. Warmup never emits suggestions. Early exit is covered by
  deterministic tests for both the locked-candidate case and the equal-score tie case, where search
  must continue because the visible top suggestion can still change. The production latency profile
  now shows the short append case completing in about 34 ms with two batched decode calls, while
  medium/long/FIM cases remain in the same release-profile range as before.

## ADR-054 — Redraw the remaining ghost text eagerly on Tab acceptance, not on the next snapshot

- Date: 2026-06-01
- Status: accepted
- Context: Tab word-by-word acceptance (`CompletionController.acceptNextWord`, ADR-016/039) inserts the
  next word, advances the live caret optimistically, and sets `visibleCandidate` to the remainder —
  but it did **not** redraw the overlay. The shrunk remainder was re-pinned to the new caret only when
  the post-insertion focused-field snapshot arrived (`handle` → `renderSuggestion`). That snapshot is
  driven by AX `kAXValueChangedNotification`/`kAXSelectedTextChangedNotification`, which is near-instant
  in web fields but lags the keystroke by tens-to-hundreds of ms in many native apps (worst case, only
  the 0.5 s safety poll). So after accepting a word mid-word at the end of a paragraph, the ghost text
  visibly stalled at its old position/length until the lagging snapshot (or the next generation) landed
  — it read as "the ghost text doesn't redraw until the next completion finishes." This is the
  acceptance-side twin of ADR-037, which already established that the AX-snapshot path is correct but
  *late* and must be front-run for UI immediacy.
- Decision: Redraw the remainder synchronously from `acceptNextWord`, without waiting for AX. The prior
  inline overlay already drew the remainder exactly `head`'s rendered width past the caret, so shifting
  the overlay by that width and redrawing just the remainder lands it where it already sat on screen
  (the inserted real text falls under where the ghost `head` was). The geometry lives in `CompletionUI`:
  `GhostTextOverlayWindow` remembers its last `show` parameters and exposes `advanceAfterAccepting(head:
  remainder:)`, which measures `head` in the on-screen (already-resolved) font, shifts the caret rect
  along the writing direction (`advanced(_:byAcceptedWidth:)` — rightward LTR, leftward RTL), and
  redraws; an empty remainder hides the overlay. It is a no-op for the **capsule** (mid-line) presentation,
  which the AX path keeps repositioning. `InlineGhostTextPresenter.advanceAfterAccepting` forwards to the
  window and updates `visibleCandidate`. The controller calls it just before synthesizing the insertion.
- Consequences:
  - Mid-word / end-of-paragraph word acceptance shrinks and follows the caret on the same run-loop turn
    as the Tab, independent of how slowly the target app reports AX changes; the AX snapshot still re-pins
    precisely a moment later, correcting any sub-pixel width drift. Repeated rapid Tabs accumulate
    correctly because each advance builds on the last shown placement, and a real snapshot resets it.
  - No public protocol change: the controller holds the concrete `InlineGhostTextPresenter`, so the new
    method is additive. The shift math is a pure static function unit-tested in `CompletionUITests`
    (LTR rightward, RTL leftward).
  - Capsule/mid-line acceptance is deliberately unchanged (the inline reposition heuristic doesn't apply),
    so this carries no regression risk for fill-in-the-middle completions.

## ADR-055 — Drop a word break the model emits after a healed stem

- Date: 2026-06-01
- Status: accepted
- Context: A user typing `"I am just doing my aft"` (caret mid-word, nothing after) saw the suggestion
  insert as `"aft ernoon"` instead of `"afternoon"` — a stray space appeared after the partial word
  on Tab. Mid-word token healing (ADR-019) backs the prompt up to the last clean boundary and forces
  the decoder to re-emit the stem as a required prefix (here `" aft"`). `GenerationBranch.consumePrefix`
  only constrains tokens *until* the prefix is satisfied; once `" aft"` is emitted the branch is free to
  continue with any token. Usually the model continues the sub-word cleanly (`" afternoon"`), but
  sometimes it treats the forced stem as a *complete* word and starts a new one, emitting `" aft ernoon"`.
  `MidWordHealing.strip` removed only the stem bytes, leaving `" ernoon"` with a leading space.
  `CaretBoundary.reconcile` would have dropped that space, but it only does so when the live `beforeCursor`
  ends in whitespace — and healing's precondition guarantees it ends in a letter/digit, so the gate never
  fired. The trailing-whitespace trim in `present()` (ADR-024) only handles a dangling space at the end.
  The result was an intermittent stray space, depending on whether the model broke the word after the stem.
- Decision: After dropping the healed stem, `MidWordHealing.strip` also drops any whitespace immediately
  following it. Healing only fires when the caret sits inside the word being typed, so the genuinely new
  text must attach directly to the partial word; a leading separator is always a spurious word break and
  is safe to remove. Spaces *between* later words in the completion are untouched.
- Consequences: Mid-word completions insert flush against the partial word again (`"aft" + "ernoon"`).
  The fix is localized to `strip` (the one place the healed stem is removed) rather than widening
  `CaretBoundary`'s whitespace rule, which must stay gated for the non-heal path. Covered by new
  `MidWordHealingTests` cases (`" aft ernoon"`/`" gre at"` → no stray space; internal spaces preserved).

## ADR-056 — Mid-word completion quality: accurate OCR, a dead-end-stem net, and a charset guard

- Date: 2026-06-01
- Status: accepted
- Context: A user report (and a `predictions.log` review) confirmed that *mid-word* completions are the
  weakest case across every model, and worse on the larger ones. Two distinct failure shapes recurred:
  (1) a useless **single letter** continuation that can't begin any English word (e.g. `"th"` → `"x"`),
  and (2) **random characters** — a stray `$`/`*` glued onto the word, or runs of periods (`"...."`) —
  which spike sharply when the opt-in screen-OCR context is enabled and feeds garbled text the model
  then parrots. Existing defences didn't cover them: the current-word typo net (ADR-015/024) only judges
  a word once it has *closed*, so an open dead-end stem and any junk character that closes the word both
  slipped through; the OCR corruption filters (ADR-049/050) are per-line lexical heuristics that can't
  catch every mangled recognition.
- Decision: three conservative, on-principle ("prefer suppression to a wrong suggestion") changes.
  - **Accurate OCR at the source.** `ScreenTextOCR.recognizeLines` now uses Vision `.accurate`
    recognition with language correction *on*. The capture runs out of band (focus/window change + a
    4 s timer, never on the keystroke path — `ScreenContextController`/`WindowOCRCaptureEngine`), so
    there is no per-keystroke latency to protect; cutting mangled recognitions at the source is the
    highest-leverage fix for OCR-induced "random character" completions. The ADR-049/050 corruption
    filters stay as a backstop.
  - **Dead-end-stem net.** `DefaultCandidateFilter` gains `currentWordIsDeadEnd`, the mirror of the
    typo net for the still-*open* case it deliberately skips: if the word the user is completing is left
    open on a stem that cannot begin any dictionary word, suppress (`SuppressionReason
    .currentWordHasNoValidCompletion`). It reuses the typo net's exact reconstruction (heal-aware via
    ADR-019, same `isEligible` rules, same already-used-term exemption) and a new
    `SynchronousWordRecognizing.canCompleteWord(prefix:language:)` (default `true`; the macOS
    `SystemWordRecognizer` implements it with `NSSpellChecker.completions(forPartialWordRange:)`,
    conservative to `true` whenever the checker can't answer). This kills the "useless single letter".
  - **Mid-word charset guard.** New `MidWordCharsetGuard` drops a prose/correction completion that closes
    the typed word with a *junk* character (anything that isn't a letter/digit/whitespace or an allowed
    word-closer like `. , ! ? ; : ' " ) ] - … / %`) or that contains a ≥4-long run of one punctuation
    mark. Applied **in the beam** (so a clean branch can win instead of the controller suppressing the
    corrupted best) and re-checked in the filter as the last gate (mapped to `.insertionUnsafe`).
    A symbol that follows a clean boundary — a brand-new word, e.g. the `$` in `" $5"` — is left alone,
    so prices/markup in ordinary prose are untouched, and the guard never runs in `.code`/`.terminal`.
- Consequences: Mid-word now either offers a real word or nothing, and OCR-polluted "random character"
  completions are caught at the source and again at the word boundary. Trade-offs: a budget-truncated
  long word whose stem *is* a viable prefix is still shown (the dead-end net only fires on truly
  impossible stems); the charset junk-closer set is deliberately narrow to avoid false positives, so
  garbage that starts a fresh word inside a completion is not policed. `swift build`/`swift test` green
  for AutocompleteCore, ConstrainedGeneration, and MacContextCapture; new `CandidateFilterTests` cover
  both nets. The `.accurate` OCR cost is unmeasured per-capture but bounded by the off-path 4 s cadence.

## ADR-057 — Mid-line FIM quality: truncate-at-overlap, suffix-likelihood rerank, windowed context

- Date: 2026-06-01
- Status: accepted
- Context: A review of mid-line (fill-in-the-middle) completions surfaced three weaknesses left after
  ADR-017/049/050. (1) On small models, FIM decoding often emits a genuine "middle" and then *runs
  into the suffix*, regurgitating text already after the caret; `SuffixOverlapGuard` caught these but
  **discarded the whole branch**, throwing away the usable fill in front of the duplication. (2) Among
  several plausible middles, nothing scored *how well the real suffix continues* once a middle is
  inserted — the strongest FIM-specific signal of a good join. (3) The FIM path fed the model the
  entire raw `beforeCursor`/`afterCursor`, so a long body of text inflated latency and diluted the
  local join signal. These are mid-line-only; end-of-line (append-at-caret) behaviour was fine.
- Decision: three changes, all **always on** for mid-line requests (numeric tunables in
  `DecodingConfiguration`, but no on/off flags), each constructed to only improve or no-op:
  - **Truncate-at-overlap.** `SuffixOverlapGuard.nonDuplicatingPrefixLength` reports where a completion
    starts reproducing the suffix (mapping the case-folded-alphanumeric overlap point back to an
    original-string character count, rounding down). `GenerationBranch.truncatedToText(prefixCharCount:)`
    rebuilds a branch from only the leading whole tokens that fit, recomputing bytes/score/displayWidth
    from per-token data now retained on the branch. The engine salvages a duplicating branch to its
    middle instead of dropping it; a pure suffix copy (or a middle below a 3-grapheme floor, or one that
    still duplicates after the cut) is dropped — identical to the old "show nothing". `duplicatesSuffix`
    is refactored to share the new overlap-detection core, so its boolean result is byte-identical.
  - **Suffix-likelihood rerank.** `ConstrainedGenerationEngine.rerankBySuffixLikelihood` measures, for
    each surviving mid-line candidate, the mean per-token log-probability of the first
    `suffixRerankTokenCount` real `afterCursor` tokens conditioned on `prefix + middle` (a round-trip
    "join" score via `anchoredLogitsBatch` on a per-candidate anchor), and adds
    `suffixRerankWeight × meanJoinLogProb` to a copy of the branch score before ranking. It is strictly
    **reorder-only** — it never drops a candidate — and a guaranteed no-op when the runtime returns no
    logits (every stub/recording runtime), so existing deterministic tests are unaffected. Suppressing
    catastrophic joins is deliberately out of scope (would risk new false suppressions).
  - **Windowed FIM context.** `fillInMiddlePrompt` keeps only the prefix *tail* (`fimMaxPrefixTokens`,
    default 256) and the suffix *head* (`fimMaxSuffixTokens`, default 64) — the bytes nearest the caret.
    A context already under the cap is fed verbatim, so short fields are unchanged. `SuffixOverlapGuard`
    still compares against the *full* `afterCursor` (windowing only changes what the model conditions on).
- Consequences: Mid-line completions now salvage a real fill where they used to vanish, are ordered by
  how cleanly they let the existing suffix continue, and stay within a bounded, caret-local context on
  long documents. Defaults (256/64/3/1.0) are starting points to tune from the on-device
  `PromptStrategyProbeTests` mid-line section (extended to print the truncated, reranked top-2) and
  `predictions.log`. The rerank adds a few short forward passes per mid-line completion on a per-candidate
  anchor (no KV reuse with the search anchor); it runs only when there are 2+ mid-line candidates. New
  tests: `SuffixOverlapGuardTruncationTests` (AutocompleteCore); `GenerationBranchTruncationTests`,
  `DecodingConfigurationTests`, engine truncation/drop + rerank flip/no-op cases, and FIM windowing cases
  (ConstrainedGeneration). `swift build` + `swift test -c release` green for both packages (65 and 109).

## ADR-058 — Show a Dock icon while a main window (Settings / setup) is open

- Date: 2026-06-01
- Status: accepted
- Context: KeyType ships as a dockless menu-bar agent — `LSUIElement` in `Info.plist` plus
  `setActivationPolicy(.accessory)` at launch (ADR-005). That's the right default during normal use
  (the app lives in the menu bar and shouldn't clutter the Dock or ⌘-Tab), but it makes the app's own
  windows awkward to return to: once you click away from the Settings or onboarding/setup window there
  is no Dock icon or ⌘-Tab entry to switch back to, so the window is effectively lost behind other apps.
- Decision: temporarily promote KeyType to `.regular` (dock-visible) while either main window — the
  Settings window or the onboarding/setup window — is on screen, then revert to `.accessory` once they
  are all closed. `AppDelegate` tracks the set of visible main-window IDs (`dockVisibleWindowIDs`) and
  exposes `mainWindowDidAppear(id:)` / `mainWindowDidDisappear(id:)`. The policy flips to `.regular`
  (followed by `NSApp.activate`) only when the set goes from empty to non-empty, and back to `.accessory`
  only when the last window closes. The window scenes in `KeyTypeApp` drive this via `.onAppear` /
  `.onDisappear`, passing their existing window-ID constants. `LSUIElement` stays `true`: it only governs
  launch state, and Apple's pattern for agent apps is to toggle the activation policy at runtime rather
  than remove the plist key.
- Consequences: while Settings or setup is open, KeyType has a normal Dock icon and ⌘-Tab entry, so
  switching back to it is trivial; the moment both are dismissed it returns to a pure menu-bar agent. A
  set (rather than a bool or counter) keeps the toggle idempotent against repeated `onAppear` calls and
  correct when both windows overlap (closing one while the other is open keeps the Dock icon). The
  completion/AX pipeline is untouched — this is purely presentation. Trade-off: SwiftUI `onDisappear`
  semantics for `Window` scenes are the close signal; if a future macOS regression stops firing it on a
  red-button close, the revert would need an `NSWindow` close observer instead.

## ADR-059 — Prefix-trie self-check tolerates duplicate-byte tokens (Gemma)

- Date: 2026-06-01
- Status: accepted
- Context: Selecting a Gemma model (`gemma-v262144`, ADR-035) aborted in-app profile
  generation with `Profile self-check failed: - [triePresence] token 239 reached state 2
  but terminal=Optional(249732)`, and ADR-052 then deleted the half-built artifact, so the
  model was unusable. Root cause: Gemma's vocabulary contains *duplicate* tokens — distinct
  ids whose raw bytes are byte-for-byte identical (here 239 and 249732). The ACPF prefix
  trie (ADR-009) is keyed purely on bytes and stores a single `terminal_token_id` per node,
  so duplicates collide on one node and only the last writer's id survives as the terminal.
  `ProfileSelfCheck.checkTriePresence` asserted exact identity (`terminal == id`) for every
  non-excluded token, which is unsatisfiable when two non-excluded tokens share bytes. The
  same wrong assumption sat in the trie-state `MmapAutocompleteProfile.tokenAllowed(_:in:)`
  (`terminal == id`), a latent admissibility bug for any duplicate-byte tokenizer.
- Decision: treat the trie as a *byte oracle*, not a token-id map. Walking a non-excluded
  token's bytes from the root must reach a **terminal** node; a different stored terminal id
  is accepted **only** when its bytes are byte-for-byte identical (a genuine duplicate). A
  non-terminal node, or a terminal whose bytes differ, is still a hard failure. The same
  byte-equality rule replaces the id-identity check in `tokenAllowed(_:in:)`, which also
  rejects ids the trie builder would exclude (base `.excluded` flag) so a non-excluded
  duplicate cannot make an excluded token admissible. No schema or
  writer change: the on-disk format, the byte-based runtime admissibility path
  (`tokenAllowed(_:afterRequiredPrefix:)`, used by the decoder) and the per-record
  `trieTerminal` jump field are untouched, so existing profiles keep loading.
- Consequences: Gemma (and any duplicate-byte tokenizer) builds and validates again; the
  self-check still catches real corruption (missing path / non-terminal / bytes mismatch).
  The trie deliberately cannot tell duplicates apart — which id wins a shared node is an
  insertion-order detail and intentionally not asserted. `terminalTokenID(at:)` stays a raw
  accessor (returns whatever id is stored). Tests: `DuplicateTokenTrieTests` builds profiles
  with identical-byte ids and asserts the self-check passes, both non-excluded duplicates are
  admissible, and an excluded duplicate is rejected; the strict `TriePresenceTests` still
  guards the no-duplicate fixture.

## ADR-060 — Reuse still-matching generated branches after the next keystroke

- Date: 2026-06-01
- Status: accepted
- Context: Branching search can produce several plausible continuations, but the UI historically
  anchored only the displayed top candidate. If the user typed the next character of a lower-ranked
  branch, the top candidate was invalidated and the controller discarded the whole suggestion before
  waiting for a fresh decode. That was correct for safety, but wasteful in the common case where a
  non-top generated branch already exactly matched the user's next character.
- Decision: after a shown prediction, keep a short-lived, string-only promotion cache containing the
  filter-approved, caret-reconciled candidate anchors from that generation, ranked by source order and
  score. On each append-only context change, or immediately on key-down before the AX snapshot arrives,
  promote the first cached branch whose anchor still matches the live typed prefix and whose remaining
  text is at least three characters. Recompute instead when there is no typed delta, the context changed
  in any non-append way (target, suffix, deletion, caret jump, active selected text), no branch
  matches, or all matches have only a one- or two-character remainder. Harmless AX metadata refreshes
  such as caret selection-range movement, typing context, labels, placeholder, or detected language do
  not invalidate an otherwise append-only match. Normal clearing paths (`reset`,
  suppression, no match, too-short match, acceptance teardown, stop/shutdown) clear the cache. The cache
  deliberately stores no logits, KV state, token branches, or model memory; a promoted branch is just a
  previously generated string re-anchored against the live caret.
- Consequences: the first post-generation keystroke can now keep a lower-ranked branch alive without a
  decode, while still falling back to generation whenever the cache signal is weak. This trades a small
  bounded string array per shown prediction for avoided decodes and avoids retaining expensive model
  internals. A quantification test with five distinct first-letter branches shows 5/6 typed choices are
  reusable with branch promotion versus 1/6 with top-candidate-only reuse (recomputes drop from 5/6 to
  1/6, an 80% reduction for that fixture). The test also covers lower-rank promotion, no-match
  recompute, too-short recompute, active-selection recompute, and metadata refresh preservation.

## ADR-061 — Held Tab-acceptance remainders outrank branch-promotion cache decisions

- Date: 2026-06-02
- Status: accepted
- Context: ADR-060's promotion cache is intentionally conservative: it recomputes when the live
  context has active selected text or when a matching branch has only a one- or two-character remainder. That
  policy is right for speculative type-through, but it is wrong during word-by-word Tab acceptance.
  Once the user has explicitly accepted the first word of a shown completion, the remaining anchored
  text is no longer a speculative branch candidate; it is the held continuation the user is walking
  through with repeated Tab presses. Letting the cache run first could clear that held continuation,
  including long remainders when a post-insert AX snapshot briefly reports an active selection.
- Decision: while `holdAnchor` is active, the controller first re-renders the held anchor against the
  live context and returns, before consulting the promotion cache or starting generation. Starting a
  word-by-word hold also clears the promotion cache, because it is not needed until the held suggestion
  is exhausted or abandoned. Transient post-insert snapshots that still match the held anchor but lack
  usable caret placement preserve the visible remainder instead of calling `reset`; the next good
  snapshot re-pins it.
- Consequences: accepting the first word of a completion keeps the rest available, including short
  remainders (`"hi"`, `"."`) and long remainders whose AX selection state changed after insertion. The cache
  remains authoritative for ordinary typing, but never overrules an explicit Tab-acceptance hold.
  Regression tests cover both a short remainder rejected by the cache floor and a long remainder
  rejected by cache context validation while still valid under the held anchor.

## ADR-062 — Bounded reuse history for typo rollbacks

- Date: 2026-06-02
- Status: accepted
- Context: After ADR-060, a generated candidate set could be reused when the user typed into a
  still-matching branch, but ordinary invalidation still flushed the previous winning completion. If
  the user made a typo, deleted one or two characters, and returned the caret to a prior prefix, the
  useful anchor was already gone and KeyType had to decode again. A time-based retention window was
  rejected: old-enough-by-wall-clock is not the relevant safety boundary, and a fixed candidate count
  is easier to reason about and bound.
- Decision: keep a bounded `CompletionReuseHistory` of recent `CompletionPromotionCache` snapshots.
  The history stores only filter-approved strings plus rank/log-prob metadata: no logits, token
  branches, or KV state. It defaults to 150 total entries. Eviction removes the oldest, lowest-ranked
  entries first, while protecting a 10% budget (15 entries at the default size) for the current append
  bucket and for older rollback-recovery entries whenever that many entries exist. Ordinary
  no-candidate/suppression/no-match or transient missing-caret/placement clears the visible
  suggestion but keeps the history; hard resets (focus/policy/model changes, stop/shutdown, full
  accept, or final word accept) clear it. Reuse is allowed for compatible same-target/same-suffix
  contexts, and still recomputes when there is no match, only a 1- or 2-character remainder, active
  selected text, suffix/trait change, or another non-append/non-rollback edit. `predictions.log` now
  records `REUSE append`, `REUSE rollback`, misses, and evictions.
- Consequences: typo rollback can recover previously generated completions without a model decode,
  while memory stays bounded to a small string array rather than model state. The trade-off is that
  reuse is intentionally lexical: it cannot rescore old candidates with fresh logits and will decode
  again whenever the string signal is weak. Tests quantify both paths: the original branch-promotion
  fixture avoids 5/6 recomputes versus 1/6 with top-only reuse, and the rollback fixture recovers 5/5
  deleted-typo anchors versus 0/5 after the old flushed-cache behavior.

## ADR-063 — Preserve visible completions for macOS screen capture shortcuts

- Date: 2026-06-02
- Status: accepted
- Context: ADR-037 correctly clears visible completions from the global key tap as soon as a
  non-accept keydown might mutate the text field or move the caret. macOS screen capture shortcuts
  (`Shift-Command-3/4/5`, plus the Control clipboard variants) are different: they are observation
  commands, not edits. Treating them as divergent `.nonText` keydowns hid the very overlay users need
  to capture in screenshot bug reports and recording demos.
- Decision: classify the macOS screen capture shortcuts as reserved system shortcuts in
  `AutocompleteCore`, before user-configurable acceptance matching. The acceptance tap passes them
  through untouched and asks the completion controller to preserve the current overlay. While that
  screen-capture hold is active, Tab acceptance is disabled until a later non-Screenshot focused-field
  snapshot revalidates the text/caret context. The WeChat fallback key tap uses the same shared
  classifier so it does not clear its fallback buffer on screenshot shortcuts.
- Consequences: screen captures can include the visible ghost text without KeyType consuming the
  shortcut or hiding the overlay. Ordinary Command shortcuts still clear eagerly, because they can
  mutate text, selection, caret, or document state. The Screenshot toolbar can temporarily take focus
  without making a stale completion acceptable; the normal AX pipeline resumes once the original field
  is seen again. Tests cover the reserved key-code/modifier contract and the acceptance-side wrapper.

## ADR-064 — Cache Electron bundle detection outside the AX hot path

- Date: 2026-06-02
- Status: accepted
- Context: KeyType already handles web-shaped AX trees by walking from `AXWebArea` to the active
  editable child and by using deeper Chromium caret-geometry fallbacks. Some Electron apps do not
  reliably expose enough URL/domain context for a domain override, but their app bundle usually
  contains stable Electron markers such as `Electron Framework.framework` or `.asar` resources. Doing
  filesystem work during every AX snapshot would add latency to the keystroke path.
- Decision: add `AppBundleWebAppClassifier`, a locked process-local cache keyed by bundle
  identifier. At app launch KeyType primes it from `NSWorkspace.runningApplications`; the shared
  `AccessibilityContextTracker` also primes defensively when it starts and scans newly launched apps
  from `NSWorkspace.didLaunchApplicationNotification`. Each bundle id is scanned at most once per
  process, using a bounded set of known Electron marker paths plus shallow checks of
  `Contents/Frameworks` and `Contents/Resources`. Focused-field capture only performs a cheap cache
  lookup and marks `TextFieldTraits.isWebField` when the focused app is known to be Electron-backed.
- Consequences: Electron-backed apps can be identified as web fields even when AX ancestry/domain
  extraction is incomplete, without putting bundle I/O on every AX read. The detector is intentionally
  conservative and local to the launch session; if an app updates while KeyType is running, the new
  bundle contents are picked up after the next KeyType launch. Tests cover Electron framework markers,
  `.asar` resource markers, and native bundles without markers.
