# termy Project Overview

## Summary

`termy` is a native macOS terminal for running multiple coding agents — Claude
Code, Codex CLI, OpenCode, and Antigravity CLI — side by side and surfacing
their live state in a dashboard at the bottom of the window. It is not a tabbed
terminal: panes are grouped into projects by cwd, and a titlebar filter bar
switches between project layouts.

The shipped 0.2.22 surface also includes rendered Markdown and PDF previews,
multi-window support with full session restore, drag-reorderable project chips,
and Sparkle updates that wait for running agents and resume their conversations.

The repository contains:

- a macOS AppKit app target (`termy`), with SwiftUI used for the mission-control
  strip
- a tiny `termy-hook` helper installed into each agent's hook or plugin surface
- an XCTest target covering the state machine, dashboard, persistence,
  integrations, previews, and update behavior

## Tech Stack

- **Language:** Swift 6.0, strict concurrency
- **Platform:** macOS 14+
- **UI:** AppKit for windows, splits, panes, and previews; SwiftUI for the
  mission-control strip
- **Terminal renderer / PTY host:** SwiftTerm from termy's fork
  (`https://github.com/yeonsh/SwiftTerm`, branch `termy/1.20`: v1.20.0 plus
  termy patches, pinned by revision in `project.yml`)
- **Auto-update:** Sparkle 2.6.4, with the appcast served from the separate
  `termy-updates` repository
- **Markdown previews:** swift-markdown 0.9.0 plus a small custom HTML writer
- **Codex TOML config:** TOMLKit 0.6
- **Project format:** XcodeGen generates `termy.xcodeproj` from `project.yml`
- **Distribution:** Developer ID-signed, hardened runtime, notarized DMG; the
  app is not sandboxed because it spawns login shells and agent CLIs
- **Tests:** XCTest

## Repository Layout

### Application and window lifecycle

- `apps/termy/Sources/AppDelegate.swift`
  App entry point. Builds the menu bar, starts `HookDaemon` and `WindowManager`,
  runs first-launch prompts (Full Disk Access and agent integrations), and
  instantiates the Sparkle updater.
- `apps/termy/Sources/WindowManager.swift`
  Owns every `MainWindowController`. Creates windows for <kbd>⌘</kbd><kbd>N</kbd>
  and session restore, routes cross-window pane focus, and drives session
  save/restore.
- `apps/termy/Sources/MainWindowController.swift`
  One window: the titlebar project filter, the `Workspace` grid, and the
  bottom mission-control strip. Also defines the runtime project identity rules
  (`ProjectIdentity`).
- `apps/termy/Sources/Workspace.swift`
  Pane lifecycle, split layout, project filtering, focus history, maximize,
  drag-reordered project order, and the balanced ALL grid.
- `apps/termy/Sources/SessionPersistence.swift`,
  `SessionAutosaver.swift`, `SessionRecord.swift`
  Multi-window session schema and persistence: window frames, layouts, filter,
  and project order in `session.json`.
- `apps/termy/Sources/WorkspacePersistence.swift`,
  `WorkspaceAutosaver.swift`, `WorkspaceRecord.swift`
  Per-project pane layout schema and persistence under
  `Application Support/termy/workspaces/`.
- `apps/termy/Sources/AppLifecycle.swift`, `MainQueueTimer.swift`
  App-termination state and a small one-shot main-queue timer used by restore
  and update flows.

### Terminal surface

- `apps/termy/Sources/Pane.swift`
  One pane: project/branch header plus the terminal view. Spawns the login
  shell through SwiftTerm, injects `TERMY_PANE_ID` / `TERMY_PROJECT_ID`, tracks
  cwd changes, and emits synthetic `PtyExit` events when the child exits.
- `apps/termy/Sources/TermyTerminalView.swift`
  `LocalProcessTerminalView` subclass. Owns <kbd>⌘</kbd>-click link handling,
  IME workarounds, mouse reporting, selection behavior, and PTY activity
  signals.
