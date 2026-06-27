# KeyType — Prompting & Context Management

How KeyType turns a captured `TextFieldContext` into a single prompt that makes a **base model**  
**continue the user's text** at the cursor.

## Core idea

Build the prompt from **named context sections**, each with a heading, content, priority, and
min/max token budget plus a truncation mode. Allocate the token budget by priority, keeping the
**cursor-local text freshest**, and **end the prompt exactly at the before-cursor text** so the
model predicts the next bytes rather than answering as an assistant.

This is implemented today in `Packages/Prompting/Sources/Prompting/Prompting.swift`
(`PromptBuilder`, `PromptSection`, `PromptTruncationMode`, `PromptTemplateMode`).

## Prompt sections (priority order)


| Section                  | Role                                                                               | Budget guidance     | Truncation                                   |
| ------------------------ | ---------------------------------------------------------------------------------- | ------------------- | -------------------------------------------- |
| `completionInstructions` | Tells the model to continue, not chat. Short, fixed.                               | tiny, high priority | hard                                         |
| `customInstructions`     | Global + per-app/domain style instructions (from `AppCompatibility`).              | small               | hard                                         |
| `generalInfo`            | Date/time, OS locale, username, app name, bundle id, window title, typing context. | small               | hard                                         |
| `textFieldProperties`    | Title, placeholder, help, labels, detected language.                               | small               | hard                                         |
| `previousUserInputs`     | Local writing samples selected by app/domain/context/language/recency.             | medium              | semantic / preserve-end                      |
| `pasteboard`             | Clipboard text when enabled.                                                       | medium, capped      | hard                                         |
| `screen` / OCR           | Nearby visible text when Screen Recording enabled.                                 | medium, capped      | hard                                         |
| `afterCursor`            | Text after the caret — prevents mid-line duplication/collision.                    | medium              | **preserve-start** (keep text nearest caret) |
| `beforeCursor`           | **Dominant signal.** The exact prefix at the insertion point.                      | largest             | **preserve-end** (keep text nearest caret)   |


### Budgeting rules

- Reserve `beforeCursor` and `afterCursor` budget **first**; allocate the rest by priority.
- Truncate **toward the caret**: `beforeCursor` keeps its *tail*, `afterCursor` keeps its *head*.
- Use semantic trimming (whole lines/sentences) for `previousUserInputs`; hard caps for
clipboard/OCR.
- Keep the whole prompt within `maxPromptTokens` (latency budget). The builder counts tokens with
the real **tokenizer-backed** `PromptTokenCounting` from `ModelRuntime` (ADR-008); the approximate
`ceil(chars/4)` counter remains only as a fallback when no tokenizer is wired (e.g. some tests).

## Base vs. chat templates

- `**baseContinuation` (default & preferred):** sections are plain text; the final bytes are
`beforeCursor`; generation begins immediately after. Best for the GGUF base models KeyType
targets.
- `**chatML`:** wraps the same payload in system/user/assistant markers, assistant turn begins at
the cursor. Only use for instruct-tuned models that need it.

**Key design rule:** the prompt must never invite the model to explain, answer, or discuss. The
single most natural continuation of the bytes after the cursor is the goal.

## Caret-boundary sanitization (ADR-017)

The live `beforeCursor` usually ends in the space the user just typed (`"…is "`). A base model
continues a *clean word boundary* (`"…is"` → `" Paris."`) far better than a dangling space
(`"…is "` → it wanders), so:

- **Prompt side:** `PromptBuilder` trims trailing whitespace from the `beforeCursor` section
(`trimmingTrailingWhitespace`). The model now always sees the clean boundary and emits a leading
separator space.
- **Candidate side:** `AutocompleteCore.CaretBoundary.reconcile(_:beforeCursor:)` re-aligns the
generated text against the *original* (untrimmed) prefix before display/insertion: it strips a
leading newline artifact, and — when the real text already ends in whitespace — drops the model's
leading separator space so the field never gets a double space. The controller stores the
*reconciled* candidate, so the overlay and the Tab/Shift+Tab accept paths agree.

## Mid-line: suppressed by default; native fill-in-the-middle is opt-in (ADR-017/082)

When the caret has non-empty `afterCursor`, KeyType uses native FIM by default but keeps the visible
surface deliberately conservative. The model is allowed to infer a short middle; filters then
suppress unsafe, suffix-copying, or low-confidence candidates. This follows the product rule: no
suggestion is better than a wrong one.

Targets can still opt out through `AppCompatibility`. Base continuation tends to duplicate the suffix
(`"The capital of " | "is Paris."` → `" France is Paris."`). For models with trained FIM tokens
(`<|fim_prefix|>` / `<|fim_suffix|>` / `<|fim_middle|>` each a single vocab token), the
`ConstrainedGenerationEngine` instead assembles, from the raw context (not the scaffolded prompt):

