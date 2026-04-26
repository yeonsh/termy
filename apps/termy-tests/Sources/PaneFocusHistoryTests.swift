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

    func test_focusAfterVisibilityChangeKeepsCurrentPaneWhenStillVisible() {
        var history = PaneFocusHistory()
        history.markFocused("first")
        history.markFocused("second")

        XCTAssertEqual(
            history.focusAfterVisibilityChange(
                currentPaneId: "first",
                visiblePaneIds: ["first", "second"]
            ),
            "first"
        )
    }

    func test_focusAfterVisibilityChangeRestoresMostRecentVisiblePane() {
        var history = PaneFocusHistory()
        history.markFocused("api-first")
        history.markFocused("web-first")
        history.markFocused("api-second")
        history.markFocused("web-second")

        XCTAssertEqual(
            history.focusAfterVisibilityChange(
                currentPaneId: "api-second",
                visiblePaneIds: ["web-first", "web-second"]
            ),
            "web-second"
        )
    }

    func test_focusAfterVisibilityChangeFallsBackToFirstVisiblePane() {
        var history = PaneFocusHistory()
        history.markFocused("api-first")

        XCTAssertEqual(
            history.focusAfterVisibilityChange(
                currentPaneId: "api-first",
                visiblePaneIds: ["web-first", "web-second"]
            ),
            "web-first"
        )
    }
}
