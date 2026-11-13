import XCTest
@testable import termy

final class RepoWebURLTests: XCTestCase {
    func test_httpsRemote() {
        let w = RepoWebURL(remote: "https://github.com/bdrive/bdweb.git")!
        XCTAssertEqual(w.host, "github.com"); XCTAssertEqual(w.path, "bdrive/bdweb")
        XCTAssertEqual(w.name, "bdweb"); XCTAssertEqual(w.displayOwner, "github.com/bdrive"); XCTAssertTrue(w.isGitHub)
    }
    func test_scpRemote() {
        XCTAssertEqual(RepoWebURL(remote: "git@github.com:bdrive/bdrive-core.git")?.storageKey, "github.com/bdrive/bdrive-core")
    }
    func test_sshRemoteWithPortAndSubgroups() {
        let w = RepoWebURL(remote: "ssh://git@gitlab.bdrive.com:2222/bdrive/group/sub/proj.git")!
        XCTAssertEqual(w.storageKey, "gitlab.bdrive.com/bdrive/group/sub/proj"); XCTAssertEqual(w.displayOwner, "gitlab.bdrive.com/bdrive/group/sub")
    }
    func test_credentialsAreDropped() {
        let w = RepoWebURL(remote: "https://ysh:glpat-SECRET@gitlab.bdrive.com/bdrive/netdrive3_sdk.git")!
        XCTAssertEqual(w.storageKey, "gitlab.bdrive.com/bdrive/netdrive3_sdk")
        XCTAssertFalse(w.url(number: 1, kind: .issue).absoluteString.contains("glpat"))
        XCTAssertFalse(String(describing: w).contains("glpat"))
        XCTAssertFalse(String(reflecting: w).contains("glpat"))
    }
    func test_localPathsAreRejected() {
        XCTAssertNil(RepoWebURL(remote: "/Users/x/repo")); XCTAssertNil(RepoWebURL(remote: "file:///x/repo")); XCTAssertNil(RepoWebURL(remote: "../sibling.git"))
    }
    /// Hosts or paths `URL(string:)` can't take would crash `url(number:kind:)`; they never become a RepoWebURL.
    func test_unusableHostOrPathIsRejected() {
        XCTAssertNil(RepoWebURL(remote: "ssh://git@[fd00::1]/team/repo.git"))
        XCTAssertNil(RepoWebURL(remote: "git@[fd00::1]:team/repo.git"))
        XCTAssertNil(RepoWebURL(remote: "https://exa mple.com/team/repo.git"))
        XCTAssertNil(RepoWebURL(remote: "git@exa mple.com:team/repo.git"))
        XCTAssertNil(RepoWebURL(remote: "https://example.com/a b/c.git"))
        XCTAssertNil(RepoWebURL(remote: "https://example..com/team/repo.git"))
        XCTAssertNil(RepoWebURL(remote: "https://example.com/team/re%70o.git"))
        XCTAssertNil(RepoWebURL(storageKey: "[fd00/x/y"))
        XCTAssertNil(RepoWebURL(storageKey: "example.com/a b/c"))
        XCTAssertNil(RepoWebURL(storageKey: "example.com/a?b"))
    }
    func test_validFormsStillAccepted() {
        XCTAssertEqual(RepoWebURL(remote: "https://GitHub.com/bdrive/bdweb.git")?.storageKey, "github.com/bdrive/bdweb")
        XCTAssertEqual(RepoWebURL(remote: "git@github.com:bdrive/bdrive-core.git")?.storageKey, "github.com/bdrive/bdrive-core")
        XCTAssertEqual(RepoWebURL(remote: "ssh://git@gitlab.bdrive.com:2222/bdrive/group/sub/proj.git")?.storageKey,
                       "gitlab.bdrive.com/bdrive/group/sub/proj")
        XCTAssertEqual(RepoWebURL(remote: "https://ysh:glpat-SECRET@gitlab.bdrive.com/bdrive/netdrive3_sdk.git")?.storageKey,
                       "gitlab.bdrive.com/bdrive/netdrive3_sdk")
        XCTAssertEqual(RepoWebURL(remote: "https://example.com/o/my.repo~x.git")?.storageKey, "example.com/o/my.repo~x")
        XCTAssertEqual(RepoWebURL(storageKey: "gitlab.bdrive.com/bdrive/netdrive4_flutter")?.path, "bdrive/netdrive4_flutter")
    }
    func test_issueAndMergeRequestURLs() {
        let gh = RepoWebURL(storageKey: "github.com/bdrive/bdweb")!
        XCTAssertEqual(gh.url(number: 1300, kind: .issue).absoluteString, "https://github.com/bdrive/bdweb/issues/1300")
        XCTAssertEqual(gh.url(number: 12, kind: .mergeRequest).absoluteString, "https://github.com/bdrive/bdweb/pull/12")
        let gl = RepoWebURL(storageKey: "gitlab.bdrive.com/bdrive/netdrive3")!
        XCTAssertEqual(gl.url(number: 1300, kind: .issue).absoluteString, "https://gitlab.bdrive.com/bdrive/netdrive3/-/issues/1300")
        XCTAssertEqual(gl.url(number: 189, kind: .mergeRequest).absoluteString, "https://gitlab.bdrive.com/bdrive/netdrive3/-/merge_requests/189")
    }
}
