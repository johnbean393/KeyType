# KeyType — Always-On Rules

KeyType is an open-source, on-device, system-wide macOS tab-autocomplete utility — a clean-room
alternative to the closed-source app *Cotypist*. The app is **built and shipping**; work is now
maintenance and iteration (quality, latency, app coverage), not initial construction.

**Read `docs/00-overview.md` first** for how the shipped system actually works; `docs/01`–`03`
describe the architecture, prompting, and token-profile format; `docs/04-roadmap.md` is the
completed-milestone archive plus the live improvement backlog; `docs/06`–`08` are the
maintenance playbooks (quality, performance, app compatibility). Log non-obvious decisions in
`docs/05-decisions.md`.

## Product principles (non-negotiable)
- Narrow the problem: predict a *short* continuation at the cursor, then discard anything not
  immediately insertable.
- **Prefer suppression to a wrong suggestion** — showing nothing beats a bad completion.
- Base-model continuation: the prompt ends exactly at the cursor (not chat/instruct).
- On-device & private: clipboard, screen/OCR, and writing history are local and opt-in.

## Architecture
- Target: macOS 14+, Swift. Logic lives in local SwiftPM packages under `Packages/`.
  **Extend the existing module graph; do not rewrite it.** Cross-module types go in
  `AutocompleteCore` (keep it free of AppKit/llama deps).
- Keep concrete wiring in the app target (`KeyTypeModuleGraph.swift`); keep packages decoupled.
- Generation must be cancellable (a newer keystroke cancels in-flight work); keep model decode off
  the main actor; AX + overlay code is `@MainActor`.

## Iteration workflow
- Make the **smallest change behind the existing protocols** that fixes the problem; don't widen
  public APIs or add packages unless a change genuinely doesn't fit the current graph.
- **Quality issues:** reproduce first, then read `~/Library/Application Support/KeyType/Logs/predictions.log`
  (truncated each launch) to see what the model predicted and why it was shown/suppressed before
  changing code. See `docs/06-quality-playbook.md`.
- **Latency work:** measure in a **release** build — debug inflates per-token Swift work by 1–2
  orders of magnitude. See `docs/07-performance.md`.
- **App/domain behavior:** add an entry to `AppCompatibility` rather than special-casing elsewhere.
  See `docs/08-app-compatibility.md`.
- For every package you touch: add/update tests and keep `swift build` + `swift test` green.
- Record any non-obvious architectural, dependency, or product choice as a new ADR in
  `docs/05-decisions.md` (append-only, next sequential number, newest at the bottom).
- **Only create git commits when the human explicitly asks.**
