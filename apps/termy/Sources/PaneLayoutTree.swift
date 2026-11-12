import Foundation

/// 분할 방향. leftToRight = 좌우로 늘어놓음(NSSplitView `isVertical = true`), topToBottom = 위아래로 쌓음.
enum PaneLayoutAxis: String, Codable, Sendable {
    case leftToRight, topToBottom
}

enum PaneEdge: String, Sendable {
    case left, right, top, bottom

    var axis: PaneLayoutAxis {
        switch self {
        case .left, .right: return .leftToRight
        case .top, .bottom: return .topToBottom
        }
    }

    var isLeading: Bool { self == .left || self == .top }
}

/// pane 배치용 분할 tree. UI와 무관한 값 타입이다.
indirect enum PaneLayoutNode<Leaf> {
    case leaf(Leaf)
    case split(PaneLayoutAxis, [PaneLayoutBranch<Leaf>])
}

struct PaneLayoutBranch<Leaf> {
    var node: PaneLayoutNode<Leaf>
    var weight: Double
}

extension PaneLayoutNode: Equatable where Leaf: Equatable {}
extension PaneLayoutBranch: Equatable where Leaf: Equatable {}
extension PaneLayoutNode: Sendable where Leaf: Sendable {}
extension PaneLayoutBranch: Sendable where Leaf: Sendable {}
extension PaneLayoutBranch: Codable where Leaf: Codable {}

extension PaneLayoutNode: Codable where Leaf: Codable {
    private enum CodingKeys: String, CodingKey { case pane, axis, children }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.pane) {
            self = .leaf(try c.decode(Leaf.self, forKey: .pane))
        } else {
            self = .split(try c.decode(PaneLayoutAxis.self, forKey: .axis),
                          try c.decode([PaneLayoutBranch<Leaf>].self, forKey: .children))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let leaf):
            try c.encode(leaf, forKey: .pane)
        case .split(let axis, let children):
            try c.encode(axis, forKey: .axis)
            try c.encode(children, forKey: .children)
        }
    }
}

enum PaneLayoutMove<Leaf> {
    case besideLeaf(Leaf, PaneEdge)
    case intoSplit(path: [Int], before: Int)
    case outerEdge(PaneEdge)
    case swap(with: Leaf)
}

extension PaneLayoutMove: Equatable where Leaf: Equatable {}

private enum PaneLayoutSlot<Leaf>: Equatable where Leaf: Equatable {
    case existing(Leaf)
    case placeholder
}

// MARK: - Generic operations

extension PaneLayoutNode {
    /// 읽는 순서(깊이 우선, 자식 순서대로).
    var leaves: [Leaf] {
        switch self {
        case .leaf(let leaf): return [leaf]
        case .split(_, let branches): return branches.flatMap { $0.node.leaves }
        }
    }

    /// transform을 읽는 순서대로 부른다.
    func map<T>(_ transform: (Leaf) throws -> T) rethrows -> PaneLayoutNode<T> {
        switch self {
        case .leaf(let leaf):
            return .leaf(try transform(leaf))
        case .split(let axis, let branches):
            var mapped: [PaneLayoutBranch<T>] = []
            for branch in branches {
                mapped.append(.init(node: try branch.node.map(transform), weight: branch.weight))
            }
            return .split(axis, mapped)
        }
    }

    /// 남는 잎이 없으면 nil. 결과는 정규화돼 있다.
    func removing(where shouldRemove: (Leaf) -> Bool) -> PaneLayoutNode? {
        removedRaw(shouldRemove)?.normalized()
    }

    private func removedRaw(_ shouldRemove: (Leaf) -> Bool) -> PaneLayoutNode? {
        switch self {
        case .leaf(let leaf):
            return shouldRemove(leaf) ? nil : self
        case .split(let axis, let branches):
            let kept = branches.compactMap { branch -> PaneLayoutBranch<Leaf>? in
                branch.node.removedRaw(shouldRemove).map { .init(node: $0, weight: branch.weight) }
            }
            return kept.isEmpty ? nil : .split(axis, kept)
        }
    }

