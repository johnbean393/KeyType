# KeyType — Architecture

This describes the module graph, each module's responsibility, the runtime data flow, and the
existing code you build on. It is a *behavior-level* reconstruction (see clean-room rules in
`00-overview.md`).

## End-to-end pipeline

The pipeline is **latency-first**: each keystroke or focus change invalidates only part of the
state. Stable prompt prefixes stay warm in the KV cache; only the changed suffix plus candidate
generation costs compute.

```
macOS Accessibility events
        │
        ▼
[MacContextCapture]  capture focused field: before/after cursor, selection, caret rect,
        │            app/window/domain, labels, language → TextFieldContext
        ▼
[AppCompatibility]   eligibility gates: is completion enabled here? mid-line allowed? → CompletionPolicy
        │
        ▼
[Prompting]          assemble budgeted, sectioned prompt ending exactly at the cursor → prompt string
        │
        ▼
[ModelRuntime]       tokenize prompt, reuse KV-cache prefix or decode batch, expose next-token logits
        │
        ▼
[ConstrainedGeneration] mask via [TokenProfiles] (exclusions/bias), enforce required-prefix &
        │                byte/token trie admissibility, branch search, stop conditions → candidates
        ▼
[AutocompleteCore]   output filters: UTF-8, required prefix, width, typo guard, app gates →
        │            show best candidate or suppress (SuppressionReason)
        ▼
[CompletionUI]       render inline ghost text at the caret rect (or mirror/table fallback)
        │
        ▼
[TextInsertion]      on Tab: save pasteboard → paste/inject → app workaround → restore pasteboard
        │
        ▼
   Target app text field
```

## Module responsibilities & current state

All modules are local SwiftPM packages under `Packages/`. The shared contract lives in
**`AutocompleteCore`**; every other package depends on it.

### `AutocompleteCore` — the contract ✅
Domain types and protocols shared by all modules. Already defined:
- `TextFieldContext` (before/after cursor, `TextSelection`, `TextFieldGeometry` with `cursorRect`,
  `AppTarget`, placeholder, labels, language, typing context).
- `CompletionRequest` (context, prompt, `requiredPrefixBytes`, `CompletionMode`,
  `maxCompletionTokens` default **4**, `maxDisplayWidth`).
- `CompletionCandidate`, `CompletionMode` (`prose/code/terminal/emoji/correction`).
- `SuppressionReason` (the full filter taxonomy).
- Protocols: `ContextProviding`, `CompletionGenerating`, `CandidateFiltering`.
- `typealias TokenID = Int32`.

**Rule:** new cross-module types belong here. Keep it free of AppKit/llama dependencies.

### `MacContextCapture` — focus & text snapshot 🟡
Currently returns only app identity with an **empty `beforeCursor`** and no caret rect.
Target behavior (from research §5 "Context Management"):
- Observe AX notifications: `AXFocusedUIElementChanged`, `AXFocusedWindowChanged`,
  `AXSelectedTextChanged`, `AXValueChanged`, `AXUIElementDestroyed`, `AXWindowMiniaturized`.
- Extract before/after cursor text, selection, caret rect, end-of-line & RTL state.
- Capture environment: bundle id, window title, URL/domain when available, field labels.
- Debounce updates; normalize AX errors; never block the main thread.
- **Reuse the proven caret code from `Red Dot`** (see below).

### `Prompting` — sectioned budgeted prompt ✅
See `02-prompting.md`. Already implements `PromptSection`, priority/min/max budgets, truncation
modes, `PromptBuilder` (base-continuation + ChatML), approximate token counter. Next step is a
real tokenizer-backed counter (via `ModelRuntime`) and personalization wiring.

### `ModelRuntime` — local LLM 🟡
Defines `LocalModelRuntime`, `ModelTokenizing`, `ModelMetadata`, `TokenLogit`. Only a
`StubModelRuntime` + `UTF8FallbackTokenizer` exist today. Target: wrap **llama.cpp** to load a
GGUF, tokenize/detokenize, decode batches, read next-token logits, expose EOS/EOT, and support
**KV-cache sequence ops** (`llama_memory_seq_cp/keep/rm`, `clear`) for prefix reuse across
keystrokes (research §8). Keep the `LocalModelRuntime` protocol stable so the stub stays usable
for tests.

### `ConstrainedGeneration` — the decoding loop ✅(multi-branch)
`ConstrainedGenerationEngine: CompletionGenerating` performs real constrained decoding (M5,
ADR-010): a deterministic best-first **multi-branch** search honouring `branchWidth`,
`relativeCutoff` (cumulative-logprob margin), and `minBranchProbability`; top-k/top-p/temperature
shaping with cumulative log-probability scoring (`TokenSampler`); required-prefix + byte/trie
admissibility from the profile (`tokenAllowed(_:afterRequiredPrefix:)`, advanced per branch);
incremental UTF-8-validated detokenization (`GenerationBranch` + `UTF8Scanner`); and stop on
EOS/EOT, `.stopAndSuppress`, sentence-end (`.stopAndDisplay`), display-width limit,
`maxCompletionTokens`, or an inadmissible transition. It drives the linear `LocalModelRuntime`
protocol by re-`prepare`-ing `basePrompt + branchTokens` and honours cooperative `Task`
cancellation so a newer keystroke aborts in-flight work. `TokenSampler` pre-selects the top
candidates by raw logit before ranking so per-step work is bounded instead of vocabulary-wide,
and the per-completion cost scales with the number of branch expansions, so `branchWidth`
defaults to 4 (ADR-012, ~0.5 s warm per 4-token completion on the reference model). Because each
divergent branch re-decodes the shared prefix (recurrent-safe, ADR-011), batching sibling
branches into one multi-sequence decode (KV-fork) is the next latency optimization.

