import XCTest
@testable import termy

final class PaneMarkdownBaseDirectoriesTests: XCTestCase {
    func test_orderIsAgentThenShellThenRepoRoot() {
        XCTAssertEqual(
            Pane.markdownBaseDirectories(agentCwd: "/agent", shellCwd: "/shell/sub", workTreeRoot: "/shell"),
            ["/agent", "/shell/sub", "/shell"]
        )
    }

    func test_missingAndDuplicateEntriesAreDropped() {
        XCTAssertEqual(
            Pane.markdownBaseDirectories(agentCwd: nil, shellCwd: "/proj", workTreeRoot: "/proj"),
            ["/proj"]
        )
        XCTAssertEqual(
            Pane.markdownBaseDirectories(agentCwd: "", shellCwd: "/proj", workTreeRoot: nil),
            ["/proj"]
        )
        XCTAssertEqual(
            Pane.markdownBaseDirectories(agentCwd: "/proj", shellCwd: "/proj", workTreeRoot: nil),
            ["/proj"]
        )
    }
}
