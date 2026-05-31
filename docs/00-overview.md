# KeyType — Project Overview

> **Read this first.** This document and its siblings (`01`–`08`) are the authoritative
> brief for any human or AI agent working on KeyType. Treat them as the source of truth.
> The app is **built and shipping**; this packet now supports maintenance and iteration
> rather than initial construction. When you make a meaningful decision, append it to
> `05-decisions.md`.

## What KeyType is

KeyType is an **open-source, on-device, system-wide tab-autocomplete utility for macOS**.
It watches the focused text field across any app, predicts a short continuation at the
cursor using a **local LLM**, and offers it as ghost text that the user accepts with **Tab**.

It is an **alternative** to the closed-source app *Cotypist*

### Core product principles (non-negotiable)

These come straight from the reconstruction research and define the product's character:

1. **Narrow the problem.** Predict a *very short* continuation at the cursor in a precise app
  context, then discard anything not immediately insertable. Quality comes from the *system*
   (context capture, prompt budgeting, constrained decoding, filtering, insertion), not from
   picking a bigger model.
2. **Prefer suppression to a wrong suggestion.** Showing nothing is almost always better than
  showing a stale, long, chatty, or visually-wrong completion. Every candidate must be both
   *model-plausible* and *UI-plausible*.
3. **Base-model continuation, not chat.** The prompt ends exactly at the cursor so the model
  continues the user's text rather than answering as an assistant.
4. **On-device & private.** Completion runs locally. Clipboard, screen/OCR, and writing-history
  context are local, optional, and off by default where sensitive.
5. **App-aware insertion.** A good suggestion still fails if paste/styling/cursor/Tab behavior is
  wrong in the target app. Insertion and overlay are per-app concerns.

## Repository layout (after the structure was flattened)

The repo root **is** the git root **is** the Cursor workspace root (previously it was
triple-nested; that has been fixed):

```
KeyType/                          ← git root / workspace root
├── .cursor/rules/keytype.mdc     ← always-on agent guardrails
├── .gitignore
├── docs/                         ← THIS project brief & playbooks (00–08)
├── KeyType.xcworkspace/          ← open this in Xcode
├── KeyType.xcodeproj/
├── KeyType/                      ← app target sources (menu-bar app shell lives here)
│   ├── KeyTypeApp.swift
│   ├── KeyTypeModuleGraph.swift  ← wires the packages together
│   └── ...
├── KeyTypeTests/  KeyTypeUITests/
└── Packages/                     ← local SwiftPM packages (the real logic)
    ├── AutocompleteCore/         ← shared domain types & protocols (the contract)
    ├── MacContextCapture/        ← AX focus + caret + text-field snapshot
    ├── Prompting/                ← sectioned, budgeted prompt builder
    ├── ModelRuntime/             ← llama.cpp wrapper: load/tokenize/decode/logits/KV
    ├── ConstrainedGeneration/    ← logit masking, trie admissibility, branch search
    ├── TokenProfiles/            ← ACPF profile reader + offline builder
    ├── CompletionUI/             ← overlay rendering (inline ghost text, etc.)
    ├── TextInsertion/            ← pasteboard / keystroke insertion strategies
    └── AppCompatibility/         ← per-app / per-domain override policy
```

The package graph mirrors the runtime architecture and contains **real implementations** behind
the `AutocompleteCore` protocols. When you change it, **extend this graph, do not rewrite it.**

## What's shipped (how it works today)

The full end-to-end pipeline is real and runs on device. Capture → policy → prompt → model →
constrained decode → filter → overlay → Tab-insert all work against live models.

- ✅ `AutocompleteCore` — the stable contract: `TextFieldContext`, `CompletionRequest`,
  `CompletionCandidate`, the `SuppressionReason` taxonomy, and the core protocols.
- ✅ `MacContextCapture` — AX-notification-driven tracker + ported caret-geometry resolver
  populate a full `TextFieldContext` (before/after, selection, caret rect, EOL, RTL, app,
  window, browser domain, labels, language). See ADR-006.
- ✅ `Prompting` — sectioned/budgeted builder with a **tokenizer-backed** counter, caret-boundary
  sanitization, native FIM for mid-line, and per-app environment-context gating (ADR-008/017).
- ✅ `ModelRuntime` — `LlamaModelRuntime` over the prebuilt llama.cpp xcframework: GGUF load,
  tokenize/detokenize, batch decode, next-token logits, EOS/EOT, and KV prefix reuse via
  snapshot/restore. `StubModelRuntime` is retained for tests (ADR-007/018).
- ✅ `ConstrainedGeneration` — real multi-branch search (branch width / cutoff / min-prob),
  top-k/top-p/temperature sampling, trie admissibility, required-prefix enforcement, sentence-
  boundary stop, in-beam typo guard, suffix-overlap suppression, and cancellation (ADR-010+).
- ✅ `TokenProfiles` — the on-disk **ACPF** format with a memory-mapped reader and an offline
  builder; profiles are generated in-app per model family (ADR-009/034).
- ✅ `CompletionUI` — inline ghost-text overlay at the caret, plus the mid-line capsule and
  text-mirror fallbacks (ADR-016/048).
- ✅ `TextInsertion` — real ⌘V/match-style/chunk/char insertion with clipboard save/restore and
  per-app workarounds (ADR-016).
- ✅ `AppCompatibility` — context-aware per-app/per-domain overrides (gating, mid-line rules, Tab
  handling, insertion/overlay tuning, secure-field exclusion) (ADR-022+).
- ✅ App target — background menu-bar / agent app with onboarding, in-app model download, Settings,
  encrypted local writing history, and local telemetry (ADR-005/023/034).

For the current set of open improvement themes (vs. the completed build milestones), see
`04-roadmap.md`.

## How to work on this project

- **Make the smallest change behind the existing protocols** that fixes the problem; extend the
  module graph, don't widen public APIs or add packages without a real need.
- **Quality issues:** reproduce, then read the prediction log *before* editing code — see
  `06-quality-playbook.md` (and *Debugging & observability* in `01-architecture.md`).
- **Latency work:** always measure in a **release** build — see `07-performance.md`.
- **App/domain behavior:** add an `AppCompatibility` override — see `08-app-compatibility.md`.
- Keep `swift build` and `swift test` green for any package you touch; add/update tests.
- Record non-obvious decisions as a new ADR in `05-decisions.md`.
- Commit with clear messages — **but only when the human asks you to commit.**

## Document index


| Doc                       | Contents                                                       |
| ------------------------- | -------------------------------------------------------------- |
| `00-overview.md`          | This file: what/why, clean-room rules, layout, what's shipped  |
| `01-architecture.md`      | Module graph, responsibilities, data flow, observability       |
| `02-prompting.md`         | Prompt sections, budgeting, base-vs-chat, FIM, example prompt  |
| `03-token-profiles.md`    | ACPF binary format, builder, runtime contract, tests           |
| `04-roadmap.md`           | Completed-milestone archive + the live improvement backlog     |
| `05-decisions.md`         | Append-only decision log (ADR-style), with an index            |
| `06-quality-playbook.md`  | Triaging bad/missing completions from `predictions.log`        |
| `07-performance.md`       | Latency budget, release-build rule, profiling methodology      |
| `08-app-compatibility.md` | How to add a new per-app / per-domain override                 |