```
<|fim_prefix|>{trailing-trimmed prefix}<|fim_suffix|>{suffix}<|fim_middle|>
```

This is gated by `CompletionPolicy.allowsMidLineCompletion`,
`DecodingConfiguration.enableFillInMiddle`, and visual mid-line geometry. It falls back to base
continuation when disabled, when there is no suffix, when the caret is visually at end of line, or
when the markers don't resolve to single tokens on the loaded model. The FIM markers are control
tokens (suppressed by the ACPF profile) so they never leak into output, and
`CaretBoundary.reconcile` strips the leading newline FIM tends to prepend.

Always-on FIM-quality behaviors then refine mid-line output (ADR-057/090): the raw prefix/suffix
are **windowed toward the caret** (`fimMaxPrefixTokens`/`fimMaxSuffixTokens`) so a long body stays
local and within budget; a branch that emits a real middle and then runs into the suffix is
**truncated at the overlap** and salvaged rather than discarded (only a pure copy is dropped); and the
surviving mid-line candidates pass a **visible confidence gate**: the accepted fill must be short and
high-confidence. The older suffix-likelihood rerank remains available through
`suffixRerankTokenCount`, but its default is `0` because the extra join probe dominated mid-line
latency without improving edge-suite precision.

## Environment-context policy (ADR-017)

The bracketed scaffolding *helps* small base models on prose, but the app/window/field **metadata**
(`generalInfo`, `textFieldProperties`) biases them toward code/numbers inside code editors and
terminals. `PromptBuilder.buildPrompt(includeEnvironmentContext:)` omits those two sections when
`CompletionPolicy.includesEnvironmentContext` is false, which `AppCompatibility` sets for targets
with `TargetOverride.environmentContextDisabled` (Xcode, VS Code, iTerm, Terminal).

## Personalization: `previousUserInputs`

Local writing history conditions style without fine-tuning. Selection dimensions (store these in
a local DB; keep it on-device and optional):

- `appBundleIdentifier`, `domain`, `typingContext`, `textLanguage`, `createdAt/updatedAt`,
`hasAcceptedCompletion`.
- Mix **recent + long + same-context** samples, optionally a few cross-app recents, all capped by
a token budget. Tunables to expose: fetch size, minimum characters, longest-count,
most-recent-count, cross-app-recent-count, token budget, same-app-only flag.

Privacy: history and clipboard are local and user-controllable, OCR remains **opt-in**, all three
never leave the device, and all are skipped for password fields and apps flagged sensitive in
`AppCompatibility`.

## Reconstructed prompt skeleton (original wording — tune freely)

```
[Completion instructions]
Continue the text at the cursor. Output only the text to insert. Match the language, tone,
and formatting of the surrounding text. Keep it short. Do not answer or explain. Do not repeat
text that already appears after the cursor.

[Custom writing instructions]
{global custom instructions}
{per-app / per-domain instructions}

[General information]
OS languages/locales: {locales}. Current time: {datetime}. User: {username}.
Application: {appName} ({bundleId}). Window: {windowTitle}. Typing context: {typingContext}.

[Text field properties]
Title: {title}  Placeholder: {placeholder}  Help: {help}  Labels: {labels}  Language: {lang}

[Relevant previous writing]
{budgeted local samples}

[Clipboard context]
{clipboard text if enabled}

[Screen context]
{nearby visible text if enabled}

[Text after cursor]
{afterCursor}

[Text before cursor]
{beforeCursor}      ← generation starts immediately after this, at the caret
```

## Worked example

Context: composing a Gmail reply in Chrome.

```
[Text after cursor]
Let me know if you want me to adjust anything.

[Text before cursor]
Hi Maya,
Thanks for sending this over. I took a look at the proposed timeline, and
```

Plausible continuations: `" it works for me."` or `" I think it works well."` —
short, insertable. Downstream constraints/filters then decide whether to show, truncate, or
suppress.

## What "good" looks like (evaluation signals)

Measure these as the prompt/generation evolve:

- **Acceptance rate** (Tab-accepted / shown).
- **Suppression rate** (suppressed / generated) — high is fine, that's the point.
- **Latency** per completion (target: feels instant per keystroke; lean on KV reuse).
- **Duplicate-after-cursor errors** (completion collides with `afterCursor`).
- **"Assistant-reply" leakage** (completion reads like a chat answer — should be ~0).

## Suggested tests for `Prompting`

- Golden prompts: fixed `TextFieldContext` → exact expected prompt string (snapshot test).
- Budget enforcement: oversized `beforeCursor` is tail-truncated and stays within budget.
- `afterCursor` is head-truncated (keeps text nearest the caret).
- Section ordering is stable and `beforeCursor` is always last in base mode.
- Optional sections (clipboard/OCR/history) omitted cleanly when empty.
