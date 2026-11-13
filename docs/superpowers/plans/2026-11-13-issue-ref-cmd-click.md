# issue · PR · MR 번호 Cmd+클릭 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 터미널의 `#1300`, `fl#45`, `bdrive-core #26`, `!189`를 Cmd+클릭하면 해당 issue · PR · MR 페이지를 브라우저로 열고, 프로젝트를 정할 수 없으면 클릭한 자리에 프로젝트 고르는 메뉴를 띄운다.

**Architecture:** 순수 로직 네 층 — remote URL 파싱(`RepoWebURL`, `GitRepoConfig`), 로컬 저장소 목록(`KnownRepoIndex` actor), 참조 인식(`IssueRefParser`), 결정(`IssueRefResolver`) — 을 따로 테스트하고, `IssueRefController`가 클릭 하나를 받아 이것들을 묶어 URL을 열거나 `IssueRefPickerPanel`을 띄운다. `TermyTerminalView`는 기존 Cmd+클릭 경로가 아무것도 하지 않을 때(`link == nil` 또는 `.ignore`)만 클릭한 줄의 텍스트와 scrollback을 뽑아 넘긴다.

**Tech Stack:** Swift 6, AppKit, XCTest, `UserDefaults`, SwiftTerm 1.20 fork(이미 의존).

**Spec:** `docs/superpowers/specs/2026-11-13-issue-ref-cmd-click-design.md`

## Global Constraints

- 새 패키지 의존 없음. macOS 14 / Swift 6. 순수 타입(struct/enum)은 nonisolated · `Sendable`, UI 타입과 `IssueRefMemory`는 `@MainActor`.
- 사용자에게 보이는 문자열은 영어 하드코딩(앱 관례). 정확한 문구:
  `Open #1300 in…` / `Open !189 in…`, `fl#45 — which project is “fl”?`, `Search projects…`, `Show All Projects…`,
  태그 `this pane` · `same line` · `recent`, 설정 머리글 `Issue Links`, 버튼 `Remove`, 빈 목록 `No abbreviations`,
  설정 항목 `fl → gitlab.bdrive.com/bdrive/netdrive4_flutter`.
- `UserDefaults` 키: `termy.issueRef.aliases`(`[String: String]`, 키는 소문자 이름, 값은 `host/path`),
  `termy.issueRef.recents`(`[String]`, `host/path`, 최대 5개).
- remote URL의 인증 정보(`user:token@`)는 `RepoWebURL`을 만들 때 버린다. `RepoWebURL`에는 host와 path만 있다. 원래 remote 문자열을 로그 · 저장값 · 화면 어디에도 쓰지 않는다.
- 여는 URL은 언제나 `https://`.
- main thread에서 git 프로세스를 띄우지 않는다. `.git/config` · `.gitmodules`는 파일로 읽고, 그 읽기는 `KnownRepoIndex` actor 안에서 한다.
- 기존 Cmd+클릭 동작(OSC 8, URL, 파일 경로, 미리보기, beep)은 그대로. 참조 인식은 `linkClickAction(atScreen:…)`가 nil이거나 `.ignore`일 때만.
- 일반 낱말(대소문자 무시): `pr`, `mr`, `issue`, `issues`, `bug`, `ticket`, `이슈`, `버그`.
- 이름 상속 구분 기호: 공백(줄바꿈 포함), `~`, `-`, `–`, `·`, `,`, `/`, `、`.
- 강한 이름: `-` · `_` · `.` · 숫자 · `/` 중 하나가 들어간 이름, 또는 pane repo · 그 submodule의 이름, 또는 등록된 줄임말. 나머지는 약한 이름.
- 메뉴 첫 후보 최대 6개, 검색 결과 최대 12개, "근처" = 클릭한 줄 위 20행.
- 테스트 실행: `cd /Users/ysh/proj/termy && xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation -only-testing:termy-tests/<Class> 2>&1 | tail -25`
  (`termy.xcodeproj`는 gitignore 대상이라 새 파일을 더하면 `xcodegen generate`가 먼저 필요하다.)
- XCTest host는 하나뿐인 창이 닫히면 앱이 끝난다. 패널 테스트는 `close()` 대신 `orderOut(nil)`, 참조를 테스트 끝까지 잡아 둔다.
- 커밋 메시지는 한국어, `feat(issue-ref): …` 꼴, Co-Authored-By 줄 없음.

## Review Focus

- **URL 안의 `#12`**(`https://example.com/page#12`): URL로 열려야 한다. 태스크 7 `test_urlWithFragment_staysURL`.
- **한글이 앞에 있는 줄의 클릭 위치**: `답을 기다리는 것: #1300`처럼 넓은 글자가 앞에 있으면 열 번호와 글자 위치가 어긋난다. 태스크 7 `test_screenContext_koreanPrefix_hitsNumber`.
- **Claude Code의 커서 이동 줄바꿈**으로 `bdrive-core`가 윗행 끝, `#26`이 아랫행 처음에 있을 때도 이름이 붙어야 한다. 태스크 7 `test_screenContext_joinsInkHardWrap`.
- **token이 든 remote URL**(`https://ysh:glpat-…@gitlab.bdrive.com/…`): 연 URL · 저장값 · 메뉴 문구에 token이 없어야 한다. 태스크 1 `test_credentialsAreDropped`, 태스크 4 `test_aliasStoredAsHostPathOnly`.
- **hc 원격 pane**: pane repo가 없으니 `this pane` 후보 없이 메뉴가 떠야 하고, 원격 cwd로 로컬 파일을 읽으면 안 된다. 태스크 5 `test_hcPane_hasNoThisPaneCandidate`, 태스크 7 `test_issueRefRepoRoots_remotePaneIsEmpty`.

---

### Task 1: remote URL → web URL, git 설정 읽기

**Files:**
- Create: `apps/termy/Sources/RepoWebURL.swift`
- Create: `apps/termy/Sources/GitRepoConfig.swift`
- Test: `apps/termy-tests/Sources/RepoWebURLTests.swift`, `apps/termy-tests/Sources/GitRepoConfigTests.swift`

**Interfaces:**
- Produces:
  - `enum IssueRefKind: String, Codable, Sendable { case issue, mergeRequest }`
  - `struct RepoWebURL: Hashable, Codable, Sendable { let host: String; let path: String; init?(remote: String); init?(storageKey: String); var storageKey: String /* "host/path" */; var name: String /* path 마지막 부분 */; var displayOwner: String /* "github.com/bdrive" */; var isGitHub: Bool; func url(number: Int, kind: IssueRefKind) -> URL }`
  - `struct GitSubmodule: Equatable, Sendable { let path: String; let url: String }`
  - `enum GitRepoConfig { static func remoteURL(configText: String) -> String?; static func submodules(gitmodulesText: String) -> [GitSubmodule]; static func configPath(repoRoot: String) -> String?; static func webURL(repoRoot: String) -> RepoWebURL?; static func submoduleWebURLs(repoRoot: String, parent: RepoWebURL?) -> [(path: String, web: RepoWebURL)] }`

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
// RepoWebURLTests
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
}
func test_localPathsAreRejected() {
    XCTAssertNil(RepoWebURL(remote: "/Users/x/repo")); XCTAssertNil(RepoWebURL(remote: "file:///x/repo")); XCTAssertNil(RepoWebURL(remote: "../sibling.git"))
}
func test_issueAndMergeRequestURLs() {
    let gh = RepoWebURL(storageKey: "github.com/bdrive/bdweb")!
    XCTAssertEqual(gh.url(number: 1300, kind: .issue).absoluteString, "https://github.com/bdrive/bdweb/issues/1300")
    XCTAssertEqual(gh.url(number: 12, kind: .mergeRequest).absoluteString, "https://github.com/bdrive/bdweb/pull/12")
    let gl = RepoWebURL(storageKey: "gitlab.bdrive.com/bdrive/netdrive3")!
    XCTAssertEqual(gl.url(number: 1300, kind: .issue).absoluteString, "https://gitlab.bdrive.com/bdrive/netdrive3/-/issues/1300")
    XCTAssertEqual(gl.url(number: 189, kind: .mergeRequest).absoluteString, "https://gitlab.bdrive.com/bdrive/netdrive3/-/merge_requests/189")
}

