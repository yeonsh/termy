# Filter Navigation History — Design

## Goal

When the last pane of a project closes (i.e. the project is "closed"), switch
the workspace filter to the **previously visited** project filter instead of
the current fallback `.all`. Users navigating between project filters
build up a back-stack and pop it on close — the same mental model as a
browser's back button.

## Status quo

- `Workspace.filter: WorkspaceFilter` is `.all` or `.project(id)`.
- All filter changes flow through one setter (`filter = …`) whose `didSet`
  triggers `relayout()` and `onFilterChanged?()`.
- Filter changes originate from:
  - `ProjectFilterBar.buttonClicked` (titlebar chips)
  - `Workspace.cycleFilter` (`⌘⇧[` / `⌘⇧]`)
  - `Workspace.selectAllFilter` / `selectProjectFilter` (number keys)
  - `Workspace.focus(pane:)` widening when target is filtered out
  - `Workspace.handlePaneProjectChanged` follow-on after `cd` drift
- When `closePaneInternal` removes the last pane belonging to the current
  filter, the existing branch sets `filter = .all`
  (`Workspace.swift:393–395`).

There is no explicit "close project" action — closing the last pane in a
project equates to closing the project.

## Behavior change

When the visible pane set becomes empty after a close:

1. Walk the filter back-stack from newest to oldest.
2. Skip (and prune) any entry whose project no longer exists in
   `knownProjectIds`.
3. The first surviving entry becomes the new filter.
4. If no entry survives, fall back to `filterOptions.first ?? .all`. This
   preserves the current `.all`-fallback when the workspace still holds
   multiple projects, and naturally picks the sole remaining
   `.project(id)` when the single-project rule hides `.all`.

Manual filter changes (chip click, cycle, number-key shortcut, dashboard
jump, `cd` drift follow-on) all push the **previous** filter onto the
back-stack. Repeated visits dedupe to the most recent position.

## Components

### `FilterNavigationHistory` (new struct, `Workspace.swift`)

Mirrors the existing `PaneFocusHistory` pattern.

```swift
struct FilterNavigationHistory {
    private var filters: [WorkspaceFilter] = []

    mutating func markVisited(_ filter: WorkspaceFilter)
    mutating func popMostRecentValid(in options: [WorkspaceFilter]) -> WorkspaceFilter?
    mutating func remove(_ filter: WorkspaceFilter)
}
```

- `markVisited` removes any prior occurrence of the same filter, then
  appends — so the stack stays deduped and the most recent visit is last.
- `popMostRecentValid` walks from the end. Each entry not contained in
  `options` is dropped from the stack and the walk continues. The first
  contained entry is removed and returned.
- `remove` deletes all occurrences (used for explicit pruning when a
  project disappears).

### `Workspace` integration

- New stored property `private var filterHistory = FilterNavigationHistory()`.
- New flag `private var suppressFilterHistoryPush = false` for the
  close-fallback path.
- `filter` `didSet`: after the existing
  `guard oldValue != filter else { return }`, push `oldValue` unless the
  flag is set:
  ```swift
  if !suppressFilterHistoryPush {
      filterHistory.markVisited(oldValue)
  }
  ```
- `closePaneInternal`, replace
  ```swift
  if visiblePanes.isEmpty {
      filter = .all
  } else {
      relayout()
  }
  ```
  with
  ```swift
  if visiblePanes.isEmpty {
      let target = filterHistory.popMostRecentValid(in: filterOptions)
          ?? filterOptions.first
          ?? .all
      suppressFilterHistoryPush = true
      filter = target
      suppressFilterHistoryPush = false
  } else {
      relayout()
  }
  ```
- `teardown(pane:)`: after the pane is removed and `paneCreationOrder`
  / `rows` are updated, if the closed pane was the last of its project
  call `filterHistory.remove(.project(projectId))`. This is purely a
  cleanliness pass — `popMostRecentValid` is already robust to stale
  entries.

### Unchanged

- `handlePaneProjectChanged` keeps current behavior; its `filter = …` calls
  flow through `didSet` and push the previous filter to history. `cd` drift
  reads as navigation, so it's back-able.
- All other filter-change call sites: nothing to change. They go through
  `filter = …` and pick up history pushes for free.

## Edge cases

| Scenario | Result |
|---|---|
| User clicks the same chip twice | `didSet`'s `guard oldValue != filter` returns early; no history push. |
| Visit A → B → C, close last pane of C | History `[A, B]`, pop B → filter becomes B. New history `[A]`. The (now invalid) entry `C` is never pushed because the close path uses the suppress flag. |
| Visit A → B → C, close A's last pane while on C | A pruned via `teardown`'s `remove`; on closing C, pop most recent valid → B (skipping nothing, since A already pruned). |
| Single project remaining; close its last pane | `panes.isEmpty` early return at top of `closePaneInternal` fires before the visible-empty branch. No filter change needed. |
| Empty history, close last pane of only filter that has panes | History pop returns nil → fallback to `filterOptions.first ?? .all`. With multiple projects this is `.all`; with one remaining project it's `.project(id)`. |
| User invokes `cd` and drifts a pane to a new project, ending up at a different filter | History records the previous filter (via normal `didSet` push). Close-fallback can still walk back. |

## Testing (`apps/termy-tests/Sources/`)

### `FilterNavigationHistoryTests` (new file)

- `markVisited` dedupes a prior occurrence and appends to the end.
- `popMostRecentValid` returns and removes the most recent entry that
  exists in the supplied options.
- `popMostRecentValid` skips and prunes entries not in the options, then
  returns the next valid one.
- Pop on empty history returns `nil`.
- `remove` deletes every occurrence of a given filter.

### `WorkspaceTests` (extend existing test target if present, else add a new file)

- Visit projects A → B → C through the filter setter, close the last
  pane of C, assert filter is `.project(B)`.
- Visit A → B → C, separately close A's last pane (no panes left in A),
  then close last pane of C, assert filter is `.project(B)` and history
  no longer contains A.
- Close last pane while history is empty, assert filter falls back to
  `filterOptions.first` (or `.all` when multiple projects remain, or
  `.project(remaining)` when only one project survives).

## Out of scope

- A user-facing "Forward" navigation. Browsers maintain forward stacks; we
  intentionally don't, because the trigger here is "project closed" — there
  is nothing to redo.
- Persisting history across app restarts. The stack is in-memory; the
  user's first close after relaunch falls back to
  `filterOptions.first`.
- Adding a UI-visible back-stack indicator. The behavior is implicit; if
  later UX research shows users want it surfaced, that's a follow-up.
