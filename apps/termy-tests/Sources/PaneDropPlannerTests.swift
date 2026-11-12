import XCTest
@testable import termy

final class PaneDropPlannerTests: XCTestCase {
    private let bounds = CGSize(width: 1000, height: 600)
    private func move(_ x: CGFloat, _ y: CGFloat) -> PaneLayoutMove<String>? {
        PaneDropPlanner.move(at: CGPoint(x: x, y: y), bounds: bounds, layout: abcdLayout())
    }
    private func assertRect(_ r: CGRect?, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        guard let r else { return XCTFail("nil frame", file: file, line: line) }
        for (a, b) in [(r.minX, x), (r.minY, y), (r.width, w), (r.height, h)] { XCTAssertEqual(a, b, accuracy: 0.01, file: file, line: line) }
    }

    func test_frames_matchSplitViewGeometry() {
        let f = abcdLayout().frames(in: PaneDropPlanner.contentRect(for: bounds), gap: 8)
        assertRect(f.frame(of: "A"), 4, 4, 325.333, 592)
        assertRect(f.frame(of: "B"), 337.333, 4, 325.333, 292)
        assertRect(f.frame(of: "C"), 337.333, 304, 325.333, 292)
        assertRect(f.frame(of: "D"), 670.667, 4, 325.333, 592)
    }

    func test_zones_inPriorityOrder() {
        XCTAssertEqual(move(5, 300), .outerEdge(.left))
        XCTAssertEqual(move(333.333, 300), .intoSplit(path: [], before: 1))
        XCTAssertEqual(move(500, 300), .intoSplit(path: [1], before: 1))
        XCTAssertEqual(move(166, 300), .swap(with: "A"))
        XCTAssertEqual(move(300, 300), .besideLeaf("A", .right))
        XCTAssertEqual(move(166, 580), .besideLeaf("A", .bottom))
        XCTAssertNil(move(-5, 300))
    }

    func test_plan_previewIsSourceFrameInResult() {
        let t = abcdLayout()
        let c = PaneDropPlanner.plan(moving: "C", to: CGPoint(x: 300, y: 300), bounds: bounds, layout: t)
        XCTAssertEqual(c.map { layoutSignature($0.result) }, "row(A:0.167,C:0.167,B:0.333,D:0.333)")
        assertRect(c?.previewFrame, 173.333, 4, 161.333, 592)

        let d = PaneDropPlanner.plan(moving: "D", to: CGPoint(x: 166, y: 580), bounds: bounds, layout: t)
        assertRect(d?.previewFrame, 4, 304, 492, 292)

        let swap = PaneDropPlanner.plan(moving: "A", to: CGPoint(x: 833.333, y: 300), bounds: bounds, layout: t)
        assertRect(swap?.previewFrame, 670.667, 4, 325.333, 592)

        let edge = PaneDropPlanner.plan(moving: "B", to: CGPoint(x: 995, y: 300), bounds: bounds, layout: t)
        XCTAssertEqual(edge.map { layoutSignature($0.result) }, "row(A:0.250,C:0.250,D:0.250,B:0.250)")
        assertRect(edge?.previewFrame, 754, 4, 242, 592)
    }

    func test_plan_inPlaceDropsAreNil() {
        let t = abcdLayout()
        XCTAssertNil(PaneDropPlanner.plan(moving: "A", to: CGPoint(x: 166, y: 300), bounds: bounds, layout: t), "own centre")
        XCTAssertNil(PaneDropPlanner.plan(moving: "C", to: CGPoint(x: 500, y: 300), bounds: bounds, layout: t), "own neighbouring gap")
        XCTAssertNil(PaneDropPlanner.plan(moving: "C", to: CGPoint(x: 500, y: 250), bounds: bounds, layout: t), "B's bottom: structure unchanged")
        XCTAssertNil(PaneDropPlanner.plan(moving: "A", to: CGPoint(x: 5, y: 300), bounds: bounds, layout: t), "already leftmost")
    }

    func test_tinyPanes_planIsSane() {
        let many = PaneLayoutNode.fromColumns((0..<40).map { ["P\($0)"] })!
        for x in stride(from: 0, through: 1000, by: 7) {
            let plan = PaneDropPlanner.plan(moving: "P0", to: CGPoint(x: CGFloat(x), y: 300), bounds: bounds, layout: many)
            if let f = plan?.previewFrame { XCTAssertGreaterThanOrEqual(f.width, 0); XCTAssertGreaterThanOrEqual(f.height, 0) }
        }
    }
}