// GitRepoConfigTests
func test_remoteURL_prefersOrigin() {
    let text = "[remote \"glab-base\"]\n\turl = git@gitlab.bdrive.com:bdrive/common.git\n[remote \"origin\"]\n\turl = https://gitlab.bdrive.com/bdrive/netdrive3.git\n"
    XCTAssertEqual(GitRepoConfig.remoteURL(configText: text), "https://gitlab.bdrive.com/bdrive/netdrive3.git")
}
func test_remoteURL_soleNonOriginRemote() { /* [remote "upstream"] 하나 → 그 url */ }
func test_remoteURL_twoRemotesWithoutOrigin_isNil() { /* upstream + fork → nil */ }
func test_submodules_parse() {
    let text = "[submodule \"3rd_party/bdrive-core\"]\n\tpath = 3rd_party/bdrive-core\n\turl = git@github.com:bdrive/bdrive-core.git\n"
    XCTAssertEqual(GitRepoConfig.submodules(gitmodulesText: text), [GitSubmodule(path: "3rd_party/bdrive-core", url: "git@github.com:bdrive/bdrive-core.git")])
}
func test_relativeSubmoduleURL_resolvesAgainstParent() throws {
    // 임시 repo: .gitmodules에 url = ../bdrive-core.git, parent = github.com/bdrive/bdweb
    // → [("3rd_party/bdrive-core", github.com/bdrive/bdrive-core)]
}
func test_configPath_gitDirectory() throws { /* root/.git/config 존재 → 그 경로 */ }
func test_configPath_gitFileForSubmodule() throws { /* root/.git 파일 "gitdir: ../../.git/modules/x" → 그 디렉터리/config */ }
func test_configPath_worktreeUsesCommondir() throws { /* gitdir 안 commondir 파일 "../.." → commondir/config */ }
```

- [ ] **Step 2: 실패 확인** — `xcodegen generate` 후 `-only-testing:termy-tests/RepoWebURLTests -only-testing:termy-tests/GitRepoConfigTests`. Expected: 컴파일 실패(`RepoWebURL` 없음).

- [ ] **Step 3: 구현** — `RepoWebURL.swift`(+`IssueRefKind`)와 `GitRepoConfig.swift`. `init?(remote:)`가 받는 꼴: `https?://[userinfo@]host[:port]/path`, `ssh://[user@]host[:port]/path`, `git://host/path`, `user@host:path`. host는 소문자, path는 앞뒤 `/`와 끝 `.git`을 뗀다. path가 비거나 host가 없으면 nil. github.com이 아닌 host는 GitLab 꼴 URL. 상대 submodule url(`../x.git`, `./x`)은 parent의 path 디렉터리 기준으로 푼다. 설정 파일 파싱은 섹션 머리(`[remote "name"]`, `[submodule "name"]`)와 `key = value` 줄만 본다.

- [ ] **Step 4: 통과 확인** — 같은 명령. Expected: 모두 PASS.

- [ ] **Step 5: 커밋** — `git add apps/termy/Sources/RepoWebURL.swift apps/termy/Sources/GitRepoConfig.swift apps/termy-tests/Sources/RepoWebURLTests.swift apps/termy-tests/Sources/GitRepoConfigTests.swift && git commit -m "feat(issue-ref): remote URL을 issue 페이지 주소로 바꾼다"`

---

### Task 2: 알려진 저장소 목록

**Files:**
- Create: `apps/termy/Sources/KnownRepoIndex.swift`
- Test: `apps/termy-tests/Sources/KnownRepoIndexTests.swift`

**Interfaces:**
- Consumes: `GitRepoConfig.webURL(repoRoot:)`, `GitRepoConfig.submoduleWebURLs(repoRoot:parent:)`, `RepoWebURL`
- Produces:
  - `struct KnownRepo: Hashable, Sendable { let web: RepoWebURL; let localPath: String }`
  - `struct KnownRepoSnapshot: Sendable { let repos: [KnownRepo]; init(repos: [KnownRepo]); func repos(named name: String) -> [RepoWebURL] }`
  - `enum KnownRepoDiscovery { static func discover(workspacePaths: [String]) -> [KnownRepo]; static func paneRepos(roots: [String]) -> [KnownRepo] }`
  - `actor KnownRepoIndex { static let shared: KnownRepoIndex; init(workspacePaths: @escaping @Sendable () -> [String]); func snapshot() -> KnownRepoSnapshot; func rebuild() -> KnownRepoSnapshot; func paneRepos(roots: [String]) -> [KnownRepo] }`

규칙(스펙 §6):
- `discover`: 각 workspace path에 대해 — `/`로 시작하지 않으면(`backend-1:/home/ubuntu`) 건너뛴다. git 저장소(`.git` 파일이나 디렉터리)면 그 저장소, 그 submodule, 같은 부모 폴더의 git 저장소(형제)를 더한다. git이 아니면 바로 아래 git 저장소들을 더한다. 그보다 깊이 훑지 않는다. web URL이 없는 저장소는 뺀다. 같은 web URL은 처음 것만 남긴다.
- `paneRepos(roots:)`: 각 root와 그 submodule.
- `repos(named:)`(대소문자 무시): `web.path == name` 또는 `web.name == name` 또는 `localPath`의 마지막 부분 `== name`. 결과는 web URL 기준 중복 제거.
- `KnownRepoIndex.shared`의 `workspacePaths`는 `(try? WorkspacePersistence())?.all().map(\.canonicalPath) ?? []`.

- [ ] **Step 1: 실패하는 테스트 작성** — 임시 디렉터리에 아래 구조를 만드는 `makeFixture() -> URL` 헬퍼(각 `.git/config`에 `[remote "origin"] url = …`).

```
work/                         (git 아님)
work/bdweb/                   origin https://github.com/bdrive/bdweb.git, .gitmodules: 3rd_party/bdrive-core → git@github.com:bdrive/bdrive-core.git
work/bdweb/3rd_party/bdrive-core/.git   (파일: "gitdir: ../../.git/modules/3rd_party/bdrive-core", 그 디렉터리에 config)
work/netdrive4_flutter/       origin https://gitlab.bdrive.com/bdrive/netdrive4_flutter.git
work/netdrive3/               (git 아님)
work/netdrive3/netdrive3/     origin https://gitlab.bdrive.com/bdrive/netdrive3.git
backup/NetDrive3/             origin https://gitlab.bdrive.com/bdrive/netdrive3.git   (같은 remote)
proj/test/                    origin https://github.com/someone/test.git
```