- `apps/termy/Sources/TerminalScrollWheel.swift`
  Distance-accurate trackpad scrolling and Ghostty-style momentum; mouse wheel
  moves three rows per notch.
- `apps/termy/Sources/TerminalFontPreference.swift`,
  `FontSettingsPanel.swift`
  Primary monospaced font, Korean fallback, and size, persisted in
  `UserDefaults` and applied live.
- `apps/termy/Sources/ThinkingActivityBar.swift`,
  `PaneStyling.swift`
  The sliding header activity bar and the jewel-tone per-project accent palette
  for light and dark appearance.
- `apps/termy/Sources/GitBranch.swift`, `GitHeadWatcher.swift`
  Branch lookup for pane headers, plus `.git/HEAD` watching so checkout,
  switch, and detached-HEAD jumps refresh immediately.

### State pipeline

- `apps/termy/Sources/HookDaemon.swift`
  Actor-backed event collector. Owns `/tmp/termy-$UID.sock`, applies the state
  machine, journals raw events, runs the WAITING and Codex silence timers, and
  publishes `AsyncStream<DaemonUpdate>` snapshots.
- `apps/termy/Sources/HookEvent.swift`
  Compact wire format shared by `termy-hook`, synthetic PTY events, and the
  daemon.
- `apps/termy/Sources/PaneState.swift`
  `PaneState`, `PaneSnapshot`, and the pure `PaneStateMachine` reducer. This is
  the source of truth for state transitions.
- `apps/termy/Sources/AgentKind.swift`
  Typed agent identity (`claude`, `codex`, `opencode`, `antigravity`) threaded
  through snapshots and installers.
- `apps/termy/Sources/ForegroundProcessWatcher.swift`
  Polls `tcgetpgrp()` + libproc at 1 Hz and synthesizes `SessionStart` /
  `SessionEnd` when a known agent enters or leaves a pane's foreground process
  group.
- `apps/termy/Sources/MissionControlModel.swift`
  Bridges the daemon actor to the main actor, merges snapshots from every
  window, and publishes the ordered chip list.
- `apps/termy/Sources/MissionControlView.swift`
  The bottom dashboard strip. Renders one chip per live pane with project /
  branch and live state.
- `apps/termy/Sources/Notifier.swift`
  macOS notifications, sound, and dock attention for WAIT transitions.

### Project navigation

- `apps/termy/Sources/ProjectFilterBar.swift`
  Scrollable titlebar filter pills, including numbered shortcuts and drag
  reordering.
- `apps/termy/Sources/ProjectSwitcherPanel.swift`,
  `FuzzyMatch.swift`
  The <kbd>⌘</kbd><kbd>K</kbd> palette over persisted projects, with fuzzy
  matching, pane counts, last-used timestamps, restore, and removal of stale
  rows.

### Previews

- `apps/termy/Sources/PreviewManager.swift`
  One preview window per Markdown or PDF file, keyed by canonical path.
- `apps/termy/Sources/PreviewLinkResolver.swift`
  Decides whether a <kbd>⌘</kbd>-clicked terminal link names a previewable
  file and resolves relative paths, `file://` URLs, line suffixes, and
  filenames with spaces or parentheses.
- `apps/termy/Sources/PreviewFileWatcher.swift`
  Watches the open file (both in-place writes and atomic saves) and drives live
  updates.
- `apps/termy/Sources/MarkdownHTMLRenderer.swift`,
  `MarkdownPreviewStyle.swift`, `MarkdownPreviewWebView.swift`,
  `MarkdownPreviewWindowController.swift`
  Swift-Markdown parsing, GitHub-like HTML/CSS, scroll-preserving live reload,
  drag-to-open, and Show in Finder.
- `apps/termy/Sources/PDFPreviewView.swift`,
  `PDFPreviewWindowController.swift`, `PreviewWindowSupport.swift`
  PDFKit preview with page/zoom retention and protection against half-written
  files.

### Agent integrations

