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
- Keep the whole prompt within `maxPromptTokens` (latency budget). The current builder uses an
**approximate** counter (`ceil(chars/4)`); replace with the real tokenizer counter from
`ModelRuntime` once available.

## Base vs. chat templates

- `**baseContinuation` (default & preferred):** sections are plain text; the final bytes are
`beforeCursor`; generation begins immediately after. Best for the GGUF base models KeyType
targets.
- `**chatML`:** wraps the same payload in system/user/assistant markers, assistant turn begins at
the cursor. Only use for instruct-tuned models that need it.

**Key design rule:** the prompt must never invite the model to explain, answer, or discuss. The
single most natural continuation of the bytes after the cursor is the goal.

## Personalization: `previousUserInputs`

Local writing history conditions style without fine-tuning. Selection dimensions (store these in
a local DB; keep it on-device and optional):

- `appBundleIdentifier`, `domain`, `typingContext`, `textLanguage`, `createdAt/updatedAt`,
`hasAcceptedCompletion`.
- Mix **recent + long + same-context** samples, optionally a few cross-app recents, all capped by
a token budget. Tunables to expose: fetch size, minimum characters, longest-count,
most-recent-count, cross-app-recent-count, token budget, same-app-only flag.

Privacy: history, clipboard, and OCR are **opt-in**, never leave the device, and are skipped for
password fields and apps flagged sensitive in `AppCompatibility`.

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

