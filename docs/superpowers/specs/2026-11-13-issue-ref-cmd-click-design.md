# issue · PR · MR 번호 Cmd+클릭 — 설계 문서

- 날짜: 2026-11-13
- 상태: 초안
- 범위: 터미널에 찍힌 `#1234`, `fl#1234`, `bdrive-core #26`, `!189` 같은 참조를 Cmd+클릭하면 해당 issue · PR · MR
  페이지를 기본 브라우저로 연다. 어느 프로젝트의 번호인지는 터미널 텍스트와 termy가 이미 아는 로컬 저장소만으로 정하고,
  정할 수 없으면 클릭한 자리에 프로젝트를 고르는 메뉴를 띄운다.
- 관련 코드: `TermyTerminalView.swift`의 Cmd+클릭 경로(`handleLinkClickMouseUp` → `linkClickAction`),
  `PreviewLinkResolver.swift`(같은 경로의 파일 미리보기 판단)

## 1. 목표와 동기

agent가 요약에서 issue를 번호로만 말한다. 사용자는 그 issue를 열어 내용을 확인하고 싶은데, 지금은 번호를 복사해 브라우저에서
직접 찾아가야 한다. 실제로 겪은 줄:

```
- 답을 기다리는 것: #1300 코디네이터 판단, bdrive-core #26~#28 수정.
```

이 줄은 `~/work/bdweb`(GitHub `github.com/bdrive/bdweb`)에서 돌던 Claude가 출력했다. 그런데 `#1300`은 사내 GitLab
`gitlab.bdrive.com/bdrive/netdrive3`의 issue이고, `bdrive-core`는 bdweb의 submodule `3rd_party/bdrive-core`
(`github.com/bdrive/bdrive-core`)이다. 그래서 **"pane이 있는 repo로 연다"는 단순한 규칙은 이 예시에서 틀린 페이지를 연다.**
대신 같은 대화 앞부분에서 agent가 `netdrive3 #1300`이라고 여러 번 썼으므로, 답은 scrollback 안에 있었다.

사용자 환경에서 확인한 사실:

- 저장소가 GitHub(`github.com/bdrive/*`)와 사내 GitLab(`gitlab.bdrive.com/bdrive/*`)에 섞여 있다. host · owner를 pane repo에서
  빌려 오는 추측은 netdrive3에서 틀린다.
- agent가 만든 줄임말을 쓴다. netdrive3 쪽 대화에서 `fl#45`, `fl!189`가 `netdrive4_flutter`를 가리켰다. `fl`을 정의한 파일은 없다.
  같은 대화에 `netdrive4_flutter#25`, `netdrive4_flutter!102` 같은 GitLab식 표기도 섞여 나온다.
- 한 저장소(`~/work/netdrive3/netdrive3_sdk`)는 origin URL에 access token이 들어 있다. remote URL을 다룰 때 인증 정보를 반드시 떼어 낸다.

성공 기준:

- 위 예시 줄에서 `#1300`을 Cmd+클릭하면, 같은 scrollback에 `netdrive3 #1300`이 남아 있는 한 netdrive3 #1300 issue가 바로 열린다.
- `bdrive-core #26`, `#28`을 각각 Cmd+클릭하면 bdrive-core의 #26, #28이 열린다.
- `fl#45`는 처음 한 번 메뉴에서 netdrive4_flutter를 고르면, 그다음부터 메뉴 없이 열린다.
- 단서가 없는 `#1234`는 메뉴가 뜨고, 첫 후보가 선택된 상태라 Enter 한 번이면 열린다.
- `Test #3`, `PR#12`처럼 평범한 낱말이 붙은 번호는 그 낱말과 이름이 같은 저장소를 조용히 열지 않는다.
- URL · 파일 경로 · OSC 8 링크의 지금 Cmd+클릭 동작은 그대로다.

## 2. 비목표와 안티 목표

비목표:

- Jira식 `ABC-123` 같은 다른 issue tracker 표기.
- GitHub Enterprise · Gitea · Bitbucket 구분. github.com이 아닌 host는 GitLab으로 본다(§6).
- Cmd를 누른 채 마우스를 올렸을 때 밑줄로 표시하기. 이번에는 클릭 동작만 만든다(내 판단).
- 범위 `#26~#28`에서 중간 번호 `#27`을 여는 것. 화면에 쓰인 번호만 클릭할 수 있다.
- issue 내용을 termy 안에서 미리 보여 주는 것. 브라우저로 넘긴다.
- 네트워크로 GitHub/GitLab API를 불러 번호가 실제로 있는지 확인하는 것.

안티 목표(동작은 해도 실패로 본다):