```swift
func test_discover_includesSiblingNeverOpenedInTermy() {
    let keys = KnownRepoDiscovery.discover(workspacePaths: [root + "/work/bdweb"]).map(\.web.storageKey)
    XCTAssertTrue(keys.contains("gitlab.bdrive.com/bdrive/netdrive4_flutter"))
}
func test_discover_includesSubmodules() { /* 같은 입력 → github.com/bdrive/bdrive-core 포함 */ }
func test_discover_reposDirectlyUnderNonGitFolder() { /* [root/work/netdrive3] → netdrive3 포함 */ }
func test_discover_doesNotDescendTwoLevels() { /* [root/work] → netdrive3(work/netdrive3/netdrive3) 없음, bdweb 있음 */ }
func test_discover_dedupsSameRemote() { /* [root/work/netdrive3, root/backup] → netdrive3 한 번 */ }
func test_discover_skipsRemoteWorkspaceRecords() { XCTAssertEqual(KnownRepoDiscovery.discover(workspacePaths: ["backend-1:/home/ubuntu"]), []) }
func test_reposNamed_matchesRepoNameFullPathAndFolderCaseInsensitively() {
    let snap = KnownRepoSnapshot(repos: KnownRepoDiscovery.discover(workspacePaths: [root + "/work/netdrive3", root + "/backup"]))
    let nd3 = RepoWebURL(storageKey: "gitlab.bdrive.com/bdrive/netdrive3")!
    XCTAssertEqual(snap.repos(named: "NetDrive3"), [nd3]); XCTAssertEqual(snap.repos(named: "bdrive/netdrive3"), [nd3])
    XCTAssertEqual(snap.repos(named: "netdrive"), [])
}
func test_index_cachesUntilRebuild() async { /* workspacePaths 호출 횟수를 잠금 걸린 카운터로 셈: snapshot() 두 번 → 1, rebuild() → 2 */ }
```

- [ ] **Step 2: 실패 확인** — `-only-testing:termy-tests/KnownRepoIndexTests`. Expected: 컴파일 실패.
- [ ] **Step 3: 구현** — 위 규칙대로 `KnownRepoIndex.swift`.
- [ ] **Step 4: 통과 확인** — Expected: PASS.
- [ ] **Step 5: 커밋** — `feat(issue-ref): termy가 아는 로컬 저장소 목록을 만든다`

---

### Task 3: 참조 인식

**Files:**
- Create: `apps/termy/Sources/IssueRefParser.swift`
- Test: `apps/termy-tests/Sources/IssueRefParserTests.swift`

**Interfaces:**
- Consumes: `IssueRefKind`, `RepoWebURL(remote:)`
- Produces:
  - `enum IssueRefQualifier: Equatable, Sendable { case joined(String), spaced(String); var name: String }`
  - `struct IssueRef: Equatable, Sendable { var number: Int; var kind: IssueRefKind; var qualifier: IssueRefQualifier? }`
  - `struct IssueRefHit: Equatable, Sendable { var ref: IssueRef; var start: Int; var end: Int }` — `start..<end`는 토큰(이름 포함)의 Character 위치
  - `struct IssueRefClue: Equatable, Sendable { enum Source: Equatable, Sendable { case name(IssueRefQualifier), url(RepoWebURL) }; var numbers: ClosedRange<Int>; var kind: IssueRefKind; var source: Source }`
  - `enum IssueRefParser { static let stopWords: Set<String>; static func hit(in text: String, atOffset offset: Int) -> IssueRefHit?; static func clues(in text: String) -> [IssueRefClue]; static func mentionedNames(in text: String) -> [String] }`
  - 위치(offset)는 모두 Character 단위(`String.count`와 같은 단위).