### `TokenProfiles` — vocabulary intelligence ✅(in-memory) / 🟡(on-disk)
`AutocompleteProfile` protocol + `InMemoryAutocompleteProfile` + `TokenProfileFlags` +
`TokenStopBehavior`. The **ACPF on-disk format and offline builder do not exist yet** — that's a
milestone (see `03-token-profiles.md`).

### `CompletionUI` — overlays ✅(types) / 🟡(rendering)
`OverlayMode` (inline/mirror/suggestionTable/correction/smartInsertWarning), `OverlayPlacement`,
`OverlayPlacementResolver`, `GhostTextView`, `NoopCompletionOverlayPresenter`. Target: a real
borderless overlay window at the caret rect — **reuse `Red Dot`'s `RedDotOverlayWindow`** as the
starting point (it already does non-activating, all-spaces, click-through panel placement).

### `TextInsertion` — acceptance ✅(plan) / 🟡(execution)
`InsertionStrategy`, `InsertionPlan`, `InsertionPlanner` (chooses strategy from policy),
`PasteboardCompletionInserter`. The inserter currently sets/restores the pasteboard but **does not
yet synthesize the paste keystroke**. Target: real paste via `CGEvent` (⌘V), paste-and-match-style,
non-breaking-space, chunked/char injection, backspace-after-paste, with pasteboard save/restore.

### `AppCompatibility` — per-app policy ✅
`TargetOverride`, `CompletionPolicy`, `AppCompatibilityStore` with a couple of seed overrides
(Terminal, Google Docs). Target: a maintainable override table covering completion gating,
mid-line rules, Tab handling, insertion workarounds, overlay geometry tuning, and custom
instructions — **authored originally, not copied from Cotypist's database.**

## Reusing the `Red Dot` caret-tracking code

A sibling Xcode project, **`Red Dot`** (`../Red Dot`), already solves the hardest part of context
capture: **robustly locating the on-screen caret rectangle** across native, Chromium/Electron, and
web (Google Docs-style) text fields. It is proven and should be ported, not rewritten.

Files to port into `MacContextCapture` (caret resolution) and `CompletionUI` (overlay window):

| Red Dot file | What it does | Port into |
|---|---|---|
| `AXCaretGeometryResolver.swift` | Resolves caret `CGRect` via `AXBoundsForRange`, text-marker ranges, previous-character bounds, deep Chromium tree walk, static-text-run estimation; multi-display CG↔AppKit coordinate conversion with quality ranking (exact/derived/estimated). | `MacContextCapture` |
| `AccessibilityCaretTracker.swift` | `@MainActor` tracker: AX permission handling, 30 fps polling of the system-wide focused element, normalization, status messaging. | `MacContextCapture` (convert polling → AX-notification-driven where possible; keep poll as fallback) |
| `RedDotOverlayWindow.swift` | Borderless `NSPanel`: `.nonactivatingPanel`, `canJoinAllSpaces`, `ignoresMouseEvents`, `.screenSaver` level, clear background — i.e. a correct click-through overlay above the caret. | `CompletionUI` (swap the red `Circle` for ghost-text/inline view) |

Porting notes:
- Replace Red Dot's 30 fps `Timer` poll with AX-notification-driven refresh + a low-frequency
  safety poll; per-keystroke latency matters.
- Keep the **quality ranking** (exact → derived → estimated) — it's what makes placement feel
  native across apps.
- The geometry resolver is `@MainActor` and AppKit-bound; keep it in a macOS-only target.
- Feed the resolved rect into `TextFieldGeometry.cursorRect` so `OverlayPlacementResolver` and the
  overlay window can consume it unchanged.

## Concurrency & threading

- AX calls and overlay windows are main-thread/AppKit-bound (`@MainActor`).
- Model decode is CPU/GPU-heavy → run off the main actor; marshal results back for UI.
- The `LocalModelRuntime` protocol is `async`; keep generation cancellable (a newer keystroke
  must cancel an in-flight completion).

## Module dependency rules

- `AutocompleteCore` depends on nothing app-specific (Foundation/CoreGraphics only).
- Everything depends on `AutocompleteCore`. `ConstrainedGeneration` also depends on `ModelRuntime`,
  `TokenProfiles`, `AppCompatibility`. UI/insertion depend on `AppCompatibility`.
- The **app target** (`KeyType/`) is the only place that wires concrete implementations together
  (`KeyTypeModuleGraph.swift`). Keep packages decoupled and individually testable.