- 확신 없이 틀린 프로젝트의 페이지를 조용히 여는 것. 이것을 막으려고 메뉴를 둔다.
- 일반 단어를 줄임말로 잘못 기억하는 것. 예: `issue #12`, `항목 #3`, `MR #102`에서 앞 단어를 프로젝트 이름으로 저장하면 안 된다.
- remote URL에 들어 있는 token이 열리는 URL, 로그, 저장된 설정 어디에든 남는 것.
- Cmd+클릭 때문에 main thread가 눈에 띄게 멈추는 것.

## 3. 지금 동작 (근거)

- Cmd+클릭은 `leftMouseUp` local monitor가 받아 `handleLinkClickMouseUp`(`TermyTerminalView.swift:351`) →
  `openLinkUnderMouse` → `linkClickAction(atScreen:…)`로 간다. 결과는 `LinkClickAction`
  (`.preview` · `.beep` · `.openURL` · `.ignore`, `TermyTerminalView.swift:23`)이다.
- 링크 후보는 SwiftTerm `terminal.link(at:mode: .explicitAndImplicit)`가 준다. OSC 8 링크와 URL · 경로는 잡지만
  `#1300` 같은 참조는 링크로 보지 않으므로 nil이 돌아온다. 이 경우 지금은 아무 일도 하지 않고 이벤트를 흘려보낸다.
- pane의 기준 디렉터리는 `Pane.previewBaseDirectories()`(`Pane.swift:690`)가 준다: 셸 cwd(OSC 7), agent hook의 `lastCwd`,
  셸 cwd의 worktree root. worktree root는 `GitBranch.workTreeRoot(for:)`.
- scrollback은 pane마다 10,000줄(`TermyTerminalView.scrollbackLines`). 클릭한 줄 주변 텍스트를 읽는 예로
  `screenText(after:at:)`가 있다(`isWrapped`로 soft wrap을 잇는다).
- termy가 아는 프로젝트는 ⌘K 기록 `WorkspacePersistence.all()`의 `canonicalPath`들이다(지금 124개, git이 아닌 폴더와
  `backend-1:/home/ubuntu` 같은 원격 항목이 섞여 있다).
- hc 원격 pane은 `Pane.isRemote`가 true이고, cwd가 원격 머신에 있다.
- ⌘K 검색은 `FuzzyMatch.score(query:text:)`를 쓴다.

## 4. 인식하는 표기

클릭한 셀이 아래 토큰 위에 있을 때만 동작한다. `N`은 숫자.

| 표기 | 예 | 종류 |
|---|---|---|
| `#N` | `#1300` | issue (GitHub에서는 PR도 같은 번호 공간) |
| `!N` | `!189` | GitLab MR (GitHub repo면 PR) |
| `이름#N`, `이름!N` (붙여 씀) | `fl#45`, `netdrive3#1300`, `bdrive/netdrive3#1300`, `netdrive4_flutter!102` | 이름이 붙은 참조 |
| `이름 #N` (한 칸 띄움) | `bdrive-core #26` | 이름이 알려진 프로젝트일 때만 이름이 붙은 참조 |
| 앞 참조에 이어지는 번호 | `bdrive-core #26~#28`의 `#28`, `bdrive-core #26, #27`의 `#27` | 앞 참조의 이름을 물려받는다 |

규칙:

- `#`/`!` 앞은 줄 시작이나 공백 · 문장부호 · 이름이어야 하고, 숫자 뒤에는 한글 조사가 바로 붙을 수 있다(`#1300에`).
- **이름을 물려받는 범위:** 번호 토큰은 바로 앞의 이름 붙은 참조와의 사이에 번호 토큰과 구분 기호(공백, `~`, `-`, `·`, `,`, `/`)만
  있을 때 그 이름을 물려받는다. 다른 단어가 끼면 끊긴다. 그래서 위 예시에서 `#1300`은 뒤의 `bdrive-core`와 상관없다.
- **띄어 쓴 이름:** `이름 #N`의 `이름`이 알려진 프로젝트나 등록된 줄임말이 아니면 그냥 번호만 있는 참조로 본다. `issue #12`,
  `항목 #3`에서 앞 단어를 줄임말 후보로 다루지 않는다.
