# KeyType — Milestones (archive) & Improvement Backlog

The app is **built and shipping**. The milestone list below (M0–M8) is the **completed
construction history**, kept for context on how each subsystem came to be and where its
acceptance criteria live. For ongoing work, jump to the **[Improvement backlog](#improvement-backlog)**
at the bottom — that is the living section.

When you pick up backlog work: make the smallest change behind the existing protocols, keep
`swift build`/`swift test` green for every package you touch, and log decisions in `05-decisions.md`.

Legend: ✅ done · 🟡 partial / has deferred follow-ups.

---

# Completed milestones (archive)

## M0 — Repo hygiene & app shell  ✅

Foundation so later work has somewhere clean to land.

**Tasks**

- ✅ Flatten the nested git/workspace structure to a single root (done at handoff).
- ✅ Add `.gitignore` (models, profiles, Xcode user data) (done at handoff).
- ✅ Add a top-level `LICENSE` (MIT) and a `README.md` pointing at `docs/`.
- ✅ Replace the default SwiftData window app (`Item.swift`, windowed `ContentView`,
`ModelContainer`) with a **menu-bar / background agent** app shell (`MenuBarExtra`,
`LSUIElement` + accessory activation policy). App Sandbox disabled (see ADR-005).
- ✅ First-run onboarding that requests **Accessibility** (and optionally **Screen Recording**)
permission with clear copy and a deep link to the right Privacy & Security pane.

**Acceptance**

- App launches as a menu-bar item (no dock window), shows permission status, and links to the
relevant System Settings pane. `swift build` + the Xcode app target build succeed.

---

## M1 — Real context capture (port Red Dot)  ✅

Make `TextFieldContext` real.

**Tasks**

- ✅ Port `AXCaretGeometryResolver` + caret-tracking into `MacContextCapture` (see ADR-006);
preserved the exact -> derived -> estimated quality ranking and multi-display CG <-> AppKit
conversion.
- ✅ Notification-driven `AccessibilityContextTracker`: `AXObserver` on focus/window/selection/
value/destroy/miniaturize, debounced (~20 ms), low-frequency safety poll (0.5 s), re-targets on
`NSWorkspace.didActivateApplicationNotification`.
- ✅ `FocusedFieldReader` populates `beforeCursor`, `afterCursor`, selection, `cursorRect`,
`isAtEndOfLine`, `isRightToLeft`, bundle id, window title, browser domain (via `AXWebArea` /
`AXURL`), labels, detected language (`NLLanguageRecognizer`). Pure helpers
(`TextCursorSplitter`, `WritingDirection`, `LanguageDetector`) covered by `swift test`.
- ✅ Debug overlay ported into `CompletionUI` as `CaretDebugOverlayWindow` (kept as a debug
marker for now; M6 swaps it for inline ghost text). App target owns the wiring and logs each
emitted context via `os.Logger`.

**Acceptance**

- Focusing a text field in TextEdit, Safari, and a Chromium app logs an accurate
`TextFieldContext` (correct before/after split and a caret rect within a few px of the real
caret). A debug overlay (reusing Red Dot's window) sits on the caret. No main-thread stalls.
- Manual on-device acceptance still to be exercised by the user; package tests
(`MacContextCaptureTests`) cover the pure logic.

---

## M2 — Model runtime (llama.cpp)  ✅

Replace the stub with a real local model. **Done** — `LlamaModelRuntime` (`ModelRuntime`
package) is an actor-isolated `LocalModelRuntime` over the official llama.cpp prebuilt
xcframework (see ADR-007), implementing GGUF load, tokenize/detokenize, raw token bytes, batch
decode, next-token logits, EOS/EOT, and vocab size. KV prefix reuse is implemented via
`reuseThreshold` (pure-append-or-clear) plus the anchored snapshot/restore path used by the
multi-branch decoder; the literal `seq_cp/keep/rm` ops were replaced by
`llama_state_seq_get_data`/`set_data` because cross-sequence `seq_cp` aborts on the hybrid
recurrent/SSM Qwen3.5 model (see ADR-018).

**Tasks**

- ✅ Integrate **llama.cpp** (SwiftPM wrapper or prebuilt xcframework; pick one and record why in
`05-decisions.md`). Implement `LocalModelRuntime` + `ModelTokenizing` over it: load GGUF,
tokenize/detokenize, raw token bytes, decode batch, next-token logits, EOS/EOT, vocab size.
- ✅ Implement KV-cache sequence ops and a `reuseThreshold` for prefix reuse across keystrokes
(snapshot/restore instead of `seq_cp/keep/rm` on hybrid memory — ADR-018).
- ✅ Keep `StubModelRuntime` working for tests; keep the protocol stable.

**Acceptance**

- ✅ Given a prompt string and a small open GGUF, the runtime returns plausible next-token logits
and can decode N tokens. A test asserts tokenizer round-trip (`detokenize(tokenize(x)) == x` for
ASCII) and that KV reuse produces identical logits to a full decode for an unchanged prefix
(`LlamaModelRuntimeTests`). On-device only: the GGUF-backed tests `XCTSkipUnless` a model is
present in the app-support container (ADR-007), so they skip on a bare machine.

---

## M3 — Prompting upgrades  ✅→

Tighten the already-working builder.

**Tasks**

- Swap the approximate token counter for a real tokenizer-backed `PromptTokenCounting` (via M2).
- Wire `customInstructions` from `AppCompatibility` and `previousUserInputs` from a local history
store (stub the store if needed).
- Add the golden-prompt and budget tests from `02-prompting.md`.

**Acceptance**

- Golden-prompt snapshot tests pass; oversized before/after-cursor truncate toward the caret;
prompt stays within `maxPromptTokens` measured by the real counter.

---

## M4 — Token profiles: ACPF format + builder  ✅

Give the sampler real vocabulary intelligence. **Done** — the on-disk `ACPF` schema (ADR-009),
the memory-mapped `MmapAutocompleteProfile` reader, and the offline builder all shipped; profiles
are generated in-app per model family during model download (ADR-034). The tasks/acceptance below
are the original spec.

**Tasks**

- Implement the `ACPF` on-disk format (`03-token-profiles.md`): header, token table, bytes blob,
prefix trie, buckets, special lists, bias tables, validation metadata.
- `MmapAutocompleteProfile: AutocompleteProfile` (memory-mapped reader, header/hash validation).
- Offline builder (SwiftPM executable) that produces a profile from a GGUF tokenizer.
- All validation tests from `03-token-profiles.md`.

**Acceptance**

- Builder produces a profile for an open tokenizer; reader memory-maps it and passes every
validation test; round-trip candidate sets are stable across serialization.

---

## M5 — Constrained generation (real search)  ✅→

Upgrade the greedy loop into proper constrained decoding.

**Tasks**

- Multi-branch search honoring `branchWidth`, `relativeCutoff`, `minBranchProbability`.
- Real top-k / top-p / temperature sampling; cumulative logprob scoring.
- Byte/token **trie admissibility** from the profile; `requiredPrefixBytes` enforcement.
- Incremental detokenization with UTF-8 validity; stop on EOS/EOT, sentence boundary policy,
width limit, `maxCompletionTokens`, or inadmissible transition.
- Cancellation: a newer keystroke cancels in-flight generation.

**Acceptance**

- With a real model+profile, generation returns a small ranked candidate set; required-prefix
tests yield only prefix-satisfying candidates; invalid-UTF8/over-width branches are dropped;
generation cancels promptly on a new request.

---

## M6 — Filtering, overlay, insertion → **MVP demo**  ✅

First end-to-end Tab-accept experience. **Done** — see ADR-016. `DefaultCandidateFilter`
(`ConstrainedGeneration`) covers the full `SuppressionReason` taxonomy; `InlineGhostTextPresenter`
+ `GhostTextOverlayWindow` (`CompletionUI`) render ghost text in the field's font at the caret;
`PasteboardCompletionInserter` (`TextInsertion`) does real ⌘V/⌘⌥⇧V/chunk/char/first-word insertion
with clipboard save+restore behind testable seams; `CompletionAcceptanceController` (`CGEvent`
session tap) accepts next word on Tab / full string on Shift+Tab via the multilingual
`NextWordSplitter`; `CompletionController` orchestrates capture→prompt→generate→filter→overlay
against the live Qwen runtime + ACPF profile (`LlamaModelRuntime` linked + library-validation
entitlement added).

**Tasks**

- Implement `CandidateFiltering` covering the `SuppressionReason` taxonomy (UTF-8, required
prefix, width, mid-line rules, app gates, current-word typo guard, insertion safety).
- Real inline ghost-text overlay at the caret rect (reuse `RedDotOverlayWindow`, swap the view).
- Real insertion in `TextInsertion`: synthesize ⌘V paste via `CGEvent`, pasteboard save/restore,
plus the policy-driven workarounds (match-style, non-breaking-space, chunk/char, backspace).
- Global **Tab** acceptance hotkey, gated by `CompletionPolicy.allowsTabAcceptance`.

**Acceptance — the milestone the whole project is gated on:**

- In **TextEdit**, typing shows relevant ghost-text completions; pressing **Tab** inserts the
completion and restores the clipboard; wrong/long/mid-line-colliding candidates are suppressed
(show nothing). Demonstrated end-to-end on device.

---

## M7 — App/domain overrides & robustness  ✅→

Make it feel native everywhere.

**Tasks**

- Expand `AppCompatibility` overrides (original content): completion gating, mid-line rules, Tab
handling, insertion workarounds, overlay geometry tuning, custom instructions per app/domain.
- Fallbacks: text-mirror overlay, terminal/TUI handling, Google-Docs-style web fields.
- Password-manager / secure-field exclusions.

**Acceptance**

- Completions behave correctly (or correctly suppress) across a matrix of apps: native Cocoa,
Chromium, a terminal, and a password field. No broken native Tab behavior.

---

## M8 — Personalization & polish  🟡

See ADR-023.

**Tasks**

- ✅ Local writing-history store + retrieval feeding `previousUserInputs` (opt-in, on-device).
Encrypted at rest with **SQLCipher** (GRDB), key in the Keychain; the new `Personalization`
package's `PersistentWritingHistoryStore` conforms to `WritingHistoryProviding`, and
`WritingHistoryRecorder` (app target) captures the user's typing — gated by the privacy switch,
`allowsTrainingDataCollection`, and secure-field exclusion. Selection mixes recent + longest
same-app + a few cross-app recents under a token budget.
- ✅ Acceptance/suppression/latency telemetry (local only, `CompletionTelemetryStore`) wired into
the controller; `ThresholdTuner` applies bounded nudges to the decoder's relative-cutoff and
min-branch-probability at engine build.
- ✅ Settings UI (`SettingsView`/`SettingsStore`): model selection, completion length, per-app
toggles, and privacy switches (history/clipboard/OCR **off by default**) with a one-action
"Clear all personal data". Per-app disables layer onto `AppCompatibility`.
- ⬜ Autocorrect/typo mode (separate from completion) — **deferred** (ADR-023); the in-beam typo
guard (ADR-015) covers the worst case for now.

**Acceptance**

- ✅ History improves acceptance rate measurably (deterministic `HistoryAcceptanceTests`; live lift
visible in the Settings stats panel); settings persist (UserDefaults); all personal data stays
local (encrypted DB + local JSON telemetry) and is clearable in one action.

---

## Cross-cutting definition of done (every change)

- New logic lives behind the `AutocompleteCore` protocols; packages stay decoupled.
- Tests added/updated; `swift build` + `swift test` green for touched packages.
- A decision-log entry added to `05-decisions.md` for any non-obvious choice.

---

# Improvement backlog

The living section. These are **themes**, not a linear plan — pick whatever the current evidence
(prediction log, telemetry, a user report) says matters most. Add, re-prioritize, or strike items
freely; promote anything substantial into an ADR when you act on it. Status is illustrative, not a
commitment.

### Completion quality
- Reduce false suppression and assistant-reply leakage; widen the `predictions.log`-driven test
  corpus as new failure classes appear (see `06-quality-playbook.md`).
- Mid-line / FIM quality on small models (suffix-duplication, capsule legibility) — ADR-048/049.
- ⬜ **Autocorrect / typo mode** as a distinct path from completion — *deferred* (ADR-023); the
  in-beam typo guard (ADR-015) covers the worst case for now.

### Latency & resource use
- Hold the per-keystroke steady-state budget as models/contexts grow; keep profiling in release
  and recording wins (see `07-performance.md`, ADR-012/043–046).
- Memory/battery footprint of the resident model; load/unload policy when idle.

### App & domain coverage
- Grow the `AppCompatibility` matrix as new apps surface broken Tab/insertion/overlay behavior
  (see `08-app-compatibility.md`, ADR-022/027–033).

### Models
- Support additional model families (catalog entries + ACPF generation + family resolution) —
  ADR-034/035; keep arbitrary user-GGUF import working — ADR-036.

### Personalization & settings
- Improve writing-history retrieval/selection and surface acceptance lift; expand telemetry-driven
  threshold tuning while keeping all data local (ADR-023).

### Packaging & distribution
- Code signing, notarization, and a release/update story for shipping builds to users.