    /// 자식 하나인 split은 그 자식으로, 같은 방향 자식 split은 펼침(비율 곱), 비율 합 1.
    func normalized() -> PaneLayoutNode {
        guard case .split(let axis, let branches) = self else { return self }
        var flat: [PaneLayoutBranch<Leaf>] = []
        for branch in branches {
            let child = branch.node.normalized()
            if case .split(let childAxis, let grand) = child, childAxis == axis {
                flat.append(contentsOf: grand.map { .init(node: $0.node, weight: $0.weight * branch.weight) })
            } else {
                flat.append(.init(node: child, weight: branch.weight))
            }
        }
        if flat.count == 1 { return flat[0].node }
        return .split(axis, Self.normalizedWeights(flat))
    }

    private static func normalizedWeights(_ branches: [PaneLayoutBranch<Leaf>]) -> [PaneLayoutBranch<Leaf>] {
        let total = branches.reduce(0) { $0 + $1.weight }
        guard total > 0 else {
            return branches.map { .init(node: $0.node, weight: 1 / Double(branches.count)) }
        }
        return branches.map { .init(node: $0.node, weight: $0.weight / total) }
    }

    /// path는 root부터 자식 index. 합 1로 맞춘다. path가 split을 가리키지 않거나 개수가 다르면 그대로.
    func settingWeights(_ weights: [Double], atSplitPath path: [Int]) -> PaneLayoutNode {
        guard case .split(let axis, let branches) = self else { return self }
        if let first = path.first {
            guard branches.indices.contains(first) else { return self }
            var copy = branches
            copy[first].node = copy[first].node.settingWeights(weights, atSplitPath: Array(path.dropFirst()))
            return .split(axis, copy)
        }
        guard weights.count == branches.count else { return self }
        let updated = zip(branches, weights).map { PaneLayoutBranch(node: $0.node, weight: $1) }
        return .split(axis, Self.normalizedWeights(updated))
    }

    /// 빈 열은 버리고 균등 비율. 열 하나면 그 열(잎 하나면 잎).
    static func fromColumns(_ columns: [[Leaf]]) -> PaneLayoutNode? {
        let nodes: [PaneLayoutNode] = columns.filter { !$0.isEmpty }.map { column in
            column.count == 1 ? .leaf(column[0]) : equalSplit(.topToBottom, column.map { .leaf($0) })
        }
        switch nodes.count {
        case 0: return nil
        case 1: return nodes[0]
        default: return equalSplit(.leftToRight, nodes)
        }
    }

    private static func equalSplit(_ axis: PaneLayoutAxis, _ nodes: [PaneLayoutNode]) -> PaneLayoutNode {
        let weight = 1 / Double(nodes.count)
        return .split(axis, nodes.map { .init(node: $0, weight: weight) })
    }

    /// root가 leftToRight split이면 자식마다 한 열, 아니면 `[leaves]`. 펼치면 언제나 `leaves`와 같다.
    func approximateColumns() -> [[Leaf]] {
        if case .split(.leftToRight, let branches) = self {
            return branches.map { $0.node.leaves }
        }
        return [leaves]
    }
}

// MARK: - Equatable operations

extension PaneLayoutNode where Leaf: Equatable {
    func contains(_ leaf: Leaf) -> Bool { leaves.contains(leaf) }

    /// target의 가장자리에 new를 붙인다. 같은 방향 부모면 target의 몫을 반으로 나누고, 아니면 target 자리를 0.5/0.5 split으로 바꾼다.
    func splitting(_ target: Leaf, edge: PaneEdge, with new: Leaf) -> PaneLayoutNode {
        switch self {
        case .leaf(let leaf):
            guard leaf == target else { return self }
            let pair: [PaneLayoutNode] = edge.isLeading ? [.leaf(new), .leaf(leaf)] : [.leaf(leaf), .leaf(new)]
            return .split(edge.axis, pair.map { .init(node: $0, weight: 0.5) })
        case .split(let axis, let branches):
            var result: [PaneLayoutBranch<Leaf>] = []
            for branch in branches {
                if axis == edge.axis, case .leaf(let leaf) = branch.node, leaf == target {
                    let half = branch.weight / 2
                    let targetBranch = PaneLayoutBranch(node: branch.node, weight: half)
                    let newBranch = PaneLayoutBranch(node: PaneLayoutNode.leaf(new), weight: half)
                    result.append(contentsOf: edge.isLeading ? [newBranch, targetBranch] : [targetBranch, newBranch])
                } else {
                    result.append(.init(node: branch.node.splitting(target, edge: edge, with: new), weight: branch.weight))
                }
            }
            return .split(axis, result)
        }
    }