- `apps/termy/Sources/HookInstaller.swift`
  Claude Code installer for `~/.claude/settings.json`.
- `apps/termy/Sources/CodexHookInstaller.swift`
  Codex installer for `~/.codex/hooks.json` or `~/.codex/config.toml`.
- `apps/termy/Sources/OpenCodePluginInstaller.swift`
  Writes the termy TUI plugin to
  `~/.config/opencode/plugins/termy/tui.js`.
- `apps/termy/Sources/AntigravityHookInstaller.swift`
  Antigravity installer for `~/.gemini/config/hooks.json`.
- `apps/termy/Resources/opencode-plugin/tui.js`
  The bundled OpenCode plugin template; the installer substitutes the current
  `termy-hook` path.

### Updates

- `apps/termy/Sources/Updater.swift`
  Sparkle wrapper and menu integration.
- `apps/termy/Sources/UpdateRelaunchGate.swift`
  Holds a Sparkle relaunch while any local agent is mid-turn, prompts the user,
  re-checks after a settle delay, and exposes
  *termy ▸ Restart Now to Install Update*.
- `apps/termy/Sources/AgentResume.swift`,
  `AgentResumeFlags.swift`, `StartupInputScheduler.swift`
  Captures safe resume records before an update relaunch and types the resume
  command into restored panes once the shell prompt is ready.

### Support and appearance

- `apps/termy/Sources/AppAppearance.swift`,
  `AppearanceBanner.swift`
  System / Light / Dark preference, <kbd>⌘</kbd><kbd>⇧</kbd><kbd>T</kbd>
  cycling, and the HUD that names the new appearance.
- `apps/termy/Sources/FullDiskAccess.swift`
  First-launch TCC guidance and deep link to System Settings.
- `apps/termy/Sources/TestHostDetector.swift`
  Suppresses launch-time installers and prompts while the app is running as the
  XCTest host.

### Hook helper target

- `apps/termy-hook/Sources/main.swift`
  Tiny CLI invoked by Claude Code, Codex, and Antigravity hooks, and by the
  OpenCode plugin. It slims the payload and writes one JSON line to
  `/tmp/termy-$UID.sock`. It is intentionally best-effort: always exits `0`,
  and gives each write a 100 ms budget so it cannot stall an agent.
- `apps/termy-hook/Sources/HookCLI.swift`
  Pure payload-slimming and argument helpers, compiled into both the helper and
  the unit-test target.

### Test target

- `apps/termy-tests/Sources/`
  670+ XCTest cases across 50+ suites at 0.2.22. Coverage includes the pane
  state machine, mission-control ordering and shape diffing, project order and
  grid placement, workspace/session persistence, fuzzy matching, preview link
  resolution and rendering, all four installers, agent resume capture, update
  relaunch gating, scrolling, fonts, and appearance.

## Runtime Architecture

```
Claude Code  ──hook───▶  termy-hook --agent claude-code  ─┐
Codex CLI    ──hook───▶  termy-hook --agent codex        ─┤
OpenCode     ──plugin─▶  termy-hook --agent opencode     ─┼─▶ /tmp/termy-$UID.sock
Antigravity  ──hook───▶  termy-hook --agent antigravity  ─┘
                                                              │
                                                              ▼
                                                     HookDaemon (actor)
                                                              │
                                            PaneStateMachine ─┤
                                                              ▼
                                       AsyncStream<DaemonUpdate>
                                                              │
                                                              ▼
                                             MissionControlModel (shared)
                                                              │
                                                              ▼
                                       MissionControlView + Notifier
```

The runtime loop is:

1. `AppDelegate` starts `HookDaemon`, `WindowManager`, and the Sparkle updater.
   `WindowManager` restores the saved multi-window session, or opens one fresh
   window when there is nothing to restore.
2. Each pane starts a login shell through SwiftTerm with `TERMY_PANE_ID` and
   `TERMY_PROJECT_ID` in its environment.
