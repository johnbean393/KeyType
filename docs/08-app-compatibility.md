# KeyType — Adding an App / Domain Override

A good completion still fails if Tab, paste, styling, the overlay, or the prompt behaves wrong in a
specific app. Per-app behavior is **data**, not code: add a `TargetOverride` to `AppCompatibility`
rather than special-casing logic elsewhere in the pipeline. This keeps the packages decoupled and
makes behavior auditable in one place.

## Where it lives

- `Packages/AppCompatibility/Sources/AppCompatibility/TargetOverride.swift` — the override struct.
- `…/DefaultOverrides.swift` — the seed table (`AppCompatibilityStore.defaultOverrides`).
- `…/AppCompatibilityStore.swift` — resolves the effective `CompletionPolicy` for an `AppTarget`.
- `…/CompletionPolicy.swift` — the resolved, read-only policy the rest of the pipeline consumes.

A target is matched by **bundle identifier**, **domain** (for browser web fields, suffix-matched and
`www.`-stripped), or both. Settings can also layer **per-app disables** on top of these defaults
(ADR-023), so user choices win over the seed table.

## `TargetOverride` fields

| Field | Effect |
| --- | --- |
| `completionsDisabled` | Suppress all completions here (`SuppressionReason.completionsDisabled`). |
| `midLineCompletionsEnabled` | Explicitly opt this target into after-cursor / FIM completion. |
| `midLineCompletionsDisabled` | Only complete at end-of-line (no FIM mid-line). |
| `tabShortcutsDisabled` | Don't bind Tab/Shift+Tab — leave native Tab behavior intact. |
| `trainingDataCollectionDisabled` | Never record writing history from this target. |
| `requiresPasteAndMatchStyle` | Insert with ⌘⌥⇧V so pasted text adopts the field's style. |
| `requiresNonBreakingSpaceWorkaround` | Use NBSP where a plain space gets eaten. |
| `stringInjectionChunkSize` | Inject in N-char chunks (slow/flaky fields, e.g. WeChat). |
| `requiresBackspaceAfterPaste` | Backspace once after paste (fields that add a stray char). |
| `fontSizeAdjustmentFactor` / `verticalAlignmentOffset` | Nudge overlay size/position to match. |
| `overlayPreference` | `.inline` / `.textMirror` / `.hidden` — pick the overlay that renders right. |
| `completionMode` | Force `.terminal` / `.code` / etc. for this surface. |
| `customInstructions` | Per-app prompt steering ("continue the current message only", …). |
| `environmentContextDisabled` | Drop app/window/field metadata from the prompt (code editors, terminals — ADR-017). |
| `secureFieldExclusion` | Treat as a secure field — never complete (`secureFieldExcluded`). |

## Recipe

1. **Get the identifier.** Bundle id from the running app (e.g. via the unified `context-capture`
   log line, which records the bundle id); domain from the resolved browser web area.
2. **Reproduce and identify the failure class** using `06-quality-playbook.md` (wrong place? broken
   Tab? mangled paste? off-topic prompt?).
3. **Add the smallest override** that fixes it. Examples already in `DefaultOverrides.swift`:
   - *Terminals* (Terminal, iTerm2, Warp, Ghostty, Alacritty, kitty, WezTerm): `.terminal` mode,
     `midLineCompletionsDisabled`, `tabShortcutsDisabled` (don't break shell Tab), `.textMirror`
     overlay, `environmentContextDisabled`.
   - *Password managers* (1Password, Apple Passwords, Bitwarden, …) and their domains:
     `completionsDisabled` + `secureFieldExclusion` + `.hidden`.
   - *Code editors* (Xcode, VS Code, Cursor): `environmentContextDisabled` only — keep cursor-local
     text, drop biasing window-title metadata (ADR-017/030).
   - *Web doc/chat surfaces* (Google Docs, Gmail, Notion, Slack, Discord, iMessage, WeChat):
     `requiresPasteAndMatchStyle`, the right `overlayPreference`, and focused `customInstructions`.
4. **Prefer a domain override** for web apps (works across Chrome/Safari/Arc/etc.); add a
   bundle-id override too when the app ships a native Electron wrapper (e.g. Slack, Discord, Notion
   all have both rows).
5. **Test it.** `AppCompatibilityTests` cover matching/resolution; add a row asserting the new
   target resolves to the intended `CompletionPolicy`.
6. **Log it** if the choice is non-obvious — append an ADR (prior art: ADR-022/027–033).

## Principle

Overrides should be **conservative and legible**: each one fixes an observed, reproducible problem
in a named app. Don't add speculative tuning. When in doubt, disabling completion in a hostile field
(`completionsDisabled`) is consistent with *prefer suppression to a wrong suggestion*.

Mid-line completion is disabled by default (ADR-082). Add `midLineCompletionsEnabled` only after a
target-specific benchmark/log review shows after-cursor suggestions are both useful and low risk.
