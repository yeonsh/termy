import CoreGraphics
import Foundation

/// split 하나의 frame. childFrames는 자식 순서대로, 사이 틈은 포함하지 않는다. y-down 좌표.
struct PaneLayoutSplitFrame: Equatable {
    var path: [Int]
    var axis: PaneLayoutAxis
    var frame: CGRect
    var childFrames: [CGRect]
    var depth: Int
}

struct PaneLayoutFrames<Leaf> {
    var leaves: [(leaf: Leaf, frame: CGRect)]
    var splits: [PaneLayoutSplitFrame]

    func frame(of leaf: Leaf) -> CGRect? where Leaf: Equatable {
        leaves.first { $0.leaf == leaf }?.frame
    }
}

extension PaneLayoutNode {
    /// NSSplitView에 `setPosition`으로 놓는 위치와 같은 식: `total = 길이 - gap*(n-1)`, 자식 = `total*weight`, 앞에서부터 + gap.
    func frames(in rect: CGRect, gap: CGFloat) -> PaneLayoutFrames<Leaf> {
        var result = PaneLayoutFrames<Leaf>(leaves: [], splits: [])
        collectFrames(in: rect, gap: gap, path: [], depth: 0, into: &result)
        return result
    }

    private func collectFrames(in rect: CGRect, gap: CGFloat, path: [Int], depth: Int, into result: inout PaneLayoutFrames<Leaf>) {
        switch self {
        case .leaf(let leaf):
            result.leaves.append((leaf, rect))
        case .split(let axis, let branches):
            let horizontal = axis == .leftToRight
            let total = max(0, (horizontal ? rect.width : rect.height) - gap * CGFloat(branches.count - 1))
            var pos = horizontal ? rect.minX : rect.minY
            var childFrames: [CGRect] = []
            for (index, branch) in branches.enumerated() {
                let size = total * CGFloat(branch.weight)
                let child = horizontal
                    ? CGRect(x: pos, y: rect.minY, width: size, height: rect.height)
                    : CGRect(x: rect.minX, y: pos, width: rect.width, height: size)
                childFrames.append(child)
                branch.node.collectFrames(in: child, gap: gap, path: path + [index], depth: depth + 1, into: &result)
                pos += size + gap
            }
            result.splits.append(PaneLayoutSplitFrame(path: path, axis: axis, frame: rect, childFrames: childFrames, depth: depth))
        }
    }
}

struct PaneDropPlan: Equatable {
    var move: PaneLayoutMove<String>
    var result: PaneLayoutNode<String>
    var previewFrame: CGRect
}

enum PaneDropPlanner {
    static let gap: CGFloat = 8
    static let inset: CGFloat = 4
    static let outerZone: CGFloat = 16
    static let gapZone: CGFloat = 14
    static let centerInset: CGFloat = 0.3

    static func contentRect(for bounds: CGSize) -> CGRect {
        CGRect(x: inset, y: inset, width: bounds.width - 2 * inset, height: bounds.height - 2 * inset)
    }

    /// 판정 순서: Workspace 가장자리 바깥 구역 → 사이 틈 → pane 가운데(바꾸기) → pane 안 삼각형. bounds 밖이면 nil.
    static func move(at point: CGPoint, bounds: CGSize, layout: PaneLayoutNode<String>) -> PaneLayoutMove<String>? {
        let distances: [(PaneEdge, CGFloat)] = [
            (.left, point.x), (.right, bounds.width - point.x),
            (.top, point.y), (.bottom, bounds.height - point.y),
        ]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 >= 0 else { return nil }
        if nearest.1 <= outerZone { return .outerEdge(nearest.0) }

        let frames = layout.frames(in: contentRect(for: bounds), gap: gap)

        var best: (dist: CGFloat, depth: Int, path: [Int], before: Int)?
        for split in frames.splits {
            let horizontal = split.axis == .leftToRight
            let along = horizontal
                ? (point.y >= split.frame.minY && point.y <= split.frame.maxY)
                : (point.x >= split.frame.minX && point.x <= split.frame.maxX)
            guard along else { continue }
            for i in 1..<max(split.childFrames.count, 1) {
                let a = split.childFrames[i - 1], b = split.childFrames[i]
                let line = horizontal ? (a.maxX + b.minX) / 2 : (a.maxY + b.minY) / 2
                let dist = abs((horizontal ? point.x : point.y) - line)
                guard dist <= gapZone else { continue }
                if best == nil || dist < best!.dist || (dist == best!.dist && split.depth > best!.depth) {
                    best = (dist, split.depth, split.path, i)
                }
            }
        }
        if let best { return .intoSplit(path: best.path, before: best.before) }

        for (leaf, r) in frames.leaves where r.contains(point) {
            let ix = r.width * centerInset, iy = r.height * centerInset
            if point.x > r.minX + ix, point.x < r.maxX - ix, point.y > r.minY + iy, point.y < r.maxY - iy {
                return .swap(with: leaf)
            }
            let dx = (point.x - r.midX) / (r.width / 2), dy = (point.y - r.midY) / (r.height / 2)
            let edge: PaneEdge = abs(dx) > abs(dy) ? (dx < 0 ? .left : .right) : (dy < 0 ? .top : .bottom)
            return .besideLeaf(leaf, edge)
        }
        return nil
    }

    /// nil = bounds 밖이거나 제자리(자기 자신을 대상으로 하거나 모양이 그대로).
    static func plan(moving source: String, to point: CGPoint, bounds: CGSize, layout: PaneLayoutNode<String>) -> PaneDropPlan? {
        guard let move = move(at: point, bounds: bounds, layout: layout) else { return nil }
        switch move {
        case .besideLeaf(let target, _), .swap(with: let target):
            if target == source { return nil }
        default: break
        }
        let result = layout.moving(source, to: move)
        if case .swap = move {} else if result.hasSameStructure(as: layout) { return nil }
        guard let frame = result.frames(in: contentRect(for: bounds), gap: gap).frame(of: source) else { return nil }
        return PaneDropPlan(move: move, result: result, previewFrame: frame)
    }
}