3. Agent hooks or the OpenCode plugin invoke `termy-hook` and write to the
   socket. Synthetic PTY-exit and foreground-process events are posted directly
   to `HookDaemon`.
4. `HookDaemon` decodes the event, applies `PaneStateMachine`, updates the
   per-pane snapshot, appends a line to `events.jsonl`, and publishes a
   `DaemonUpdate`.
5. `MissionControlModel` — a single app-wide `@Observable` — folds every
   snapshot into its map and recomputes the chip list. Every window's
   `MissionControlView` observes that one model.
6. `Notifier` watches fresh WAIT transitions, updates the dock badge, plays the
   alert sound, bounces the dock when termy is in the background, and posts a
   banner whose copy depends on the wait reason.
7. Layout and window mutations flow through the debounced autosavers into
   `session.json` and the per-project workspace files.
8. On a Sparkle relaunch, `UpdateRelaunchGate` waits for local agents to finish
   their turns; `AgentResume` records are sealed into the session file, and the
   next launch types the appropriate resume command into each restored pane.

## Core Concepts

### Pane states

`PaneState` is the reducer-level state; the dashboard renders a shorter label.

| Dashboard | Internal | Meaning |
|---|---|---|
| `INIT` | `initializing` | Pane created, no agent event yet. Hidden from the dashboard unless it needs attention. |
| `THINK` | `thinking` | A turn or tool call is in flight. |
| `THINK` | `possiblyWaiting` | Codex-only silent hedge; rendered as THINK and never announced. |
| `WAIT` | `waiting` | Blocked on a permission prompt, a question, or a finished turn. |
| `IDLE` | `idle` | At the prompt with nothing running. |
| `ERR` | `errored` | The turn or shell failed. Stays red until the pane changes state. |

Two orthogonal fields matter:

- `needsAttention` distinguishes "WAIT because the user must answer" from
  "WAIT because the turn ended"; the dashboard uses it to keep the attention
  styling, and a WAIT that still needs an answer is not aged out to IDLE.
- `turnOpen` tracks turn boundaries independently of the visible state and is
  what `UpdateRelaunchGate` uses to decide whether a relaunch would kill work.

Key transitions:

- `UserPromptSubmit` and tool activity move a pane to THINK.
- `Stop` moves a turn-end pane to WAIT; that WAIT falls back to IDLE after 30
  seconds. A WAIT that still needs attention stays until the user answers.
- Permission prompts and MCP-tool approvals arrive through `Notification`;
  `AskUserQuestion` is detected from `PreToolUse`. Both move the pane to WAIT
  with `needsAttention` and a macOS alert.
- `StopFailure`, or `PtyExit` with a non-zero status, moves it to ERR.
- `SessionEnd` or a zero-status `PtyExit` moves it to INIT.
- Codex and Antigravity treat every `SessionStart` as a hard reset to IDLE.
- The OpenCode plugin reports level-triggered statuses (`running`,
  `permission`, `question`, `succeeded`, `failed`, `idle`).

The transition table in `PaneState.swift` is authoritative; this section is a
summary.

### Mission-control dashboard

The dashboard is the strip at the bottom of each window. It shows one chip per
live pane, with the pane's project, branch, and state.

- The chip order is fixed: window registration order, then pane creation order
  within each window. Panes do not reshuffle when their state changes, so a chip
  keeps its position.
- The model is shared across every window, so each window's strip shows the
  chips for **all** open windows. Clicking a chip brings the owning window
  forward and focuses the pane.
- Panes still in `INIT` are hidden unless they have attention.
- The bar caps at 32 chips; beyond that, the oldest panes in creation order win.
- <kbd>⌘</kbd><kbd>G</kbd> jumps to the next WAIT pane across splits, filters,
  and windows. <kbd>⌘</kbd><kbd>⌥</kbd><kbd>G</kbd> walks every dashboard chip
  in order; holding <kbd>⌘</kbd><kbd>⌥</kbd> shows numeric badges.
