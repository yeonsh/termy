# Filter Navigation History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the last pane of a project closes, restore the previously visited filter from a back-stack instead of falling back to `.all`.

**Architecture:** A new pure `FilterNavigationHistory` struct (mirrors `PaneFocusHistory`) lives in `Workspace.swift`. `Workspace.filter`'s `didSet` pushes the previous value onto the stack; `closePaneInternal`'s "no visible panes" branch pops the most recent still-valid entry. A `suppressFilterHistoryPush` flag prevents the close-fallback path from re-pushing the just-closed filter.

**Tech Stack:** Swift 6, AppKit, XCTest, xcodegen (`project.yml`).

---

## Spec

`docs/superpowers/specs/2026-04-28-filter-navigation-history-design.md`

## File Map

- **Modify:** `apps/termy/Sources/Workspace.swift`
  - Add `FilterNavigationHistory` struct next to `PaneFocusHistory` (around line 131).
  - Add `private var filterHistory` and `private var suppressFilterHistoryPush` to `Workspace`.
  - Modify `filter`'s `didSet` to push old value to history.
  - Modify `closePaneInternal`'s `visiblePanes.isEmpty` branch to pop history.
  - Modify `teardown(pane:)` to prune history when a project becomes empty.
- **Create:** `apps/termy-tests/Sources/FilterNavigationHistoryTests.swift`

No `project.yml` changes — `apps/termy/Sources` and `apps/termy-tests/Sources` are picked up by directory glob.

---

### Task 1: FilterNavigationHistory struct + tests (TDD)

**Files:**
- Modify: `apps/termy/Sources/Workspace.swift` (add struct around line 131)
- Create: `apps/termy-tests/Sources/FilterNavigationHistoryTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `apps/termy-tests/Sources/FilterNavigationHistoryTests.swift`:

```swift
import XCTest
@testable import termy

final class FilterNavigationHistoryTests: XCTestCase {
    func test_markVisited_dedupesPriorOccurrence() {
        var history = FilterNavigationHistory()
        history.markVisited(.project("a"))
        history.markVisited(.project("b"))
        history.markVisited(.project("a"))

        XCTAssertEqual(
            history.popMostRecentValid(in: [.project("a"), .project("b")]),
            .project("a")
        )
    }

    func test_popMostRecentValid_returnsAndRemovesNewestEntry() {
        var history = FilterNavigationHistory()
        history.markVisited(.project("a"))
        history.markVisited(.project("b"))

        XCTAssertEqual(
            history.popMostRecentValid(in: [.project("a"), .project("b")]),
            .project("b")
        )
        XCTAssertEqual(
            history.popMostRecentValid(in: [.project("a"), .project("b")]),
            .project("a")
        )
        XCTAssertNil(
            history.popMostRecentValid(in: [.project("a"), .project("b")])
        )
    }

    func test_popMostRecentValid_skipsAndPrunesEntriesNotInOptions() {
        var history = FilterNavigationHistory()
        history.markVisited(.project("a"))
        history.markVisited(.project("gone"))
        history.markVisited(.project("also-gone"))

        XCTAssertEqual(
            history.popMostRecentValid(in: [.project("a")]),
            .project("a")
        )
        XCTAssertNil(
            history.popMostRecentValid(in: [.project("a")])
        )
    }

    func test_popMostRecentValid_onEmptyHistoryReturnsNil() {
        var history = FilterNavigationHistory()
        XCTAssertNil(history.popMostRecentValid(in: [.all, .project("a")]))
    }

    func test_remove_deletesEveryOccurrence() {
        var history = FilterNavigationHistory()
        history.markVisited(.project("a"))
        history.markVisited(.project("b"))
        history.markVisited(.project("a")) // dedupes — only one "a" remains
        history.remove(.project("a"))

        XCTAssertEqual(
            history.popMostRecentValid(in: [.project("a"), .project("b")]),
            .project("b")
        )
    }

