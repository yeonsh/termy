@testable import termy

/// 프로토타입 출력과 같은 모양: row(A:0.333,col(B:0.500,C:0.500):0.333,D:0.333)
func layoutSignature(_ node: PaneLayoutNode<String>) -> String {
    switch node {
    case .leaf(let id): return id
    case .split(let axis, let branches):
        let name = axis == .leftToRight ? "row" : "col"
        let inner = branches.map { "\(layoutSignature($0.node)):\(String(format: "%.3f", $0.weight))" }
        return "\(name)(\(inner.joined(separator: ",")))"
    }
}

/// 스펙 5.4의 기본 배치 `A | B/C | D` (열 셋 각 1/3).
func abcdLayout() -> PaneLayoutNode<String> {
    PaneLayoutNode.fromColumns([["A"], ["B", "C"], ["D"]])!
}