- Tapping a WAIT notification activates the owning window and pane as well.
- Re-renders are diffed on the fields the chips actually read, so timestamp-only
  hook updates do not force a full SwiftUI re-measure.

### Workspace and projects

A window is one `Workspace`, not a tab container. Layout is nested
`NSSplitView`s: an outer vertical split for rows, with a horizontal split for
the panes in each row. Moving an `NSView` between superviews preserves its
state, so PTYs keep running across filter switches.

- **Project identity.** The display label is the basename of the containing git
  worktree root, falling back to the cwd. The persistence key is the
  symlink-resolved canonical path. Two unrelated repositories with the same
  basename therefore share a filter label today; see `TODOS.md`.
- **Filtering.** The titlebar filter bar shows one pill per project plus ALL.
  <kbd>⌘</kbd><kbd>1</kbd>–<kbd>⌘</kbd><kbd>9</kbd> pick projects;
  <kbd>⌘</kbd><kbd>⇧</kbd><kbd>[</kbd> / <kbd>⌘</kbd><kbd>⇧</kbd><kbd>]</kbd>
  walk filters. Filter changes return focus to the last active pane in that
  scope where possible.
- **ALL view.** ALL lays panes out in one balanced grid with `ceil(sqrt(N))`
  columns and keeps each project's panes clustered together. A single-project
  filter keeps the split layout the user built.
- **Project order.** Dragging titlebar chips stores a preferred order layered
  over discovery order. The same order drives the filter bar,
  <kbd>⌘</kbd><kbd>1</kbd>–<kbd>⌘</kbd><kbd>9</kbd>, the ALL grid, and focus
  traversal.
- **Project switcher.** <kbd>⌘</kbd><kbd>K</kbd> fuzzy-matches every persisted
  project and restores its saved pane grid when it has no live panes. Stale rows
  can be removed with the trash button or
  <kbd>⌘</kbd><kbd>⌫</kbd>; the folder on disk is never touched.
- **Multi-window.** <kbd>⌘</kbd><kbd>N</kbd> creates an independent window.
  Session restore brings back window frames, pane layouts, filters, and project
  order; off-screen frames are clamped back onto a visible display.

### Markdown and PDF previews

- <kbd>⌘</kbd>-clicking a Markdown or PDF path in a pane resolves it through
  `PreviewLinkResolver`, then opens a preview window owned by `PreviewManager`.
  A file already open is brought forward instead of duplicated.
- Markdown is parsed with swift-markdown and rendered by a custom HTML writer.
  Page JavaScript is disabled; navigation is decided by the controller. Tables,
  task lists, and fenced code blocks follow a GitHub-like style.
- Previews follow the app's light or dark appearance. `PreviewFileWatcher`
  reloads on both in-place writes and atomic saves; Markdown keeps the reader's
  scroll position, while PDF keeps page and zoom. A half-written PDF leaves the
  previous version on screen.
- Dropping a Markdown or PDF file on a Markdown preview opens it in a preview
  of its own. PDF links inside a Markdown preview and `file://` links to PDFs
  open in a termy preview.
- <kbd>⌘</kbd><kbd>W</kbd> closes the current preview, and
  <kbd>⌥</kbd><kbd>⌘</kbd><kbd>R</kbd> / right-click → Show in Finder reveals
  the file.

Only `.md` and `.pdf` files are previewable today.

### Updates and agent resume

- Sparkle checks `https://termy.nugo.cc/appcast.xml` and verifies the EdDSA
  signature on every update.
- `UpdateRelaunchGate` intercepts a relaunch while any local pane is mid-turn.
  It offers *Wait for Agents* or *Restart Now*; waiting re-counts on every
  snapshot change and releases two seconds after the count reaches zero. It
  reminds the user every 10 minutes and exposes
  *termy ▸ Restart Now to Install Update* as the escape hatch.
- Before relaunch, `AgentResume` records the agent kind, session id, cwd, and
  safe flags. On the next launch, `StartupInputScheduler` waits for the shell
  prompt and types `claude --resume …`, `codex resume …`, or
  `agy --conversation …` into the restored pane.
