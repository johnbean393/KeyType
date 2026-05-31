# KeyType

**KeyType** is an open-source, on-device, system-wide **tab-autocomplete utility for macOS**.
It watches the focused text field across any app, predicts a short continuation at the cursor
using a **local LLM**, and offers it as ghost text that you accept with **Tab**.

It is a clean-room, MIT-licensed alternative to the closed-source app *Cotypist*.

> **Status:** built and running. The full pipeline — context capture, local model runtime,
> constrained decoding, overlay, and Tab insertion — is implemented and works on device. Work is
> now maintenance and iteration (see the [improvement backlog](docs/04-roadmap.md#improvement-backlog)).

## Read this first

The authoritative brief lives in [`docs/`](docs/). **Start with
[`docs/00-overview.md`](docs/00-overview.md)** and read across:

| Doc | Contents |
| --- | --- |
| [`docs/00-overview.md`](docs/00-overview.md) | What/why, principles, repo layout, what's shipped |
| [`docs/01-architecture.md`](docs/01-architecture.md) | Module graph, responsibilities, data flow |
| [`docs/02-prompting.md`](docs/02-prompting.md) | Prompt sections, budgeting, base-vs-chat, FIM |
| [`docs/03-token-profiles.md`](docs/03-token-profiles.md) | ACPF binary format, builder, runtime contract |
| [`docs/04-roadmap.md`](docs/04-roadmap.md) | Completed-milestone archive + improvement backlog |
| [`docs/05-decisions.md`](docs/05-decisions.md) | Append-only ADR-style decision log (indexed) |
| [`docs/06-quality-playbook.md`](docs/06-quality-playbook.md) | Triaging bad/missing completions |
| [`docs/07-performance.md`](docs/07-performance.md) | Latency budget + profiling methodology |
| [`docs/08-app-compatibility.md`](docs/08-app-compatibility.md) | Adding a per-app/domain override |

## Repo layout

```
KeyType/
├── KeyType.xcworkspace/      ← open this in Xcode
├── KeyType.xcodeproj/
├── KeyType/                  ← app target (menu-bar shell)
├── KeyTypeTests/  KeyTypeUITests/
├── docs/                     ← the project brief & playbooks (00–08)
└── Packages/                 ← local SwiftPM packages (the real logic)
    ├── AutocompleteCore/         shared domain types & protocols
    ├── MacContextCapture/        AX focus + caret + text-field snapshot
    ├── Prompting/                sectioned, budgeted prompt builder
    ├── ModelRuntime/             llama.cpp wrapper
    ├── ConstrainedGeneration/    logit masking, trie admissibility, search
    ├── TokenProfiles/            ACPF profile reader + offline builder
    ├── CompletionUI/             overlay rendering (inline ghost text)
    ├── TextInsertion/            pasteboard / keystroke insertion strategies
    └── AppCompatibility/         per-app / per-domain override policy
```

`AutocompleteCore` is the dependency-free shared contract; every other package depends on it.
The app target (`KeyType/`) is the only wiring layer.

## Getting started

Requirements: macOS 15+ and a recent Xcode (the project was created with Xcode 26.4).

```sh
git clone <this-repo>
cd KeyType
open KeyType.xcworkspace
```

Build/run the **KeyType** scheme. KeyType is a background **menu-bar / agent app** — it does
not show a dock icon. On first launch the onboarding window walks you through granting
**Accessibility** permission (required so KeyType can read the focused text field) and,
optionally, **Screen Recording** (for richer context capture).

Per-package builds:

```sh
swift build --package-path Packages/AutocompleteCore
swift test  --package-path Packages/Prompting
```

## Contributing

KeyType is a clean-room reconstruction; don't paste code from closed-source predecessors.
- Pick up work from the [improvement backlog](docs/04-roadmap.md#improvement-backlog); make the
  smallest change behind the existing protocols (extend the module graph, don't rewrite it).
- Triage completion quality from the prediction log first ([`docs/06-quality-playbook.md`](docs/06-quality-playbook.md));
  measure latency in a release build ([`docs/07-performance.md`](docs/07-performance.md)).
- Keep `swift build` + `swift test` green for every package you touch.
- Log non-obvious decisions in [`docs/05-decisions.md`](docs/05-decisions.md).
- Commits happen only when the human asks.

## License

MIT — see [`LICENSE`](LICENSE).