규칙(스펙 §4):
- 토큰: `[#!]숫자{1,7}`. 숫자 뒤에 ASCII 글자 · 숫자 · `_`가 오면 토큰 아님(한글은 허용). `#` 앞에 붙은 `[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9._-]+)*`는 붙여 쓴 이름. 이름 없는 `#`/`!` 앞은 줄 처음이나 `[A-Za-z0-9_/]`가 아닌 글자.
- `!`는 `.mergeRequest`, `#`은 `.issue`. 붙여 쓴 이름이 일반 낱말이면 qualifier는 nil이고, 그 낱말이 `mr`이면 kind는 `.mergeRequest`.
- 이름 없는 토큰: 바로 앞이 `이름 + 공백`이면 `.spaced(이름)`. 그 이름이 일반 낱말이면 qualifier nil(`mr`이면 kind `.mergeRequest`).
- 상속: 한 줄의 토큰을 왼쪽부터 보며, 자기 qualifier가 없고 바로 앞 토큰과의 사이가 구분 기호뿐이면 앞 토큰의 qualifier를 물려받는다.
- 단서(`clues`): qualifier가 있는 토큰마다 하나. 상속으로 이어진 토큰 사이에 `~` · `-` · `–`가 있으면 그 둘을 범위 하나로 합친다. URL `https?://host/path/(-/)?(issues|pull|merge_requests)/N` 마다 하나(`issues`·`pull` → `.issue`, `merge_requests` → `.mergeRequest`). 이름 없는 토큰은 단서가 아니다. 결과는 왼쪽부터.
- `mentionedNames`: qualifier가 있는 토큰들의 이름, 왼쪽부터, 중복 없이.

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
let example = "- 답을 기다리는 것: #1300 코디네이터 판단, bdrive-core #26~#28 수정."
private func ref(_ text: String, at needle: String, plus: Int = 1) -> IssueRef? {
    let offset = text.distance(from: text.startIndex, to: text.range(of: needle)!.lowerBound) + plus
    return IssueRefParser.hit(in: text, atOffset: offset)?.ref
}
func test_example_bareNumber() { XCTAssertEqual(ref(example, at: "#1300"), IssueRef(number: 1300, kind: .issue, qualifier: nil)) }
func test_example_spacedName() { XCTAssertEqual(ref(example, at: "#26"), IssueRef(number: 26, kind: .issue, qualifier: .spaced("bdrive-core"))) }
func test_example_rangeEndInheritsName() { XCTAssertEqual(ref(example, at: "#28"), IssueRef(number: 28, kind: .issue, qualifier: .spaced("bdrive-core"))) }
func test_clickOnNameOfJoinedRef_hits() { XCTAssertEqual(ref("see fl#45 now", at: "fl#45", plus: 0)?.qualifier, .joined("fl")) }
func test_joinedForms() {
    XCTAssertEqual(ref("fl!189", at: "!189"), IssueRef(number: 189, kind: .mergeRequest, qualifier: .joined("fl")))
    XCTAssertEqual(ref("x netdrive4_flutter#25", at: "#25")?.qualifier, .joined("netdrive4_flutter"))
    XCTAssertEqual(ref("x bdrive/netdrive3#1300", at: "#1300")?.qualifier, .joined("bdrive/netdrive3"))
}
func test_stopWords() {
    XCTAssertEqual(ref("PR#12", at: "#12"), IssueRef(number: 12, kind: .issue, qualifier: nil))
    XCTAssertEqual(ref("MR!3", at: "!3"), IssueRef(number: 3, kind: .mergeRequest, qualifier: nil))
    XCTAssertEqual(ref("see MR #102", at: "#102"), IssueRef(number: 102, kind: .mergeRequest, qualifier: nil))
    XCTAssertEqual(ref("issue #12", at: "#12")?.qualifier, nil)
    XCTAssertEqual(ref("항목 #3", at: "#3")?.qualifier, nil)
}
func test_koreanParticleAfterNumber() { XCTAssertEqual(ref("#1300에 9번 항목", at: "#1300")?.number, 1300) }
func test_notTokens() {
    XCTAssertNil(ref("abc#12x", at: "#12")); XCTAssertNil(ref("## 2", at: "## 2", plus: 0))
    XCTAssertNil(IssueRefParser.hit(in: example, atOffset: example.count - 3))   // "수정" 위
}
func test_wordBreaksInheritance() { XCTAssertNil(ref("netdrive3 #1300 코디네이터 판단, #26", at: "#26")?.qualifier) }
func test_commaListInherits() { XCTAssertEqual(ref("bdrive-core #26, #27", at: "#27")?.qualifier, .spaced("bdrive-core")) }
func test_clues_nameAndRange() {
    XCTAssertEqual(IssueRefParser.clues(in: "2. netdrive3 #1300 코디네이터 판단"),
                   [IssueRefClue(numbers: 1300...1300, kind: .issue, source: .name(.spaced("netdrive3")))])
    XCTAssertEqual(IssueRefParser.clues(in: example),
                   [IssueRefClue(numbers: 26...28, kind: .issue, source: .name(.spaced("bdrive-core")))])
}
func test_clues_urls() {
    let gl = RepoWebURL(storageKey: "gitlab.bdrive.com/bdrive/netdrive3")!
    XCTAssertEqual(IssueRefParser.clues(in: "1300 https://gitlab.bdrive.com/bdrive/netdrive3/-/issues/1300 ['nd4::GA전']"),
                   [IssueRefClue(numbers: 1300...1300, kind: .issue, source: .url(gl))])
    XCTAssertEqual(IssueRefParser.clues(in: "https://github.com/bdrive/bdweb/pull/7").first?.kind, .issue)
    XCTAssertEqual(IssueRefParser.clues(in: "https://gitlab.bdrive.com/bdrive/netdrive3/-/merge_requests/102").first?.kind, .mergeRequest)
}
func test_mentionedNames() { XCTAssertEqual(IssueRefParser.mentionedNames(in: example), ["bdrive-core"]) }
```

- [ ] **Step 2: 실패 확인** — `-only-testing:termy-tests/IssueRefParserTests`. Expected: 컴파일 실패.
- [ ] **Step 3: 구현** — 위 규칙대로 `IssueRefParser.swift`. 정규식은 Character 위치로 바꿔 돌려준다.
- [ ] **Step 4: 통과 확인** — Expected: PASS.
- [ ] **Step 5: 커밋** — `feat(issue-ref): 터미널 텍스트에서 issue 참조와 단서를 찾는다`

---

### Task 4: 기억하기

**Files:**
- Create: `apps/termy/Sources/IssueRefMemory.swift`
- Test: `apps/termy-tests/Sources/IssueRefMemoryTests.swift`

**Interfaces:**
- Consumes: `RepoWebURL(storageKey:)`, `.storageKey`, `IssueRefKind`
- Produces:
  - `struct IssueRefPickKey: Hashable, Sendable { let paneId: String; let number: Int; let kind: IssueRefKind }`
  - `struct IssueRefAlias: Equatable, Sendable { let name: String; let repo: RepoWebURL }`
  - `struct IssueRefMemorySnapshot: Sendable { var aliases: [String: RepoWebURL] /* 소문자 키 */; var picks: [IssueRefPickKey: RepoWebURL]; var recents: [RepoWebURL]; init(aliases:picks:recents:) /* 모두 기본값 빈 값 */ }`
  - `@MainActor final class IssueRefMemory { static let shared: IssueRefMemory; static let aliasesKey = "termy.issueRef.aliases"; static let recentsKey = "termy.issueRef.recents"; static let maxRecents = 5; init(defaults: UserDefaults); func alias(_ name: String) -> RepoWebURL?; func setAlias(_ name: String, to repo: RepoWebURL); func removeAlias(_ name: String); var aliases: [IssueRefAlias] /* 이름순 */; func setPick(_ repo: RepoWebURL, for key: IssueRefPickKey); var recents: [RepoWebURL]; func noteOpened(_ repo: RepoWebURL); var snapshot: IssueRefMemorySnapshot }`
  - picks는 메모리에만 둔다(저장하지 않음).

- [ ] **Step 1: 실패하는 테스트 작성** — 각 테스트는 `UserDefaults(suiteName: "IssueRefMemoryTests-\(UUID())")!`.

```swift
func test_aliasPersistsAcrossInstances_caseInsensitive() {
    IssueRefMemory(defaults: d).setAlias("FL", to: flutter)
    XCTAssertEqual(IssueRefMemory(defaults: d).alias("fl"), flutter)
}
func test_aliasStoredAsHostPathOnly() {
    IssueRefMemory(defaults: d).setAlias("fl", to: flutter)
    XCTAssertEqual(d.dictionary(forKey: IssueRefMemory.aliasesKey) as? [String: String], ["fl": "gitlab.bdrive.com/bdrive/netdrive4_flutter"])
}
func test_removeAlias() { /* set → remove → alias("fl") nil, aliases 빈 배열 */ }
func test_picksAreNotPersisted() {
    let key = IssueRefPickKey(paneId: "p1", number: 1300, kind: .issue)
    let m = IssueRefMemory(defaults: d); m.setPick(nd3, for: key)
    XCTAssertEqual(m.snapshot.picks[key], nd3); XCTAssertNil(IssueRefMemory(defaults: d).snapshot.picks[key])
}
func test_recents_moveToFrontAndCapAtFive() { /* 6개 noteOpened 후 다시 첫 것 → count 5, first == 그것, 중복 없음 */ }
```

- [ ] **Step 2: 실패 확인** — `-only-testing:termy-tests/IssueRefMemoryTests`. Expected: 컴파일 실패.
- [ ] **Step 3: 구현** — `IssueRefMemory.swift`. `shared`는 `IssueRefMemory(defaults: .standard)`.
- [ ] **Step 4: 통과 확인** — Expected: PASS.
- [ ] **Step 5: 커밋** — `feat(issue-ref): 고른 프로젝트와 줄임말을 기억한다`

---

### Task 5: 어느 프로젝트로 열지 정하기

**Files:**
- Create: `apps/termy/Sources/IssueRefResolver.swift`
- Test: `apps/termy-tests/Sources/IssueRefResolverTests.swift`

**Interfaces:**
- Consumes: `IssueRef`, `IssueRefClue`, `KnownRepo`, `KnownRepoSnapshot.repos(named:)`, `IssueRefMemorySnapshot`, `IssueRefPickKey`, `RepoWebURL.url(number:kind:)`
- Produces:
  - `enum IssueRefCandidateTag: Equatable, Sendable { case thisPane, sameLine, recent }`
  - `struct IssueRefCandidate: Equatable, Sendable { var repo: RepoWebURL; var tag: IssueRefCandidateTag? }`
  - `enum IssueRefSaveTarget: Equatable, Sendable { case none, alias(String), pick(IssueRefPickKey) }`
  - `struct IssueRefMenuRequest: Equatable, Sendable { var title: String; var number: Int; var kind: IssueRefKind; var candidates: [IssueRefCandidate]; var limitToCandidates: Bool; var saveTarget: IssueRefSaveTarget }`
  - `enum IssueRefDecision: Equatable, Sendable { case open(URL, repo: RepoWebURL), menu(IssueRefMenuRequest), beep }`
  - `struct IssueRefContext: Sendable { var ref: IssueRef; var paneId: String?; var paneRepos: [KnownRepo]; var clues: [IssueRefClue] /* 가까운 것 먼저 */; var nearbyNames: [String] /* 가까운 것 먼저 */; var forceMenu: Bool }`
  - `enum IssueRefResolver { static let maxInitialCandidates = 6; static func isStrong(name: String, paneRepos: [KnownRepo], aliases: [String: RepoWebURL]) -> Bool; static func decide(_ ctx: IssueRefContext, index: KnownRepoSnapshot, memory: IssueRefMemorySnapshot) -> IssueRefDecision; static func names(in ctx: IssueRefContext) -> [String] /* qualifier 이름 + 이름 단서들, 다시 만들기 판단용 */ }`

결정 순서(스펙 §5 · §8). `resolve(name)` = 줄임말이 있으면 `[그것]`(줄임말로 찾음), 없으면 `index.repos(named:)`와 이름이 같은 `paneRepos`의 합. `defaults` = `paneRepos`(`.thisPane`) → `nearbyNames`를 resolve한 것(`.sameLine`) → `memory.recents`(`.recent`), web URL 중복 제거, 최대 6개. `key` = `paneId`가 있으면 `.pick(IssueRefPickKey(paneId, number, kind))`, 없으면 `.none`. "X 먼저 메뉴" = 후보 `[X(tag nil)] + defaults`(중복 제거).

1. qualifier `.joined(name)`:
   - 줄임말로 찾음 → forceMenu면 "X 먼저 메뉴"(save `.alias(name)`), 아니면 open.
   - 1개 → forceMenu면 "X 먼저 메뉴"(save `.none`), 아니면 open.
   - 여러 개 → 그것들만 후보, `limitToCandidates = true`, save `.alias(name)`.
   - 0개 → defaults 메뉴, 제목 `"\(name)\(sigil)\(n) — which project is “\(name)”?"`, save `.alias(name)`.
2. qualifier `.spaced(name)`: 0개면 qualifier 없는 것처럼 3으로. 1개이고 강한 이름이고 forceMenu 아니면 open. 1개(약한 이름이거나 forceMenu)면 "X 먼저 메뉴"(save `.none`). 여러 개면 1의 여러 개와 같다.
3. 번호만: forceMenu 아니고 `memory.picks[key]`가 있으면 open.
4. forceMenu 아니면 `clues`에서 kind가 같고 `numbers`가 번호를 포함하는 첫 단서: `.url(r)` → open. `.name(q)` → resolve가 비면 다음 단서. 1개이고 (줄임말로 찾음 또는 `.joined` 또는 강한 이름)이면 open, 아니면 "X 먼저 메뉴"(save `key`).
5. forceMenu로 여기 왔으면 3·4에서 열었을 프로젝트를 X로 한 "X 먼저 메뉴"(save `key`). 그런 것이 없거나 forceMenu가 아니면 defaults 메뉴(save `key`). defaults도 비고 `index.repos`도 비면 `.beep`.
- 기본 제목은 `"Open \(sigil)\(n) in…"`(sigil은 `#` 또는 `!`). 열 때 kind는 `ref.kind`.

