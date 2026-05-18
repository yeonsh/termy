// SessionRecord.swift
//
// On-disk schema for the full multi-window session — the set of windows
// open at quit time and each window's pane layout / frame / filter.
// Written by `SessionAutosaver`, read by `WindowManager` on launch.
// Schema-versioned like `WorkspaceRecord`: a newer-than-known file is
// quarantined by `SessionPersistence` rather than partially decoded.

import Foundation

struct SessionRecord: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var windows: [WindowRecord]

    init(schemaVersion: Int = Self.currentSchemaVersion, windows: [WindowRecord]) {
        self.schemaVersion = schemaVersion
        self.windows = windows
    }
}

/// One window's restorable state.
struct WindowRecord: Codable, Equatable {
    /// Window frame (screen coordinates) at save time. Restored frames are
    /// clamped to the visible screen area first — see `WindowManager`.
    var frame: FrameRecord
    /// Row-major pane grid: row 0 is the top row, each inner array a
    /// horizontal row of panes. Mirrors `Workspace.rows`.
    var rows: [[PaneRecord]]
    /// Active project filter: `nil` = `.all`, a value = `.project(id)`.
    var filterProjectId: String?
    /// Index of the focused pane into the flattened `rows` (creation order).
    /// `nil` when the window had no focused pane.
    var focusedPaneIndex: Int?

    init(
        frame: FrameRecord,
        rows: [[PaneRecord]],
        filterProjectId: String? = nil,
        focusedPaneIndex: Int? = nil
    ) {
        self.frame = frame
        self.rows = rows
        self.filterProjectId = filterProjectId
        self.focusedPaneIndex = focusedPaneIndex
    }
}

/// Plain-`Double` window frame. `CGRect` is Codable, but an explicit struct
/// keeps the JSON shape stable and human-readable.
struct FrameRecord: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.size.width)
        self.height = Double(rect.size.height)
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}