- **강한 이름과 약한 이름(내 판단):** 알려진 저장소 이름에 `test`, `support`, `common`, `protocols`, `framework`, `fonts`처럼
  평범한 낱말이 많다(지금 목록에서 약 50개). 그래서 띄어 쓴 이름은 둘로 나눈다.
  - **강한 이름**은 바로 연다: 이 pane의 repo와 그 submodule의 이름, 등록된 줄임말, `-` · `_` · `.` · 숫자가 들어간 이름
    (`bdrive-core`, `netdrive3`, `netdrive4_flutter`), `owner/repo` 꼴.
  - **약한 이름**(영문자만으로 된 그 밖의 이름)은 바로 열지 않는다. 메뉴를 띄우되 그 프로젝트를 첫 후보로 선택해 둔다.
    그래서 `Test #3`이 test 저장소를 조용히 열지 않고, `common #12`가 진짜 common 저장소를 뜻했다면 Enter 한 번으로 열린다.
  - 붙여 쓴 알려진 이름(`common#12`)은 GitLab 표기를 일부러 쓴 것으로 보고 강한 이름으로 다룬다.
- **붙여 쓴 이름:** `fl#45`처럼 붙어 있는데 모르는 이름이면 줄임말로 보고 메뉴를 띄운다(§7).
- **일반 낱말 제외(내 판단):** `PR`, `MR`, `issue`, `Issue`, `bug`, `ticket`, `이슈`, `버그` 같은 낱말이 붙어 있으면(`PR#12`,
  `MR!3`, `issue#12`) 줄임말로 보지 않고 번호만 있는 참조로 다룬다. 목록은 builder가 다듬는다. 이 낱말들은 줄임말로 저장되지 않는다.
- **MR 낱말(내 판단):** 번호 바로 앞이 `MR`이고 프로젝트가 GitLab이면 `#N`도 merge request로 연다. `PR #N`은 GitHub에서 issue URL로
  열어도 PR로 넘어가므로 따로 다루지 않는다.
- Claude Code는 긴 줄을 커서 이동으로 줄바꿈하므로 `bdrive-core`가 한 행 끝에, `#26`이 다음 행 처음에 있을 수 있다.
  `isWrapped`가 아니어도 클릭한 행의 바로 윗행 끝을 이어서 보고 이름을 찾는다. 구체적인 방법은 builder에게 맡긴다.
- 이미 링크인 텍스트(OSC 8, URL, 파일 경로)는 지금 동작이 먼저다. 참조 인식은 `terminal.link(at:)`가 nil일 때만 한다.

## 5. 어느 프로젝트인지 정하는 순서

클릭한 참조마다 위에서부터 처음 걸리는 것을 쓴다.

1. **이름이 붙은 참조:** 이름을 §6으로 프로젝트에 대응시켜 바로 연다. 약한 이름(§4)이면 그 프로젝트를 첫 후보로 둔 메뉴를
   띄운다. 대응하는 프로젝트가 여럿이면(같은 이름, 다른 remote) 그 프로젝트들만 후보로 메뉴를 띄운다. 붙여 쓴 모르는 이름도 메뉴(§7).
2. **이 pane에서 전에 고른 것(내 판단):** 이 pane에서 같은 번호를 메뉴로 고른 적이 있으면 그 프로젝트로 연다.
3. **scrollback 단서:** 클릭한 행에서 위로 거슬러 올라가며 같은 번호를 가리키는 단서를 찾는다. 가장 가까운 것을 쓴다.
   - 이름 붙은 참조 중 같은 번호인 것: `netdrive3 #1300`, `netdrive3#1300`. 범위도 포함한다: `bdrive-core #26~#28`은 #26, #27, #28의
     단서다(그래서 다음 문장의 `#26·#27`도 bdrive-core로 열린다).
   - 같은 번호로 끝나는 issue · PR · MR URL: `…/netdrive3/-/issues/1300`, `…/bdweb/pull/1300`. URL이면 이름 대응 없이 그 repo를 쓴다.
   - `#`은 issue · PR 단서와, `!`는 MR 단서와 짝을 맞춘다.
   - 가장 가까운 단서가 약한 이름이면 바로 열지 않고, 그 프로젝트를 첫 후보로 둔 메뉴를 띄운다.
   - 클릭한 행 아래쪽(이후 출력)은 보지 않는다(내 판단).
4. **메뉴:** 여기까지 정해지지 않으면 클릭한 자리에 메뉴를 띄운다(§7). **pane repo로 바로 열지 않는다** — 사용자가 정했다.

## 6. 이름에서 프로젝트로, 프로젝트에서 URL로

**알려진 프로젝트 목록**(내 판단):

