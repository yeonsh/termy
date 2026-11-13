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

    /// A remote pane's cwd is a path on another machine; never read it here.
    func test_issueRefRepoRoots_remotePaneIsEmpty() {
        XCTAssertEqual(
            Pane.issueRefRepoRoots(isRemote: true, shellCwd: "/w/bdweb", agentCwd: nil, workTreeRoot: { $0 }),
            []
        )
    }

    func test_issueRefRepoRoots_shellThenAgentDeduped() {
        XCTAssertEqual(
            Pane.issueRefRepoRoots(isRemote: false, shellCwd: "/w/bdweb/sub", agentCwd: "/w/bdweb",
                                   workTreeRoot: { $0.hasPrefix("/w/bdweb") ? "/w/bdweb" : nil }),
            ["/w/bdweb"]
        )
        XCTAssertEqual(
            Pane.issueRefRepoRoots(isRemote: false, shellCwd: "/w/bdweb", agentCwd: "/w/netdrive3",
                                   workTreeRoot: { $0 }),
            ["/w/bdweb", "/w/netdrive3"]
        )
    }
}