- OpenCode sessions are not resumed after an update yet.

### Appearance, fonts, and input

- Appearance is System, Light, or Dark. <kbd>⌘</kbd><kbd>⇧</kbd><kbd>T</kbd>
  cycles it and shows a short HUD; panes, chrome, dashboard, and previews follow.
- <kbd>⌘</kbd><kbd>,</kbd> picks the terminal's monospaced font, Korean
  fallback, and point size. Changes apply live and trigger a grid-size update.
- Trackpad scrolling follows gesture distance with momentum; mouse wheels move
  three rows per notch; scrollback stops snapping while the user reads.
- Mouse reporting is forwarded to full-screen apps such as Claude Code, tmux,
  and vim; holding <kbd>⇧</kbd> uses termy's own selection instead.
- Dropping files from Finder onto a pane types escaped absolute paths.
  <kbd>⇧</kbd><kbd>⏎</kbd> inserts a newline in Claude Code rather than
  submitting the prompt.

## Agent Integrations

| Agent | Integration | Installed to |
|---|---|---|
| Claude Code | hooks | `~/.claude/settings.json` |
| Codex CLI | hooks | `~/.codex/hooks.json` when present, otherwise `~/.codex/config.toml` |
| OpenCode | TUI plugin | `~/.config/opencode/plugins/termy/tui.js` |
| Antigravity CLI (`agy`) | hooks | `~/.gemini/config/hooks.json` |

All installers are non-destructive: termy owns only its own keys or file,
preserves other hooks and plugins, backs up any existing configuration file
before editing it, and can be uninstalled from the `termy` menu. Moving the app
re-registers the new hook path on the next launch.

### Claude Code hooks

The installer merges termy's entries into `~/.claude/settings.json` after a
first-run consent prompt. It registers nine events:

