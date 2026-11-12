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

/// 한 project의 분할 tree. 잎은 pane 기록이다.
struct ProjectLayoutRecord: Codable, Equatable {
    var projectId: String
    var root: PaneLayoutNode<PaneRecord>
}

/// One window's restorable state.
struct WindowRecord: Codable, Equatable {
    /// Window frame (screen coordinates) at save time. Restored frames are
    /// clamped to the visible screen area first — see `WindowManager`.
    var frame: FrameRecord
    /// 열 구조(`rows[i]`가 열 하나, 위에서 아래로). 새 빌드는 `layouts`를 열로 근사해 함께 쓴다 — 예전 빌드(Debug와
    /// release가 session.json을 함께 쓴다)가 이것만 읽어도 pane을 잃지 않게. 펼친 순서는 `layouts` 잎 읽는 순서와 같다.
    var rows: [[PaneRecord]]
    /// Active project filter: `nil` = `.all`, a value = `.project(id)`.
    var filterProjectId: String?
    /// 포커스된 pane의 index: 펼친 `rows` 순서(= `layoutTrees` 잎 읽는 순서).
    /// `nil` when the window had no focused pane.
    var focusedPaneIndex: Int?
    /// Project ids in the order the user dragged the titlebar chips into.
    /// `nil` on sessions saved before drag-reorder existed — restore then
    /// falls back to discovery order. Optional rather than a schema bump so
    /// older builds keep reading the file.
    var projectOrder: [String]?
    /// project마다 보이는 분할 tree(`knownProjectIds` 순서, 비율 포함). 이 필드 전의 파일은 nil이고 `rows`에서 만든다.
    /// 스키마 버전을 올리지 않으려고 optional이다.
    var layouts: [ProjectLayoutRecord]?

    init(
        frame: FrameRecord,
        rows: [[PaneRecord]],
        filterProjectId: String? = nil,
        focusedPaneIndex: Int? = nil,
        projectOrder: [String]? = nil,
        layouts: [ProjectLayoutRecord]? = nil
    ) {
        self.frame = frame
        self.rows = rows
        self.filterProjectId = filterProjectId
        self.focusedPaneIndex = focusedPaneIndex
        self.projectOrder = projectOrder
        self.layouts = layouts
    }

    /// 저장 경로가 쓰는 기록: `rows`는 project tree마다 열로 근사해 잇는다(펼친 순서 == 잎 읽는 순서).
    init(
        frame: FrameRecord,
        layouts: [ProjectLayoutRecord],
        filterProjectId: String? = nil,
        focusedPaneIndex: Int? = nil,
        projectOrder: [String]? = nil
    ) {
        self.init(frame: frame, rows: layouts.flatMap { $0.root.approximateColumns() },
                  filterProjectId: filterProjectId, focusedPaneIndex: focusedPaneIndex,
                  projectOrder: projectOrder, layouts: layouts)
    }

    /// 복원할 tree들. `layouts`가 있으면 그것만 믿고, 없으면(예전 파일) `rows`에서 만든 tree 하나(비율 균등).
    /// 잎을 이어 읽은 순서가 `focusedPaneIndex`의 순서다.
    var layoutTrees: [PaneLayoutNode<PaneRecord>] {
        if let layouts, !layouts.isEmpty { return layouts.map(\.root) }
        return PaneLayoutNode.fromColumns(rows).map { [$0] } ?? []
    }
}

extension WindowRecord {
    /// 이 termy(`instance`)가 복원할 창. Debug와 release는 session.json을 함께 쓰므로, 다른 instance가 남긴 hc pane을
    /// 복원하면 그 pane id의 terminal을 자기 label로 찾지 못해 같은 id로 셸을 또 띄우고 hook이 섞인다. 그런 pane은
    /// 빼고, 그 terminal은 그 instance가 다음에 켤 때 고아로 되찾는다. local pane과 instance가 없는 hc pane(이 필드
    /// 전의 파일)은 그대로다. 뺀 pane이 없으면 기록 그대로, 빼고 남은 pane이 없으면 nil(창을 열지 않는다).
    /// `layouts`에서도 같은 pane을 뺀다(빼기 규칙대로 정규화, 빈 tree는 버림). 순서를 지키며 빼므로 `rows`를 펼친 순서와
    /// 잎 읽는 순서는 계속 같다.
    func restorable(instance: String) -> WindowRecord? {
        func kept(_ pane: PaneRecord) -> Bool {
            pane.backend != .hc || pane.instance == nil || pane.instance == instance
        }
        let flat = rows.flatMap { $0 }
        let layoutLeaves = layouts?.flatMap { $0.root.leaves } ?? []
        guard !(flat.allSatisfy(kept) && layoutLeaves.allSatisfy(kept)) else { return self }
        var result = self
        result.rows = rows.map { $0.filter(kept) }.filter { !$0.isEmpty }
        result.layouts = layouts?.compactMap { layout in
            layout.root.removing(where: { !kept($0) }).map { ProjectLayoutRecord(projectId: layout.projectId, root: $0) }
        }
        let remaining = result.rows.flatMap { $0 }
        guard !remaining.isEmpty else { return nil }
        // 포커스는 같은 pane을 따라가고(그 pane을 뺐으면 없다), 필터의 project에 남은 pane이 없으면 빈 화면 대신 전체다.
        if let index = focusedPaneIndex, flat.indices.contains(index), kept(flat[index]) {
            result.focusedPaneIndex = flat[..<index].filter(kept).count
        } else {
            result.focusedPaneIndex = nil
        }
        if let projectId = filterProjectId, !remaining.contains(where: { $0.projectId == projectId }) {
            result.filterProjectId = nil
        }
        return result
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