- [ ] **Step 1: 실패하는 테스트 작성** — fixture: `bdweb`(github.com/bdrive/bdweb, pane), `bdriveCore`(github.com/bdrive/bdrive-core), `nd3`(gitlab.bdrive.com/bdrive/netdrive3), `flutter`(gitlab.bdrive.com/bdrive/netdrive4_flutter), `testRepo`(github.com/someone/test). `ctx(_ ref:, clues:, nearby:, paneRepos: [bdweb], force: false)` 헬퍼, `paneId: "p1"`.

```swift
func test_bareNumber_usesScrollbackNameClue() {
    let d = decide(ctx(IssueRef(number: 1300, kind: .issue, qualifier: nil),
                       clues: [IssueRefClue(numbers: 1300...1300, kind: .issue, source: .name(.spaced("netdrive3")))]))
    XCTAssertEqual(d, .open(URL(string: "https://gitlab.bdrive.com/bdrive/netdrive3/-/issues/1300")!, repo: nd3))
}
func test_bareNumber_withoutClue_showsMenu_paneRepoFirst() {
    guard case .menu(let m) = decide(ctx(bare1300, nearby: ["bdrive-core"])) else { return XCTFail() }
    XCTAssertEqual(m.title, "Open #1300 in…")
    XCTAssertEqual(m.candidates.prefix(2).map(\.tag), [.thisPane, .sameLine])
    XCTAssertEqual(m.candidates.first?.repo, bdweb)
    XCTAssertEqual(m.saveTarget, .pick(IssueRefPickKey(paneId: "p1", number: 1300, kind: .issue)))
}
func test_rangeClue_opensMiddleNumber() { /* clue bdrive-core 26...28, bare #27 → open .../bdrive-core/issues/27 */ }
func test_urlClue_opensThatRepo() { /* clue .url(nd3) 1300 → open nd3 */ }
func test_clueKindMustMatch() { /* !1300 bare + #1300 clue → 메뉴 */ }
func test_spacedStrongName_opensDirectly() { /* .spaced("bdrive-core") #26 → open */ }
func test_spacedWeakName_showsMenuWithThatRepoFirst() {
    guard case .menu(let m) = decide(ctx(IssueRef(number: 3, kind: .issue, qualifier: .spaced("Test")))) else { return XCTFail() }
    XCTAssertEqual(m.candidates.first?.repo, testRepo); XCTAssertEqual(m.saveTarget, .none)
}
func test_spacedUnknownName_actsLikeBareNumber() { /* .spaced("foo") → defaults 메뉴, save .pick */ }
func test_joinedUnknown_asksWhichProject_savesAlias() {
    guard case .menu(let m) = decide(ctx(IssueRef(number: 45, kind: .issue, qualifier: .joined("fl")))) else { return XCTFail() }
    XCTAssertEqual(m.title, "fl#45 — which project is “fl”?"); XCTAssertEqual(m.saveTarget, .alias("fl"))
}
func test_joinedAlias_opensIssueAndMergeRequest() {
    let mem = IssueRefMemorySnapshot(aliases: ["fl": flutter])
    XCTAssertEqual(decide(ctx(IssueRef(number: 189, kind: .mergeRequest, qualifier: .joined("fl"))), memory: mem),
                   .open(URL(string: "https://gitlab.bdrive.com/bdrive/netdrive4_flutter/-/merge_requests/189")!, repo: flutter))
}
func test_ambiguousName_limitsMenu_savesAlias() { /* index에 이름이 같은 두 저장소 → limitToCandidates, save .alias */ }
func test_rememberedPick_beatsClue() { /* picks[p1,1300,issue] = bdweb, clue netdrive3 → open bdweb */ }
func test_forceMenu_onBare_putsWhatWouldOpenFirst() { /* clue netdrive3 + force → menu, first nd3, save .pick */ }
func test_forceMenu_onKnownJoinedName_savesNothing() { /* netdrive3#1300 + force → menu, save .none */ }
func test_weakNameClue_showsMenu() { /* clue .spaced("test") 3...3, bare #3 → menu, first testRepo, save .pick */ }
func test_hcPane_hasNoThisPaneCandidate() { /* paneRepos [], paneId "p1" → menu, tags에 .thisPane 없음 */ }
func test_noKnownProjects_beeps() { /* index 빈 것, paneRepos [], recents [] → .beep */ }
func test_isStrong() {
    XCTAssertTrue(IssueRefResolver.isStrong(name: "bdrive-core", paneRepos: [], aliases: [:]))
    XCTAssertTrue(IssueRefResolver.isStrong(name: "netdrive3", paneRepos: [], aliases: [:]))
    XCTAssertFalse(IssueRefResolver.isStrong(name: "common", paneRepos: [], aliases: [:]))
    XCTAssertTrue(IssueRefResolver.isStrong(name: "bdweb", paneRepos: [KnownRepo(web: bdweb, localPath: "/w/bdweb")], aliases: [:]))
}
```

