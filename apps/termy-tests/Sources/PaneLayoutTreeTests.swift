import XCTest
@testable import termy

final class PaneLayoutTreeTests: XCTestCase {
    func test_fromColumns_buildsRowOfColumns() {
        XCTAssertEqual(layoutSignature(abcdLayout()), "row(A:0.333,col(B:0.500,C:0.500):0.333,D:0.333)")
        XCTAssertEqual(PaneLayoutNode.fromColumns([["A"]]), .leaf("A"))
        XCTAssertEqual(PaneLayoutNode.fromColumns([[], ["A", "B"]]).map(layoutSignature), "col(A:0.500,B:0.500)")
        XCTAssertNil(PaneLayoutNode<String>.fromColumns([]))
    }

    func test_leaves_and_approximateColumns_shareReadingOrder() {
        let tree = abcdLayout().splitting("C", edge: .right, with: "E")   // row(A, col(B, row(C,E)), D)
        XCTAssertEqual(tree.leaves, ["A", "B", "C", "E", "D"])
        XCTAssertEqual(tree.approximateColumns(), [["A"], ["B", "C", "E"], ["D"]])
        XCTAssertEqual(PaneLayoutNode.fromColumns([["A", "B"]])!.approximateColumns(), [["A", "B"]])
        XCTAssertEqual(PaneLayoutNode.leaf("A").approximateColumns(), [["A"]])
    }

    func test_removing_redistributesProportionallyAndCollapses() {
        let tree = PaneLayoutNode<String>.split(.leftToRight, [
            .init(node: .leaf("A"), weight: 0.5),
            .init(node: .split(.topToBottom, [
                .init(node: .leaf("B"), weight: 0.5),
                .init(node: .split(.leftToRight, [.init(node: .leaf("C"), weight: 0.5), .init(node: .leaf("D"), weight: 0.5)]), weight: 0.5),
            ]), weight: 0.5),
        ])
        XCTAssertEqual(tree.removing { $0 == "B" }.map(layoutSignature), "row(A:0.500,C:0.250,D:0.250)")
        XCTAssertEqual(tree.removing { $0 == "A" }.map(layoutSignature), "col(B:0.500,row(C:0.500,D:0.500):0.500)")
        XCTAssertNil(PaneLayoutNode.leaf("A").removing { $0 == "A" })
    }

    func test_moving_matchesPrototype() {
        let t = abcdLayout()
        XCTAssertEqual(layoutSignature(t.moving("C", to: .besideLeaf("B", .right))), "row(A:0.333,B:0.167,C:0.167,D:0.333)")
        XCTAssertEqual(layoutSignature(t.moving("D", to: .besideLeaf("A", .bottom))), "row(col(A:0.500,D:0.500):0.500,col(B:0.500,C:0.500):0.500)")
        XCTAssertEqual(layoutSignature(t.moving("A", to: .intoSplit(path: [1], before: 1))), "row(col(B:0.333,A:0.333,C:0.333):0.500,D:0.500)")
        XCTAssertEqual(layoutSignature(t.moving("B", to: .intoSplit(path: [], before: 1))), "row(A:0.250,B:0.250,C:0.250,D:0.250)")
        XCTAssertEqual(layoutSignature(t.moving("A", to: .outerEdge(.bottom))), "col(row(col(B:0.500,C:0.500):0.500,D:0.500):0.500,A:0.500)")
        XCTAssertEqual(layoutSignature(t.moving("A", to: .swap(with: "D"))), "row(D:0.333,col(B:0.500,C:0.500):0.333,A:0.333)")
    }

    func test_moving_invalidDestinationLeavesTreeUnchanged() {
        let t = abcdLayout()
        XCTAssertEqual(t.moving("A", to: .besideLeaf("Z", .right)), t)
        XCTAssertEqual(t.moving("A", to: .intoSplit(path: [0], before: 0)), t)
        XCTAssertEqual(t.moving("A", to: .intoSplit(path: [9], before: 0)), t)
        XCTAssertEqual(t.moving("A", to: .swap(with: "Z")), t)
    }

    func test_hasSameStructure_ignoresWeights() {
        let t = abcdLayout()
        XCTAssertTrue(t.moving("C", to: .besideLeaf("B", .bottom)).hasSameStructure(as: t))
        XCTAssertTrue(t.settingWeights([0.6, 0.2, 0.2], atSplitPath: []).hasSameStructure(as: t))
        XCTAssertFalse(t.moving("C", to: .besideLeaf("B", .right)).hasSameStructure(as: t))
    }

    func test_settingWeights_normalizesAtPath() {
        let t = abcdLayout().settingWeights([7, 3], atSplitPath: [1])
        XCTAssertEqual(layoutSignature(t), "row(A:0.333,col(B:0.700,C:0.300):0.333,D:0.333)")
    }

    func test_codable_roundTripsAndUsesDocumentedKeys() throws {
        let t = abcdLayout()
        let data = try JSONEncoder().encode(t)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"axis\":\"leftToRight\""))
        XCTAssertTrue(json.contains("\"pane\":\"A\""))
        XCTAssertTrue(json.contains("\"weight\""))
        XCTAssertEqual(try JSONDecoder().decode(PaneLayoutNode<String>.self, from: data), t)
    }
}
