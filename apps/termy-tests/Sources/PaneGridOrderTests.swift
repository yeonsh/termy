import XCTest
@testable import termy

final class PaneGridOrderTests: XCTestCase {
    /// Fixture panes are named "<project><n>", e.g. "api1".
    private func readingOrder(_ columns: [[String]], projects: [String]) -> [String] {
        PaneGridOrder.readingOrder(columns: columns, projectOrder: projects) {
            String($0.prefix(3))
        }
    }

    func test_singleProject_walksColumnsLeftToRightEachTopToBottom() {
        // api3 was opened before api4, but ⌘D put api4's column in between.
        XCTAssertEqual(
            readingOrder([["api1", "api2"], ["api4"], ["api3"]], projects: ["api"]),
            ["api1", "api2", "api4", "api3"]
        )
    }

    func test_emptyColumns_areSkipped() {
        XCTAssertEqual(
            readingOrder([["api1"], [], ["api2"]], projects: ["api"]),
            ["api1", "api2"]
        )
    }

    func test_allView_walksProjectCellsInChipOrder() {
        // The order the ALL grid fills its rows in: projects in chip order,
        // each keeping its own columns left to right.
        XCTAssertEqual(
            readingOrder([["web1"], ["api1", "api2"], ["web2"]], projects: ["api", "web"]),
            ["api1", "api2", "web1", "web2"]
        )
    }

    func test_columnMixingProjects_splitsIntoEachProjectsCell() {
        XCTAssertEqual(
            readingOrder([["api1", "web1", "api2"]], projects: ["api", "web"]),
            ["api1", "api2", "web1"]
        )
    }

    func test_equalRowSizes_perfectGrids_fillEveryRow() {
        XCTAssertEqual(PaneGridOrder.equalRowSizes(paneCount: 1), [1])
        XCTAssertEqual(PaneGridOrder.equalRowSizes(paneCount: 2), [2])
        XCTAssertEqual(PaneGridOrder.equalRowSizes(paneCount: 4), [2, 2])
        XCTAssertEqual(PaneGridOrder.equalRowSizes(paneCount: 6), [3, 3])
        XCTAssertEqual(PaneGridOrder.equalRowSizes(paneCount: 9), [3, 3, 3])
    }

    func test_equalRowSizes_remainder_spreadsAcrossRowsTopFirst() {
        // Rows never differ by more than one pane, so no row ends up with a
        // lone pane stretched across the full width (7 → 3+2+2, not 3+3+1).
        XCTAssertEqual(PaneGridOrder.equalRowSizes(paneCount: 3), [2, 1])
        XCTAssertEqual(PaneGridOrder.equalRowSizes(paneCount: 5), [3, 2])
        XCTAssertEqual(PaneGridOrder.equalRowSizes(paneCount: 7), [3, 2, 2])
        XCTAssertEqual(PaneGridOrder.equalRowSizes(paneCount: 10), [4, 3, 3])
    }

    func test_equalRowSizes_noPanes_isEmpty() {
        XCTAssertEqual(PaneGridOrder.equalRowSizes(paneCount: 0), [])
    }
}