- [ ] **Step 2: 실패 확인** — `-only-testing:termy-tests/IssueRefResolverTests`. Expected: 컴파일 실패.
- [ ] **Step 3: 구현** — 위 결정 순서대로 `IssueRefResolver.swift`.
- [ ] **Step 4: 통과 확인** — Expected: PASS.
- [ ] **Step 5: 커밋** — `feat(issue-ref): 참조를 어느 프로젝트로 열지 정한다`

---

### Task 6: 프로젝트 고르는 메뉴

**Files:**
- Create: `apps/termy/Sources/IssueRefPickerModel.swift`, `apps/termy/Sources/IssueRefPickerPanel.swift`
- Test: `apps/termy-tests/Sources/IssueRefPickerTests.swift`

**Interfaces:**
- Consumes: `IssueRefMenuRequest`, `IssueRefCandidate`, `IssueRefCandidateTag`, `RepoWebURL`, `FuzzyMatch.score(query:text:)`
- Produces:
  - `struct IssueRefPickerRow: Equatable { enum Action: Equatable { case pick(RepoWebURL), showAll }; let action: Action; let title: String; let tagLabel: String?; let detail: String }`
  - `struct IssueRefPickerModel { static let maxSearchResults = 12; init(request: IssueRefMenuRequest, allRepos: [RepoWebURL]); func rows(query: String, showAll: Bool) -> [IssueRefPickerRow] }`
  - `@MainActor final class IssueRefPickerPanel: NSPanel { static let shared: IssueRefPickerPanel; init(); func present(request: IssueRefMenuRequest, allRepos: [RepoWebURL], at screenPoint: NSPoint, onPick: @escaping (RepoWebURL) -> Void); func commitSelection(); func cancelAndClose(); var visibleRows: [IssueRefPickerRow] { get } }`

`rows` 규칙: 검색어가 비고 `showAll`이 아니면 후보 줄들 + (`limitToCandidates`가 아니면) 끝에 `Show All Projects…` 줄. `showAll`이면 전체(`allRepos` + 후보, 중복 제거)를 이름순으로. 검색어가 있으면 범위(`limitToCandidates`면 후보만, 아니면 전체)에서 `FuzzyMatch.score(query, name) ?? FuzzyMatch.score(query, storageKey)`가 있는 것만, 점수 오름차순 · 이름순, 최대 12개, `Show All Projects…` 없음. `title` = `repo.name`, `detail` = `repo.displayOwner`, `tagLabel` = `this pane` / `same line` / `recent` / nil.

