import XCTest
@testable import termy

final class IssueRefResolverTests: XCTestCase {
    private let bdweb = RepoWebURL(remote: "git@github.com:bdrive/bdweb.git")!
    private let bdriveCore = RepoWebURL(remote: "git@github.com:bdrive/bdrive-core.git")!
    private let nd3 = RepoWebURL(remote: "https://gitlab.bdrive.com/bdrive/netdrive3.git")!
    private let flutter = RepoWebURL(remote: "https://gitlab.bdrive.com/bdrive/netdrive4_flutter.git")!
    private let testRepo = RepoWebURL(remote: "git@github.com:someone/test.git")!

    private var paneBdweb: KnownRepo { KnownRepo(web: bdweb, localPath: "/w/bdweb") }
    private var index: KnownRepoSnapshot {
        KnownRepoSnapshot(repos: [paneBdweb,
                                  KnownRepo(web: bdriveCore, localPath: "/w/bdrive-core"),
                                  KnownRepo(web: nd3, localPath: "/w/netdrive3"),
                                  KnownRepo(web: flutter, localPath: "/w/netdrive4_flutter"),
                                  KnownRepo(web: testRepo, localPath: "/w/test")])
    }
    private var bare1300: IssueRef { IssueRef(number: 1300, kind: .issue, qualifier: nil) }
    private func key(_ n: Int = 1300, _ kind: IssueRefKind = .issue) -> IssueRefPickKey {
        IssueRefPickKey(paneId: "p1", number: n, kind: kind)
    }

    private func ctx(_ ref: IssueRef, clues: [IssueRefClue] = [], nearby: [String] = [],
                     paneRepos: [KnownRepo]? = nil, force: Bool = false) -> IssueRefContext {
        IssueRefContext(ref: ref, paneId: "p1", paneRepos: paneRepos ?? [paneBdweb],
                        clues: clues, nearbyNames: nearby, forceMenu: force)
    }
    private func decide(_ c: IssueRefContext, index: KnownRepoSnapshot? = nil,
                        memory: IssueRefMemorySnapshot = IssueRefMemorySnapshot()) -> IssueRefDecision {
        IssueRefResolver.decide(c, index: index ?? self.index, memory: memory)
    }
    private func nameClue(_ q: IssueRefQualifier, _ r: ClosedRange<Int>, _ kind: IssueRefKind = .issue) -> IssueRefClue {
        IssueRefClue(numbers: r, kind: kind, source: .name(q))
    }
    private func menu(_ d: IssueRefDecision, file: StaticString = #filePath, line: UInt = #line) -> IssueRefMenuRequest? {
        guard case .menu(let m) = d else { XCTFail("expected menu, got \(d)", file: file, line: line); return nil }
        return m
    }

