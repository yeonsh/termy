# Changelog

All notable changes to termy. Each section heading's version must match the
`CFBundleShortVersionString` at release time — `scripts/render-release-notes.py`
extracts the matching section into the Sparkle appcast `<description>`.

## Unreleased

- Codex: replace 8s fake-WAIT heuristic with two-stage POSSIBLY_WAITING → WAITING(.promotedFromPossible). Reasoning-model silence (GPT-5/o-series) no longer triggers spurious WAIT chips or sounds; PTY byte arrival reverts the silent interim state. Total silence-to-sound is now ~20s.

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
