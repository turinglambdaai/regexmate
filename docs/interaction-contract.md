# Interaction contract: keyboard result inspection and invalid-pattern recovery

This document is the reviewable interaction contract for the keyboard
result-inspection scenario. Every row was verified against the macOS host
implementation (`macos-host/Sources/RivetHost/`) and against the native-ui
acceptance run (`scripts/e2e/macos-ax.swift`, suite `macos-native-ui` in
`rivet-acceptance.rktd`). It is written from the keyboard-only user's point
of view; the assistive-technology surface (AX identifiers, row labels,
actions) is part of the contract, not an implementation detail.

Cross-platform rule: the **semantics** in the table are the product contract
on all three hosts; the **native presentation** column is the macOS
expression of them. Windows/Linux columns are owned by their platform legs.

## Scenario: keyboard result inspection + invalid-pattern recovery

| Column | Contract (verified) |
|---|---|
| Initial state | App running with the embedded Racket CS backend ready. Default sample text `Order 12345 shipped on 2026-09-28 to zip 10115.` and default pattern `\d+` are loaded and auto-run once when the backend becomes ready (`AppModel.finishStarting` → `refreshNow`), so 5 matches are listed before the user types. Initial keyboard focus is the window itself — no control holds focus until the user Tabs, clicks, or an assistive client sets focus. |
| User action | Typing in the pattern field updates the draft live but does **not** run the engine. The engine runs on: (a) Return in the pattern field (the field's action), (b) ⌘R (toolbar Run button keyboard shortcut), or (c) any edit in the sample text — sample edits auto-run after a 300 ms typing silence (`AppModel.scheduleRefresh`). After results appear, Tab moves keyboard focus through the three first-responder surfaces — the observed walk from the pattern field is pattern field → sample editor → match list, and from the sample editor a single Tab lands on the match list; Shift-Tab walks backwards. Arrow keys walk the rows once the list holds focus. |
| Visible result | The walked/selected row carries the table selection highlight (forced emphasized, so it stays visible even when the table is not the key view). The same span is selected in the sample editor — one selection means "inspect this match"; engine code-point offsets are converted to UTF-16 locations so highlights and selection land on the same characters even around astral-plane text. The status-bar count (`MatchCount`) reads `N match(es)`. |
| Persisted effect | Nothing. The inspection selection is transient: a new/changed result list clears it; an identical result list keeps it. Pattern, sample text and selection live in memory only — the host persists nothing (no defaults/database writes), and a relaunch starts from the same defaults. |
| Failure / recovery | Typing an invalid pattern (e.g. `[a-`) and submitting runs `status`, which returns the engine's single-line error (`missing closing square bracket in pattern`). The error is inline in the status bar, the match count yields to `—`, the result list empties with the placeholder "Fix the pattern to match", lint findings and the diagram clear, and the inspection selection clears. The invalid draft stays in the field for editing. The explanation panel keeps the previous pattern's explanation until the pattern is fixed (same retention as the Windows host). Fixing the pattern and resubmitting over the same path restores the full result set. |
| Keyboard | ⌘R run · Return submits the pattern field · Tab walks focus into the match list · ↑/↓ walk the result rows (the table is a first responder) · ⌘G / ⌘⇧G inspect next/previous match with wrap-around (Match menu, also the assistive path) · ⌘A select-all inside a text field · ⌘⇧U check for updates. No other product-specific shortcuts are defined. |
| Native presentation | SwiftUI toolbar with `PatternField` (a real `NSTextField` bridged via `NSViewRepresentable`, `.accessibilityIdentifier("PatternField")`) + Run/Export toolbar buttons (`RefreshButton`); `MatchTableView` — an `NSTableView` (`AXTable`, identifier `MatchList`), rows `MatchRow-N` with the structured label `Match i of N: 'text', characters start–end[, k capture groups]` and an AXPress inspect action; `SampleTextView` — an `NSTextView` whose layout manager paints match highlights as rounded pills; status-bar count as `MatchCount` static text. |

## State rules the hosts must share

1. **One meaning for selection.** Selecting a row by any means — pointer,
   keyboard, ⌘G/⌘⇧G, or assistive AXPress — inspects that match: the same
   span is selected in the sample editor and the table reflects it.
2. **Selection belongs to one result set.** When the result list changes,
   the selection clears; it never points into a stale list. An identical
   list (same spans) keeps the selection stable.
3. **Typing is not running.** Pattern keystrokes update the draft only.
   Submission is Return, ⌘R, or the assistive `AXConfirm` write. Sample-text
   edits are the only auto-run path (300 ms debounce).
4. **An invalid pattern is an error state, not a zero-match result.** The
   count cell shows `—`, the list shows the fix-placeholder, and the engine
   error text is presented inline. Zero matches on a valid pattern is the
   ordinary "No matches" state instead.
5. **Zero-width matches are first-class rows**, named "zero-width match at
   character N", and inspecting one places the caret at that offset.
6. **Live edits never leave the caret on a removed match** (rule 2 applied
   while the user keeps typing in the sample editor).
7. **Unicode-safe spans.** Engine offsets are code points; native text views
   count UTF-16 units. Hosts convert at the boundary so BMP and astral
   matches inspect the exact characters.

## Accessibility notes for assistive clients

- The match list is an `AXTable` (`MatchList`) whose rows carry the
  structured inspection label and an AXPress action; the pattern field is an
  `AXTextField` (`PatternField`) that also exposes `AXConfirm` as the
  assistive submit, and the sample editor is the window's only `AXTextArea`.
- Assistive clients should re-resolve the match list after a result refresh:
  the host rebuilds the table's NSView when the result list appears,
  disappears or changes, so a captured element reference can go stale while
  the visible list stays live.
- Synthetic keyboard input (CGEvent) lands only when the application holds
  the key window, and an active third-party input method consumes
  unicode-string key events before they reach the app; acceptance drivers
  must switch to an ASCII keyboard layout for typed-key assertions and
  restore the original input source afterwards.

## Evidence

The `macos-native-ui` acceptance suite drives this whole scenario on the
packaged app: AX snapshots before / during row inspection / error state /
final (`accessibility-*.json`), per-window screenshots
(`screen-*.png`), and the bounded interaction trace
(`interaction-trace.json`) with every action, assertion and observation.
The real-keyboard path uses CGEvent typing, Return, Tab, arrows and ⌘R —
never an AX value write — so the asserted path is the one a keyboard-only
user exercises. Suite declaration: `rivet-acceptance.rktd`; driver:
`scripts/e2e/macos-ax.swift`; launch orchestration: `scripts/e2e/e2e-macos.sh`.