- Lifecycle: `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `Stop`,
  `StopFailure`, `Notification`
- Tool events: `PreToolUse`, `PostToolUse`, `PostToolUseFailure`

Every managed block is tagged `_termy_managed: true` for surgical uninstall,
and the previous file is copied to `settings.json.backup-<ts>` before any
write. Permission prompts and MCP-tool approvals arrive through `Notification`;
`AskUserQuestion` is detected from `PreToolUse`. Both move the pane to WAIT.
`termy-hook` always exits `0` and times out its socket write after 100 ms, so
it cannot block Claude Code even when termy is not running.

### Codex CLI hooks

If `~/.codex/hooks.json` exists, termy prefers it so other tools such as OMX
share one representation; otherwise it writes inline TOML to
`~/.codex/config.toml`. Either way it enables `[features] hooks = true` and
removes the deprecated `[features].codex_hooks` alias. Managed blocks carry
`_termy_managed = true`; existing hooks and feature settings are preserved and
the files are backed up before a write.

Codex has six events: `SessionStart`, `PreToolUse`, `PermissionRequest`,
`PostToolUse`, `UserPromptSubmit`, and `Stop`.

| Codex event | Pane state |
|---|---|
| `SessionStart` | hard reset to `IDLE` |
| `PreToolUse` / `PostToolUse` | `THINK` |
| `PermissionRequest` | `WAIT` + macOS notification |
| `Stop` | `WAIT` (turn end), then `IDLE` after 30 s |

Codex has no native `SessionEnd` hook. `ForegroundProcessWatcher` synthesizes
one when `codex` leaves the pane's foreground process group, resetting the chip
to INIT. Codex also has no `Notification`-equivalent: `PermissionRequest` fires
only for explicit permission asks, not the general "I'm waiting on you" pause
of reasoning models. termy fills that gap with a two-stage silence detector:

- ~8 s of PTY quiet moves THINKING to `POSSIBLY_WAITING` (visual only).
- ~12 s more promotes it to WAIT with a notification and sound.
- Any PTY byte or tool event reverts the silent state immediately.

The trade-off is that Codex WAIT can land roughly 20 seconds after the agent
pauses, and false positives are possible.

### OpenCode plugin

OpenCode reports state through a bundled TUI plugin instead of hooks. The
installer writes exactly one file,
`~/.config/opencode/plugins/termy/tui.js`, and never edits `opencode.json`.
OpenCode sessions that are already open pick the plugin up without a restart.

The plugin watches the routed root session's permission, question, and busy
flags, plus its execution outcome:

| Plugin signal | Pane state |
|---|---|
| `running` | `THINK` |
| `permission` / `question` | `WAIT` + notification |
| `succeeded` | `WAIT` (turn end), then `IDLE` after 30 s |
| `failed` | `ERR` |
| `idle` | `IDLE` |

The plugin only tracks the routed root session; background tabs are ignored.
Uninstall removes termy's file and leaves sibling plugins untouched. OpenCode
sessions are not resumed after a termy update yet.

### Antigravity hooks

Antigravity loads global hooks from `~/.gemini/config/hooks.json`. termy owns a
single top-level `"termy"` group; other groups are preserved and the previous
file is backed up before a write. The installer registers `SessionStart`,
`PreInvocation`, `PostInvocation`, `Stop`, and `PostToolUse`.

It deliberately does not register `PreToolUse`: Antigravity requires a hook
reply carrying a permission decision, and termy only observes, so replying
would block or deny tool calls. `PreInvocation` covers the start of a model
call, `PostInvocation` covers the end of a tool batch, and `Stop` with reason
`ERROR` drives ERR. Antigravity also lets termy reopen the same conversation
with `agy --conversation` after an update.

### Shared agent detection

`AgentKind` is stamped onto `PaneSnapshot` from the wire-level `agent` field on
the first non-synthetic event. The foreground-process watcher recognizes
`claude`, `codex`, `agy`, and `opencode`, and synthesizes session bookends
without screen scraping. Hook events themselves are the source for
THINK/WAIT/IDLE/ERR once an agent is running.

## Persistence, Sockets, and Logs

| Path | Purpose |
|---|---|
| `/tmp/termy-$UID.sock` | Unix-domain socket from `termy-hook` / synthetic events to `HookDaemon` |
| `~/Library/Application Support/termy/session.json` | Multi-window session: frames, pane layouts, filters, project order, update resume records |
| `~/Library/Application Support/termy/workspaces/*.json` | Per-project pane layouts for the ⌘K switcher |
| `~/Library/Application Support/termy/events.jsonl` | Append-only raw hook event journal (rotation is deferred) |
| `~/Library/Application Support/termy/_quarantine/` | Corrupt session/workspace files moved aside instead of overwritten |
| `/tmp/termy-hook-debug.log` | Best-effort helper delivery-failure log |
| `UserDefaults` (`app.termy.macos`) | Appearance, font, and integration preferences |

Session and workspace writes go through a temp-file + atomic rename. Autosavers
debounce bursts of mutations for 500 ms so pane movement and resizing do not
turn into a write storm.

## Current Product Surface

Shipped through 0.2.22:

- Four agents end-to-end: Claude Code, Codex CLI, OpenCode, and Antigravity CLI
- Bottom dashboard with THINK / WAIT / IDLE / ERR, notifications, and
  <kbd>⌘</kbd><kbd>G</kbd> navigation
- SwiftTerm panes with OSC 7 cwd tracking, nested splits, mouse-aware TUIs, and
  <kbd>⌘</kbd>-click URLs
- Markdown and PDF previews with live updates, drag-to-open, and Show in Finder
- Hook daemon + `termy-hook` + non-destructive installers for all four agents
- Workspace autosave, multi-window dashboard, and full session restore
- Reorderable/prunable project chips, per-project accents, and
  <kbd>⌘</kbd><kbd>1</kbd>–<kbd>⌘</kbd><kbd>9</kbd> filters
- Sparkle auto-update that waits for running agents and resumes conversations
  for Claude Code, Codex, and Antigravity
- Developer ID-signed, notarized DMG pipeline and 670+ unit tests

Deferred:

- Screen-scraping fallback for agents without hooks
- A separate LaunchAgent daemon
- User-editable hook config
- Per-project settings UI
- OpenCode resume after an update

## In progress: herdr-core backend

An optional herdr-core (`hc`) backend is in progress but is not part of the
0.2.22 shipped surface. It adds remote projects as machine + folder pairs and
an opt-in local mode that runs panes inside herdr-core instead of termy's own
PTY. Local PTY remains the default, and herdr-core is not required for the
behavior described above. The `Hc*.swift` files and
`docs/superpowers/specs/2026-11-01-herdr-core-backend-design.md` cover that
work.

## Known Limitations

- **Codex WAIT is heuristic.** There is no native notification hook; the
  silence detector trades instant feedback for a ~20 s delay and occasional
  false positives.
- **OpenCode coverage is partial.** Only the routed root session is tracked,
  background tabs are ignored, and sessions are not resumed after an update.
- **The foreground watcher is 1 Hz and process-name based.** A very short agent
  run can be missed, and pipelines such as `claude | tee` hide the agent.
- **`HookDaemon` lives in the app.** If termy crashes, hook events are dropped
  until the app is restarted; a separate LaunchAgent is deferred.
- **Project labels can collide.** Two unrelated repositories named `api` share
  one display label and filter pill; persistence still keys them separately by
  canonical path.
- **SwiftTerm is pinned to the 1.x fork.** Moving to 2.0 requires reworking
  `dataReceived`-based PTY activity, IME overlays, full-screen redraw, and
  scroll behavior; see `TODOS.md`.
- **Previews are Markdown/PDF only.** Other text and image formats are not
  rendered by termy.
- **Update resume is best-effort.** It requires a captured session id and safe
  flags; OpenCode is excluded, and panes without a session id restart as plain
  shells.

## Practical Entry Points

If you need to understand or modify behavior quickly, start here:

1. `apps/termy/Sources/PaneState.swift`
   State semantics and transitions.
2. `apps/termy/Sources/HookDaemon.swift`
   Event ingestion, timers, journaling, and update fan-out.
3. `apps/termy/Sources/MissionControlModel.swift`,
   `MissionControlView.swift`
   Dashboard ordering and presentation.
4. `apps/termy/Sources/Workspace.swift`,
   `MainWindowController.swift`, `WindowManager.swift`
   Pane lifecycle, layout, projects, filters, and multi-window behavior.
5. `apps/termy/Sources/Pane.swift`,
   `TermyTerminalView.swift`
   Shell spawning, PTY behavior, links, IME, mouse, and synthetic exits.
6. `apps/termy/Sources/HookInstaller.swift`,
   `CodexHookInstaller.swift`, `OpenCodePluginInstaller.swift`,
   `AntigravityHookInstaller.swift`
   Agent integration install/uninstall.
7. `apps/termy/Sources/PreviewManager.swift`,
   `PreviewLinkResolver.swift`, `PreviewFileWatcher.swift`
   Markdown/PDF preview routing and live updates.
8. `apps/termy/Sources/UpdateRelaunchGate.swift`,
   `AgentResume.swift`
   Update waiting and conversation resume.

## Documentation Map

- [`README.md`](../README.md) — product overview, download link, screenshots,
  shortcuts, and agent integration details
- [`CHANGELOG.md`](../CHANGELOG.md) — user-visible changes per release
- [`docs/auto-update.md`](./auto-update.md) — Sparkle setup, keys, appcast, and
  recovery
- [`docs/release-cycle.md`](./release-cycle.md) — operator checklist for
  cutting a release
- [`TODOS.md`](../TODOS.md) — deferred work and known follow-ups
- [`docs/superpowers/specs/`](./superpowers/specs/) — design documents for
  multi-window, previews, OpenCode, PDF, updates, and herdr-core
- [`docs/superpowers/plans/`](./superpowers/plans/) — implementation plans for
  the same features