    func test_bareNumber_usesScrollbackNameClue() {
        let d = decide(ctx(bare1300, clues: [nameClue(.spaced("netdrive3"), 1300...1300)]))
        XCTAssertEqual(d, .open(URL(string: "https://gitlab.bdrive.com/bdrive/netdrive3/-/issues/1300")!, repo: nd3))
    }
    func test_bareNumber_withoutClue_showsMenu_paneRepoFirst() {
        guard case .menu(let m) = decide(ctx(bare1300, nearby: ["bdrive-core"])) else { return XCTFail() }
        XCTAssertEqual(m.title, "Open #1300 in…")
        XCTAssertEqual(m.candidates.prefix(2).map(\.tag), [.thisPane, .sameLine])
        XCTAssertEqual(m.candidates.first?.repo, bdweb)
        XCTAssertEqual(m.saveTarget, .pick(IssueRefPickKey(paneId: "p1", number: 1300, kind: .issue)))
    }
    func test_rangeClue_opensMiddleNumber() {
        let d = decide(ctx(IssueRef(number: 27, kind: .issue, qualifier: nil),
                           clues: [nameClue(.joined("bdrive-core"), 26...28)]))
        XCTAssertEqual(d, .open(URL(string: "https://github.com/bdrive/bdrive-core/issues/27")!, repo: bdriveCore))
    }
    func test_urlClue_opensThatRepo() {
        let d = decide(ctx(bare1300, clues: [IssueRefClue(numbers: 1300...1300, kind: .issue, source: .url(nd3))]))
        XCTAssertEqual(d, .open(URL(string: "https://gitlab.bdrive.com/bdrive/netdrive3/-/issues/1300")!, repo: nd3))
    }
    func test_clueKindMustMatch() {
        let d = decide(ctx(IssueRef(number: 1300, kind: .mergeRequest, qualifier: nil),
                           clues: [nameClue(.spaced("netdrive3"), 1300...1300, .issue)]))
        guard let m = menu(d) else { return }
        XCTAssertEqual(m.title, "Open !1300 in…")
    }
    func test_spacedStrongName_opensDirectly() {
        let d = decide(ctx(IssueRef(number: 26, kind: .issue, qualifier: .spaced("bdrive-core"))))
        XCTAssertEqual(d, .open(URL(string: "https://github.com/bdrive/bdrive-core/issues/26")!, repo: bdriveCore))
    }
    func test_spacedWeakName_showsMenuWithThatRepoFirst() {
        guard case .menu(let m) = decide(ctx(IssueRef(number: 3, kind: .issue, qualifier: .spaced("Test")))) else { return XCTFail() }
        XCTAssertEqual(m.candidates.first?.repo, testRepo); XCTAssertEqual(m.saveTarget, .none)
    }
    func test_spacedUnknownName_actsLikeBareNumber() {
        guard let m = menu(decide(ctx(IssueRef(number: 5, kind: .issue, qualifier: .spaced("foo"))))) else { return }
        XCTAssertEqual(m.title, "Open #5 in…")
        XCTAssertEqual(m.candidates.first?.repo, bdweb)
        XCTAssertEqual(m.saveTarget, .pick(key(5)))
    }
    func test_joinedUnknown_asksWhichProject_savesAlias() {
        guard case .menu(let m) = decide(ctx(IssueRef(number: 45, kind: .issue, qualifier: .joined("fl")))) else { return XCTFail() }
        XCTAssertEqual(m.title, "fl#45 — which project is “fl”?"); XCTAssertEqual(m.saveTarget, .alias("fl"))
    }
    func test_joinedAlias_opensIssueAndMergeRequest() {
        let mem = IssueRefMemorySnapshot(aliases: ["fl": flutter])
        XCTAssertEqual(decide(ctx(IssueRef(number: 189, kind: .mergeRequest, qualifier: .joined("fl"))), memory: mem),
                       .open(URL(string: "https://gitlab.bdrive.com/bdrive/netdrive4_flutter/-/merge_requests/189")!, repo: flutter))
        XCTAssertEqual(decide(ctx(IssueRef(number: 45, kind: .issue, qualifier: .joined("FL"))), memory: mem),
                       .open(URL(string: "https://gitlab.bdrive.com/bdrive/netdrive4_flutter/-/issues/45")!, repo: flutter))
    }
    private var twoSame: KnownRepoSnapshot {
        KnownRepoSnapshot(repos: [KnownRepo(web: RepoWebURL(remote: "git@github.com:a/api.git")!, localPath: "/w/api"),
                                  KnownRepo(web: RepoWebURL(remote: "git@gitlab.com:b/api.git")!, localPath: "/x/api")])
    }
    func test_ambiguousName_limitsMenu_savesAlias() {
        guard let m = menu(decide(ctx(IssueRef(number: 7, kind: .issue, qualifier: .joined("api")), paneRepos: []),
                                  index: twoSame)) else { return }
        XCTAssertTrue(m.limitToCandidates)
        XCTAssertEqual(m.candidates.count, 2)
        XCTAssertEqual(m.saveTarget, .alias("api"))
    }
    func test_rememberedPick_beatsClue() {
        let mem = IssueRefMemorySnapshot(picks: [key(): bdweb])
        let d = decide(ctx(bare1300, clues: [nameClue(.spaced("netdrive3"), 1300...1300)]), memory: mem)
        XCTAssertEqual(d, .open(URL(string: "https://github.com/bdrive/bdweb/issues/1300")!, repo: bdweb))
    }
    func test_forceMenu_onBare_putsWhatWouldOpenFirst() {
        guard let m = menu(decide(ctx(bare1300, clues: [nameClue(.spaced("netdrive3"), 1300...1300)], force: true))) else { return }
        XCTAssertEqual(m.candidates.first?.repo, nd3)
        XCTAssertNil(m.candidates.first?.tag)
        XCTAssertEqual(m.saveTarget, .pick(key()))
    }
    func test_forceMenu_onKnownJoinedName_savesNothing() {
        guard let m = menu(decide(ctx(IssueRef(number: 1300, kind: .issue, qualifier: .joined("netdrive3")), force: true))) else { return }
        XCTAssertEqual(m.candidates.first?.repo, nd3)
        XCTAssertEqual(m.saveTarget, .none)
    }
    func test_weakNameClue_showsMenu() {
        guard let m = menu(decide(ctx(IssueRef(number: 3, kind: .issue, qualifier: nil),
                                      clues: [nameClue(.spaced("test"), 3...3)]))) else { return }
        XCTAssertEqual(m.candidates.first?.repo, testRepo)
        XCTAssertEqual(m.saveTarget, .pick(key(3)))
    }
    func test_hcPane_hasNoThisPaneCandidate() {
        guard let m = menu(decide(ctx(bare1300, nearby: ["bdrive-core"], paneRepos: []),
                                  memory: IssueRefMemorySnapshot(recents: [nd3]))) else { return }
        XCTAssertFalse(m.candidates.isEmpty)
        XCTAssertFalse(m.candidates.contains { $0.tag == .thisPane })
    }
    func test_saveTargets_acrossPaths() {
        let mem = IssueRefMemorySnapshot(aliases: ["fl": flutter])
        // force on joined alias
        XCTAssertEqual(menu(decide(ctx(IssueRef(number: 45, kind: .issue, qualifier: .joined("fl")), force: true), memory: mem))?.saveTarget, .alias("fl"))
        // spaced strong single + force
        XCTAssertEqual(menu(decide(ctx(IssueRef(number: 26, kind: .issue, qualifier: .spaced("bdrive-core")), force: true)))?.saveTarget, Optional(IssueRefSaveTarget.none))
        // spaced strong multi
        let strongDup = KnownRepoSnapshot(repos: [KnownRepo(web: RepoWebURL(remote: "git@github.com:a/api-x.git")!, localPath: "/w/api-x"),
                                                  KnownRepo(web: RepoWebURL(remote: "git@gitlab.com:b/api-x.git")!, localPath: "/x/api-x")])
        let strong = menu(decide(ctx(IssueRef(number: 7, kind: .issue, qualifier: .spaced("api-x")), paneRepos: []), index: strongDup))
        XCTAssertEqual(strong?.limitToCandidates, true)
        XCTAssertEqual(strong?.saveTarget, .alias("api-x"))
        // spaced weak multi: not limited, nothing saved, matches first then defaults
        let weak = menu(decide(ctx(IssueRef(number: 7, kind: .issue, qualifier: .spaced("api")), paneRepos: [paneBdweb]),
                               index: KnownRepoSnapshot(repos: twoSame.repos + [paneBdweb])))
        XCTAssertEqual(weak?.limitToCandidates, false)
        XCTAssertEqual(weak?.saveTarget, Optional(IssueRefSaveTarget.none))
        XCTAssertEqual(weak?.candidates.map(\.repo.path), ["a/api", "b/api", "bdrive/bdweb"])
        XCTAssertEqual(weak?.candidates.map(\.tag), [nil, nil, .thisPane])
        // paneId nil
        var noPane = ctx(bare1300); noPane.paneId = nil
        XCTAssertEqual(menu(decide(noPane))?.saveTarget, Optional(IssueRefSaveTarget.none))
        // force, bare, no clue
        XCTAssertEqual(menu(decide(ctx(bare1300, force: true)))?.saveTarget, .pick(key()))
    }
    func test_noKnownProjects_beeps() {
        XCTAssertEqual(decide(ctx(bare1300, paneRepos: []), index: KnownRepoSnapshot(repos: [])), .beep)
    }
    func test_isStrong() {
        XCTAssertTrue(IssueRefResolver.isStrong(name: "bdrive-core", paneRepos: [], aliases: [:]))
        XCTAssertTrue(IssueRefResolver.isStrong(name: "netdrive3", paneRepos: [], aliases: [:]))
        XCTAssertFalse(IssueRefResolver.isStrong(name: "common", paneRepos: [], aliases: [:]))
        XCTAssertTrue(IssueRefResolver.isStrong(name: "bdweb", paneRepos: [KnownRepo(web: bdweb, localPath: "/w/bdweb")], aliases: [:]))
        XCTAssertTrue(IssueRefResolver.isStrong(name: "fl", paneRepos: [], aliases: ["fl": flutter]))
    }

