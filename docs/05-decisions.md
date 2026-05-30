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

