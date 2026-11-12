import CoreGraphics

/// 한 project의 분할 tree. 다른 project로 `cd`한 pane의 잎은 "떠난 자리"로 tree에 남지만 그려지지 않는다.
/// 배치를 손대기 전에 돌아오면 옛 자리와 크기를 그대로 되찾고, 손대는 순간(`replaceVisibleTree`) 떠난 잎은 사라진다.
struct ProjectPaneLayout: Equatable {
    private(set) var tree: PaneLayoutNode<String>?
    private(set) var awayPaneIds: Set<String> = []

    init(tree: PaneLayoutNode<String>? = nil) {
        self.tree = tree
    }

    var visibleTree: PaneLayoutNode<String>? {
        guard !awayPaneIds.isEmpty else { return tree }
        return tree?.removing(where: { awayPaneIds.contains($0) })
    }

    var isEmpty: Bool { tree == nil }

    mutating func materialize() {
        tree = visibleTree
        awayPaneIds = []
    }

    mutating func replaceVisibleTree(_ new: PaneLayoutNode<String>?) {
        materialize()
        tree = new
    }

    mutating func markAway(_ paneId: String) {
        guard tree?.contains(paneId) == true else { return }
        awayPaneIds.insert(paneId)
    }

    mutating func returnFromAway(_ paneId: String) -> Bool {
        awayPaneIds.remove(paneId) != nil
    }

    mutating func removePane(_ paneId: String) {
        materialize()
        tree = tree?.removing(where: { $0 == paneId })
    }

    mutating func forgetAway(_ paneId: String) {
        guard awayPaneIds.remove(paneId) != nil else { return }
        tree = tree?.removing(where: { $0 == paneId })
    }
}

/// 새 pane(⌘T)이 들어갈 자리.
enum PanePlacement {
    /// 열 모양 tree의 열마다 잎 개수. 열 모양이 아니면 nil.
    static func columnCounts(of tree: PaneLayoutNode<String>) -> [Int]? {
        switch tree {
        case .leaf:
            return [1]
        case .split(.topToBottom, let branches):
            return allLeaves(branches) ? [branches.count] : nil
        case .split(.leftToRight, let branches):
            var counts: [Int] = []
            for branch in branches {
                switch branch.node {
                case .leaf:
                    counts.append(1)
                case .split(.topToBottom, let inner) where allLeaves(inner):
                    counts.append(inner.count)
                default:
                    return nil
                }
            }
            return counts
        }
    }

    private static func allLeaves(_ branches: [PaneLayoutBranch<String>]) -> Bool {
        branches.allSatisfy { if case .leaf = $0.node { return true } else { return false } }
    }

    static func balanced(_ new: String, into tree: PaneLayoutNode<String>?, workspaceSize: CGSize) -> PaneLayoutNode<String> {
        guard let tree else { return .leaf(new) }
        if let counts = columnCounts(of: tree) {
            let rows = counts.enumerated().map { BalancedPaneLayoutRow(index: $0.offset, paneCount: $0.element) }
            switch BalancedPanePlacementPlanner.placement(rows: rows, workspaceSize: workspaceSize, preferredRow: nil) {
            case .append(let column)?:
                return appendToColumn(new, column: column, in: tree)
            case .insertRow(let after)?:
                if case .split(.leftToRight, _) = tree {
                    return tree.inserting(new, intoSplitAt: [], before: after + 1)
                }
                return tree.inserting(new, atOuterEdge: .right)
            case nil:
                break
            }
        }
        let frames = tree.frames(in: PaneDropPlanner.contentRect(for: workspaceSize), gap: PaneDropPlanner.gap)
        var best: (leaf: String, frame: CGRect)?
        for entry in frames.leaves {
            let area = entry.frame.width * entry.frame.height
            if best == nil || area > best!.frame.width * best!.frame.height {
                best = (entry.leaf, entry.frame)
            }
        }
        guard let best else { return tree.inserting(new, atOuterEdge: .right) }
        return tree.splitting(best.leaf, edge: best.frame.width >= best.frame.height ? .right : .bottom, with: new)
    }

    private static func appendToColumn(_ new: String, column: Int, in tree: PaneLayoutNode<String>) -> PaneLayoutNode<String> {
        switch tree {
        case .leaf(let leaf):
            return tree.splitting(leaf, edge: .bottom, with: new)
        case .split(.topToBottom, let branches):
            return tree.inserting(new, intoSplitAt: [], before: branches.count)
        case .split(.leftToRight, let branches):
            guard branches.indices.contains(column) else { return tree }
            switch branches[column].node {
            case .leaf(let leaf):
                return tree.splitting(leaf, edge: .bottom, with: new)
            case .split(_, let inner):
                return tree.inserting(new, intoSplitAt: [column], before: inner.count)
            }
        }
    }
}
