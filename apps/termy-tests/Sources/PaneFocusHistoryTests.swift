import XCTest
@testable import termy

final class PaneFocusHistoryTests: XCTestCase {
    func test_mostRecentReturnsLatestFocusedCandidate() {
        var history = PaneFocusHistory()
        history.markFocused("first")
        history.markFocused("second")
        history.markFocused("third")

        XCTAssertEqual(
            history.mostRecent(in: ["first", "second"]),
            "second"
        )
    }

    func test_markFocusedMovesExistingPaneToMostRecent() {
        var history = PaneFocusHistory()
        history.markFocused("first")
        history.markFocused("second")
        history.markFocused("first")

        XCTAssertEqual(
            history.mostRecent(in: ["first", "second"]),
            "first"
        )
    }

    func test_removeExcludesClosedPaneFromFallback() {
        var history = PaneFocusHistory()
        history.markFocused("first")
        history.markFocused("second")
        history.remove("second")

        XCTAssertEqual(
            history.mostRecent(in: ["first", "second"]),
            "first"
        )
    }
}