패널: `ProjectSwitcherPanel`을 본뜬다(`.nonactivatingPanel, .borderless`, `canBecomeKey == true`, 검색 칸이 first responder, `SearchDelegate`가 ↑↓ · Enter · Esc 처리, 바깥 클릭으로 key를 잃으면 고르지 않고 닫음). 위에서부터 회색 제목(`request.title`), 검색 칸(placeholder `Search projects…`), 줄 목록(이름, 태그, 오른쪽 회색 detail), 첫 줄 선택 상태. 왼쪽 위 모서리를 `screenPoint`에 두고 화면 `visibleFrame` 안으로 당긴다. 폭 360. `Show All Projects…`를 고르면 검색 칸을 비우고 `showAll` 목록으로 바꾼다(닫지 않음).

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
func test_rows_emptyQuery_candidatesThenShowAll() {
    let rows = IssueRefPickerModel(request: request(candidates: [.init(repo: bdweb, tag: .thisPane), .init(repo: bdriveCore, tag: .sameLine)]),
                                   allRepos: [nd3]).rows(query: "", showAll: false)
    XCTAssertEqual(rows.map(\.title), ["bdweb", "bdrive-core", "Show All Projects…"])
    XCTAssertEqual(rows.map(\.tagLabel), ["this pane", "same line", nil])
    XCTAssertEqual(rows.first?.detail, "github.com/bdrive")
}
func test_rows_query_searchesAllKnownRepos() { /* "nd3" → 첫 줄 netdrive3 */ }
func test_rows_limitToCandidates_hidesShowAllAndOtherRepos() { /* limit true → Show All 없음, 검색도 후보 안에서만 */ }
func test_rows_showAll_sortedByName() { /* showAll true → 이름순 전체 */ }
func test_rows_searchCappedAtTwelve() { /* 20개 중 "a" → 12줄 */ }
@MainActor func test_panel_enterPicksFirstCandidate() {
    let panel = IssueRefPickerPanel(); var picked: [RepoWebURL] = []
    panel.present(request: request(candidates: [.init(repo: bdweb, tag: .thisPane)]), allRepos: [], at: NSPoint(x: 100, y: 500)) { picked.append($0) }
    panel.commitSelection(); XCTAssertEqual(picked, [bdweb]); panel.orderOut(nil)
}
@MainActor func test_panel_cancelPicksNothing() { /* present → cancelAndClose → picked 빈 배열 */ }
```

- [ ] **Step 2: 실패 확인** — `-only-testing:termy-tests/IssueRefPickerTests`. Expected: 컴파일 실패.
- [ ] **Step 3: 구현** — 모델, 그다음 패널.
- [ ] **Step 4: 통과 확인** — Expected: PASS.
- [ ] **Step 5: 커밋** — `feat(issue-ref): 프로젝트를 고르는 메뉴를 더한다`

---

### Task 7: Cmd+클릭에 연결

**Files:**
- Create: `apps/termy/Sources/IssueRefController.swift`
- Modify: `apps/termy/Sources/TermyTerminalView.swift` (`handleLinkClickMouseUp` 351행 근처, `openLinkUnderMouse` 367행 근처, `screenText(after:at:)`의 `continues(below:)`를 private 메서드로 꺼내 함께 씀)
- Modify: `apps/termy/Sources/Pane.swift` (177행 근처 클로저 연결, `previewBaseDirectories` 옆에 static 함수)
- Test: `apps/termy-tests/Sources/TermyTerminalViewTests.swift`(추가), `apps/termy-tests/Sources/IssueRefControllerTests.swift`, `apps/termy-tests/Sources/PanePreviewBaseDirectoriesTests.swift`(추가)

**Interfaces:**
- Consumes: Task 2–6의 전부.
- Produces:
  - `struct IssueRefScreenContext: Equatable, Sendable { var text: String; var clickOffset: Int; var linesAbove: [String] /* 오래된 것 먼저 */ }`
  - `struct IssueRefClick: Sendable { var hit: IssueRefHit; var screen: IssueRefScreenContext; var forceMenu: Bool; var anchorScreenPoint: NSPoint }`
  - `TermyTerminalView`: `var onIssueRefClick: ((IssueRefClick) -> Void)?`; `func issueRefScreenContext(atScreen pos: Position) -> IssueRefScreenContext?`
  - `Pane`: `nonisolated static func issueRefRepoRoots(isRemote: Bool, shellCwd: String, agentCwd: String?, workTreeRoot: (String) -> String?) -> [String]`
  - `@MainActor final class IssueRefController { static let shared: IssueRefController; init(index: KnownRepoIndex, memory: IssueRefMemory, openURL: @escaping (URL) -> Void, presentMenu: @escaping (IssueRefMenuRequest, [RepoWebURL], NSPoint, @escaping (RepoWebURL) -> Void) -> Void, beep: @escaping () -> Void); func handle(_ click: IssueRefClick, paneId: String?, paneRoots: [String]) async; func applyPick(_ repo: RepoWebURL, request: IssueRefMenuRequest); nonisolated static func context(for click: IssueRefClick, paneId: String?, paneRepos: [KnownRepo]) -> IssueRefContext }`

동작:
- `issueRefScreenContext`: 클릭한 행과, 그 행이 이어 붙는 윗행들(`continues(below:)`가 참인 동안, 최대 4행)을 `screenText`와 같은 방식으로 합친다(soft wrap은 그냥 붙이고, 아니면 `"\n"`). 넓은 글자의 오른쪽 반을 누르면 그 글자로 친다. `linesAbove`는 합친 첫 행 위의 모든 행: `getBufferAsData()`를 줄로 나눠 `getTopVisibleRow() + 첫 행` 앞까지, 각 줄에서 `"\u{0}"`을 지운다.
- `openLinkUnderMouse(windowLocation:forceMenu:)`: `linkClickAction(atScreen:…)` 결과가 nil이거나 `.ignore`면 `issueRefScreenContext` → `IssueRefParser.hit` → 있으면 `onIssueRefClick` 호출 후 `true`(클릭 소비). `handleLinkClickMouseUp`은 `event.modifierFlags.contains(.option)`을 `forceMenu`로 넘기고, `anchorScreenPoint`는 `window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow`(테스트의 창 없는 view 대비).
- `context(for:…)`: 단서 = `linesAbove` + 클릭한 텍스트의 `hit.start` 앞부분을 줄마다 `IssueRefParser.clues`로 읽어, 아래 줄부터 · 한 줄 안에서는 오른쪽부터. `nearbyNames` = 클릭한 텍스트 전체의 `mentionedNames` → `linesAbove` 끝 20행을 아래부터, 중복 없이.
- `handle`: `paneRepos = await index.paneRepos(roots: paneRoots)`, `snapshot = await index.snapshot()`, `decide`. 결과가 `.menu`이고 `IssueRefResolver.names(in:)` 중 `snapshot.repos(named:)`도 비고 줄임말도 없는 이름이 있으면 `await index.rebuild()`로 한 번만 다시 정한다. `.open(url, repo)` → `memory.noteOpened(repo)` 후 `openURL(url)`. `.menu(req)` → `presentMenu(req, snapshot.repos.map(\.web) + 줄임말 대상들, anchor) { applyPick($0, request: req) }`. `.beep` → `beep()`.
- `applyPick`: saveTarget이 `.alias(n)`이면 `memory.setAlias(n, to: repo)`, `.pick(k)`이면 `memory.setPick(repo, for: k)`. 그다음 `noteOpened`, `openURL(repo.url(number:kind:))`.
- `Pane.issueRefRepoRoots`: `isRemote`면 `[]`, 아니면 `[shellCwd, agentCwd]`의 worktree root를 그 순서로 중복 없이. Pane은 `terminal.onIssueRefClick`에서 `paneId`와 이 roots를 잡아 `Task { await IssueRefController.shared.handle(…) }`.

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
// TermyTerminalViewTests
@MainActor func test_screenContext_koreanPrefix_hitsNumber() throws {
    let view = TermyTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
    view.getTerminal().resize(cols: 100, rows: 10)
    view.feed(text: "- 답을 기다리는 것: #1300 코디네이터 판단, bdrive-core #26~#28 수정.")
    // "- "=0–1, 답을=2–5, 공백 6, 기다리는=7–14, 공백 15, 것=16–17, ':'=18, 공백 19, '#'=20, '1'=21
    let ctx = try XCTUnwrap(view.issueRefScreenContext(atScreen: Position(col: 21, row: 0)))
    XCTAssertEqual(IssueRefParser.hit(in: ctx.text, atOffset: ctx.clickOffset)?.ref, IssueRef(number: 1300, kind: .issue, qualifier: nil))
}
@MainActor func test_screenContext_joinsInkHardWrap() throws {
    let view = TermyTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    view.getTerminal().resize(cols: 40, rows: 10)
    // 0행이 40칸을 꽉 채우고, Ink처럼 CR · 커서 아래 · 두 칸 들여쓰기로 이어 쓴다.
    view.feed(text: "  waiting: coordinator call, bdrive-core\r\u{1b}[1B\u{1b}[2C#26 fix")
    let ctx = try XCTUnwrap(view.issueRefScreenContext(atScreen: Position(col: 3, row: 1)))
    XCTAssertEqual(IssueRefParser.hit(in: ctx.text, atOffset: ctx.clickOffset)?.ref.qualifier, .spaced("bdrive-core"))
}
@MainActor func test_screenContext_linesAboveIncludeScrollback() { /* 30행 터미널에 40줄 출력, 마지막 줄 클릭 → linesAbove.count >= 39, linesAbove.first == 첫 줄 */ }
@MainActor func test_urlWithFragment_staysURL() {
    // "see https://example.com/page#12" 의 '#12' 위 → linkClickAction(atScreen:…) == .openURL(https://example.com/page#12)
}
@MainActor func test_cmdClickOnIssueRef_reportsClickAndConsumes() throws {
    let view = Self.mouseCapturingTerminal(showing: "fl#45")
    var clicks: [IssueRefClick] = []; view.onIssueRefClick = { clicks.append($0) }
    let up = try XCTUnwrap(Self.mouseEvent(.leftMouseUp, at: NSPoint(x: 2, y: view.frame.height - 2), modifierFlags: [.command, .option]))
    XCTAssertNil(view.handleLinkClickMouseUp(up))
    XCTAssertEqual(clicks.first?.hit.ref, IssueRef(number: 45, kind: .issue, qualifier: .joined("fl")))
    XCTAssertEqual(clicks.first?.forceMenu, true)
}

// IssueRefControllerTests — 임시 디렉터리 저장소 + 테스트용 UserDefaults, openURL/presentMenu/beep 기록
@MainActor func test_handle_exampleLine_opensNetdrive3WithoutMenu() async {
    // linesAbove: ["2. netdrive3 #1300 코디네이터 판단: 아직 답이 없습니다"], text: 예시 줄, #1300 클릭, index에 netdrive3
    // → opened == [https://gitlab.bdrive.com/bdrive/netdrive3/-/issues/1300], menus 빈 배열, memory.recents.first == nd3
}
@MainActor func test_handle_unknownName_rebuildsIndexOnce() async {
    // workspacePaths가 첫 호출엔 [], 둘째부터 [netdrive3 저장소] → "netdrive3#1300" 클릭이 메뉴 없이 열림, 호출 2회
}
@MainActor func test_applyPick_savesAliasAndOpens() {
    // request(number 45, .issue, save .alias("fl")) + flutter → memory.alias("fl") == flutter, opened == [.../netdrive4_flutter/-/issues/45]
}
func test_context_cluesNearestFirst() {
    // linesAbove ["netdrive3 #1300", "bdweb #1300"] → context.clues.first?.source == .name(.spaced("bdweb"))
}

// PanePreviewBaseDirectoriesTests
func test_issueRefRepoRoots_remotePaneIsEmpty() { XCTAssertEqual(Pane.issueRefRepoRoots(isRemote: true, shellCwd: "/w/bdweb", agentCwd: nil, workTreeRoot: { $0 }), []) }
func test_issueRefRepoRoots_shellThenAgentDeduped() { /* shell /w/bdweb/sub, agent /w/bdweb, workTreeRoot → "/w/bdweb" 둘 다 → ["/w/bdweb"] */ }
```

