# termy Project Overview

## Summary

`termy` is a native macOS terminal for running multiple Claude Code agents in
parallel and surfacing their live status in a mission-control bar. The current
repository already contains a working app scaffold, a Claude Code hook bridge,
and unit tests for the pane state machine.

The root `README.md` still says `pre-scaffold`, but the source tree is already
beyond that stage. In practice, the repo contains:

- a macOS AppKit app target with SwiftUI used for the mission-control strip
- a small helper CLI invoked by Claude Code hooks
- a unit-test target covering the pane state machine

## Tech Stack

- Language: Swift
- Platform: macOS 14+
- UI: AppKit + SwiftUI
- Terminal renderer / PTY host: `SwiftTerm`
- Project format: Xcode project (`termy.xcodeproj`)
- Package dependency: `SwiftTerm` from `https://github.com/migueldeicaza/SwiftTerm`

## Repository Layout

### App target

- `apps/termy/Sources/AppDelegate.swift`
  App entry point. Sets up the menu bar, starts `HookDaemon`, creates the main
  window, and shows the Full Disk Access prompt on first launch.
- `apps/termy/Sources/MainWindowController.swift`
  Owns the main window, the mission-control bar, the workspace grid, and the
  titlebar project filter.
- `apps/termy/Sources/Workspace.swift`
  Manages all panes in one window, including split layout, focus movement,
  maximize/restore, close behavior, and project-based filtering.
- `apps/termy/Sources/Pane.swift`
  Wraps one terminal pane. Starts a login shell through `SwiftTerm`, injects
  `TERMY_PANE_ID` and `TERMY_PROJECT_ID`, tracks cwd changes, and posts
  synthetic `PtyExit` events when the child process exits.
- `apps/termy/Sources/MissionControlModel.swift`
  Subscribes to daemon updates and produces a sorted snapshot list for UI.
- `apps/termy/Sources/MissionControlView.swift`
  Renders the top mission-control strip showing per-pane state and attention.
- `apps/termy/Sources/HookDaemon.swift`
  Actor-backed event collector. Owns the Unix-domain socket, applies the state
  machine, journals events, and streams updates to the UI.
- `apps/termy/Sources/HookEvent.swift`
  Defines the compact wire format exchanged over the local socket.
- `apps/termy/Sources/PaneState.swift`
  Defines `PaneState`, `PaneSnapshot`, and the pure state transition function.
- `apps/termy/Sources/ProjectFilterBar.swift`
  Toolbar segmented control for filtering panes by project.
- `apps/termy/Sources/GitBranch.swift`
  Lightweight git branch / worktree lookup for pane headers.
- `apps/termy/Sources/FullDiskAccess.swift`
  Handles Full Disk Access prompting and deep-linking to macOS settings.

### Hook helper target

- `apps/termy-hook/Sources/main.swift`
  Tiny CLI invoked by Claude Code hooks. Reads the hook event name from argv,
  reads JSON from stdin, slims the payload, and writes one JSON line to the
  app daemon over `/tmp/termy-$UID.sock`. It is intentionally best-effort and
  always exits `0` so it cannot stall Claude Code.

### Test target

- `apps/termy-tests/Sources/PaneStateMachineTests.swift`
  Unit coverage for the pane state machine, including happy-path transitions,
  error transitions, notifications, `AskUserQuestion`, session resets, and
  timestamp updates.

## Runtime Architecture

The runtime loop is:

1. The app launches and starts `HookDaemon`.
2. Each pane starts a login shell through `SwiftTerm`.
3. The shell environment includes `TERMY_PANE_ID` and `TERMY_PROJECT_ID`.
4. Claude Code hook configuration invokes `termy-hook`.
5. `termy-hook` sends slimmed hook events to the local Unix socket.
6. `HookDaemon` decodes events, applies `PaneStateMachine`, updates per-pane
   snapshots, journals the raw event, and emits a `DaemonUpdate`.
7. `MissionControlModel` consumes those updates and recomputes dashboard items.
8. `MissionControlView` renders the sorted chips and routes clicks back to the
   target pane.
9. If a pane process exits, `Pane.processTerminated` emits a synthetic
   `PtyExit` event so crash / exit state still goes through the same state
   machine path.

## Core Concepts

### Pane states

The app tracks one snapshot per pane. Main states are:

- `INIT`
- `THINKING`
- `WAITING`
- `IDLE`
- `ERRORED`

