# termy TODOs

Open follow-ups after 0.2.22. Shipped work is recorded in
[`CHANGELOG.md`](./CHANGELOG.md) and removed from this list; keep only items
that are still actionable, with enough context to pick them up later.

Last reviewed: 2026-11-01.

## Agent coverage

### Codex follow-ups

- **ERR inference.** Derive ERRORED from `Stop.stopReason` and
  `PostToolUse.tool_response` so failed runs surface without a manual reset.
  Today only `StopFailure` and a non-zero `PtyExit` drive ERR.
- **0.124.0 hook regression (issue #19199).** Warn during
  `CodexHookInstaller` install when the local Codex CLI is on the known-broken
  release.
- **THINK timeout guard.** Drift-correct panes stuck in THINK past a threshold
  when the foreground process is gone but no `SessionEnd` / `Stop` arrives.
- **Live integration smoke test.** Run the real `codex` CLI in CI through the
  hook → daemon → `PaneState` path; current tests are unit-level only.
- **Hook-less agents.** The foreground watcher covers start/end, but
  THINK/WAIT/IDLE for agents without hooks still needs heuristics (output
  cadence, prompt regex, or a screen-scraping fallback).

### OpenCode follow-ups

- **Resume after update.** OpenCode sessions are not included in
  `AgentResume`; restoring the same conversation after a Sparkle relaunch
  would need to capture an `opencode --session` record.
- **Background sessions.** The plugin tracks only the routed root session, so
  prompts in background tabs are invisible to the dashboard. Revisit when
  users report missed prompts.

## Terminal engine

### Migrate to SwiftTerm 2.0

- **What:** Move from the 1.20.0-based fork (`yeonsh/SwiftTerm`, branch
  `termy/1.20`) to SwiftTerm 2.0 once it is tagged. Upstream `main`
  (`15fed4f`, 2026-10-05) is already 2.0 but untagged; 2026-10-07 bumped
  f37922e → 1.20.0 instead.
- **Why:** 2.0 is where upstream development continues (strict concurrency,
  parse thread, renderer work). Staying on 1.x means no new fixes.
- **Cons:** 2.0 parses PTY output on the IO thread and never calls
  `LocalProcessTerminalView.dataReceived`. termy overrides it for the Codex
  PTY-activity ping (POSSIBLY_WAITING → THINKING) and the IME overlay
  re-anchor; both would go silent with no compile error. Move them to
  `setProcessOutputHandler` (runs on the parse thread, `@Sendable`, must
  return fast) and hop to main. `Terminal` is no longer reachable from the
  view, so `Workspace.flushPendingTerminalThaws`
  (`pane.terminal.terminal.updateFullScreen()`) needs another way to force a
  full redraw. See `MigratingFrom1To2.md` in the SwiftTerm docs.
- **Scroll:** Keep `TerminalScrollWheel.swift`. 2.0 adds a wheel-report budget
  (5d3026a / #657, 100 reports/s, burst 6, one report per wheel notch) that
  felt too slow in Claude Code side by side, and has no gesture latch.
- **Fork patches:** Re-apply or drop the commits on `termy/1.20`.
  Single-width glyphs wider than their cell (D2Coding's ①…⑳, fallback glyphs
  under Menlo) are fitted in `glyphSlotFit`, borrowing 3/8 of a blank neighbor
  cell (`singleCellRoom`) so they stay legible; upstream 2.0 fits only
  fallback-font glyphs, so a primary font such as D2Coding still needs the
  patch.
- **Context:** Re-verify every SwiftTerm workaround in `TermyTerminalView`
  live after the move (IME `kittyIsComposing`, caret overlay timing,
  `feedPrepare` selection clearing, the mouse-reporting bypass,
  Option+Left/Right, `requestOpenLink` allowlist, selected-text color).

### SwiftTerm 1.20 audit leftovers

Found while auditing f37922e → 1.20.0 (2026-10-07). Re-check each after any
SwiftTerm bump.

- **Pane teardown leaves `ForegroundProcessWatcher` polling.** Unregistering
  happens only in `shellExited`, which does not run when `Workspace` clears the
  shell-exit callback before `terminate()` (⌘W) or when the pane deallocates.
  Since 1.20 (424a5a1) `LocalProcess.deinit` closes the PTY, so closing a
  window ends its shells with SIGHUP instead of leaking them, and that path
  joins ⌘W. The watcher keeps calling `tcgetpgrp` on a closed fd; if the fd
  number is reused, a synthetic SessionStart can attach to the wrong pane.
- **`TermyTerminalView.cellPosition` doesn't match SwiftTerm's cell width.**
  SwiftTerm pixel-snaps the width (rounded since 87a7888); termy uses the raw
  "W" advance, so Cmd+click and wheel-report columns drift on long lines.
- **Ctrl retarget monitor mangles Ctrl+function keys.** Arrows/F-keys report
  private-use scalars (0xF7xx), so `needsASCIIRetargeting` is true and
  `UCKeyTranslate` returns an ASCII control byte. Skip retargeting for
  0xF700–0xF8FF.
- **Drag auto-scroll keeps running** if the drag ends with a Cmd+mouseUp over a
  URL: termy's link monitor swallows the mouseUp, and SwiftTerm only stops its
  timer there.

## Runtime and distribution

### Separate LaunchAgent daemon

- **What:** Move `HookDaemon` out of termy.app into
  `~/Library/LaunchAgents/app.termy.daemon.plist`.
- **Why:** Survives app crashes; hook events keep flowing while termy is
  force-quit or crashed.
- **Pros:** Dashboard state is never stale-due-to-crash.
- **Cons:** Install/uninstall ceremony, LaunchAgent plist management,
  auto-update of the daemon binary.
- **Context:** `/plan-eng-review` accepted an in-process `HookDaemon` for v1.
  Document "if the dashboard is empty after a crash, restart your agents" as
  a limitation. Migrate if crash frequency is a real user complaint.

### User-editable termy hook config (replace hooks.json mutation)

- **What:** Ship a separate
  `~/Library/Application Support/termy/hook-config.json` that `termy-hook`
  reads directly. Install writes a single hook entry per event in
  `~/.claude/hooks.json` pointing at `termy-hook`; `termy-hook` consults its
  own config for behavior.
- **Why:** Removes the entire "merge into user's hooks.json" risk category.
  Uninstall becomes trivial. The user can tune termy without touching Claude
  Code's config.
- **Pros:** Clean separation of concerns. Easy to reason about. Resilient to
  hand-edits.
- **Cons:** One more config file; existing installs would need a migration.
- **Context:** Flagged in the design doc's Reviewer Concerns and in
  `/plan-eng-review` Implementation Notes.

### Apple crash reporter (enabled by default)

- **What:** Enable Apple's built-in crash reporting during notarization; check
  Xcode Organizer weekly.
- **Why:** A solo-dev app with real users needs repro data for bugs the
  developer cannot trigger.
- **Pros:** Free, zero-effort, native.
- **Cons:** None; just a config checkbox.

## Product

### Disambiguate same-name projects in the pane filter

- **What:** Two panes whose worktree basenames collide (e.g. `~/code/api` and
  `~/other/api`) are bucketed under one `.project("api")` filter and paint
  with the same accent color. They should be treated as separate projects.
- **Why:** The bug is documented in `ProjectIdentity.derive` ("⚠️ NOT a
  persistence key — basename collides…") but the live `projectId` in `Pane`
  still uses the basename. `WorkspacePersistence` already keys on
  `canonicalPath`, so there is a known split between the persistence id (path)
  and the runtime id (basename).
- **Pros:** Fixes a real misgrouping; restores a 1:1 mapping between the
  filter pill and a single repo.
- **Cons:** The filter chip label needs disambiguation when basenames collide
  (path suffix? parent dir? truncated absolute path?). Touches
  `Pane.projectId`, `Workspace.orderedProjectIds`, `ProjectFilterBar` display
  strings, and the chip accent key in `MissionControlView`.
- **Context:** Use `ProjectIdentity.canonicalPath` (already exists) as the
  filter key; derive a display label that stays "api" when unique and expands
  (e.g. "api (other)") only when colliding.

### Per-project settings UI

- **What:** Right-click a project in the ⌘K switcher → settings pane (override
  project id, custom cwd, pinned agents).
- **Why:** Power users want control over project identity beyond
  `git root || basename(cwd)`.
- **Cons:** UX surface that does not exist yet. Not painful today because the
  defaults are sensible.

### Permission-prompt context tooltip

- **What:** On a Claude `Notification` with `reason: permission`, render a
  tooltip on the pulse dot showing what the prompt is about ("Claude wants to
  run `rm -rf /tmp/foo`").
- **Why:** The user can triage multiple waiting panes without clicking each
  one.
- **Cons:** Depends on the notification payload carrying the prompt text.
  Verify against current Claude Code versions before building the UI.
- **Context:** Flagged [P2] in `/plan-eng-review` Architecture. The dashboard
  already has a generic state/cwd/prompt tooltip; this item is specifically
  the permission context.

### User-provided themes

- **What:** Named themes beyond the built-in System / Light / Dark modes, with
  a loader for user-provided JSON files that define the accent palette, pane
  background, chrome tints, `headerTintAlpha`, dashboard chip treatments, and
  the SwiftTerm ANSI 16-color map.
- **Status:** Built-in light/dark themes and the `TermyTheme` structure ship.
  The JSON loader, theme picker, and compatibility contract do not.
- **Why:** Terminals are personal. Users have strong opinions (Solarized,
  Nord, Tokyo Night, Dracula). A small theme surface is cheap in a tool where
  everything already routes through `PaneStyling`.
- **Pros:** Low code cost — `PaneStyling` already funnels every accent through
  one palette, so most of the work is externalizing the constants. Unlocks
  community themes.
- **Cons:** The theme file format becomes a public API with compatibility
  obligations. Bad user themes (low contrast, clashing palettes) degrade the
  product's visual identity — worth shipping curated built-ins and validating
  user themes on load.

### Separate UI chrome scaling

- **What:** A size override for pane headers, dashboard chips, and project
  filter pills, independent of the terminal font size.
- **Status:** Terminal font family, Korean fallback, and point size ship via
  ⌘, (`FontSettingsPanel`). `TermyTypography.defaultPointSize` is still fixed
  for UI chrome.
- **Why:** Users pick a terminal size for readability and may want a different
  density for the surrounding chrome.
- **Cons:** Changes layout metrics in several custom views; needs a live
  re-layout pass and sensible min/max bounds.
