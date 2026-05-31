# KeyType — Completion Quality Playbook

How to triage a **bad or missing completion**. This is the most common maintenance task. The
golden rule from the product principles still holds: **prefer suppression to a wrong suggestion** —
so "it showed nothing" is often correct, not a bug. Confirm the *intended* behavior before changing
code.

## 1. Reproduce, then read the prediction log first

The running app writes every generation result and its acceptance status to:

```
~/Library/Application Support/KeyType/Logs/predictions.log
```

It is **truncated on each launch** (fresh ISO-timestamped header) and appended during the session,
written off-main by `PredictionLog` (`KeyType/…/PredictionLog.swift`), owned by
`CompletionController`. Lines are timestamped `HH:mm:ss.SSS`:

- `PREDICT ctx="…tail" ["a" | "b" | …] → SHOWN "a"` — best candidate shown as ghost text.
- `PREDICT ctx="…" [...] → SUPPRESS(<reason>)` — the `SuppressionReason` the filter returned.
- `PREDICT ctx="…" → SUPPRESS(noCandidate)` — generation returned nothing.
- `ACCEPT(word) "<head>" of "<full>"` (Tab) / `ACCEPT(full) "<text>"` (Shift+Tab).

Reproduce the case on device, then read the log to see **what the model actually predicted** and
**why** it was shown or suppressed. This almost always localizes the problem to one stage of the
pipeline before you touch any code. Context capture is also summarized to the unified log under
category `context-capture`.

## 2. Classify the failure

| Symptom in the log | Likely stage | Where to look |
| --- | --- | --- |
| `SUPPRESS(noCandidate)` — model produced nothing usable | generation / prompt | `Prompting` budget, required-prefix decode (ADR-025), FIM resolution (ADR-017) |
| Good candidates but `SUPPRESS(<reason>)` you disagree with | filtering | `DefaultCandidateFilter` + the `SuppressionReason` mapping below |
| `SHOWN` but the text is wrong/duplicative/chatty | generation quality | beam config, FIM/suffix-overlap (ADR-049), sentence stop (ADR-013) |
| `SHOWN` but it renders in the wrong place / unreadable | overlay | `CompletionUI` placement, capsule vs inline (ADR-048) |
| Accepts but the inserted text is wrong (style/spacing/dupe) | insertion / boundary | `TextInsertion`, `CaretBoundary.reconcile` (ADR-017), Tab units (ADR-038/050) |
| `ctx="…"` itself looks wrong (bad before/after split) | context capture | `MacContextCapture`, browser focus (ADR-027/033), OCR (ADR-040/049) |

## 3. The `SuppressionReason` taxonomy

`SuppressionReason` (`AutocompleteCore`) is the vocabulary for "why nothing showed". When a log line
reads `SUPPRESS(x)`, find `x` here and check whether the gate is firing correctly:

| Reason | Meaning / where set |
| --- | --- |
| `secureFieldExcluded` | Password/secure field — never complete. `AppCompatibility` `secureFieldExclusion`. |
| `completionsDisabled` | App/domain disabled via `TargetOverride.completionsDisabled`. |
| `midLineCompletionDisabled` | Mid-line gated off for this target (`midLineCompletionsDisabled`). |
| `tabShortcutsDisabled` | Tab acceptance disabled for this target. |
| `invalidUTF8` | Candidate bytes don't decode — dropped in the engine / filter. |
| `requiredPrefixNotSatisfied` | Doesn't extend the current word's required prefix (ADR-025). |
| `displayWidthExceeded` | Wider than `maxDisplayWidth`. |
| `maxCompletionLengthExceeded` | Longer than `maxCompletionTokens` allows. |
| `insertionUnsafe` | Insertion strategy can't safely apply here. |
| `currentWordLooksLikeTypo` | In-beam typo guard closed the word into a misspelling (ADR-015/026). |
| `duplicatesAfterCursor` | Reproduces text already after the caret — `SuffixOverlapGuard` (ADR-049). |
| `noCandidate` | Generation returned nothing admissible. |

If a gate is firing when it shouldn't, fix the **policy or guard that set it**, not the call site —
the filter is deliberately the last, documented line of defense.

## 4. Make the smallest correct change

- Change behavior **behind the existing protocols** (`CompletionGenerating`, `CandidateFiltering`,
  `AppCompatibility` overrides). Don't widen public APIs to patch one app — add a `TargetOverride`
  (`08-app-compatibility.md`).
- Stay conservative: a new guard must not introduce false positives on ordinary continuations.
  Every quality guard shipped so far (typo, suffix-overlap, sentence-boundary) is tuned to fire
  rarely — match that bar.
- **Capture the case as a test.** The quality guards each have deterministic tests
  (`ConstrainedGenerationTests`, `AutocompleteCore` filter tests, `MacContextCaptureTests`). Add the
  reproducing context/candidate so the regression can't return.

## 5. Evaluation signals (don't regress these)

From `02-prompting.md`: acceptance rate (accepted/shown), suppression rate (high is fine, that's the
point), per-completion latency (`07-performance.md`), duplicate-after-cursor errors (~0), and
assistant-reply leakage (~0). The Settings stats panel surfaces live acceptance/latency from the
local `CompletionTelemetryStore` (ADR-023).

## 6. Log it

Any non-obvious quality fix gets a new ADR in `05-decisions.md` (next sequential number, add an
index row). The quality ADRs to read for prior art: ADR-013/015/017/019/024/025/026/048/049.