`needsAttention` is an overlay flag independent of the base state. That lets
the UI distinguish "Claude is waiting on me" from "Claude is doing work but a
notification or prompt still needs to be surfaced."

### Mission-control ordering

Dashboard items are intentionally sorted by urgency:

1. `WAITING`
2. `ERRORED`
3. any pane with `needsAttention`
4. `IDLE`
5. `THINKING`
6. `INIT` is hidden unless attention is set

This keeps the bar focused on panes that require user action first.

### Workspace model

The main window is not tab-based. It is a single workspace made of nested
`NSSplitView` layouts:

- outer vertical split for rows
- inner horizontal splits for panes within each row
- one project filter controlling which panes are visible
- one maximize mode that temporarily shows only the focused pane

Project identity is derived from the current git worktree root when possible.
Pane headers and filter segments both use that project identity.

### Hook system constraints

Durable findings about Claude Code's hook surface that shape the architecture:

- **Config lives in `~/.claude/settings.json`**, not `hooks.json`. Schema is
  nested matcher blocks:
  ```jsonc
  { "hooks": {
      "PreToolUse": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "..." }] }],
      "Stop":       [{               "hooks": [{ "type": "command", "command": "..." }] }]
  } }
  ```
- **Hard crashes (Ctrl+C mid-response, SIGKILL) fire no hook event** — not
  `Stop`, not `SessionEnd`, not `Error`. `ERRORED` therefore cannot be driven
  by hooks. `Pane.processTerminated` emits a synthetic `PtyExit` event on pty
  EOF with `exit_code != 0` as the sole crash signal.
- **`PostToolUseFailure` is not a reliable `ERRORED` signal.** It fires on
  routine tool errors (missing file, empty glob, Bash exit 1) that Claude
  recovers from within the same turn. Only `StopFailure` and `PtyExit` drive
  `ERRORED`. See `PaneState.swift` for the transition table.
- **Login-shell init preserves env.** `zsh -l` and `bash -l` both carry
  `TERMY_PANE_ID` / `TERMY_PROJECT_ID` through shell startup, so pty spawn
  with an explicit environment is sound.
- **`UserPromptSubmit` fires in `--print` mode too**, not only interactive —
  `claude --print "..."` still produces the full event stream.

The canonical event set is defined in `HookEvent.swift`; treat the code as the
source of truth, since CC's event surface has changed across versions.

## Current Product Surface

What is already implemented:

- one macOS window with a mission-control strip at the top
- multi-pane terminal workspace
- project-aware pane grouping and filtering
- per-pane header showing project and branch
- daemon-backed live state updates
- journaling of events to Application Support
- first-run Full Disk Access guidance
- unit tests for the state machine

What appears intentionally deferred or still thin:

- no broader docs beyond this overview and the root README
- no higher-level project switching beyond current pane/filter mechanics
- no explicit packaging, release, or CI documentation in-repo

## Notable Files Outside the Main App Loop

- `README.md`
  High-level product statement, but currently stale versus the actual source
  tree because it still describes the repo as `pre-scaffold`.
- `apps/termy/Info.plist`
  Bundle metadata. Current app version is `0.1.0` and minimum macOS version is
  `14.0`.

## Risks and Open Questions

- `xcodebuild test -scheme termy -destination 'platform=macOS'` currently
  passes, but it emits Auto Layout warnings around the titlebar filter UI
  (`ProjectFilterBar` / `FilterAccessoryContainer`).
- Verification commands that resolve Swift packages may require access to cache
  directories outside the workspace, which can fail under a sandboxed agent
  environment.

## Practical Entry Points

If you need to understand or modify behavior quickly, start here:

1. `apps/termy/Sources/PaneState.swift`
   State semantics and transitions.
2. `apps/termy/Sources/HookDaemon.swift`
   Event ingestion, journaling, and update fan-out.
3. `apps/termy/Sources/Workspace.swift`
   Pane lifecycle and layout behavior.
4. `apps/termy/Sources/Pane.swift`
   Terminal spawning, cwd tracking, and synthetic exit events.
5. `apps/termy/Sources/MissionControlView.swift`
   User-visible dashboard presentation.

## Suggested Next Documentation

The next useful docs to add would be:

- a build/run guide for the Xcode targets
- a concise Claude Code hook installation guide for local development
- an architecture decision note reconciling the current hook error model
- a roadmap or scope note matching the implemented Weekend 1/2/3 milestones
