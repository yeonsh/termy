import XCTest
@testable import termy

final class ProjectPaneLayoutTests: XCTestCase {
    private let row3 = PaneLayoutNode.fromColumns([["A"], ["B"], ["C"]])!

    func test_awayAndBack_restoresSameSlot() {
        var l = ProjectPaneLayout(tree: row3)
        l.markAway("B")
        XCTAssertEqual(l.visibleTree.map(layoutSignature), "row(A:0.500,C:0.500)")
        XCTAssertTrue(l.returnFromAway("B"))
        XCTAssertEqual(l.visibleTree, row3)
    }

    func test_editWhileAway_forgetsSlot() {
        var l = ProjectPaneLayout(tree: row3)
        l.markAway("B")
        l.replaceVisibleTree(l.visibleTree!.splitting("A", edge: .bottom, with: "N"))
        XCTAssertFalse(l.returnFromAway("B"))
        XCTAssertFalse(l.tree!.contains("B"))
    }

    func test_removePane_dropsAwayLeavesToo() {
        var l = ProjectPaneLayout(tree: row3)
        l.markAway("B")
        l.removePane("C")
        XCTAssertEqual(l.tree, .leaf("A"))
        XCTAssertTrue(l.awayPaneIds.isEmpty)
    }

    func test_forgetAway_removesOnlyThatLeaf() {
        var l = ProjectPaneLayout(tree: row3)
        l.markAway("A"); l.markAway("B")
        l.forgetAway("A")
        XCTAssertEqual(l.awayPaneIds, ["B"])
        XCTAssertTrue(l.returnFromAway("B"))
        XCTAssertEqual(l.visibleTree.map(layoutSignature), "row(B:0.500,C:0.500)")
    }

    func test_onlyAwayLeavesLeft_visibleTreeIsNil() {
        var l = ProjectPaneLayout(tree: .leaf("A"))
        l.markAway("A")
        XCTAssertNil(l.visibleTree)
        XCTAssertFalse(l.isEmpty)
    }

    func test_balanced_matchesColumnPlannerOnColumnShapes() {
        let wide = CGSize(width: 1000, height: 600), tall = CGSize(width: 600, height: 1000)
        XCTAssertEqual(PanePlacement.balanced("N", into: nil, workspaceSize: wide), .leaf("N"))
        XCTAssertEqual(layoutSignature(PanePlacement.balanced("N", into: .leaf("A"), workspaceSize: wide)), "row(A:0.500,N:0.500)")
        XCTAssertEqual(layoutSignature(PanePlacement.balanced("N", into: .leaf("A"), workspaceSize: tall)), "col(A:0.500,N:0.500)")
        let two = PaneLayoutNode.fromColumns([["A"], ["B"]])!   // BalancedPanePlacementTests.test_twoSideBySidePanes_splitLeftmostTallPaneOnTie
        XCTAssertEqual(layoutSignature(PanePlacement.balanced("N", into: two, workspaceSize: wide)), "row(col(A:0.500,N:0.500):0.500,B:0.500)")
    }

    func test_balanced_nonColumnShape_splitsLargestPaneAlongLongerSide() {
        let t = PaneLayoutNode.fromColumns([["A"], ["B", "C"]])!.splitting("C", edge: .right, with: "D")
        XCTAssertNil(PanePlacement.columnCounts(of: t))
        // 1000×600: A 492×592 가 가장 넓고 세로가 더 길다 → 아래로 나눈다.
        XCTAssertEqual(layoutSignature(PanePlacement.balanced("N", into: t, workspaceSize: CGSize(width: 1000, height: 600))),
                       "row(col(A:0.500,N:0.500):0.500,col(B:0.500,row(C:0.500,D:0.500):0.500):0.500)")
    }
}
