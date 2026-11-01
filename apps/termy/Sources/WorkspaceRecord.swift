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
//
// 원격 project(머신 + 폴더)도 같은 v1 기록이다. `machine`이 있으면 원격이고, 키(`canonicalPath`)는
// `<machine>:<folder>`라 로컬 경로와 겹치지 않으며 `displayLabel`은 `<folder basename>@<machine>`이다.
// `machine`이 없는 예전 파일은 지금처럼 로컬 project다.

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
    /// 원격 project의 머신(hc `machine.list`의 이름). 로컬 project와 예전 파일은 nil.
    var machine: String?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        canonicalPath: String,
        displayLabel: String,
        updatedAt: Date = Date(),
        panes: [PaneRecord],
        rows: [[PaneRecord]]? = nil,
        machine: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.canonicalPath = canonicalPath
        self.displayLabel = displayLabel
        self.updatedAt = updatedAt
        self.panes = panes
        self.rows = rows
        self.machine = machine
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
    /// Agent session to resume in this pane. Written only by the
    /// update-relaunch save (`WindowManager.prepareForUpdateRelaunch`); nil
    /// in every other session save and in ⌘K workspace records, so the key
    /// is absent from those files.
    var agentResume: AgentResumeRecord? = nil

    // hc pane은 termy가 꺼져도 core 안에서 살아 있고 `termy.pane` label로 다시 찾는다. 그래서 pane id와 backend를
    // 남겨 같은 id로 복원한다. 아래 필드가 없는 예전 파일은 지금처럼 새 id의 local pane이 된다.
    /// 복원할 때 다시 쓰는 pane id(`TERMY_PANE_ID`, hc terminal의 `termy.pane` label).
    var paneId: String? = nil
    /// nil이면 local(예전 파일).
    var backend: PaneBackendKind? = nil
    /// 원격 hc pane의 머신. local과 로컬 hc pane은 nil.
    var machine: String? = nil
    var projectId: String? = nil
    /// hc terminal의 `termy.project` label(local은 worktree root, 원격은 `<machine>:<folder>`).
    var projectKey: String? = nil
    /// hc pane만: termy가 꺼진 동안 잃지 않게 남기는 hook 세부 정보.
    var hookDetails: PaneHookDetails? = nil

    /// 이 기록으로 만들 pane의 backend. hc를 쓸 수 없어도 local로 바꾸지 않는다(같은 pane id의 셸이 둘이 된다).
    var launch: PaneLaunch {
        backend == .hc ? .hc(machine: machine) : .local
    }
}

/// hc pane의 `PaneSnapshot` 가운데 다시 켰을 때 되살릴 hook 정보. 상태는 남기지 않는다: 켜진 뒤의 7501 status나
/// 다음 hook이 정한다.
struct PaneHookDetails: Codable, Equatable, Sendable {
    var lastSessionId: String?
    var lastPrompt: String?
    var lastAssistantMessage: String?
    var lastCwd: String?
    var agentKind: AgentKind?

    private enum CodingKeys: String, CodingKey {
        case lastSessionId, lastPrompt, lastAssistantMessage, lastCwd, agentKind
    }
}

extension PaneHookDetails {
    /// agentKind만 너그럽게 읽는다: 모르는 값(다른 빌드가 더한 agent)은 nil이다. Debug와 release가 session.json을
    /// 함께 쓰는데, 이 값 하나로 decode가 실패하면 SessionPersistence가 파일 전체를 격리해 모든 창 배치를 잃는다.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastSessionId = try c.decodeIfPresent(String.self, forKey: .lastSessionId)
        lastPrompt = try c.decodeIfPresent(String.self, forKey: .lastPrompt)
        lastAssistantMessage = try c.decodeIfPresent(String.self, forKey: .lastAssistantMessage)
        lastCwd = try c.decodeIfPresent(String.self, forKey: .lastCwd)
        agentKind = try c.decodeIfPresent(String.self, forKey: .agentKind).flatMap(AgentKind.init(rawValue:))
    }
}

extension PaneHookDetails {
    /// 남길 것이 없으면(snapshot이 없거나 hook이 한 번도 오지 않았으면) nil.
    init?(snapshot: PaneSnapshot?) {
        guard let snapshot else { return nil }
        let texts = [snapshot.lastSessionId, snapshot.lastPrompt, snapshot.lastAssistantMessage, snapshot.lastCwd]
        let defaultKind = PaneSnapshot.empty(paneId: snapshot.paneId, projectId: nil).agentKind
        guard texts.contains(where: { $0 != nil }) || snapshot.agentKind != defaultKind else { return nil }
        self.init(lastSessionId: snapshot.lastSessionId, lastPrompt: snapshot.lastPrompt,
                  lastAssistantMessage: snapshot.lastAssistantMessage, lastCwd: snapshot.lastCwd,
                  agentKind: snapshot.agentKind)
    }
}
