# KeyType — Roadmap & Milestones

Hand the agent **one milestone per session**. Each is an independently testable vertical slice
with explicit acceptance criteria. Keep `swift build`/`swift test` green for every package you
touch, and log decisions in `05-decisions.md`.

Legend: ✅ done · 🟡 partial · ⬜ not started.

---

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

## M2 — Model runtime (llama.cpp)  🟡

Replace the stub with a real local model.

**Tasks**

- Integrate **llama.cpp** (SwiftPM wrapper or prebuilt xcframework; pick one and record why in
`05-decisions.md`). Implement `LocalModelRuntime` + `ModelTokenizing` over it: load GGUF,
tokenize/detokenize, raw token bytes, decode batch, next-token logits, EOS/EOT, vocab size.
- Implement KV-cache sequence ops (`seq_cp/keep/rm`, `clear`) and a `reuseThreshold` for prefix
reuse across keystrokes.
- Keep `StubModelRuntime` working for tests; keep the protocol stable.

**Acceptance**

- Given a prompt string and a small open GGUF, the runtime returns plausible next-token logits and
can decode N tokens. A test asserts tokenizer round-trip (`detokenize(tokenize(x)) == x` for
ASCII) and that KV reuse produces identical logits to a full decode for an unchanged prefix.

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

## M4 — Token profiles: ACPF format + builder  🟡

Give the sampler real vocabulary intelligence.

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

## M6 — Filtering, overlay, insertion → **MVP demo**  🟡

First end-to-end Tab-accept experience.

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

## M8 — Personalization & polish  ⬜

**Tasks**

- Local writing-history store + retrieval feeding `previousUserInputs` (opt-in, on-device).
- Acceptance/suppression/latency telemetry (local only) to tune biases & thresholds.
- Settings UI: model selection, completion length, per-app toggles, privacy switches.
- Autocorrect/typo mode (separate from completion) if desired.

**Acceptance**

- History improves acceptance rate measurably; settings persist; all personal data stays local
and is clearable.

---

## Cross-cutting definition of done (every milestone)

- New logic lives behind the `AutocompleteCore` protocols; packages stay decoupled.
- Tests added/updated; `swift build` + `swift test` green for touched packages.
- A decision-log entry added to `05-decisions.md` for any non-obvious choice.

