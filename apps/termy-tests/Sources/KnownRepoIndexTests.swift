import XCTest
@testable import termy

final class KnownRepoIndexTests: XCTestCase {
    private var tmp: URL!
    private var root: String!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("KnownRepoIndexTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        root = try makeFixture().path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func write(_ text: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeRepo(_ path: String, origin: String) throws {
        try write("[remote \"origin\"]\n\turl = \(origin)\n", to: path + "/.git/config")
    }

    private func makeFixture() throws -> URL {
        let base = tmp.appendingPathComponent("fx").path
        try makeRepo(base + "/work/bdweb", origin: "https://github.com/bdrive/bdweb.git")
        try write("[submodule \"3rd_party/bdrive-core\"]\n\tpath = 3rd_party/bdrive-core\n\turl = git@github.com:bdrive/bdrive-core.git\n",
                  to: base + "/work/bdweb/.gitmodules")
        let sub = base + "/work/bdweb/3rd_party/bdrive-core"
        try write("gitdir: ../../.git/modules/3rd_party/bdrive-core\n", to: sub + "/.git")
        try write("[remote \"origin\"]\n\turl = git@github.com:bdrive/bdrive-core.git\n",
                  to: base + "/work/bdweb/.git/modules/3rd_party/bdrive-core/config")
        try makeRepo(base + "/work/netdrive4_flutter", origin: "https://gitlab.bdrive.com/bdrive/netdrive4_flutter.git")
        try makeRepo(base + "/work/netdrive3/netdrive3", origin: "https://gitlab.bdrive.com/bdrive/netdrive3.git")
        try makeRepo(base + "/backup/NetDrive3", origin: "https://gitlab.bdrive.com/bdrive/netdrive3.git")
        try makeRepo(base + "/proj/test", origin: "https://github.com/someone/test.git")
        return URL(fileURLWithPath: base)
    }

    private func keys(_ paths: [String]) -> [String] {
        KnownRepoDiscovery.discover(workspacePaths: paths).map(\.web.storageKey)
    }

    func test_discover_includesSiblingNeverOpenedInTermy() {
        XCTAssertTrue(keys([root + "/work/bdweb"]).contains("gitlab.bdrive.com/bdrive/netdrive4_flutter"))
    }

    func test_discover_includesSubmodules() {
        XCTAssertTrue(keys([root + "/work/bdweb"]).contains("github.com/bdrive/bdrive-core"))
    }

    func test_discover_reposDirectlyUnderNonGitFolder() {
        XCTAssertTrue(keys([root + "/work/netdrive3"]).contains("gitlab.bdrive.com/bdrive/netdrive3"))
    }

    func test_discover_doesNotDescendTwoLevels() {
        let k = keys([root + "/work"])
        XCTAssertFalse(k.contains("gitlab.bdrive.com/bdrive/netdrive3"))
        XCTAssertTrue(k.contains("github.com/bdrive/bdweb"))
    }

    func test_discover_dedupsSameRemote() {
        let k = keys([root + "/work/netdrive3", root + "/backup"])
        XCTAssertEqual(k.filter { $0 == "gitlab.bdrive.com/bdrive/netdrive3" }.count, 1)
    }

    func test_discover_skipsRemoteWorkspaceRecords() {
        XCTAssertEqual(KnownRepoDiscovery.discover(workspacePaths: ["backend-1:/home/ubuntu"]), [])
    }

    func test_paneRepos_returnsRootAndSubmodules() {
        let k = KnownRepoDiscovery.paneRepos(roots: [root + "/work/bdweb"]).map(\.web.storageKey)
        XCTAssertEqual(Set(k), ["github.com/bdrive/bdweb", "github.com/bdrive/bdrive-core"])
    }

    func test_reposNamed_matchesRepoNameFullPathAndFolderCaseInsensitively() {
        let snap = KnownRepoSnapshot(repos: KnownRepoDiscovery.discover(workspacePaths: [root + "/work/netdrive3", root + "/backup"]))
        let nd3 = RepoWebURL(storageKey: "gitlab.bdrive.com/bdrive/netdrive3")!
        XCTAssertEqual(snap.repos(named: "NetDrive3"), [nd3])
        XCTAssertEqual(snap.repos(named: "bdrive/netdrive3"), [nd3])
        XCTAssertEqual(snap.repos(named: "netdrive"), [])
    }

    func test_index_cachesUntilRebuild() async {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func bump() { lock.lock(); n += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        }
        let counter = Counter()
        let paths = [root + "/work/bdweb"]
        let index = KnownRepoIndex(workspacePaths: { counter.bump(); return paths })
        _ = await index.snapshot()
        _ = await index.snapshot()
        XCTAssertEqual(counter.value, 1)
        _ = await index.rebuild()
        XCTAssertEqual(counter.value, 2)
    }
}