- 이 pane의 repo(셸 cwd와 agent `lastCwd`의 worktree root). hc 원격 pane은 없음.
- 그 repo의 submodule(`.gitmodules`의 path · url).
- ⌘K 기록 중 로컬에 있고 git 저장소인 것, 그리고 그 submodule.
- ⌘K 기록 중 git 저장소가 아닌 폴더(예: `~/work`, `~/proj`)의 바로 아래 git 저장소.
- ⌘K 기록에 있는 git 저장소와 같은 부모 폴더에 있는 git 저장소(형제).
- 줄임말 표(§8)에 있는 것.
- 왜 넓히는가: termy에서 한 번도 연 적 없는 저장소는 ⌘K 기록에 없다. 실제로 `~/work/netdrive4_flutter`는 ⌘K 기록에도, 어느
  저장소의 submodule에도 없어서, 넓히지 않으면 `fl#45`에서 고를 수조차 없다. 위 두 줄을 더하면 지금 기준으로 55개에서 139개가 되고
  netdrive4_flutter가 들어온다. 이보다 깊이 훑지는 않는다.
- 같은 web URL을 가리키는 항목은 하나로 합친다(예: `~/work/netdrive3/netdrive3`와 백업 폴더의 같은 clone).

**이름 대응**(대소문자 무시): 줄임말 → remote 경로 전체(`bdrive/netdrive3`) → remote repo 이름(`netdrive3`) → 로컬 폴더 이름.
remote 경로의 마지막 부분이 이름과 같아야 한다. 부분 일치나 fuzzy 일치로 이름을 대응시키지 않는다(그건 메뉴 검색의 몫).

**remote 고르기:** `origin`, 없으면 remote가 하나뿐일 때 그것, 아니면 그 저장소는 목록에서 뺀다
(netdrive3는 `origin`과 `glab-base`가 있으므로 `origin`).

**remote URL → web URL:** `https://[인증정보@]host/path(.git)`, `git@host:path(.git)`, `ssh://git@host[:port]/path(.git)`를
`https://host/path`로 바꾼다. 인증 정보, ssh 포트, `.git`은 버린다. GitLab subgroup(`group/sub/project`)을 지원한다.

**URL 만들기:**

| host | `#N` | `!N` (또는 `MR #N`) |
|---|---|---|
| `github.com` | `https://github.com/{path}/issues/{N}` (PR이면 GitHub이 `/pull/{N}`으로 넘겨 준다 — 구현 때 한 번 확인) | `https://github.com/{path}/pull/{N}` |
| 그 밖의 host | `https://{host}/{path}/-/issues/{N}` | `https://{host}/{path}/-/merge_requests/{N}` |

열기는 지금 `.openURL` 경로처럼 `NSWorkspace.shared.open`. http(s) URL만 연다.

**읽는 시점:** 목록은 첫 클릭 때 만들고 캐시한다. 이름을 못 찾으면 한 번 다시 만든다. git 설정은 파일로 읽든 `git`을 실행하든
builder가 정하되, main thread를 막지 않는다(§10).

## 7. 메뉴 (사용자가 고른 A안)

mockup: `.superpowers/brainstorm/94566-1794539912/content/issue-menu.html`의 A.

화면 문구는 이 앱의 관례대로 영어로 쓴다(내 판단 — mockup은 설명용으로 한국어였다). 아래 괄호 안이 실제 문구다.

- 클릭한 자리에 macOS 메뉴처럼 뜬다. 맨 위 회색 제목(`Open #1300 in…`), 그 아래 검색 칸(`Search projects…`),
  그 아래 후보 목록, 구분선, `Show All Projects…`.
- 메뉴가 뜨자마자 타이핑하면 검색 칸으로 들어가고, 목록이 알려진 프로젝트 전체(§6)에서 `FuzzyMatch`로 걸러진다.
- 처음 보이는 후보 순서: 이 pane의 repo(`this pane`) → 같은 줄이나 근처 scrollback에 이름이 나온 프로젝트(`same line`) →
  최근에 issue를 연 프로젝트(`recent`). 최대 몇 개를 보일지는 builder가 정한다. 각 줄 오른쪽에 회색으로 host와 owner
  (`github.com/bdrive`, `gitlab.bdrive.com/bdrive`).
- 첫 후보가 선택된 채로 뜬다. ↑↓로 고르고, Enter나 클릭으로 열고, Esc나 바깥 클릭으로 닫는다.
- `Show All Projects…`는 검색 칸을 비운 채 전체 목록을 보여 준다.
- 붙여 쓴 모르는 이름(`fl#45`)일 때 제목은 `fl#45 — which project is “fl”?`로 바꾸고, 검색 칸에 미리 `fl`을 넣지는 않는다(내 판단).
- hc 원격 pane에서는 `this pane` 후보가 없다.
- 알려진 프로젝트가 하나도 없으면 메뉴 대신 지금처럼 beep(내 판단).