    func test_filterToRestore_fallsBackToFirstOptionWhenHistoryEmpty() {
        var history = FilterNavigationHistory()
        XCTAssertEqual(
            history.filterToRestore(in: [.all, .project("a")]),
            .all
        )
    }

    func test_filterToRestore_prefersHistoryOverFirstOption() {
        var history = FilterNavigationHistory()
        history.markVisited(.project("b"))
        XCTAssertEqual(
            history.filterToRestore(in: [.all, .project("a"), .project("b")]),
            .project("b")
        )
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme termy -destination 'platform=macOS' -only-testing:termy-tests/FilterNavigationHistoryTests 2>&1 | tail -30`

Expected: build failure — "cannot find 'FilterNavigationHistory' in scope".

- [ ] **Step 3: Implement the struct**

In `apps/termy/Sources/Workspace.swift`, immediately after the `PaneFocusHistory` struct (after the closing brace at line 131), add:

```swift
struct FilterNavigationHistory {
    private var filters: [WorkspaceFilter] = []

    mutating func markVisited(_ filter: WorkspaceFilter) {
        filters.removeAll { $0 == filter }
        filters.append(filter)
    }

    mutating func popMostRecentValid(in options: [WorkspaceFilter]) -> WorkspaceFilter? {
        while let last = filters.popLast() {
            if options.contains(last) {
                return last
            }
        }
        return nil
    }

    mutating func remove(_ filter: WorkspaceFilter) {
        filters.removeAll { $0 == filter }
    }

    mutating func filterToRestore(in options: [WorkspaceFilter]) -> WorkspaceFilter? {
        popMostRecentValid(in: options) ?? options.first
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme termy -destination 'platform=macOS' -only-testing:termy-tests/FilterNavigationHistoryTests 2>&1 | tail -30`

Expected: all 7 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/termy/Sources/Workspace.swift apps/termy-tests/Sources/FilterNavigationHistoryTests.swift
git commit -m "feat(workspace): add FilterNavigationHistory struct"
```

---

### Task 2: Wire history into Workspace.filter setter

**Files:**
- Modify: `apps/termy/Sources/Workspace.swift:139-152` (focusHistory area + filter didSet)

- [ ] **Step 1: Add stored properties**

In `apps/termy/Sources/Workspace.swift`, find the `private var focusHistory = PaneFocusHistory()` line (currently line 139). Immediately after it, add:

```swift
    private var filterHistory = FilterNavigationHistory()
    /// Set during the close-fallback path so the dying filter doesn't get
    /// pushed back onto `filterHistory` by the `filter` didSet.
    private var suppressFilterHistoryPush = false
```

- [ ] **Step 2: Push old filter onto history in didSet**

In `apps/termy/Sources/Workspace.swift`, modify the `filter` property (currently lines 142-152). The current code:

```swift
    var filter: WorkspaceFilter = .all {
        didSet {
            guard oldValue != filter else { return }
            // A filter change implicitly exits "single-pane focus" — if we
            // kept maximizedPane set, relayout() would still short-circuit to
            // [maximizedPane] and the user would see one pane under ALL.
            maximizedPane = nil
            relayout()
            onFilterChanged?()
        }
    }
```

Replace with:

```swift
    var filter: WorkspaceFilter = .all {
        didSet {
            guard oldValue != filter else { return }
            if !suppressFilterHistoryPush {
                filterHistory.markVisited(oldValue)
            }
            // A filter change implicitly exits "single-pane focus" — if we
            // kept maximizedPane set, relayout() would still short-circuit to
            // [maximizedPane] and the user would see one pane under ALL.
            maximizedPane = nil
            relayout()
            onFilterChanged?()
        }
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild build -scheme termy -destination 'platform=macOS' 2>&1 | tail -20`

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Re-run existing test suite to make sure nothing regressed**

Run: `xcodebuild test -scheme termy -destination 'platform=macOS' -only-testing:termy-tests/WorkspaceFilterOptionsTests -only-testing:termy-tests/WorkspacePersistenceTests -only-testing:termy-tests/FilterNavigationHistoryTests 2>&1 | tail -30`

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/termy/Sources/Workspace.swift
git commit -m "feat(workspace): record filter history on every filter change"
```

---

### Task 3: Replace close-fallback with history pop

**Files:**
- Modify: `apps/termy/Sources/Workspace.swift:392-398` (closePaneInternal visiblePanes.isEmpty branch)

- [ ] **Step 1: Modify closePaneInternal**

In `apps/termy/Sources/Workspace.swift`, find the `closePaneInternal` method's `wasFocused` branch (currently around lines 392-398). The current code:

```swift
        if wasFocused {
            // If the current filter no longer has any panes, fall back to .all.
            if visiblePanes.isEmpty {
                filter = .all
            } else {
                relayout()
            }
```

Replace with:

```swift
        if wasFocused {
            // If the current filter no longer has any panes, restore the
            // most recently visited still-valid filter (the project the
            // user was on before this one). Falls back to filterOptions.first
            // — which is `.all` when multiple projects remain, or the only
            // remaining project — and finally `.all` if nothing is left.
            if visiblePanes.isEmpty {
                let target = filterHistory.filterToRestore(in: filterOptions) ?? .all
                suppressFilterHistoryPush = true
                filter = target
                suppressFilterHistoryPush = false
            } else {
                relayout()
            }
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -scheme termy -destination 'platform=macOS' 2>&1 | tail -20`

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run filter and persistence tests to make sure nothing regressed**

Run: `xcodebuild test -scheme termy -destination 'platform=macOS' -only-testing:termy-tests/WorkspaceFilterOptionsTests -only-testing:termy-tests/WorkspacePersistenceTests -only-testing:termy-tests/FilterNavigationHistoryTests 2>&1 | tail -30`

Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add apps/termy/Sources/Workspace.swift
git commit -m "feat(workspace): restore prior filter when closing last pane of a project"
```

---

### Task 4: Prune dead projects from history in teardown

**Files:**
- Modify: `apps/termy/Sources/Workspace.swift:413-428` (teardown method)

- [ ] **Step 1: Modify teardown to prune history**

In `apps/termy/Sources/Workspace.swift`, find the `teardown` method. The current code:

```swift
    private func teardown(pane: Pane) {
        // Clear the shell-exit callback first — teardown calls terminate()
        // which fires processTerminated → onShellExited; we'd otherwise
        // recurse right back into closePane.
        pane.onShellExited = nil
        pane.terminal.process.terminate()
        pane.removeFromSuperview()
        if maximizedPane === pane { maximizedPane = nil }
        parkedPaneFrames.removeValue(forKey: ObjectIdentifier(pane))
        focusHistory.remove(pane.paneId)
        paneCreationOrder.removeAll { $0 === pane }
        for r in 0..<rows.count {
            rows[r].removeAll { $0 === pane }
        }
        rows.removeAll { $0.isEmpty }
    }
```

Replace with:

```swift
    private func teardown(pane: Pane) {
        // Clear the shell-exit callback first — teardown calls terminate()
        // which fires processTerminated → onShellExited; we'd otherwise
        // recurse right back into closePane.
        pane.onShellExited = nil
        pane.terminal.process.terminate()
        pane.removeFromSuperview()
        if maximizedPane === pane { maximizedPane = nil }
        parkedPaneFrames.removeValue(forKey: ObjectIdentifier(pane))
        focusHistory.remove(pane.paneId)
        let removedProjectId = pane.projectId
        paneCreationOrder.removeAll { $0 === pane }
        for r in 0..<rows.count {
            rows[r].removeAll { $0 === pane }
        }
        rows.removeAll { $0.isEmpty }
        if !paneCreationOrder.contains(where: { $0.projectId == removedProjectId }) {
            filterHistory.remove(.project(removedProjectId))
        }
    }
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -scheme termy -destination 'platform=macOS' 2>&1 | tail -20`

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run full test suite as a regression sweep**

Run: `xcodebuild test -scheme termy -destination 'platform=macOS' 2>&1 | tail -30`

Expected: all tests PASS.

- [ ] **Step 4: Commit**

```bash
git add apps/termy/Sources/Workspace.swift
git commit -m "feat(workspace): prune closed projects from filter history"
```

---

### Task 5: Manual smoke test

This step is a live verification — the project's CLAUDE.md guidance is that pane/filter UI changes need live testing because passing unit tests don't prove the wiring works.

**Files:**
- None modified.

- [ ] **Step 1: Build and launch the app**

Run: `xcodebuild build -scheme termy -destination 'platform=macOS' 2>&1 | tail -5 && open -a "$(xcodebuild -showBuildSettings -scheme termy -destination 'platform=macOS' 2>/dev/null | awk '/CONFIGURATION_BUILD_DIR/ {print $3}' | head -1)/termy.app"`

Expected: app launches with one pane.

- [ ] **Step 2: Set up three project filters**

Open three panes in three different project directories using `cd /path/to/projectA`, `cd /path/to/projectB`, `cd /path/to/projectC` (or `⌘D` to split, then `cd`). The titlebar filter bar should show `ALL | projectA | projectB | projectC`.

- [ ] **Step 3: Verify back-stack behavior**

Click `projectA` → `projectB` → `projectC` chips in order. Then close the last pane in `projectC` (focus it, `⌘W` or `exit`).

Expected: filter switches to `projectB`, **not** `.all`.

- [ ] **Step 4: Verify pruning of dead projects**

With panes still open in `projectA` and `projectB`, focused on `projectB`:
1. Click chips: `projectA` → `projectB`. (history now: `[projectA]`.)
2. Switch focus to `projectA`'s pane and close its last pane.
3. The `projectA` chip disappears.
4. Switch back to `projectB`'s last pane and close it.

Expected: filter falls back to `filterOptions.first` (whichever remains) — not stuck on the gone `projectA`.

- [ ] **Step 5: Verify empty-history fallback**

Restart the app. Open one pane in `projectA` only. Close that pane.

Expected: app stays open with an empty workspace; no crash.

- [ ] **Step 6: Verify `cd`-drift back-stack**

Open one pane in `projectA`. In that pane, run `cd /path/to/projectB`. Filter should auto-switch to `projectB`. Add a second pane in `projectB`. Close that second pane (focused). Filter stays on `projectB`. Close the remaining pane.

Expected: filter restores to `projectA` (because the `cd`-drift pushed `projectA` onto history), and since `projectA` itself has no panes anymore, falls through to `filterOptions.first` (or `.all` if multiple remain).

- [ ] **Step 7: If any step misbehaves, do NOT mark plan complete**

Investigate, fix, and re-test before considering the plan done.

---

## Self-Review (completed by plan author)

- **Spec coverage:**
  - "Walk back through history, skip filters whose project no longer exists" → Task 1's `popMostRecentValid` + Task 4's `teardown` prune.
  - "Fall back to filterOptions.first" → Task 1's `filterToRestore` + Task 3's `?? .all` tail.
  - "Manual filter changes push the previous filter" → Task 2's didSet push.
  - "Suppress flag for close-fallback path" → Task 3's `suppressFilterHistoryPush` toggle.
  - "Prune project from history when last pane closes" → Task 4.
  - All edge cases in spec table → covered by Task 1's tests + Task 5's manual smoke checks.

- **Placeholder scan:** No TBD/TODO. All code blocks complete. Test commands include exact `-only-testing:` targets.

- **Type consistency:** `WorkspaceFilter`, `FilterNavigationHistory`, `markVisited`, `popMostRecentValid`, `remove`, `filterToRestore`, `filterHistory`, `suppressFilterHistoryPush`, `filterOptions` — names are consistent across all tasks.

---

## Execution

Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration. Uses `superpowers:subagent-driven-development`.
2. **Inline Execution** — execute tasks in this session, batch with checkpoints. Uses `superpowers:executing-plans`.