    // MARK: controller rulings

    func test_ruling_nameClueWithSeveralRepos_menuFirstThenDefaults() {
        guard let m = menu(decide(ctx(IssueRef(number: 7, kind: .issue, qualifier: nil),
                                      clues: [nameClue(.spaced("api"), 7...7)], paneRepos: [paneBdweb]),
                                  index: KnownRepoSnapshot(repos: twoSame.repos + [paneBdweb]))) else { return }
        XCTAssertEqual(m.candidates.map(\.repo.path), ["a/api", "b/api", "bdrive/bdweb"])
        XCTAssertEqual(m.candidates.map(\.tag), [nil, nil, .thisPane])
        XCTAssertFalse(m.limitToCandidates)
        XCTAssertEqual(m.saveTarget, .pick(key(7)))
    }
    func test_ruling_forceMenu_prefersRememberedPick() {
        let mem = IssueRefMemorySnapshot(picks: [key(): bdriveCore])
        guard let m = menu(decide(ctx(bare1300, clues: [nameClue(.spaced("netdrive3"), 1300...1300)], force: true),
                                  memory: mem)) else { return }
        XCTAssertEqual(m.candidates.first?.repo, bdriveCore)
        XCTAssertEqual(m.saveTarget, .pick(key()))
    }
    func test_ruling_forceMenu_urlClue_andNoClue() {
        guard let m = menu(decide(ctx(bare1300, clues: [IssueRefClue(numbers: 1300...1300, kind: .issue, source: .url(nd3))], force: true))) else { return }
        XCTAssertEqual(m.candidates.first?.repo, nd3)
        guard let d = menu(decide(ctx(bare1300, nearby: ["bdrive-core"], force: true))) else { return }
        XCTAssertEqual(d.candidates.map(\.tag), [.thisPane, .sameLine])
    }
    func test_ruling_resolveMergesPaneReposAndDedups() {
        // index 가 비어 있어도 pane repo 이름으로 찾고, 둘 다 있으면 한 번만 센다
        let d = decide(ctx(IssueRef(number: 9, kind: .issue, qualifier: .joined("bdweb"))), index: KnownRepoSnapshot(repos: []))
        XCTAssertEqual(d, .open(URL(string: "https://github.com/bdrive/bdweb/issues/9")!, repo: bdweb))
        let d2 = decide(ctx(IssueRef(number: 9, kind: .issue, qualifier: .joined("bdweb"))))
        XCTAssertEqual(d2, .open(URL(string: "https://github.com/bdrive/bdweb/issues/9")!, repo: bdweb))
    }
    func test_ruling_initialCandidatesCappedAtSix_includingX() {
        let many = (1...10).map { KnownRepo(web: RepoWebURL(remote: "git@github.com:o/r\($0).git")!, localPath: "/w/r\($0)") }
        let mem = IssueRefMemorySnapshot(recents: many.map(\.web))
        guard let m = menu(decide(ctx(bare1300, paneRepos: []), index: KnownRepoSnapshot(repos: many), memory: mem)) else { return }
        XCTAssertEqual(m.candidates.count, 6)
        guard let x = menu(decide(ctx(bare1300, clues: [nameClue(.spaced("netdrive3"), 1300...1300)], paneRepos: [], force: true),
                                  index: KnownRepoSnapshot(repos: many + index.repos), memory: mem)) else { return }
        XCTAssertEqual(x.candidates.count, 6)
        XCTAssertEqual(x.candidates.first?.repo, nd3)
    }
    func test_ruling_limitedListNotCapped() {
        let repos = (1...8).map { KnownRepo(web: RepoWebURL(remote: "git@host\($0).com:o/dup.git")!, localPath: "/w\($0)/dup") }
        guard let m = menu(decide(ctx(IssueRef(number: 1, kind: .issue, qualifier: .joined("dup")), paneRepos: []),
                                  index: KnownRepoSnapshot(repos: repos))) else { return }
        XCTAssertEqual(m.candidates.count, 8)
        XCTAssertTrue(m.limitToCandidates)
    }
    func test_ruling_joinedUnknown_staysMenuWhenEmpty() {
        let d = decide(ctx(IssueRef(number: 45, kind: .issue, qualifier: .joined("fl")), paneRepos: []),
                       index: KnownRepoSnapshot(repos: []))
        guard let m = menu(d) else { return }
        XCTAssertTrue(m.candidates.isEmpty)
        XCTAssertEqual(m.saveTarget, .alias("fl"))
    }
    func test_ruling_names() {
        let c = ctx(IssueRef(number: 1, kind: .issue, qualifier: .joined("fl")),
                    clues: [nameClue(.spaced("netdrive3"), 1...1), nameClue(.joined("fl"), 2...2),
                            IssueRefClue(numbers: 3...3, kind: .issue, source: .url(nd3)),
                            nameClue(.spaced("api"), 4...4)])
        XCTAssertEqual(IssueRefResolver.names(in: c), ["fl", "netdrive3", "api"])
        XCTAssertEqual(IssueRefResolver.names(in: ctx(bare1300)), [])
    }
}
