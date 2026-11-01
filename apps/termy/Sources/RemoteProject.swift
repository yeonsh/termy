import Foundation

// 원격 project는 머신 + 폴더다(spec §6.8). 그 pane은 늘 그 머신의 hc terminal이고, project는 만들 때 정한 값으로
// 고정이다(`cd`해도 바뀌지 않는다). ⌘K 기록의 키는 `<machine>:<folder>`라 로컬 경로와 겹치지 않고, 표시 이름은
// `<folder basename>@<machine>`이다. 같은 키는 hc terminal의 `termy.project` label이 된다.
// 머신을 고르는 목록은 그 머신의 줄 상태를 보여 준다. Windows 머신은 1차에서 뺀다: ConPTY가 요구하는
// win32-input-mode(`CSI ?9001h`)로 키를 인코딩하는 코드가 SwiftTerm에 없다.

enum RemoteProject {
    static func key(machine: String, folder: String) -> String {
        "\(machine):\(folder)"
    }

    static func projectId(machine: String, folder: String) -> String {
        "\((folder as NSString).lastPathComponent)@\(machine)"
    }

    /// 새 원격 project의 ⌘K 기록. 그 폴더의 hc pane 하나로 시작한다.
    static func record(machine: String, folder: String, now: Date) -> WorkspaceRecord {
        let key = key(machine: machine, folder: folder)
        let projectId = projectId(machine: machine, folder: folder)
        return WorkspaceRecord(
            schemaVersion: WorkspaceRecord.currentSchemaVersion, canonicalPath: key, displayLabel: projectId,
            updatedAt: now,
            panes: [PaneRecord(cwd: folder, backend: .hc, machine: machine, projectId: projectId, projectKey: key)],
            rows: nil, machine: machine)
    }

    /// 머신 목록 한 줄. enabled는 그 머신에 project를 만들 수 있는지다(연결돼 있고 Windows가 아니다).
    static func machineLabel(_ m: HcMachine, isWindows: Bool) -> (title: String, enabled: Bool) {
        if isWindows { return (m.name + " (Windows not supported)", false) }
        switch m.state {
        case "connected": return (m.name, true)
        case "needs_login": return (m.name + " (needs login)", false)
        case "unreachable": return (m.name + " (unreachable)", false)
        case "connecting": return (m.name + " (connecting)", false)
        default: return (m.name, false)
        }
    }

    static func loginHint(machine: String) -> String {
        "Run `hc machine login \(machine)` in a terminal, then try again."
    }

    static func folderNotFound(machine: String) -> String {
        "Folder not found on \(machine)."
    }

    /// 입력한 폴더를 키로 쓸 모양으로 다듬는다: 앞뒤 공백과 끝의 `/`를 뗀다. 절대 경로가 아니면 nil이다.
    /// 폴더는 셸 없이(`machine.exec` argv) 확인하므로 `~`는 펼쳐지지 않고, 상대 경로는 어디 기준인지 정해져 있지 않다.
    static func normalizedFolder(_ input: String) -> String? {
        var folder = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard folder.hasPrefix("/") else { return nil }
        while folder.count > 1, folder.hasSuffix("/") { folder.removeLast() }
        return folder
    }

    /// `uname` 결과로 Windows인지와 그 판정을 기억해도 되는지. 0이 아니거나 호출이 실패하면 Windows로 본다.
    /// 기억은 머신이 답한 것(스스로 끝나 낸 exit code, 실행 실패 `spawn_failed`)만 한다. 줄이 잠깐 끊겨 실패했거나
    /// 느린 머신에서 시간이 다 돼(또는 signal로) 끝난 것까지 기억하면, 멀쩡한 머신을 앱을 다시 켤 때까지 고를 수 없다.
    static func windowsVerdict(_ result: Result<HcExecResult, any Error>) -> (isWindows: Bool, cache: Bool) {
        switch result {
        case .success(let run):
            guard let code = run.exitCode else { return (true, false) }
            return (code != 0, true)
        case .failure(HcError.rpc(kind: "spawn_failed", _)):
            return (true, true)
        case .failure:
            return (true, false)
        }
    }

    /// ⌘K로 다시 여는 기록의 pane. 원격 기록이면 그 머신의 hc pane으로, project는 기록의 것으로 단다(원격 폴더는
    /// 이 Mac에 없어 cwd로 정할 수 없다). 로컬 기록은 그대로다.
    static func reopenedPane(_ pane: PaneRecord, in record: WorkspaceRecord) -> PaneRecord {
        guard let machine = record.machine else { return pane }
        var remote = pane
        remote.backend = .hc
        remote.machine = machine
        remote.projectId = record.displayLabel
        remote.projectKey = record.canonicalPath
        return remote
    }
}
