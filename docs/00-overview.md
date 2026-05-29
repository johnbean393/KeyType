# KeyType — Project Overview & Agent Handoff

> **Read this first.** This document and its siblings (`01`–`05`) are the authoritative
> brief for any human or AI agent working on KeyType. Treat them as the source of truth.
> When you make a meaningful decision, append it to `05-decisions.md`.

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
├── docs/                         ← THIS handoff packet (00–05)
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

The package graph already mirrors the target architecture and contains **real domain types
and protocols** plus stub/in-memory implementations. Your job is to fill in the real
implementations behind those protocols — **extend this graph, do not rewrite it.**

## Current state (as of handoff)

- ✅ Module graph + `AutocompleteCore` contract types (`TextFieldContext`, `CompletionRequest`,
`CompletionCandidate`, `SuppressionReason`, protocols) — solid.
- ✅ `Prompting` — working sectioned/budgeted builder (approximate token counter).
- ✅ `ConstrainedGeneration` — greedy branch loop against the profile + runtime protocols.
- ✅ `TokenProfiles` — in-memory profile + flags; **ACPF on-disk format not yet built**.
- ✅ `AppCompatibility`, `TextInsertion`, `CompletionUI` — policy/plan/placement types with
stub presenters/inserters.
- 🟡 `ModelRuntime` — **only a `StubModelRuntime` exists. No real llama.cpp yet.**
- ✅ `MacContextCapture` — AX-notification-driven tracker + ported caret-geometry resolver
populate a full `TextFieldContext` (before/after, selection, caret rect, EOL, RTL, app,
window, browser domain, labels, language). See ADR-006.
- 🟡 App target — still the default SwiftData window template; needs to become a background
menu-bar/agent app.
- 🎁 **Proven caret-tracking code exists** in the sibling `Red Dot` project and should be
ported into `MacContextCapture` + `CompletionUI` (see `01-architecture.md`).

## How to work on this project

- **One milestone per session** (see `04-roadmap.md`), each with explicit acceptance criteria.
- Keep `swift build` and `swift test` green for any package you touch.
- Write tests first where practical (especially profiles, prompting, constrained generation).
- Record decisions in `05-decisions.md`.
- Commit per milestone, with clear messages — **but only when the human asks you to commit.**

## Document index


| Doc                    | Contents                                                     |
| ---------------------- | ------------------------------------------------------------ |
| `00-overview.md`       | This file: what/why, clean-room rules, layout, current state |
| `01-architecture.md`   | Module graph, responsibilities, data flow, Red Dot reuse     |
| `02-prompting.md`      | Prompt sections, budgeting, base-vs-chat, example prompt     |
| `03-token-profiles.md` | ACPF binary format, builder, runtime contract, tests         |
| `04-roadmap.md`        | Phased milestones with acceptance criteria                   |
| `05-decisions.md`      | Append-only decision log (ADR-style)                         |


