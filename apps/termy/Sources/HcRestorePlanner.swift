import Foundation

// 복원 뒤 hc에 남은 고아 terminal을 찾는다. 자기 instance의 `termy.pane` label이 있는데 저장된 레이아웃에 없는
// 살아 있는 terminal(autosave 전에 termy가 꺼진 경우 등)은 보이는 pane이 없어서, 그 안에서 agent가 돌아도
// 사용자가 모른다. 그런 terminal을 pane으로 열어 붙이도록 `WindowManager.adoptHcOrphans`에 넘긴다.
// pane ↔ terminal 대응은 label이 기준이라 같은 paneId로 pane을 만들면 backend가 그 terminal을 찾아 붙는다.

struct HcOrphan: Equatable {
    let paneId: String
    let address: String
    /// 원격 terminal이면 그 머신(`bdpc01/t2` → `bdpc01`).
    let machine: String?
    /// `termy.project` label.
    let projectKey: String?
    let cwd: String?
}

enum HcRestorePlanner {
    /// `live`는 자기 instance의 termy terminal(`HcEventStore.termyTerminals`). 끝난 것과 pane label이 없는 것은
    /// 빼고, 같은 paneId는 하나만 연다(한 terminal에 pane이 둘이면 한쪽을 닫을 때 다른 쪽 셸도 끝난다).
    static func orphans(live: [HcTerminal], knownPaneIds: Set<String>) -> [HcOrphan] {
        var taken = knownPaneIds
        var result: [HcOrphan] = []
        for terminal in live where terminal.state == "live" {
            guard let paneId = terminal.labels["termy.pane"], !paneId.isEmpty, taken.insert(paneId).inserted else { continue }
            result.append(HcOrphan(paneId: paneId, address: terminal.address, machine: HcAddress.machine(of: terminal.address),
                                   projectKey: terminal.labels["termy.project"], cwd: terminal.cwd))
        }
        return result
    }

    /// 원격 고아의 project 표시 이름 `<folder basename>@<machine>`. folder는 project 키(`<machine>:<folder>`)에서,
    /// 없으면 terminal cwd에서 읽는다. local 고아는 nil(지금처럼 cwd로 정한다).
    static func projectId(for orphan: HcOrphan) -> String? {
        guard let machine = orphan.machine else { return nil }
        let prefix = machine + ":"
        let folder = orphan.projectKey.flatMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil }
            ?? orphan.cwd ?? "~"
        return RemoteProject.projectId(machine: machine, folder: folder)
    }
}
