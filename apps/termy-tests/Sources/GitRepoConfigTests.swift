import XCTest
@testable import termy

final class GitRepoConfigTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    private func write(_ text: String, _ relative: String) throws {
        let url = tmp.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    private func real(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }

    func test_remoteURL_prefersOrigin() {
        let text = "[remote \"glab-base\"]\n\turl = git@gitlab.bdrive.com:bdrive/common.git\n[remote \"origin\"]\n\turl = https://gitlab.bdrive.com/bdrive/netdrive3.git\n"
        XCTAssertEqual(GitRepoConfig.remoteURL(configText: text), "https://gitlab.bdrive.com/bdrive/netdrive3.git")
    }
    func test_remoteURL_soleNonOriginRemote() {
        let text = "[remote \"upstream\"]\n\turl = git@github.com:bdrive/x.git\n"
        XCTAssertEqual(GitRepoConfig.remoteURL(configText: text), "git@github.com:bdrive/x.git")
    }
    func test_remoteURL_twoRemotesWithoutOrigin_isNil() {
        let text = "[remote \"upstream\"]\n\turl = git@github.com:a/x.git\n[remote \"fork\"]\n\turl = git@github.com:b/x.git\n"
        XCTAssertNil(GitRepoConfig.remoteURL(configText: text))
    }
    func test_submodules_parse() {
        let text = "[submodule \"3rd_party/bdrive-core\"]\n\tpath = 3rd_party/bdrive-core\n\turl = git@github.com:bdrive/bdrive-core.git\n"
        XCTAssertEqual(GitRepoConfig.submodules(gitmodulesText: text), [GitSubmodule(path: "3rd_party/bdrive-core", url: "git@github.com:bdrive/bdrive-core.git")])
    }
    func test_relativeSubmoduleURL_resolvesAgainstParent() throws {
        try write("[submodule \"3rd_party/bdrive-core\"]\n\tpath = 3rd_party/bdrive-core\n\turl = ../bdrive-core.git\n", ".gitmodules")
        let parent = RepoWebURL(storageKey: "github.com/bdrive/bdweb")
        let result = GitRepoConfig.submoduleWebURLs(repoRoot: tmp.path, parent: parent)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.path, "3rd_party/bdrive-core")
        XCTAssertEqual(result.first?.web.storageKey, "github.com/bdrive/bdrive-core")
        XCTAssertTrue(GitRepoConfig.submoduleWebURLs(repoRoot: tmp.path, parent: nil).isEmpty)
    }
    func test_configPath_gitDirectory() throws {
        try write("[core]\n", "root/.git/config")
        XCTAssertEqual(GitRepoConfig.configPath(repoRoot: tmp.appendingPathComponent("root").path).map(real),
                       real(tmp.appendingPathComponent("root/.git/config").path))
    }
    func test_configPath_gitFileForSubmodule() throws {
        try write("[core]\n", "super/.git/modules/x/config")
        try write("gitdir: ../../.git/modules/x\n", "super/a/b/.git")
        XCTAssertEqual(GitRepoConfig.configPath(repoRoot: tmp.appendingPathComponent("super/a/b").path).map(real),
                       real(tmp.appendingPathComponent("super/.git/modules/x/config").path))
    }
    func test_configPath_worktreeUsesCommondir() throws {
        try write("[core]\n", "main/.git/config")
        try write("../..\n", "main/.git/worktrees/wt/commondir")
        try write("gitdir: \(tmp.path)/main/.git/worktrees/wt\n", "wt/.git")
        XCTAssertEqual(GitRepoConfig.configPath(repoRoot: tmp.appendingPathComponent("wt").path).map(real),
                       real(tmp.appendingPathComponent("main/.git/config").path))
    }
    func test_webURL_readsOriginFromFile() throws {
        try write("[remote \"origin\"]\n\turl = https://u:tok@github.com/bdrive/bdweb.git\n", "r/.git/config")
        XCTAssertEqual(GitRepoConfig.webURL(repoRoot: tmp.appendingPathComponent("r").path)?.storageKey, "github.com/bdrive/bdweb")
    }
}
