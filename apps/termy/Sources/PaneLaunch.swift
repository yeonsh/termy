import Foundation

// pane 하나의 프로세스가 어디서 도는가. local은 termy가 직접 띄운 PTY 셸(지금까지의 동작)이고, hc는
// herdr-core 안의 terminal에 attach한 viewer다(termy가 꺼져도 셸이 산다). hc에 machine이 있으면 원격 pane이다.
// 한 번 정해진 backend는 pane이 닫힐 때까지 바뀌지 않는다. 닫기·종료 규칙과 업데이트 gate가 이 값으로 갈린다.

enum PaneLaunch: Equatable, Sendable {
    case local
    case hc(machine: String?)

    var backendKind: PaneBackendKind {
        switch self {
        case .local: return .local
        case .hc: return .hc
        }
    }

    /// 원격 hc pane의 머신. local과 로컬 hc pane은 nil.
    var machine: String? {
        if case .hc(let machine) = self { return machine }
        return nil
    }
}

enum PaneBackendKind: String, Codable, Sendable {
    case local, hc
}
