import XCTest
@testable import termy

final class BalancedPanePlacementTests: XCTestCase {
    func test_singlePaneInWideWorkspace_insertsSideBySideRow() {
        let placement = BalancedPanePlacementPlanner.placement(
            rows: [BalancedPaneLayoutRow(index: 0, paneCount: 1)],
            workspaceSize: CGSize(width: 1200, height: 760),
            preferredRow: 0
        )

        XCTAssertEqual(placement, .insertRow(after: 0))
    }

    func test_singlePaneInTallWorkspace_appendsToSameRow() {
        let placement = BalancedPanePlacementPlanner.placement(
            rows: [BalancedPaneLayoutRow(index: 0, paneCount: 1)],
            workspaceSize: CGSize(width: 640, height: 1000),
            preferredRow: 0
        )

        XCTAssertEqual(placement, .append(toRow: 0))
    }

    func test_twoSideBySidePanes_splitLeftmostTallPaneOnTie() {
        let placement = BalancedPanePlacementPlanner.placement(
            rows: [
                BalancedPaneLayoutRow(index: 0, paneCount: 1),
                BalancedPaneLayoutRow(index: 1, paneCount: 1)
            ],
            workspaceSize: CGSize(width: 1200, height: 760),
            preferredRow: 1
        )

        XCTAssertEqual(placement, .append(toRow: 0))
    }

    func test_unbalancedRows_splitLargestPaneEvenWhenFocusIsElsewhere() {
        let placement = BalancedPanePlacementPlanner.placement(
            rows: [
                BalancedPaneLayoutRow(index: 0, paneCount: 1),
                BalancedPaneLayoutRow(index: 1, paneCount: 2)
            ],
            workspaceSize: CGSize(width: 1200, height: 760),
            preferredRow: 1
        )

        XCTAssertEqual(placement, .append(toRow: 0))
    }

    func test_evenGridWidePanes_appendNewColumnAfterEqualSizedGroup() {
        let placement = BalancedPanePlacementPlanner.placement(
            rows: [
                BalancedPaneLayoutRow(index: 0, paneCount: 2),
                BalancedPaneLayoutRow(index: 1, paneCount: 2)
            ],
            workspaceSize: CGSize(width: 1200, height: 760),
            preferredRow: 1
        )

        XCTAssertEqual(placement, .insertRow(after: 1))
    }

    func test_afterWideEvenGridCreatesRightColumn_nextSplitFillsThatColumn() {
        let placement = BalancedPanePlacementPlanner.placement(
            rows: [
                BalancedPaneLayoutRow(index: 0, paneCount: 2),
                BalancedPaneLayoutRow(index: 1, paneCount: 2),
                BalancedPaneLayoutRow(index: 2, paneCount: 1)
            ],
            workspaceSize: CGSize(width: 1200, height: 800),
            preferredRow: 2
        )

        XCTAssertEqual(placement, .append(toRow: 2))
    }

    func test_equalSizedCandidates_chooseLowestIndexEvenWhenInputIsUnsorted() {
        let placement = BalancedPanePlacementPlanner.placement(
            rows: [
                BalancedPaneLayoutRow(index: 2, paneCount: 1),
                BalancedPaneLayoutRow(index: 0, paneCount: 1),
                BalancedPaneLayoutRow(index: 1, paneCount: 1)
            ],
            workspaceSize: CGSize(width: 1200, height: 760),
            preferredRow: 2
        )

        XCTAssertEqual(placement, .append(toRow: 0))
    }

    func test_unsortedWideEqualSizedCandidates_insertAfterRightmostEqualSizedRow() {
        let placement = BalancedPanePlacementPlanner.placement(
            rows: [
                BalancedPaneLayoutRow(index: 2, paneCount: 2),
                BalancedPaneLayoutRow(index: 0, paneCount: 2),
                BalancedPaneLayoutRow(index: 1, paneCount: 2)
            ],
            workspaceSize: CGSize(width: 1200, height: 760),
            preferredRow: 2
        )

        XCTAssertEqual(placement, .insertRow(after: 2))
    }
}
