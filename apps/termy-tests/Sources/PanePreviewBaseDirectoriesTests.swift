import XCTest
@testable import termy

final class PanePreviewBaseDirectoriesTests: XCTestCase {
    func test_orderIsShellThenAgentThenRepoRoot() {
        XCTAssertEqual(
            Pane.previewBaseDirectories(agentCwd: "/agent", shellCwd: "/shell/sub", workTreeRoot: "/shell"),
            ["/shell/sub", "/agent", "/shell"]
        )
    }

    /// The agent cwd outlives the agent: after `exit` and `cd` into another
    /// project, a common name like `README.md` must not resolve against
    /// the old project.
    func test_staleAgentCwdDoesNotBeatShellCwd() {
        let bases = Pane.previewBaseDirectories(agentCwd: "/old-proj", shellCwd: "/new-proj", workTreeRoot: "/new-proj")
        let resolution = PreviewLinkResolver.resolve(
            linkText: "README.md",
            baseDirectories: bases,
            homeDirectory: "/Users/me",
            isRegularFile: { ["/old-proj/README.md", "/new-proj/README.md"].contains($0) }
        )
        XCTAssertEqual(resolution, .file(URL(fileURLWithPath: "/new-proj/README.md").resolvingSymlinksInPath()))
    }

    func test_missingAndDuplicateEntriesAreDropped() {
        XCTAssertEqual(
            Pane.previewBaseDirectories(agentCwd: nil, shellCwd: "/proj", workTreeRoot: "/proj"),
            ["/proj"]
        )
        XCTAssertEqual(
            Pane.previewBaseDirectories(agentCwd: "", shellCwd: "/proj", workTreeRoot: nil),
            ["/proj"]
        )
        XCTAssertEqual(
            Pane.previewBaseDirectories(agentCwd: "/proj", shellCwd: "/proj", workTreeRoot: nil),
            ["/proj"]
        )
        XCTAssertEqual(
            Pane.previewBaseDirectories(agentCwd: nil, shellCwd: "", workTreeRoot: nil),
            []
        )
    }
}
