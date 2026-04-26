# termy TODOs

Candidates captured during /office-hours and /plan-eng-review on 2026-04-19.
Not v1 scope. Revisit after v1 ships and real users surface real priorities.

## v1.1 candidates

### Codex support — SHIPPED on branch `codex-support` (2026-04-26)
Both Codex hooks (via `~/.codex/config.toml` + TOMLKit) and the
foreground-process watcher (synthetic `SessionStart`/`SessionEnd`) landed.
PermissionRequest drives THINK→WAIT; Codex `SessionStart` is a hard reset
to IDLE; the fg-process watcher closes the missing-`SessionEnd` gap.
Squash-merged to main as `690a193` on 2026-04-26.

### Codex follow-ups
- ~~**Fake-WAIT prevention** — reasoning-model silence shouldn't trip the 8s reconciler.~~ Shipped 2026-04-27 via two-stage WAIT (POSSIBLY_WAITING + PTY-activity gate + promotion timer). See `docs/superpowers/plans/2026-04-26-codex-possibly-waiting-state.md`.
- **ERR inference** — derive ERRORED state from `Stop.stopReason` +
  `PostToolUse.tool_response` so failed runs surface in the dashboard
  without a manual reset.
- **0.124.0 hook regression (issue #19199)** — emit a version warning
  during `CodexHookInstaller` install when the local Codex CLI is on a
  known-broken release.
- **THINK timeout guard** — drift-correct panes stuck in THINK past a
  threshold (foreground process gone but no terminal SessionEnd / Stop).
- **Live integration smoke test** — real `codex` CLI invocation in CI
  exercising the full hook → daemon → PaneState path; current tests are
  unit-level only.
- **"Works with every LLM CLI" reach** — fg-process watcher already
  covers start/end; THINK/WAIT/IDLE for hook-less agents would need
  bespoke heuristics (e.g., output cadence, prompt regex).

### Separate LaunchAgent daemon
- **What:** Move HookDaemon out of termy.app into `~/Library/LaunchAgents/app.termy.daemon.plist`.
- **Why:** Survives app crashes; hook events keep flowing while termy is force-quit or crashed.
- **Pros:** Dashboard state is never stale-due-to-crash.
- **Cons:** Install/uninstall ceremony, LaunchAgent plist management, auto-update of the daemon binary.
- **Context:** /plan-eng-review accepted in-process HookDaemon for v1. Document "if dashboard is empty after crash, restart your agents" as a v1 limitation. Migrate if crash frequency is a real user complaint.

### User-editable termy hook config (replace hooks.json mutation)
- **What:** Ship a separate `~/Library/Application Support/termy/hook-config.json` that `termy-hook` reads directly. Install writes a single hook entry per event in `~/.claude/hooks.json` pointing at `termy-hook`; `termy-hook` consults its own config for behavior.
- **Why:** Removes the entire "merge into user's hooks.json" risk category. Uninstall becomes trivial. User can tune termy without touching Claude Code's config.
- **Pros:** Clean separation of concerns. Easy to reason about. Resilient to hand-edits.
- **Cons:** One more config file; v1 users who already have installs would need a migration.
- **Context:** Flagged in design doc Reviewer Concerns. Also flagged in /plan-eng-review Implementation Notes.

### Apple crash reporter (enabled by default)
- **What:** Enable Apple's built-in crash reporting during notarization; check Xcode Organizer weekly.
- **Why:** Solo-dev app with real users needs repro data for bugs the dev can't trigger.
- **Pros:** Free, zero-effort, native.
- **Cons:** None for v1; just a config checkbox.
- **Context:** Move to v1 if remembered early; otherwise land in v1.1 first release bump.

### Disambiguate same-name projects in the pane filter
- **What:** Two panes whose worktree basenames collide (e.g. `~/code/api`
  and `~/other/api`) are bucketed under one `.project("api")` filter and
  paint with the same accent color. They should be treated as separate
  projects.
- **Why:** The bug is documented in `ProjectIdentity.derive` ("⚠️ NOT a
  persistence key — basename collides...") but the live `projectId` in
  `Pane` still uses the basename. `WorkspacePersistence` already keys on
  `canonicalPath`, so there's a known split between persistence id (path)
  and runtime id (basename).
- **Pros:** Fixes a real misgrouping; restores 1:1 mapping between the
  filter pill and a single repo.
- **Cons:** Filter chip label needs disambiguation when basenames collide
  (path suffix? parent dir? truncated absolute path?). Touches
  `Pane.projectId`, `Workspace.orderedProjectIds`, `ProjectFilterBar`
  display strings, and the chip accent key in `MissionControlView`.
- **Context:** Use `ProjectIdentity.canonicalPath` (already exists) as the
  filter key; derive a display label that stays "api" when unique and
  expands (e.g. "api (other)") only when colliding.

### Per-project settings UI
- **What:** Right-click a project in `⌘K` switcher → settings pane (override project id, custom cwd, pinned agents).
- **Why:** Power users want control over project identity beyond `git root || basename(cwd)`.
- **Cons:** UX surface that doesn't exist yet. Not painful in v1 because defaults are sensible.

### Permission-prompt context tooltip
- **What:** On `CC-Notification` with `reason: permission`, render a tooltip on the pulse dot showing what the prompt is about ("Claude wants to run `rm -rf /tmp/foo`").
- **Why:** User can triage multiple waiting panes without clicking each one.
- **Cons:** Depends on CC-Notification payload carrying the prompt text. Verify in Week 0 spike.
- **Context:** Flagged [P2] in /plan-eng-review Architecture.

### Light mode
- **What:** Honor system Appearance (light/dark) and/or expose an explicit override in Preferences. Needs light-mode analogs for pane background, titlebar chrome, dashboard chips, pane-header tint alpha, and the `PaneStyling.palette`.
- **Why:** termy hard-codes a dark theme today. macOS users on Light system-wide get a jarring black rectangle in a bright desktop.
- **Pros:** Table-stakes parity with native macOS. Broader appeal.
- **Cons:** The palette comment calls the current pastels "pastel on a dark background" — a light-mode palette is a separate color tuning problem, not a toggle. App icon's gradient background is dark-only too; needs a light variant or stay dark.
- **Context:** v1 deliberately shipped dark-only to avoid the palette work. Revisit once theme scaffolding (below) lands — light mode becomes the first built-in light theme rather than a one-off code path.
- **Depends on:** Theme system — land the plumbing, then ship light as the first non-default theme.

### Theme system
- **What:** Named themes users can switch between — `default-dark`, `default-light`, plus a loader for user-provided JSON files that define: accent palette, pane background, chrome tints, `headerTintAlpha`, dashboard chip treatments, and the SwiftTerm ANSI 16-color map.
- **Why:** Terminals are personal. Users have strong opinions (Solarized, Nord, Tokyo Night, Dracula). A small theme surface is cheap to ship in a tool where everything already routes through `PaneStyling`.
- **Pros:** Low code cost — `PaneStyling` already funnels every accent through one palette, so most of the work is externalizing the constants. Unlocks community themes. Absorbs light mode as a natural use case.
- **Cons:** Theme file format becomes a public API with compatibility obligations. Bad user themes (low contrast, clashing pastels) degrade the product's visual identity — worth shipping 2-3 curated built-ins and validating user themes on load.
- **Context:** Touches `PaneStyling`, `MissionControlView`, `MainWindowController` titlebar chrome, `ProjectFilterBar`, pane headers, and any SwiftTerm color overrides. Pair with a Preferences window (doesn't exist yet in v1).

### Font settings
- **What:** Preferences for the terminal font (family + size), with a separate size override for UI chrome (pane header, dashboard chip, project filter). Persist to `UserDefaults`. Live-apply on change so users can dial in size without quitting.
- **Why:** 14 pt FiraCode is hard-coded for both the PTY and the UI chrome. Users come with opinions and with eyes of different ages — the default is not one-size-fits-all.
- **Pros:** Single chokepoint (`TermyTypography`) — roughly a day of work to externalize. Immediate quality-of-life win users notice the moment they open the app.
- **Cons:** SwiftTerm cell-size recalc happens on font change; need to propagate a re-layout through every pane + call `processTerminated`-safe paths. Non-monospace fonts will break column alignment — filter the font picker to monospaced families only.
- **Context:** `TermyTypography` in `PaneStyling.swift` is the only place fonts are resolved today. Fallback chain already tolerates missing FiraCode (falls back to `monospacedSystemFont`), so the preference layer just needs to inject a user-chosen family at the top of `candidateNames(for:)`. Pair with the same Preferences window as Theme system.