    /// path가 가리키는 split의 index 앞에 끼운다. 새 잎은 1/(n+1), 형제는 n/(n+1)배. path가 split이 아니면 그대로.
    func inserting(_ new: Leaf, intoSplitAt path: [Int], before index: Int) -> PaneLayoutNode {
        guard case .split(let axis, let branches) = self else { return self }
        if let first = path.first {
            guard branches.indices.contains(first) else { return self }
            var copy = branches
            copy[first].node = copy[first].node.inserting(new, intoSplitAt: Array(path.dropFirst()), before: index)
            return .split(axis, copy)
        }
        return .split(axis, Self.insertingBranch(.leaf(new), into: branches, at: index))
    }

    /// root의 바깥 가장자리에 붙인다. 같은 방향 root split이면 그 안에 끼우고, 아니면 root를 0.5/0.5로 감싼다.
    func inserting(_ new: Leaf, atOuterEdge edge: PaneEdge) -> PaneLayoutNode {
        if case .split(let axis, let branches) = self, axis == edge.axis {
            return .split(axis, Self.insertingBranch(.leaf(new), into: branches, at: edge.isLeading ? 0 : branches.count))
        }
        let pair: [PaneLayoutNode] = edge.isLeading ? [.leaf(new), self] : [self, .leaf(new)]
        return .split(edge.axis, pair.map { .init(node: $0, weight: 0.5) })
    }

    private static func insertingBranch(_ node: PaneLayoutNode, into branches: [PaneLayoutBranch<Leaf>], at index: Int) -> [PaneLayoutBranch<Leaf>] {
        let n = Double(branches.count)
        var result = branches.map { PaneLayoutBranch(node: $0.node, weight: $0.weight * n / (n + 1)) }
        result.insert(.init(node: node, weight: 1 / (n + 1)), at: min(max(index, 0), result.count))
        return result
    }

    func swapping(_ a: Leaf, _ b: Leaf) -> PaneLayoutNode {
        map { $0 == a ? b : ($0 == b ? a : $0) }
    }

    /// swap은 `swapping`. 나머지는 도착 자리에 자리표시를 먼저 넣고 `source`를 뺀 뒤 자리표시를 `source`로 바꾼다.
    /// `source`가 유일한 잎이면 그대로 돌려준다.
    func moving(_ source: Leaf, to move: PaneLayoutMove<Leaf>) -> PaneLayoutNode {
        if case .swap(let other) = move { return swapping(source, other) }
        guard leaves != [source] else { return self }
        typealias Slot = PaneLayoutSlot<Leaf>
        let tree = map { Slot.existing($0) }
        let placed: PaneLayoutNode<Slot>
        switch move {
        case .besideLeaf(let target, let edge):
            placed = tree.splitting(.existing(target), edge: edge, with: .placeholder)
        case .intoSplit(let path, let before):
            placed = tree.inserting(.placeholder, intoSplitAt: path, before: before)
        case .outerEdge(let edge):
            placed = tree.inserting(.placeholder, atOuterEdge: edge)
        case .swap:
            return self
        }
        guard let removed = placed.removing(where: { $0 == .existing(source) }) else { return self }
        return removed.map { slot in
            if case .existing(let leaf) = slot { return leaf }
            return source
        }
    }

    /// 비율을 무시하고 모양(방향과 잎 순서)만 비교한다.
    func hasSameStructure(as other: PaneLayoutNode) -> Bool {
        switch (self, other) {
        case (.leaf(let a), .leaf(let b)):
            return a == b
        case (.split(let axisA, let a), .split(let axisB, let b)):
            return axisA == axisB && a.count == b.count
                && zip(a, b).allSatisfy { $0.node.hasSameStructure(as: $1.node) }
        default:
            return false
        }
    }
}