메뉴를 NSMenu로 만들지, 검색 칸을 넣기 쉬운 NSPanel/NSPopover로 만들지는 builder에게 맡긴다. 보이는 모양과 키 동작이 위와 같으면 된다.

## 8. 기억하기 (내 판단 — 사용자에게 물었으나 답 없이 진행하라고 했다)

- **줄임말:** 붙여 쓴 모르는 이름에서 프로젝트를 고르면 `이름 → web URL`을 `UserDefaults`에 영구히 저장한다. 다음부터 그
  이름은 §5의 1번으로 바로 열린다. 띄어 쓴 이름은 저장하지 않는다(§2 안티 목표).
- **번호만 있는 참조:** 메뉴에서 고른 것은 `(pane, 번호, #/!) → 프로젝트`로 메모리에만 기억한다. 앱을 다시 켜면 잊는다.
- **최근 프로젝트:** issue를 연 프로젝트 몇 개를 `UserDefaults`에 최근 순으로 둔다(메뉴의 `recent` 후보).
- **같은 이름이 여러 프로젝트에 대응할 때:** 메뉴에서 고른 것을 그 이름의 줄임말로 저장한다. 다음부터는 묻지 않는다.
- **고치는 길:** ⌥⌘+클릭은 단서나 기억이 있어도 항상 메뉴를 띄운다. 고른 결과를 어디에 남기는지는 참조 종류에 따라 다르다.
  - 번호만 있는 참조: 이 pane의 기억(`(pane, 번호, #/!)`)을 덮어쓴다.
  - 붙여 쓴 줄임말(`fl#45`)이나 여러 프로젝트에 대응하는 이름: 줄임말 표를 덮어쓴다.
  - 그 밖의 이름 붙은 참조(`bdrive-core #26`, `netdrive3#1300`처럼 실제 저장소 이름과 맞는 것): 이번 한 번만 연다. 저장하지 않는다.
    실제 저장소 이름을 다른 프로젝트로 영구히 돌리는 기능은 만들지 않는다.
- ⌘, 설정 패널에 줄임말 목록을 두고 지울 수 있게 한다(편집은 지우고 다시 고르는 것으로 충분하다).

## 9. 사용자가 정한 것

- Cmd+클릭으로 issue · PR · MR을 브라우저에서 연다. `#1234`, `fl#1234` 같은 표기, MR · PR도 같은 방식.
- 터미널 텍스트만으로 동작한다(LLM에게 묻지 않는다).
- 단서가 없을 때는 pane repo로 바로 열지 않고 프로젝트를 고르는 메뉴를 띄운다.
- 메뉴 모양은 A안: 클릭한 자리의 macOS 메뉴 + 맨 위 검색 칸.

## 10. 제약

- main thread에서 git 프로세스를 기다리지 않는다. 목록을 아직 못 만들었으면 만든 뒤에 열거나 메뉴를 띄운다.
  클릭에서 브라우저가 열리기까지 사람이 느낄 지연이 없어야 한다.
- scrollback 검색은 최대 10,000줄을 클릭할 때 한 번 훑는다. 매 출력마다 색인을 만들지 않는다(내 판단).
- 인증 정보가 든 remote URL을 로그 · 저장값 · 메뉴 표시 어디에도 남기지 않는다.
- agent TUI가 alternate screen을 쓰면 scrollback이 없으므로 보이는 화면만 단서가 된다. 그때는 메뉴로 떨어진다.
- termy의 XCTest host는 하나뿐인 창이 닫히거나 해제되면 앱이 끝난다. 메뉴 · 패널 테스트에서 창을 닫지 말고
  `orderOut` + 참조 유지로 다룬다.

## 11. builder에게 맡기는 것

- 토큰 인식 · 이름 범위 · scrollback 단서 · URL 만들기를 어떤 타입으로 나눌지. 단, 이것들은 순수 함수로 두고
  `apps/termy-tests`에서 단위 테스트한다(예시 줄, 범위, 한글 조사, 줄바꿈된 이름, token 든 remote URL을 포함).
- git 설정 읽는 방법, 캐시 갱신 시점.
- 메뉴 구현 방식(§7), 후보 개수.
- 설정 패널에서 줄임말 목록이 놓일 자리.

## 12. 확인 방법

- 단위 테스트: §1 성공 기준의 각 줄을 텍스트 입력으로 재현한다.
- 실제 앱에서: agent pane에 예시 줄과 그 앞의 `netdrive3 #1300` 줄을 찍어 놓고 Cmd+클릭해 열리는 URL을 확인한다.
  scrollback을 지운 뒤(`clear`) 다시 눌러 메뉴가 뜨는지, `fl#45`를 두 번 눌러 두 번째는 바로 열리는지 본다.
