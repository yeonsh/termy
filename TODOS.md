# termy TODOs

Candidates captured during /office-hours and /plan-eng-review on 2026-04-19.
Not v1 scope. Revisit after v1 ships and real users surface real priorities.

## v1.1 candidates

### Codex support
- **What:** Extend HookDaemon to handle Codex's hook event set.
- **Why:** Codex users exist; "CC-only" limits reach.
- **Pros:** Doubles addressable audience overnight.
- **Cons:** Codex's hook set (`SessionStart`, `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `Stop`) has no Notification or error events. Codex panes can only reliably produce THINKING/WAITING. ERRORED requires a fallback (pty exit code or screen-scrape).
- **Context:** Verified during /office-hours — Codex's Notification event does not exist, so parity with CC needs additional signals. See design doc premise 5.
- **Depends on:** CC path being stable in v1.

### Screen-scraping fallback for agents without hooks
- **What:** Optional per-pane stdout parser that detects state transitions via output patterns.
- **Why:** Unlocks support for any CLI agent (Aider, Gemini CLI, homegrown tools), not just CC/Codex.
- **Pros:** Product reach expands significantly. "Works with every LLM CLI" is a better tagline than "works with Claude Code."
- **Cons:** Fragile. Pattern-per-agent. Breaks when the agent's output format changes.
- **Context:** /office-hours explicitly rejected this for v1 in favor of hooks-first. Revisit if hook-first proves too restrictive.

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
