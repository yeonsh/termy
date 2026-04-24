// WorkspaceRecord.swift
//
// On-disk schema for per-project pane layouts. Written by
// `WorkspacePersistence` on mutation, read by the ⌘K project switcher when
// restoring a project with no alive panes. Schema-versioned so future
// changes to the shape survive downgrades: when code encounters a newer
// version than it understands, the file is quarantined and the project
// starts fresh rather than corrupting state with a partial decode.
//
// Schema version 1 (initial):
//   * canonicalPath — full symlink-resolved worktree root; the persistence key
//   * displayLabel   — basename (for ⌘K row display only)
//   * updatedAt      — last mutation timestamp; drives ⌘K row sort order
//   * panes[]        — ordered list of panes in creation order (matches the
//                      current Workspace.swift pane-grid semantics)
//
// Not yet in schema v1 (deferred with explicit nil/optional shapes so we
// can add them without a version bump):
//   * pane geometry (width/height ratios for multi-pane split restore)
//   * last-focused pane ID
//
// Both can be added as optional fields in a later commit once Workspace.swift
// carries enough structure to serialize them.

import Foundation

struct WorkspaceRecord: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var canonicalPath: String
    var displayLabel: String
    var updatedAt: Date
    /// Flat list of every pane in the workspace. Preserved alongside `rows`
    /// so older code (or hand-edited files) still round-trip without loss.
    var panes: [PaneRecord]
    /// Ordered row structure — row 0 is the top row of the grid, each inner
    /// array is a horizontal row of panes. Optional for backward compat with
    /// v1 records that only had `panes`; restore infers a single-row layout
    /// (all column splits) when this is missing.
    var rows: [[PaneRecord]]?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        canonicalPath: String,
        displayLabel: String,
        updatedAt: Date = Date(),
        panes: [PaneRecord],
        rows: [[PaneRecord]]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.canonicalPath = canonicalPath
        self.displayLabel = displayLabel
        self.updatedAt = updatedAt
        self.panes = panes
        self.rows = rows
    }

    /// Effective grid layout: prefer the structured `rows` when present,
    /// else wrap the flat `panes` list as a single horizontal row. Callers
    /// restoring a workspace should always use this — not `panes` directly.
    var effectiveRows: [[PaneRecord]] {
        if let rows, !rows.isEmpty { return rows }
        return panes.isEmpty ? [] : [panes]
    }
}

struct PaneRecord: Codable, Equatable {
    /// Last-known cwd of the pane. Stored as an absolute path; restore falls
    /// back to `$HOME` if the folder no longer exists at restore time.
    var cwd: String
}
