# Changelog

All notable changes to termy. Each section heading's version must match the
`CFBundleShortVersionString` at release time — `scripts/render-release-notes.py`
extracts the matching section into the Sparkle appcast `<description>`.

## Unreleased

## 0.2.1 — 2026-08-22

- New app icon. The mark moves from a near-black tile to a light one — white/off-white gradient, deep-green glyph, and the three brand pills (teal, amber, pink) re-mixed at full opacity so they stay saturated against paper instead of washing out. The dark tile disappeared into the Dock on dark wallpapers and read as a featureless square at 16pt; the light version keeps its silhouette at every size.

## 0.2.0 — 2026-05-18

- Multi-window support. ⌘N opens an independent new window — its own pane grid, project filter, and split behaviour — cascaded off the front window so it doesn't land exactly on top. ⌘T now adds a pane to the current window (⌘N did this previously; the ⌘/ shortcut overlay and the dashboard's empty-state hint legend reflect the new mapping). The use case is spreading agent work across multiple monitors.
- The mission-control dashboard aggregates every window. Each window's bottom bar shows the pane chips for all open windows, not just its own. Clicking a chip — or tapping a WAITING notification banner — brings the owning window forward and focuses the right pane, wherever it lives.
- Full session restore. Quit with several windows open at different sizes and positions, relaunch, and they all come back: window frames, pane layouts, and project filters. A frame that would land off-screen (a monitor was unplugged) is clamped back onto a visible display. The session file is schema-versioned and written atomically, with the same quarantine-on-corruption handling as the per-project workspace store.

## 0.1.8 — 2026-05-04

- Pane caret unifies to a single mono color (white in dark mode, black in light mode) instead of taking the per-project accent. Multi-pane windows feel calmer and the caret stays legible regardless of the focus-border color.
- Refreshed per-project accent palette to a jewel-tone set with broader hue spread. The prior pastel/Tailwind-300 family read as washed out once the alpha-blended header tint and pill fills muted them further; consecutive panes now contrast strongly. Dark `headerTintAlpha` drops 0.65 → 0.5 so the more saturated colors don't crush the pane behind them.
- Mission-control dashboard skips re-renders when only timestamps changed. Hook events that just stamped `updatedAt` / `lastPtyActivityAt` were forcing a full SwiftUI re-measure of the chip strip on every PTY chunk, pegging the main thread on 9-pane windows; the dashboard diff now ignores fields the chips don't render. Mission-control bar height changes are also de-bounced against equal values to break a measurement-probe feedback loop.
- CMD+click on a path no longer pops a "해당 프로그램을 실행할 수 없습니다" alert. SwiftTerm's link detector matches paths like `./src/main.swift`, but `NSWorkspace.shared.open` on a scheme-less URL fails loudly — common reproducer was an incidental trackpad tap landing while CMD was held for ⌘+TAB. The opener now no-ops on path matches and only routes URLs whose scheme NSWorkspace can actually handle.
- Closing the last pane no longer stalls visibly. The shutdown autosave that ran inside `applicationWillTerminate` blocked the main thread for up to 2s; the flush now starts the moment the workspace empties, so by the time the app terminates the disk write is in flight (often complete) and the WillTerminate budget shrinks to 0.5s.

## 0.1.7 — 2026-04-28

- Drag-and-drop file paths into the terminal. Drop one or more files from Finder onto a pane and termy injects the absolute paths as typed text — backslash-escaped so unquoted shell context (zsh prompt) parses each as a single argument. TUI clients (Claude Code, Codex) receive the same text into their input fields, mirroring the drag-from-Finder UX iTerm2 / Terminal.app provide. Multiple files are space-separated.
- Shift+Enter now inserts a newline inside Claude Code (and other CLIs that don't push the kitty keyboard `disambiguate` flag). Termy intercepts Shift+Return when the kitty flag is off and sends `ESC + CR` — the same byte sequence as macOS Option+Enter, which Claude Code already documents as its multiline shortcut. Codex CLI's existing kitty path (`CSI 13;2u`) is unchanged.

## 0.1.6 — 2026-04-28

- Codex: replace 8s fake-WAIT heuristic with two-stage POSSIBLY_WAITING → WAITING(.promotedFromPossible). Reasoning-model silence (GPT-5/o-series) no longer triggers spurious WAIT chips or sounds; PTY byte arrival reverts the silent interim state. Total silence-to-sound is now ~20s.
- ⌘⌥G now jumps to the next dashboard chip — single-handed alternative to ⌘⌥], pairing with ⌘G (next WAITING) under different modifiers. Listed in the ⌘/ shortcuts overlay.

## 0.1.5 — 2026-04-26

- Codex CLI support: termy now reads Codex's hook events alongside Claude
  Code's, so panes running `codex` get the same live IDLE / THINK / WAIT
  chips and macOS notifications. `PermissionRequest` is the THINK→WAIT
  trigger (Codex's equivalent of CC's permission notification).
- Codex install path: <kbd>termy</kbd> menu → *Codex Hooks…* writes to
  `~/.codex/config.toml` with the same non-destructive merge contract as
  the Claude Code installer (marker-tagged blocks, backup before write,
  user blocks preserved).
- Foreground-process detection: 1 Hz watcher synthesizes
  `SessionStart` / `SessionEnd` when `claude` or `codex` enters or leaves
  the foreground PG of a pane's shell. Closes Codex's missing
  `SessionEnd` event and resets the chip when the user types `/exit`.
- Active pane now wears the project accent border; inactive panes dim,
  making focus state legible at a glance across a packed dashboard.
- Project filter respects the last active pane: changing the filter
  returns focus to the previously focused pane in that scope rather than
  the topmost.
- Dashboard chip's state pill no longer compresses its label when the
  chip is narrow.

## 0.1.4 — 2026-04-25

- App icon: drop the small blue pill that sat below the underscore in
  the `>_<` face. Eyebrows + face only — cleaner read at small sizes.

## 0.1.3 — 2026-04-25

- Dashboard chip redesign: per-pane state now reads as a right-side
  capsule with a blinking dot for THINK/WAIT, the chip body becomes a
  neutral surface that holds up in light and dark modes, and a left
  accent bar carries the project hue so chips for the same project
  group visually.
- Caret no longer bleeds through SwiftTerm's marked-text overlay as
  a faint gray box during Korean / CJK IME composition.
- Focused pane gets a blinking bar caret; previously the focus state
  was ambiguous when the pane held a TUI that hadn't issued DECSCUSR.
- Forcing a full SwiftTerm redraw after a pane is unparked fixes the
  blank-frame flicker that showed up on the first redraw.
- IDLE dashboard chip stays gray even when `needsAttention` is set
  (e.g. an `auth_success` notification), instead of flashing accent
  blue and reading like a blocking THINK/WAIT chip.

## 0.1.2 — 2026-04-25

- ALL view now packs projects into a balanced grid (e.g. 2×2 for four
  projects) instead of stacking them as thin vertical columns. Each
  project's internal row/column layout is preserved inside its grid cell.

## 0.1.1 — 2026-04-25

- Project filter chips now sit in the titlebar zone, reclaiming ~28pt of
  vertical space for the workspace. Empty regions of the bar still drag the
  window.

## 0.1.0 — 2026-04-22

Initial release.
