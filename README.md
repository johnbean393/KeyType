<p align="center" width="100%">
<img width="120" alt="KeyType app icon" src="https://raw.githubusercontent.com/johnbean393/KeyType/main/.github/images/app-icon.png">
</p>

<h1 align="center">KeyType</h1>

<p align="center">
An open-source, on-device, system-wide tab-autocomplete utility for macOS.
</p>

<p align="center">
  <a href="https://github.com/johnbean393/KeyType/releases/latest">
    <img src="https://img.shields.io/badge/Download_DMG-Latest_Release-blue?style=for-the-badge&logo=apple&logoColor=white" alt="Download DMG">
  </a>
</p>

**KeyType** is an open-source, on-device, system-wide **tab-autocomplete utility for macOS**.

It watches the focused text field across any app, predicts a short continuation at the cursor
using a **local LLM**, and offers it as ghost text that you accept with **Tab**.

It is a MIT-licensed alternative to the closed-source app *Cotypist*.

## Getting started

### Installation

1. Download the latest release from the [releases](https://github.com/johnbean393/KeyType/releases) page
2. Double-click the downloaded `KeyType.dmg` file
3. Drag the `KeyType` app into `Applications`
4. Open `KeyType` and complete the onboarding

### Development

Requirements: macOS 14+ and a recent version of Xcode.

```sh
git clone https://github.com/johnbean393/KeyType.git
cd KeyType
open KeyType.xcworkspace
```

Build/run the **KeyType** scheme.

Per-package builds:

```sh
swift build --package-path Packages/AutocompleteCore
swift test  --package-path Packages/Prompting
```

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

## License

MIT — see `[LICENSE](LICENSE)`.