- [ ] **Step 2: 실패 확인** — `-only-testing:termy-tests/TermyTerminalViewTests -only-testing:termy-tests/IssueRefControllerTests -only-testing:termy-tests/PanePreviewBaseDirectoriesTests`. Expected: 컴파일 실패.
- [ ] **Step 3: 구현** — `IssueRefController.swift`, `TermyTerminalView` 변경, `Pane` 연결. `IssueRefController.shared`는 `KnownRepoIndex.shared`, `IssueRefMemory.shared`, `NSWorkspace.shared.open`, `IssueRefPickerPanel.shared.present`, `NSSound.beep`로 만든다.
- [ ] **Step 4: 통과 확인** — 같은 명령, 그다음 기존 링크 테스트가 그대로인지 `-only-testing:termy-tests/PreviewLinkResolverTests`도. Expected: PASS.
- [ ] **Step 5: 커밋** — `feat(issue-ref): Cmd+클릭한 issue 번호를 브라우저로 연다`

---

### Task 8: 설정에서 줄임말 지우기

**Files:**
- Modify: `apps/termy/Sources/FontSettingsPanel.swift` (`Quitting` 섹션 뒤에 같은 꼴의 섹션)
- Test: `apps/termy-tests/Sources/FontSettingsPanelIssueLinksTests.swift`

**Interfaces:**
- Consumes: `IssueRefMemory.aliases`, `removeAlias(_:)`
- Produces: `FontSettingsPanel`: `var issueRefMemory: IssueRefMemory` (기본 `.shared`); `func reloadIssueAliases()`; `@objc func removeIssueAlias(_ sender: Any?)`; 테스트용 `var issueAliasTitles: [String] { get }`, `var isRemoveIssueAliasEnabled: Bool { get }`

머리글 `Issue Links`, 그 아래 한 줄: 줄임말 popup(`fl → gitlab.bdrive.com/bdrive/netdrive4_flutter`, 이름순) + `Remove` 버튼. 줄임말이 없으면 popup에 비활성 항목 `No abbreviations` 하나, `Remove`도 비활성. 패널을 열 때(`syncFromPreference()`)와 지운 뒤 `reloadIssueAliases()`.

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
@MainActor func test_issueLinks_listsAndRemovesAliases() {
    let panel = FontSettingsPanel(); panel.issueRefMemory = IssueRefMemory(defaults: testDefaults)
    panel.issueRefMemory.setAlias("fl", to: RepoWebURL(storageKey: "gitlab.bdrive.com/bdrive/netdrive4_flutter")!)
    panel.reloadIssueAliases()
    XCTAssertEqual(panel.issueAliasTitles, ["fl → gitlab.bdrive.com/bdrive/netdrive4_flutter"]); XCTAssertTrue(panel.isRemoveIssueAliasEnabled)
    panel.removeIssueAlias(nil)
    XCTAssertEqual(panel.issueRefMemory.aliases, []); XCTAssertEqual(panel.issueAliasTitles, ["No abbreviations"]); XCTAssertFalse(panel.isRemoveIssueAliasEnabled)
    panel.orderOut(nil)
}
```

- [ ] **Step 2: 실패 확인** — `-only-testing:termy-tests/FontSettingsPanelIssueLinksTests`. Expected: 컴파일 실패.
- [ ] **Step 3: 구현** — 기존 `quittingStack`과 같은 레이아웃 패턴으로 섹션 추가, 패널 높이 조정.
- [ ] **Step 4: 통과 확인** — Expected: PASS.
- [ ] **Step 5: 커밋** — `feat(issue-ref): 설정에서 issue 줄임말을 지울 수 있다`

---

### Task 9: 전체 테스트와 실제 앱 확인

**Files:** 없음(확인만). 고칠 것이 나오면 해당 태스크 파일을 고치고 그 태스크 꼴로 커밋.

- [ ] **Step 1: 전체 테스트** — `cd /Users/ysh/proj/termy && xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation 2>&1 | tail -25`. Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 2: Debug 빌드** — `xcodebuild -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-build build 2>&1 | tail -5`. Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 3: 실제 앱에서 확인(사용자에게 부탁)** — Debug 앱을 agent가 띄우면 hook 경로를 바꾸고 이전 debug 세션의 agent를 되살리므로, 앱은 직접 띄우지 않는다. Step 2의 빌드 경로와 아래 목록을 사용자에게 넘기고 결과를 받는다. `~/work/bdweb`에서 연 pane에서:
  1. `printf '2. netdrive3 #1300 코디네이터 판단: 아직 답이 없습니다\n- 답을 기다리는 것: #1300 코디네이터 판단, bdrive-core #26~#28 수정.\n'` → 둘째 줄 `#1300` Cmd+클릭: 메뉴 없이 `gitlab.bdrive.com/bdrive/netdrive3/-/issues/1300`. `#28`: `github.com/bdrive/bdrive-core/issues/28`.
  2. scrollback이 빈 새 pane(같은 `~/work/bdweb`)에서 `printf -- '- 답을 기다리는 것: #1300 코디네이터 판단\n'` → `#1300` Cmd+클릭: 메뉴, 첫 줄 `bdweb  this pane`. Esc로 닫힘.
  3. `printf 'fl#45\n'` → 메뉴(`fl#45 — which project is “fl”?`), `flu` 입력 → netdrive4_flutter 선택. 다시 Cmd+클릭 → 메뉴 없이 열림. ⌥⌘+클릭 → 메뉴. ⌘, → `Issue Links`에 `fl → …` 있고 `Remove`로 지워짐.
  4. `printf 'Test #3\n'` → 메뉴(바로 열리지 않음).
  5. `printf 'https://example.com/page#12\n'` → Cmd+클릭은 URL을 연다.
- [ ] **Step 4: GitHub PR 번호 redirect 확인** — `gh pr list -R bdrive/bdweb --state all --limit 1 --json number`로 PR 번호를 얻고 브라우저에서 `https://github.com/bdrive/bdweb/issues/<번호>`를 열어 `/pull/<번호>`로 넘어가는지 본다. 넘어가지 않으면 사용자에게 알리고 멈춘다(설계를 고쳐야 한다).
