# KeyType — Decision Log

Append-only record of meaningful decisions (lightweight ADR style). Newest at the bottom.
Add an entry whenever you make a non-obvious architectural, dependency, or product choice so the
next session (human or agent) has the context. **Do not rewrite history; only append.**

Template:

```
## ADR-NNN — <short title>
- Date: YYYY-MM-DD
- Status: proposed | accepted | superseded by ADR-XXX
- Context: what problem / constraint prompted this.
- Decision: what we chose.
- Consequences: trade-offs, follow-ups, what this rules out.
```

---

## ADR-001 — Reconstruction, MIT license

- Date: 2026-05-29
- Status: accepted
- Context: KeyType is an open-source alternative to the closed-source Cotypist.
- Decision: Build from behavior-level research (`docs/01–03`). Use our own `ACPF` profile  
format (not Cotypist's `FEBI`).  
License under MIT.

## ADR-002 — Modular SwiftPM package architecture

- Date: 2026-05-29
- Status: accepted
- Context: A system-wide autocomplete spans AX capture, model runtime, prompting, decoding, UI,
and insertion. These need independent testing and clear boundaries.
- Decision: Keep the existing 9-package graph under `Packages/`, with `AutocompleteCore` as the
dependency-free shared contract. The app target is the only wiring layer.
- Consequences: Cross-module types go in `AutocompleteCore`. Packages stay decoupled and unit-
testable; the app composes concrete implementations in `KeyTypeModuleGraph.swift`.

## ADR-003 — Flatten the nested repository structure

- Date: 2026-05-29
- Status: accepted
- Context: The project was triple-nested: the Cursor workspace root (with `.cursor/` and the
`.xcworkspace`) sat one level *above* the git root + Xcode project, so rules/workspace files
were outside version control and an agent's commits wouldn't capture them.
- Decision: Move the `.git` directory and all project folders up so the workspace root == git root
== Xcode project root. Update the `.xcworkspace` reference from `group:KeyType/KeyType.xcodeproj`
to `group:KeyType.xcodeproj`. Local SwiftPM package references were unaffected (relative paths
preserved). Working tree verified clean afterward.
- Consequences: `.cursor/rules`, `docs/`, and the workspace file are now versioned. App-target
sources remain at `KeyType/KeyType/` (standard Xcode layout). The `.xcworkspace` and
`.gitignore` should be committed (the user controls when commits happen).

## ADR-004 — Reuse Red Dot caret-tracking code

- Date: 2026-05-29
- Status: accepted
- Context: Robust on-screen caret location across native/Chromium/web fields is the hardest part
of context capture and is already solved in the sibling `Red Dot` project.
- Decision: Port `AXCaretGeometryResolver`, the caret tracker, and the overlay panel from Red Dot
into `MacContextCapture` / `CompletionUI` rather than rewriting. Convert 30 fps polling to
AX-notification-driven refresh with a poll fallback.
- Consequences: Preserves the proven exact/derived/estimated quality ranking and multi-display
coordinate conversion. Keeps placement feeling native; reduces risk in M1.

## ADR-005 — Background menu-bar app shell; App Sandbox disabled

- Date: 2026-05-29
- Status: accepted
- Context: The Xcode template shipped a windowed SwiftData app with `ENABLE_APP_SANDBOX = YES`.
KeyType is a system-wide utility: it must read the focused text field across any app (AX) and
later synthesize keystrokes (`CGEvent`). Both are blocked by App Sandbox, and the product needs
no dock window — only a menu-bar presence plus an onboarding window.
- Decision:
  - App shell uses SwiftUI `MenuBarExtra` for the status item plus a single named `Window`
  scene (`id: "onboarding"`) for first-run / settings UI. `NSApplicationDelegateAdaptor`
  sets `NSApp.setActivationPolicy(.accessory)` and posts a notification observed by the
  `MenuBarExtra` content to open the onboarding window with `@Environment(\.openWindow)`.
  - `INFOPLIST_KEY_LSUIElement = YES` suppresses the dock icon.
  - `ENABLE_APP_SANDBOX = NO`; `ENABLE_HARDENED_RUNTIME = YES` stays on. KeyType is distributed
  outside the Mac App Store (Developer ID), so this trade-off is acceptable.
  - First-run onboarding (`OnboardingView`) explains why each permission is needed, shows live
  granted / not-granted status from `PermissionsManager`, calls
  `AXIsProcessTrustedWithOptions([prompt: true])` / `CGRequestScreenCaptureAccess()` to
  trigger the system prompt, and deep-links to the right Privacy & Security pane via
  `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` /
  `Privacy_ScreenCapture`. Accessibility is required; Screen Recording is optional.
  - The SwiftData template files (`Item.swift`, `ContentView.swift`, `ModelContainer`) were
  removed.
- Consequences:
  - Cannot ship via the Mac App Store; must notarize via Developer ID — fine for the product.
  - Need to keep an eye on hardened-runtime entitlements as we add capabilities
  (e.g. `com.apple.security.cs.disable-library-validation` if we ever load third-party
  dylibs for llama.cpp; revisit when M2 lands).
  - The activation policy is `.accessory`, so `NSApp.activate(...)` is needed before showing
  the onboarding window to bring focus to KeyType.

## ADR-006 — Notification-driven context capture (replaces Red Dot's 30 fps poll)

- Date: 2026-05-29
- Status: accepted
- Context: Red Dot's `AccessibilityCaretTracker` ran a 30 fps `Timer` that always re-resolved the
focused element + caret, regardless of user activity. KeyType is keystroke-driven, must feel
instant, and must not burn battery while no one is typing.
- Decision:
  - Port `AXCaretGeometryResolver`, `AXCaretHelper`, and the multi-display
    `DisplayGeometry` / `DisplayCoordinateConverter` into `MacContextCapture` verbatim in
    behavior, preserving the exact -> derived -> estimated quality ranking.
  - Replace the 30 fps poll with `AccessibilityContextTracker`: an `AXObserver` registered on
    the frontmost app's pid for
    `kAXFocusedUIElementChanged`, `kAXFocusedWindowChanged`,
    `kAXSelectedTextChanged`, `kAXValueChanged`, `kAXUIElementDestroyed`,
    and `kAXWindowMiniaturized`, plus an `NSWorkspace.didActivateApplicationNotification`
    listener to re-target the observer on app switches. Refreshes are debounced (~20 ms) so
    bursts of `AXValueChanged` / `AXSelectedTextChanged` coalesce, and a low-frequency
    (2 Hz) safety poll catches apps that under-report notifications. All AX reads happen on
    the main actor, bounded by the resolver's existing depth/node caps.
  - Field reading is centralized in a pure `FocusedFieldReader` plus small helpers
    (`TextCursorSplitter`, `WritingDirection`, `LanguageDetector`) so they can be unit-tested
    without a live AX tree. `MacContextCaptureService` (the pull-style `ContextProviding`
    entry) shares the same reader, so both push and pull paths emit identical
    `TextFieldContext` values.
  - Port `RedDotOverlayWindow` into `CompletionUI` as `CaretDebugOverlayWindow` — same
    borderless, non-activating, all-spaces, click-through `NSPanel` recipe, but with a thin
    caret-aligned marker. M1 ships this as a **debug overlay only**; M6 swaps the marker for
    real ghost-text.
  - Wiring lives in the app target (`KeyType/ContextCaptureController.swift`): it owns the
    tracker + overlay, logs each emitted context via `os.Logger`, and is gated on the
    Accessibility permission. This keeps `MacContextCapture` (no AppCompatibility / overlay
    dependency) and `CompletionUI` decoupled.
- Consequences:
  - CPU/energy near zero when the user is idle; latency to first context is bounded by
    `debounceInterval` (~20 ms) rather than the 33 ms polling tick.
  - The `safetyPollInterval` (0.5 s) is the worst-case staleness on apps that swallow AX
    notifications; tunable per-app via `AppCompatibility` in a later milestone.
  - Browser domain extraction is best-effort (`AXWebArea` -> `AXURL`, fallback to the trailing
    token of the window title). Sites that don't surface `AXURL` will report a nil domain;
    M7 (per-app overrides) is the place to add web-specific fallbacks if needed.
  - Initializers across the new types are `nonisolated` so they can be referenced from default
    parameter values in either Swift 5 (SPM packages) or the Xcode app's Swift 6-mode strict
    isolation defaults; their methods stay `@MainActor`.

## ADR-007 — llama.cpp integration via prebuilt xcframework `binaryTarget`

- Date: 2026-05-29
- Status: accepted (amended 2026-05-29 to use a local-path binding)
- Context: M2 needs a real `LocalModelRuntime` backed by llama.cpp. Three integration paths were
  considered: (A) a third-party SwiftPM wrapper (`mattt/llama.swift`, `StanfordBDHG/llama.cpp`)
  that re-exports the full C++ API and forces `.interoperabilityMode(.Cxx)` to propagate through
  every consumer of `ModelRuntime`; (B) the official llama.cpp prebuilt **xcframework** consumed
  directly as a SwiftPM `binaryTarget`, using only the C API; (C) building llama.cpp from source
  inside this repo (vendors a large ggml/Metal tree, slow + fragile, high maintenance).
- Decision: Take option **B**. Use the official llama.cpp xcframework (current target build
  `b9402`, produced by `build-xcframework.sh`) and wrap only the C surface (`llama.h`) in a new
  isolated target `LlamaModelRuntime` inside the `ModelRuntime` package. The pre-existing
  `ModelRuntime` library target (with the `LocalModelRuntime` / `ModelTokenizing` protocols,
  `StubModelRuntime`, `UTF8FallbackTokenizer`) stays dependency-free and untouched so
  `ConstrainedGeneration`, `Prompting`, and existing tests keep compiling and running with the
  stub. The Xcode app and other packages depend on the protocol target; only the eventual
  concrete wiring point links the llama target.
- Binding form (amended): the binary is consumed as `binaryTarget(path:)` pointing at a vendored
  copy under `Packages/ModelRuntime/Vendor/llama.xcframework`. The Vendor directory is
  gitignored, so the binary is never committed. The original plan was `binaryTarget(url:checksum:)`
  against `https://github.com/ggml-org/llama.cpp/releases/download/b9402/llama-b9402-xcframework.zip`,
  but the GitHub release CDN was practically unusable for our network during M2 implementation;
  we switched to a locally-supplied build of the same `b9402` tag. The url+checksum form remains
  the preferred shape once we have a reliable mirror — only the `Package.swift` line changes;
  the wrapping target stays identical. The vendored framework's macOS slice is
  `macos-arm64_x86_64/llama.framework` (~9.6 MB binary, universal arm64+x86_64) with Metal
  acceleration on Apple Silicon and a module map that exposes `import llama` directly.
- Consequences:
  - The binary is never committed (gitignored under `Packages/ModelRuntime/Vendor/`). A
    fresh clone must drop a matching `llama.xcframework` into that directory before
    `swift build` for the `LlamaModelRuntime` target will succeed — `ModelRuntime` (protocols
    + stub) and every other package keep building without the framework present.
  - The `LocalModelRuntime` protocol surface is unchanged — KV prefix reuse is an internal detail
    of `LlamaModelRuntime.prepare(promptTokens:)`. No consumer changes.
  - Because the framework is dynamic, when the **app target** eventually links it (out of scope
    for M2, which is package-test acceptance only), the hardened runtime will need
    `com.apple.security.cs.disable-library-validation`. ADR-005 already flagged this as a
    follow-up; document it here as the trigger.
  - Pin updates are explicit: bumping the build tag means replacing the vendored framework
    (or, once we move to url+checksum, recomputing the checksum) — reproducible and auditable.
  - If a future upstream change forces C++ interop at the Swift import boundary, the wrap is
    already isolated to one target — we can interpose a thin C-only shim target without touching
    `AutocompleteCore` / `ConstrainedGeneration`.

