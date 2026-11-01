# herdr-core 백엔드 — 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** termy가 herdr-core(`hc`)의 클라이언트가 되어 원격 머신의 pane을 열고, 설정을 켜면 로컬 pane도 hc에서 돌려 termy를 다시 켜도 같은 프로세스에 다시 붙게 한다. 기본 local PTY 경로는 지금과 똑같이 동작한다.

**Architecture:** termy는 `herdr-core connect` 하위 프로세스의 stdin/stdout으로 hc와 JSON-RPC + framed 프로토콜을 주고받는다(`HcConnection`). `HcSessionManager`가 연결·events·재연결을 맡고, pane마다 `HcPaneBackend`가 `terminal.run`/`attach`로 hc terminal을 `TermyTerminalView`에 잇는다. 뷰는 `LocalProcessTerminalView` 상속을 유지하고 `send(source:data:)` override와 `receiveRemote(_:)`로 hc 입출력을 받는다. 상태는 hc의 7501 status가 있으면 그것이, 없으면 지금 hook 상태 머신이 정한다.

**Tech Stack:** Swift 6, AppKit, SwiftTerm 1.20.0 fork(고정), Foundation `Process`/`Pipe`, XcodeGen(`project.yml`), XCTest, herdr-core 0.1.16(protocol generation 1).

**Spec:** `docs/superpowers/specs/2026-11-01-herdr-core-backend-design.md`(특히 §4 herdr-core 요약, §5 결정 사항, §6.1 끝의 "계획 단계에서 바꾼 것"). 프로토콜 원문: `gh api repos/herdrdev/herdr-core/contents/schema/README.md --jq .content | base64 -d`.

## Global Constraints

- Swift 6 언어 모드, macOS 14 deployment target. 새 코드는 strict concurrency에서 경고 없이 컴파일돼야 한다.
- 새 패키지를 더하지 않는다. `project.yml`은 고치지 않는다.
- **새 `.swift` 파일을 만들면 반드시 `xcodegen generate`를 실행**한다. 새 파일은 기존처럼 `apps/termy/Sources/`, `apps/termy-tests/Sources/`에 평평하게 둔다(hc 관련 파일은 `Hc` 접두사). `termy.xcodeproj/`는 커밋하지 않는다.
- 테스트 명령(모든 태스크 공통):
  `xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation -only-testing:termy-tests/<Class> 2>&1 | tail -25`
  → `** TEST SUCCEEDED **`. 아래의 `xcodebuild test … <Class>`는 이 명령을 줄여 쓴 것이다. 태스크 끝에는 `-only-testing` 없이 전체를 한 번 돌린다.
- **Task 1–11에서는 termy.app을 실행하지 않는다**(`scripts/relaunch.sh`, `open`, Debug 실행 금지). 두 번째 instance는 hook socket(`/tmp/termy-$UID.sock`)과 `session.json`을 가로챈다. XCTest host로 뜨는 것은 괜찮다.
- **사용자의 hc core(`default` session)를 건드리지 않는다.** 테스트와 spike는 `HcTestCore`(Task 4)처럼 전용 `HC_SESSION` + 임시 `XDG_STATE_HOME`/`XDG_CONFIG_HOME`으로 core를 띄우고 끝나면 `server.stop` 후 디렉터리를 지운다. hc가 없으면 통합 테스트는 `XCTSkip`.
- hc 고정값: protocol generation `1`. 필수 method `["terminal.run","terminal.attach","terminal.kill","terminal.list","events.subscribe","machine.list","machine.exec"]`. frame 헤더 `[channel u32 LE][kind u8][len u32 LE]`, payload 최대 16 MiB(16_777_216). kind: DATA 0, CREDIT 1, CLOSE 2, RESIZE 3, FOCUS 4, FACTS 5. 스트림 초기 credit 256 KiB.
- label: `termy.pane=<paneId>`, `termy.project=<project 키>`, `termy.instance=<debug|release>`. instance는 `ProcessInfo.environment["TERMY_INSTANCE"]` 우선, 없으면 `#if DEBUG` → `"debug"`, 아니면 `"release"`.
- defaults key: `"termy.herdrCore.localPanes"`(Bool, 기본 false). 테스트는 `InMemoryUserDefaults()`(`apps/termy-tests/Sources/InMemoryUserDefaults.swift`)를 주입한다.
- 설치 명령: `curl -fsSL https://releases.herdr.dev/core/install.sh | sh`.
- 앱 UI 문구는 영어이며 아래를 그대로 쓴다.
  - pane 상태: `"Connecting to herdr-core…"`, `"Restarting shell…"`, `"herdr-core unavailable: <reason>"`
  - 설치 시트: 제목 `"herdr-core is required"`, 본문 `"Remote projects and local panes that survive restarts run in herdr-core, a background program that keeps terminals alive. Install it now?"`, 버튼 `"Install"` / `"Cancel"`, 실패 `"Couldn't install herdr-core. See the output above."`
  - 설정: 체크박스 `"Run local panes in herdr-core"`, 상태 `"herdr-core <version> · connected"` / `"herdr-core: not installed"` / `"herdr-core: unavailable (<reason>)"`
  - ⌘K: 버튼 `"New Remote Project…"`. 시트 제목 `"New Remote Project"`, 라벨 `"Machine"` / `"Folder"`, 버튼 `"Create"` / `"Cancel"`, 오류 `"Folder not found on <machine>."`, 머신 상태 접미사 `" (needs login)"` / `" (unreachable)"` / `" (connecting)"` / `" (Windows not supported)"`, 안내 `"Run `hc machine login <name>` in a terminal, then try again."`
- 원격 project 키는 `"<machine>:<folder>"`, 원격 projectId(표시 이름)는 `"<folder basename>@<machine>"`.
- 커밋 메시지는 한국어, `Co-Authored-By` 라인을 넣지 않는다. 접두사는 `feat(hc):`, `refactor(pane):`, `test(hc):`, `docs(spec):` 등. 브랜치 `feat/herdr-core-backend`.
- 주석 밀도와 스타일은 주변 코드를 따른다. 파일 머리 주석에 "왜"를 쓴다.

## Review Focus

spec이 암시하지만 쉽게 놓치는 입력 가운데 실제로 부딪히기 쉬운 순서로 적는다. 각 줄의 테스트는 해당 태스크에 들어 있다.

1. **마지막 창을 닫아 앱이 곧바로 종료될 때** kill 요청이 hc에 닿기 전에 프로세스가 끝나 agent가 살아남는다 → `applicationWillTerminate`가 보류 중인 kill을 기다린다(Task 7: `testPendingKillsFlushBeforeExit`).
2. **Herdr.app이 hc를 업데이트해 core가 재시작될 때** termy가 다시 연결하면서 새 terminal을 또 만든다 → 살아 있는 terminal에 다시 attach만 하고 개수는 그대로다(Task 6: `testReconnectReattachesWithoutNewTerminal`).
3. **큰 출력 폭주(수 MiB 로그 `cat`)** 에서 CREDIT 계산이 어긋나 스트림이 멈춘다 → 끝까지 받고 마지막 줄이 화면에 있다(Task 4: `testCreditFlowDeliversLargeOutput`, Task 6: `testLargeBurstReachesScreen`).
4. **hc를 쓸 수 없는 상태로 hc pane이 든 session.json을 복원할 때** local 셸로 바뀌거나 죽는다 → pane은 unavailable 상태로 남고 같은 paneId로 local 셸을 띄우지 않는다(Task 9: `testHcPaneStaysUnavailableWhenCoreMissing`).
5. **7501 status가 있는 agent가 종료될 때** CLOSE(PtyExit)가 status null보다 먼저 와서 상태가 굳는다 → PtyExit은 항상 적용되고 7501 경로를 끈다(Task 8: `testPtyExitAppliesWhileProgramStatusActive`).

---

### Task 1: spike — 구현 전 gate (버리는 코드)

spec §8 항목을 확인하고 결과를 spec에 적는다. 이 태스크의 코드는 커밋하지 않는다(`docs/local/`은 git이 무시한다).

**Files:**
- Create(커밋 안 함): `docs/local/spikes/hc_attach_spike.py`
- Modify: `docs/superpowers/specs/2026-11-01-herdr-core-backend-design.md`(§8 아래 `### 결과(2026-11-xx, hc 0.1.16)` 추가)

- [ ] **Step 1: spike 스크립트를 쓴다.** Python 3 표준 라이브러리만 쓴다. 임시 디렉터리를 만들어 `HC_SESSION=termy-spike`, `XDG_STATE_HOME`, `XDG_CONFIG_HOME`을 거기로 두고, `herdr-core connect`를 `env -i HOME=… PATH=/usr/bin:/bin …`으로 띄운다. plain mode로 `{"jsonrpc":"2.0","id":1,"method":"hello","params":{"generation":1,"framed":true}}` 한 줄을 보내고 응답 한 줄을 읽은 뒤, 이후는 framed로 읽고 쓴다. 기능: `run(argv, labels)`, `attach(addr, history)`가 첫 화면 바이트를 2초 동안 모아 돌려준다, `send_data`, `credit`, `close_channel`, `subscribe`. 실행은 `python3 -I docs/local/spikes/hc_attach_spike.py <항목>`.
- [ ] **Step 2: 다시 attach할 때 모드가 살아 있는지 확인한다(항목 2).** 프로그램 `["/bin/sh","-c","printf '\\033[>1u\\033[?2004h\\033[?1000h\\033[?1006h\\033[?1049h'; exec cat"]`를 run → attach → CLOSE → 다시 attach해서 두 번째 첫 화면에 `\x1b[>1u`(또는 같은 의미의 kitty flags), `\x1b[?2004h`, `\x1b[?1000h`, `\x1b[?1006h`, `\x1b[?1049h`가 있는지 출력한다. 같은 확인을 `claude`로 한 번 더 한다(대화창이 뜬 뒤 다시 attach).
- [ ] **Step 3: 흐름 제어와 종료를 확인한다.** `head -c 8388608 /dev/zero | tr '\0' a; echo; echo END`를 run → attach. credit을 돌려주면서 `END`가 오는지, credit을 돌려주지 않으면 256 KiB 근처에서 멈추는지 본다. 끝난 뒤 CLOSE payload(`{"reason":"exited","exit_code":0,...}`)를 출력한다.
- [ ] **Step 4: events와 7501 값을 확인한다(항목 4, 5).** `subscribe` 후 `claude`를 run하고 Ghostty에서 `HC_SESSION=termy-spike XDG_STATE_HOME=… hc attach <addr>`로 들어가 (a) 권한 프롬프트, (b) AskUserQuestion, (c) turn 끝, (d) 오류(존재하지 않는 모델로 `/model`)를 만들고, 각각의 `status` 이벤트 data를 기록한다. 이어서 claude를 끝내고 같은 terminal에서 `codex --no-daemon`을 띄워 `status`/`reported` 변화와 `foreground` 이벤트를 기록한다.
- [ ] **Step 5: `TERM_PROGRAM`을 정한다(항목 6).** 같은 claude를 `env {"TERM_PROGRAM":"termy","TERM_PROGRAM_VERSION":"<앱 버전>"}`와 env 없이 각각 띄워, hc가 XTVERSION에 무엇으로 답하는지(terminal 기록의 `identity`)와 Claude Code 화면 차이를 기록한다. 결론을 한 줄로 적는다. 기본값은 `"termy"`이고, 결과가 다르면 Task 6의 `HcPaneBackend.termProgram`을 바꾼다.
- [ ] **Step 6: 사용자의 core 환경을 읽기만 한다(항목 8).** `ps eww -p $(pgrep -f 'herdr-core serve')`로 사용자 core의 환경에 `CLAUDECODE` 등 `Pane.agentSessionMarkerEnvKeys`가 있는지 기록한다. core에 아무것도 보내지 않는다.
- [ ] **Step 7: Herdr.app 공존은 사용자에게 요청한다(항목 7).** 사용자에게 다음을 부탁하고 결과를 받는다. "Ghostty에서 `hc run --bg --name termy-spike --label termy.pane=spike --label termy.instance=spike -- sleep 900`을 실행한 뒤 Herdr.app에 이 terminal이 어떻게 보이는지(목록에 나오는지, 자동으로 tab이 생기는지, 닫히는지) 알려 주세요. 확인 후 `hc kill termy-spike`." 질문 문장은 한국어로 보낸다.
- [ ] **Step 8: spike core를 정리하고 결과를 spec에 적는다.** `server.stop` → 임시 디렉터리 삭제 → `hc ls`(사용자 core)가 spike 전과 같은지 확인. spec §8 아래에 항목 1–8의 결과를 한두 줄씩 적는다.
- [ ] **Step 9: gate를 판정한다.** 다음 중 하나라도 해당하면 **여기서 멈추고** 결과와 함께 사용자에게 보고한다. Task 2 이후로 넘어가지 않는다.
  - 다시 attach한 첫 화면에 kitty flags 또는 bracketed paste 모드가 없다(Shift+Return, IME 커밋 우회, 붙여넣기가 termy 재시작 뒤 깨진다).
  - framed mode가 `herdr-core connect` 위에서 동작하지 않는다.
  - CREDIT을 돌려줘도 `END`가 오지 않는다.
  - Herdr.app이 termy label이 붙은 terminal을 지우거나 바꾼다.
  
  7501 값이 Task 8 매핑과 다르면 멈추지 않고 Task 8의 테스트 기대값을 spike 결과에 맞춘다(결과를 spec에 적은 그대로).
- [ ] **Step 10: 커밋한다.**

```bash
git add docs/superpowers/specs/2026-11-01-herdr-core-backend-design.md
git commit -m "docs(spec): herdr-core spike 결과 기록"
```

---

### Task 2: TermyTerminalView에 hc 입출력 경로 추가 (local 동작 변화 없음)

**Files:**
- Modify: `apps/termy/Sources/TermyTerminalView.swift`(`setFrameSize` :73, `dataReceived` :907, 새 override `send(source:data:)`)
- Test: `apps/termy-tests/Sources/TermyTerminalViewRemoteIOTests.swift`

**Interfaces:**
- Produces:
  - `var remoteInput: ((ArraySlice<UInt8>) -> Void)?` — nil이 아니면 모든 사용자 입력(키, 붙여넣기, 마우스, termy가 보내는 `send(txt:)`)이 process 대신 여기로 간다.
  - `func receiveRemote(_ bytes: ArraySlice<UInt8>)` — hc 출력. `dataReceived`와 같은 부수 효과(`feed`, `onOutput`, `recordPtyActivity`, marked text 위치 조정).
  - `var onGridSizeChanged: ((_ cols: Int, _ rows: Int) -> Void)?` — freeze 중이 아닐 때 `super.setFrameSize` 뒤 터미널 cols/rows가 바뀌었으면 호출. thaw로 미뤄진 크기가 적용될 때도 호출.

- [ ] **Step 1: 실패하는 테스트를 쓴다.**

```swift
final class TermyTerminalViewRemoteIOTests: XCTestCase {
    func testSendRoutesToRemoteInputWhenSet() {
        let view = TermyTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var sent: [UInt8] = []
        view.remoteInput = { sent.append(contentsOf: $0) }
        view.send(txt: "a")
        XCTAssertEqual(sent, [0x61])
    }
    func testReceiveRemoteFeedsTerminalAndFiresOnOutput() {
        let view = TermyTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var outputs = 0
        view.onOutput = { outputs += 1 }
        view.receiveRemote(ArraySlice(Array("hello".utf8)))
        let line = view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true)
        XCTAssertEqual(line, "hello")
        XCTAssertEqual(outputs, 1)
    }
    func testGridSizeCallbackFiresOnResizeButNotWhileFrozen() {
        let view = TermyTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var sizes: [[Int]] = []
        view.onGridSizeChanged = { sizes.append([$0, $1]) }
        view.freezeSizePropagation()
        view.setFrameSize(NSSize(width: 800, height: 600))
        XCTAssertTrue(sizes.isEmpty)
        view.thawSizePropagation()
        let t = view.getTerminal()
        XCTAssertEqual(sizes.last, [t.cols, t.rows])
    }
}
```

- [ ] **Step 2: 실패를 확인한다.** `xcodebuild test … TermyTerminalViewRemoteIOTests` → `remoteInput` 등이 없어 컴파일 실패.
- [ ] **Step 3: 구현한다.** `override func send(source: TerminalView, data: ArraySlice<UInt8>)`가 `remoteInput`이 있으면 거기로, 없으면 `super`로 보낸다. `dataReceived`의 본문 중 `super.dataReceived` 뒤의 부수 효과를 `private func afterOutput()`로 빼고, `receiveRemote`는 `feed(byteArray:)` 후 `afterOutput()`을 부른다. `setFrameSize`는 `super.setFrameSize` 호출 전후의 `(cols, rows)`를 비교해 `onGridSizeChanged`를 부른다(thaw 경로가 결국 `setFrameSize`를 다시 부르는지 확인하고, 아니면 thaw에서도 같은 비교를 한다). local pane에서는 세 속성이 모두 nil이므로 동작이 바뀌지 않는다.
- [ ] **Step 4: 통과를 확인한다.** `xcodebuild test … TermyTerminalViewRemoteIOTests` → PASS. 이어서 `TermyTerminalViewTests`, `TerminalScrollWheelTests`, `WorkspaceParkingTests`도 PASS.
- [ ] **Step 5: 커밋한다.** `git commit -m "refactor(pane): TermyTerminalView에 원격 입출력 경로 추가"`

---

### Task 3: hc frame codec과 JSON-RPC 메시지

**Files:**
- Create: `apps/termy/Sources/HcFrame.swift`, `apps/termy/Sources/HcRPC.swift`
- Test: `apps/termy-tests/Sources/HcFrameTests.swift`, `apps/termy-tests/Sources/HcRPCTests.swift`

**Interfaces:**
- Produces:
  - `enum HcFrameKind: UInt8, Sendable { case data = 0, credit = 1, close = 2, resize = 3, focus = 4, facts = 5 }`
  - `struct HcFrame: Equatable, Sendable { var channel: UInt32; var kind: HcFrameKind; var payload: Data; func encoded() -> Data; static func credit(channel: UInt32, bytes: UInt32) -> HcFrame; static func resize(channel: UInt32, cols: UInt16, rows: UInt16) -> HcFrame; static func focus(channel: UInt32, _ focused: Bool) -> HcFrame; static func close(channel: UInt32) -> HcFrame }`
  - `struct HcFrameDecoder: Sendable { mutating func append(_ data: Data) throws -> [HcFrame] }`, `enum HcFrameError: Error, Equatable { case payloadTooLarge(UInt32), unknownKind(UInt8) }`
  - `struct HcRPCErrorPayload: Decodable, Sendable, Equatable { let code: Int; let message: String; let kind: String?; let hint: String? }`(JSON의 `error.data.kind`/`error.data.hint`를 평평하게)
  - `enum HcRPCIncoming: Sendable { case response(id: Int, raw: Data); case error(id: Int, HcRPCErrorPayload); case notification(method: String, raw: Data) }`, `static func HcRPC.parse(_ line: Data) throws -> HcRPCIncoming`
  - `static func HcRPC.request(id: Int, method: String, params: some Encodable) throws -> Data`
  - `static func HcRPC.decodeResult<R: Decodable>(_ type: R.Type, from raw: Data) throws -> R`(`{"result": …}`에서 꺼냄), `static func HcRPC.decodeParams<P: Decodable>(_ type: P.Type, from raw: Data) throws -> P`

- [ ] **Step 1: 실패하는 테스트를 쓴다.**

```swift
func testResizeFrameBytes() {
    let f = HcFrame.resize(channel: 7, cols: 120, rows: 40).encoded()
    XCTAssertEqual([UInt8](f), [7,0,0,0, 3, 4,0,0,0, 120,0, 40,0])
}
func testDecoderHandlesSplitAndBatchedFrames() throws {
    let a = HcFrame(channel: 0, kind: .data, payload: Data("{\"id\":1}".utf8)).encoded()
    let b = HcFrame.credit(channel: 3, bytes: 4096).encoded()
    var d = HcFrameDecoder()
    var all = a + b
    let first = try d.append(all.prefix(5))
    XCTAssertEqual(first, [])
    all.removeFirst(5)
    XCTAssertEqual(try d.append(all).map(\.kind), [.data, .credit])
}
func testDecoderRejectsOversizedPayload() {
    var header = Data([0,0,0,0, 0]); var len = UInt32(16_777_217).littleEndian
    header.append(Data(bytes: &len, count: 4))
    var d = HcFrameDecoder()
    XCTAssertThrowsError(try d.append(header)) { XCTAssertEqual($0 as? HcFrameError, .payloadTooLarge(16_777_217)) }
}
func testParseResponseErrorAndNotification() throws {
    if case .response(let id, _) = try HcRPC.parse(Data(#"{"jsonrpc":"2.0","id":4,"result":{"ok":true}}"#.utf8)) { XCTAssertEqual(id, 4) } else { XCTFail() }
    if case .error(_, let e) = try HcRPC.parse(Data(#"{"jsonrpc":"2.0","id":5,"error":{"code":-32000,"message":"no terminal t9","data":{"kind":"not_found","hint":"h"}}}"#.utf8)) { XCTAssertEqual(e.kind, "not_found") } else { XCTFail() }
    if case .notification(let m, _) = try HcRPC.parse(Data(#"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":42}}"#.utf8)) { XCTAssertEqual(m, "heartbeat") } else { XCTFail() }
}
```

- [ ] **Step 2: 실패를 확인한다.** `xcodebuild test … HcFrameTests HcRPCTests` → 컴파일 실패.
- [ ] **Step 3: 구현한다.** decoder는 내부 `Data` 버퍼에 쌓고, 헤더 9바이트를 읽을 수 있을 때마다 길이를 보고 꺼낸다. 길이가 16_777_216을 넘으면 payload를 읽기 전에 던진다. `HcRPC.parse`는 `id`/`method`/`error`만 가진 envelope로 먼저 decode한 뒤 원본 `Data`를 그대로 넘긴다.
- [ ] **Step 4: 통과를 확인한다.** → PASS.
- [ ] **Step 5: 커밋한다.** `git commit -m "feat(hc): frame codec과 JSON-RPC 메시지 파서"`

---

### Task 4: HcConnection — `herdr-core connect` 위의 연결

**Files:**
- Create: `apps/termy/Sources/HcConnection.swift`, `apps/termy/Sources/HcLocator.swift`
- Create(테스트 지원): `apps/termy-tests/Sources/HcTestCore.swift`
- Test: `apps/termy-tests/Sources/HcLocatorTests.swift`, `apps/termy-tests/Sources/HcConnectionIntegrationTests.swift`

**Interfaces:**
- Consumes: Task 3의 `HcFrame`, `HcFrameDecoder`, `HcRPC`.
- Produces:
  - `enum HcLocator { static func find(environment: [String: String], fileManager: FileManager = .default) -> URL? }` — 순서: `~/.local/bin/herdr-core`, `/opt/homebrew/bin/herdr-core`, `/usr/local/bin/herdr-core`, 그다음 `PATH`의 각 항목. 실행 가능한 파일만.
  - `struct HcEndpoint: Sendable { var executable: URL; var session: String?; var extraEnvironment: [String: String]; static func minimalEnvironment(base: [String: String]) -> [String: String] }` — `minimalEnvironment`는 `HOME`, `USER`, `LOGNAME`, `SHELL`, `LANG`, `TMPDIR`만 base에서 가져오고 `PATH="/usr/bin:/bin:/usr/sbin:/sbin"`을 넣는다. 실제 환경 = minimal + `HC_SESSION`(session이 있으면) + `extraEnvironment`.
  - `struct HcHello: Decodable, Sendable { let generation: Int; let methods: [String]; let version: String; let features: [String] }`
  - `enum HcError: Error, Equatable { case notInstalled; case launchFailed(String); case incompatibleGeneration(Int); case missingMethods([String]); case rpc(kind: String?, message: String); case disconnected; case protocolViolation(String) }`
  - `enum HcStreamEvent: Sendable { case data(Data); case closed(Data?) }`(closed의 Data는 core가 보낸 CLOSE JSON)
  - `actor HcConnection`:
    - `init(endpoint: HcEndpoint)`
    - `func open() async throws -> HcHello` — 프로세스를 띄우고 plain mode로 `hello {generation: 1, framed: true}`를 보내 응답 한 줄을 받은 뒤 framed로 바꾼다. generation ≠ 1이면 `.incompatibleGeneration`, 필수 method가 빠지면 `.missingMethods`.
    - `func call<R: Decodable & Sendable>(_ method: String, _ params: some Encodable & Sendable) async throws -> R`
    - `func stream(_ channel: UInt32) -> AsyncStream<HcStreamEvent>` — 그 channel의 DATA/CLOSE를 받는다. attach와 events 구독 채널 모두 이것을 쓴다.
    - `func send(_ frame: HcFrame)`
    - `nonisolated let disconnected: AsyncStream<HcError?>` — 프로세스가 끝나거나 읽기가 실패하면 한 번 내보낸다. 대기 중인 `call`은 모두 `.disconnected`로 끝난다.
    - `func close()`
  - `static let HcConnection.requiredMethods: [String]`(Global Constraints의 목록)
  - 테스트 지원 `final class HcTestCore`: `static func makeOrSkip() throws -> HcTestCore`(hc가 없으면 `XCTSkip`), `let endpoint: HcEndpoint`, `func stop() async`. 임시 디렉터리, session `"termy-test-<UUID 앞 8자>"`, `extraEnvironment = ["XDG_STATE_HOME": …, "XDG_CONFIG_HOME": …]`. `stop()`은 새 연결로 `server.stop`을 부른 뒤 디렉터리를 지운다.

- [ ] **Step 1: 실패하는 테스트를 쓴다.**

```swift
func testLocatorPrefersLocalBinThenPath() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let bin = tmp.appendingPathComponent("bin"); try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let exe = bin.appendingPathComponent("herdr-core"); FileManager.default.createFile(atPath: exe.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
    XCTAssertEqual(HcLocator.find(environment: ["HOME": "/nonexistent", "PATH": bin.path])?.path, exe.path)
    XCTAssertNil(HcLocator.find(environment: ["HOME": "/nonexistent", "PATH": "/nonexistent"]))
}
func testMinimalEnvironmentDropsAgentMarkers() {
    let env = HcEndpoint.minimalEnvironment(base: ["HOME": "/h", "CLAUDECODE": "1", "TERM_PROGRAM": "ghostty", "LANG": "ko_KR.UTF-8"])
    XCTAssertEqual(env, ["HOME": "/h", "LANG": "ko_KR.UTF-8", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
}
// HcConnectionIntegrationTests (scratch core)
func testHelloReportsGenerationOne() async throws {
    let core = try HcTestCore.makeOrSkip(); addTeardownBlock { await core.stop() }
    let hello = try await HcConnection(endpoint: core.endpoint).open()
    XCTAssertEqual(hello.generation, 1)
}
func testAttachEchoesInput() async throws { /* run ["/bin/cat"], attach cols 80 rows 24, send DATA "abc\n", expect stream data containing "abc" within 3 s */ }
func testCreditFlowDeliversLargeOutput() async throws { /* run ["/bin/sh","-c","head -c 8388608 /dev/zero | tr '\\0' a; echo; echo END"], read stream sending CREDIT for every chunk, expect "END" within 20 s (a repaint after falling behind is acceptable) */ }
func testCloseCarriesExitCode() async throws { /* run ["/bin/sh","-c","exit 3"] + attach; expect .closed whose JSON has reason "exited", exit_code 3 */ }
```

- [ ] **Step 2: 실패를 확인한다.** → 컴파일 실패.
- [ ] **Step 3: 구현한다.** `Process` + `Pipe` 세 개. 읽기는 stdout `FileHandle.readabilityHandler`에서 actor로 넘긴다. plain mode 동안은 줄 단위, hello 응답 뒤로는 `HcFrameDecoder`. channel 0 DATA는 `HcRPC.parse`로 짝짓고, 다른 channel은 `stream(_:)` continuation으로 보낸다. 쓰기는 actor 안에서 순서대로 `write`. id는 1부터 증가. stderr는 `NSLog`로 남긴다.
- [ ] **Step 4: 통과를 확인한다.** `xcodebuild test … HcLocatorTests HcConnectionIntegrationTests` → PASS(hc가 없으면 통합 테스트는 skip으로 표시).
- [ ] **Step 5: 커밋한다.** `git commit -m "feat(hc): herdr-core connect 위의 HcConnection"`

---

### Task 5: HcEventStore — terminal 사실 모음

**Files:**
- Create: `apps/termy/Sources/HcModels.swift`, `apps/termy/Sources/HcEventStore.swift`
- Test: `apps/termy-tests/Sources/HcEventStoreTests.swift`

**Interfaces:**
- Produces:
  - `struct HcStatus: Codable, Sendable, Equatable { var state: String; var kind: String?; var msg: String?; var app: String? }`
  - `struct HcForeground: Codable, Sendable, Equatable { var pid: Int?; var name: String?; var argv: [String]?; var cwd: String? }`
  - `struct HcTerminal: Codable, Sendable, Equatable { var address: String; var state: String; var labels: [String: String]; var cwd: String?; var exitCode: Int32?; var reason: String?; var status: HcStatus?; var foreground: HcForeground?; var cols: Int?; var rows: Int?; var title: String? }`(JSON 키는 snake_case, `labels`가 없으면 `[:]`)
  - `enum HcAddress { static func machine(of address: String) -> String? }`(`"bdpc01/t3"` → `"bdpc01"`, `"t3"` → nil)
  - `struct HcEvent: Sendable { let seq: UInt64; let type: String; let terminal: String?; let data: Data }` + `static func decode(notification raw: Data) throws -> HcEvent`
  - `enum HcTerminalChange: Sendable, Equatable { case upserted(HcTerminal); case removed(String); case status(String, HcStatus?); case foreground(String, HcForeground?); case lost(String, reason: String); case restarted(HcTerminal); case finished(String, exitCode: Int32?, reason: String) }`
  - `struct HcEventStore: Sendable { private(set) var seq: UInt64; private(set) var terminals: [String: HcTerminal]; init(seq: UInt64, terminals: [HcTerminal]); mutating func apply(_ event: HcEvent) -> HcTerminalChange?; mutating func resetFromMissed(seq: UInt64, terminals: [HcTerminal]) }`
  - `func HcEventStore.termyTerminals(instance: String) -> [HcTerminal]` — `labels["termy.instance"] == instance`이고 `labels["termy.pane"]`가 있는 살아 있는 terminal.

- [ ] **Step 1: 실패하는 테스트를 쓴다.** README의 예시 JSON을 fixture로 쓴다.
  - `testStaleSeqIgnored`: seq 10 store에 seq 10 `title` 이벤트 → nil, terminals 그대로.
  - `testStatusEventReplacesStatus`: `{"seq":11,"type":"status","terminal":"t7","data":{"status":{"state":"working","app":"claude-code"},"records":{},"reported":true}}` → `.status("t7", HcStatus(state: "working", kind: nil, msg: nil, app: "claude-code"))`.
  - `testFinishedDropsForegroundAndSetsState`: `finished` 뒤 `terminals["t7"]?.state == "finished"`, `foreground == nil`, `.finished("t7", exitCode: 0, reason: "exited")`.
  - `testLabelsWithRecordAddsTerminal`, `testRemovedDrops`, `testForegroundNullClears`.
  - `testMissedResets`: `resetFromMissed(seq: 57, …)` 뒤 seq 50 이벤트는 무시.
  - `testRemoteAddressMachine`: `HcAddress.machine(of: "bdpc01/t3") == "bdpc01"`.
  - `testTermyTerminalsFiltersByInstance`: instance `"release"`인 것만 나온다.
- [ ] **Step 2: 실패를 확인한다.** → 컴파일 실패.
- [ ] **Step 3: 구현한다.** README의 "apply" 열을 그대로 따른다(`lost`는 state를 live로 두고 pid/foreground를 지운다. `restarted`는 레코드 교체. `turn`, `doc`, `size`, `keep`은 저장만 하거나 무시하고 `nil`을 돌려준다).
- [ ] **Step 4: 통과를 확인한다.** → PASS.
- [ ] **Step 5: 커밋한다.** `git commit -m "feat(hc): events를 적용하는 HcEventStore"`

---

### Task 6: HcSessionManager와 HcPaneBackend — hc pane 하나의 수명

**Files:**
- Create: `apps/termy/Sources/HcSessionManager.swift`, `apps/termy/Sources/HcPaneBackend.swift`
- Test: `apps/termy-tests/Sources/HcPaneBackendTests.swift`(순수), `apps/termy-tests/Sources/HcPaneBackendIntegrationTests.swift`(scratch core)

**Interfaces:**
- Consumes: Task 2 `TermyTerminalView.remoteInput/receiveRemote/onGridSizeChanged`, Task 4 `HcConnection`, Task 5 `HcEventStore`/`HcTerminalChange`.
- Produces:
  - `enum HcAvailability: Equatable, Sendable { case notInstalled, connecting, connected(version: String), unavailable(String) }`
  - `@MainActor final class HcSessionManager`:
    - `static let shared: HcSessionManager`(endpoint는 `HcLocator`로 찾음), `init(endpointProvider: @escaping () -> HcEndpoint?)`
    - `static var instanceLabel: String`(Global Constraints 규칙)
    - `private(set) var availability: HcAvailability`, `var onAvailabilityChange: ((HcAvailability) -> Void)?`
    - `func ensureConnected() async throws` — 처음 부를 때 연결 + `events.subscribe {}`. 끊기면 0.5, 1, 2, 4, 8, 15초(이후 15초 고정) 간격으로 다시 연결하고, 다시 subscribe한 뒤 등록된 backend 모두에 `reattach()`를 요청한다.
    - `var store: HcEventStore { get }`
    - `func call<R: Decodable & Sendable>(_ method: String, _ params: some Encodable & Sendable) async throws -> R`
    - `func register(_ backend: HcPaneBackend)`, `func unregister(_ backend: HcPaneBackend)` — events 변화는 address로 backend에 전달된다.
    - `func machines() async throws -> [HcMachine]`, `struct HcMachine: Decodable, Sendable, Equatable { let name: String; let host: String?; let state: String; let why: String? }`
    - `func exec(on machine: String?, argv: [String], timeout: Int = 10) async throws -> Int32`(exit code만)
    - `func kill(address: String)` — 보류 목록에 넣고 `terminal.kill`을 보낸다. `func flushPendingKills(timeout: TimeInterval) async`
  - `struct HcLaunch: Equatable, Sendable { var machine: String?; var cwd: String; var shell: String }`
  - `enum HcPaneConnectionState: Equatable { case connecting, attached, restartingShell, unavailable(String) }`
  - `enum HcCloseOutcome: Equatable { case exited(Int32), unavailable(String) }`, `static func HcPaneBackend.closeOutcome(json: Data?) -> HcCloseOutcome` — reason `exited`/`killed`면 `.exited(exit_code ?? -1)`, 나머지(`server_stop`, `holder_lost`, `host_shutdown`, `stopped_by_restart`, JSON 없음)는 `.unavailable(reason)`.
  - `struct HcRunParams: Encodable, Equatable`(필드: `argv: [String]?`, `cwd`, `env: [String: String]`, `labels: [String]`(`"k=v"`), `keep: Bool`, `on: String?`, `no_parent: Bool`, `no_notify: Bool`)
  - `static func HcPaneBackend.runParams(paneId: String, projectKey: String, projectId: String, launch: HcLaunch, instance: String, baseEnvironment: [String: String]) -> HcRunParams`
  - `static let HcPaneBackend.termProgram = "termy"`(Task 1 Step 5 결과로 바뀔 수 있음)
  - `@MainActor final class HcPaneBackend`:
    - `init(paneId: String, projectKey: String, projectId: String, launch: HcLaunch, view: TermyTerminalView, manager: HcSessionManager = .shared)`
    - `private(set) var address: String?`, `private(set) var connectionState: HcPaneConnectionState`
    - 콜백: `var onExit: ((Int32) -> Void)?`, `var onStatus: ((HcStatus?) -> Void)?`, `var onForeground: ((HcForeground?) -> Void)?`, `var onConnectionState: ((HcPaneConnectionState) -> Void)?`
    - `func start()` — `ensureConnected` → `store.termyTerminals(instance:)`에서 `termy.pane == paneId`인 살아 있는 terminal을 찾으면 attach(`history: 10_000`), 없으면 `terminal.run` 후 attach(`history: 0`). attach 직후 그 terminal의 `status`/`foreground`로 `onStatus`/`onForeground`를 한 번 부른다. 연결에 실패하면 `.unavailable(reason)`으로 두고 manager의 재연결을 기다린다.
    - `func reattach()`, `func setFocused(_ focused: Bool)`, `func sendDisplayFacts()`, `func kill()`, `func detach()`

`runParams` 고정값:
- local(`launch.machine == nil`): `argv = ["/bin/sh", "-c", script, "termy-shell", launch.shell]`. `script`는 `Pane.agentSessionMarkerEnvKeys`를 한 줄 `unset A B C …;`로 지우고, `[ "${GIT_EDITOR-}" = true ] && unset GIT_EDITOR;`, `exec "$1" -l`로 끝난다. `env`: `TERMY_PANE_ID`, `TERMY_PROJECT_ID`(= projectId), `TERM="xterm-256color"`, `COLORTERM="truecolor"`, `LC_ALL`(= `baseEnvironment["LC_ALL"] ?? "en_US.UTF-8"`), `TERM_PROGRAM`(= `termProgram`), `TERM_PROGRAM_VERSION`(= `CFBundleShortVersionString`).
- remote: `argv = nil`, `on = machine`, `env`에서 `LC_ALL` 제외(나머지 같음).
- 공통: `cwd = launch.cwd`, `labels = ["termy.pane=\(paneId)", "termy.project=\(projectKey)", "termy.instance=\(instance)"]`, `keep = true`, `no_parent = true`, `no_notify = true`.

attach 뒤 연결: `view.remoteInput` → DATA, `view.onGridSizeChanged` → RESIZE, 스트림 DATA → `view.receiveRemote` 후 같은 바이트 수만큼 CREDIT, 스트림 CLOSE → `closeOutcome`에 따라 `onExit` 또는 `.unavailable`. events의 `.lost` → `.restartingShell`, `.restarted` → `reattach()`, `.status` → `onStatus`, `.foreground` → `onForeground`. `sendDisplayFacts`는 `Display {bg, fg, cursor: "#rrggbb", cell: [w, h]}`를 보내며 cell은 `view.frame.width / cols`, `view.frame.height / rows`를 반올림한 값이다.

- [ ] **Step 1: 실패하는 순수 테스트를 쓴다.**

```swift
func testLocalRunParams() {
    let p = HcPaneBackend.runParams(paneId: "P1", projectKey: "/Users/u/app", projectId: "app",
        launch: HcLaunch(machine: nil, cwd: "/Users/u/app", shell: "/bin/zsh"),
        instance: "release", baseEnvironment: [:])
    XCTAssertEqual(p.argv?.first, "/bin/sh"); XCTAssertEqual(p.argv?.last, "/bin/zsh")
    XCTAssertTrue(p.argv![2].contains("unset CLAUDECODE"))
    XCTAssertTrue(p.argv![2].contains(#"[ "${GIT_EDITOR-}" = true ] && unset GIT_EDITOR"#))
    XCTAssertTrue(p.argv![2].hasSuffix(#"exec "$1" -l"#))
    XCTAssertEqual(p.env["TERMY_PANE_ID"], "P1"); XCTAssertEqual(p.env["LC_ALL"], "en_US.UTF-8")
    XCTAssertEqual(p.labels, ["termy.pane=P1", "termy.project=/Users/u/app", "termy.instance=release"])
    XCTAssertTrue(p.keep && p.no_parent && p.no_notify); XCTAssertNil(p.on)
}
func testRemoteRunParams() {
    let p = HcPaneBackend.runParams(paneId: "P2", projectKey: "bdpc01:/srv/app", projectId: "app@bdpc01",
        launch: HcLaunch(machine: "bdpc01", cwd: "/srv/app", shell: "/bin/zsh"), instance: "debug", baseEnvironment: [:])
    XCTAssertNil(p.argv); XCTAssertEqual(p.on, "bdpc01"); XCTAssertNil(p.env["LC_ALL"])
}
func testCloseOutcome() {
    XCTAssertEqual(HcPaneBackend.closeOutcome(json: Data(#"{"reason":"exited","exit_code":0,"signal":null}"#.utf8)), .exited(0))
    XCTAssertEqual(HcPaneBackend.closeOutcome(json: Data(#"{"reason":"killed","exit_code":null,"signal":15}"#.utf8)), .exited(-1))
    XCTAssertEqual(HcPaneBackend.closeOutcome(json: Data(#"{"reason":"server_stop"}"#.utf8)), .unavailable("server_stop"))
}
func testInstanceLabelHonorsOverride() { /* setenv("TERMY_INSTANCE","t") → HcSessionManager.instanceLabel == "t"; unsetenv afterwards */ }
```

- [ ] **Step 2: 실패를 확인한다.** → 컴파일 실패.
- [ ] **Step 3: 통합 테스트를 쓴다(scratch core, `TERMY_INSTANCE=test`).**
  - `testStartRunsShellAndEchoes`: `TermyTerminalView(frame: 640×400)`에 backend를 붙여 `start()` → `view.send(txt: "echo hc-ok\r")` → 5초 안에 화면 어느 줄에 `hc-ok`.
  - `testStartReattachesExistingTerminal`: 같은 paneId로 backend를 두 번 만든다(첫 번째 `detach()` 뒤). 두 번째는 `terminal.run`을 부르지 않는다(`terminal.list`의 개수 1). 첫 화면에 이전 출력이 보인다.
  - `testKillRemovesTerminal`: `kill()` + `flushPendingKills(timeout: 2)` 뒤 `terminal.list`에 그 address가 없다.
  - `testReconnectReattachesWithoutNewTerminal`(Review Focus 2): manager의 연결 프로세스를 강제로 끝낸다(테스트용 `func _debugTerminateConnection()`) → 10초 안에 `connectionState == .attached`, `terminal.list` 개수 그대로, 입력이 다시 된다.
  - `testLargeBurstReachesScreen`(Review Focus 3): `seq 1 200000; echo LAST-LINE`를 보내고 20초 안에 화면에 `LAST-LINE`.
  - `testExitClosesWithCode`: `exit 4` 입력 → `onExit(4)`.
- [ ] **Step 4: 구현한다.** manager는 events 채널(구독 결과의 `channel`)을 `stream(_:)`로 받아 줄 단위 JSON으로 나누고 CREDIT을 돌려준다. `missed`면 `resetFromMissed` 후 등록된 backend마다 자기 terminal을 다시 확인한다. backend는 attach 결과 `channel`의 스트림을 읽는 Task 하나를 가진다.
- [ ] **Step 5: 통과를 확인한다.** `xcodebuild test … HcPaneBackendTests HcPaneBackendIntegrationTests` → PASS.
- [ ] **Step 6: 커밋한다.** `git commit -m "feat(hc): HcSessionManager와 HcPaneBackend"`

---

### Task 7: Pane·Workspace에 hc pane 연결, 닫기와 종료 규칙

**Files:**
- Modify: `apps/termy/Sources/Pane.swift`(init :88, `startShell` :268, `agentResumeRecord` :323, `applyActiveAppearance` :348, `refreshHeader` :387, `hostCurrentDirectoryUpdate` :452, `processTerminated` :473)
- Modify: `apps/termy/Sources/Workspace.swift`(`addPane` :451, `teardown` :627)
- Modify: `apps/termy/Sources/ForegroundProcessWatcher.swift`(`register` :77, `tick` :92)
- Modify: `apps/termy/Sources/MainWindowController.swift`(`windowWillClose` :576), `apps/termy/Sources/AppDelegate.swift`(`applicationWillTerminate` :110, 새 `applicationShouldTerminate`)
- Modify: `apps/termy/Sources/MissionControlModel.swift`(`midTurnPaneCount` :162)
- Create: `apps/termy/Sources/AppLifecycle.swift`, `apps/termy/Sources/PaneLaunch.swift`
- Test: `apps/termy-tests/Sources/PaneLaunchTests.swift`, `apps/termy-tests/Sources/ForegroundEdgesTests.swift`, `apps/termy-tests/Sources/HcPaneLifecycleIntegrationTests.swift`

**Interfaces:**
- Consumes: Task 6 `HcPaneBackend`, `HcSessionManager`, `HcLaunch`.
- Produces:
  - `enum PaneLaunch: Equatable, Sendable { case local; case hc(machine: String?) }`, `enum PaneBackendKind: String, Codable, Sendable { case local, hc }`, `var PaneLaunch.backendKind: PaneBackendKind`
  - `enum AppLifecycle { @MainActor static var isTerminating: Bool }`
  - `Pane.init(projectId: String, cwd: String? = nil, startupInput: String? = nil, paneId: String = UUID().uuidString, launch: PaneLaunch = .local, projectKey: String? = nil)` — `projectKey` nil이면 `ProjectIdentity.canonicalPath(for: cwd)`.
  - `Pane.launch: PaneLaunch`, `Pane.hcBackend: HcPaneBackend?`, `Pane.isRemote: Bool`(`launch == .hc(machine: non-nil)`)
  - `Workspace.addPane(cwd: String? = nil, splitAxis: SplitAxis = .balanced, startupInput: String? = nil, paneId: String? = nil, launch: PaneLaunch = .local, projectId: String? = nil, projectKey: String? = nil) -> Pane`
  - `Workspace.killHcPanes()` — 모든 hc pane의 `hcBackend?.kill()`.
  - `enum TeardownAction: Equatable { case terminateLocal, killHc, none }`, `static func Workspace.teardownAction(kind: PaneBackendKind, isTerminating: Bool) -> TeardownAction`
  - `enum ForegroundEdges { static func transition(from prior: AgentKind?, to detected: AgentKind?) -> (end: Bool, start: AgentKind?) }`
  - `ForegroundProcessWatcher.registerPushed(paneId: String, projectId: String?)`, `ForegroundProcessWatcher.updatePushed(paneId: String, agent: AgentKind?)` — 이 항목은 syscall 대신 마지막으로 받은 값을 "감지 값"으로 쓰고, `tick`의 edge 처리와 codex reconcile을 그대로 탄다.
  - `MissionControlModel.setHcPaneIds(_ ids: Set<String>, forWindow windowId: UUID)` — `midTurnPaneCount`는 hc pane을 세지 않는다.

동작:
- hc pane은 `startShell()`을 부르지 않고 `HcPaneBackend(…, launch: HcLaunch(machine:, cwd:, shell: $SHELL ?? "/bin/zsh"))`를 만들어 `start()`. `onExit` → 지금 `processTerminated`와 같은 처리(`postPtyExit` → `unregister` → `headWatcher?.stop()` → `onShellExited`). `onForeground` → `updatePushed(paneId:, agent: ForegroundProcessWatcher.classifyAgent(processName: name, arguments: argv ?? []))`, 그리고 로컬 hc pane이면 `foreground.cwd`로 OSC 7과 같은 cwd 갱신 경로를 탄다(원격 pane은 `currentCwd`만 바꾸고 git/drift는 하지 않는다). `onStatus`는 Task 8에서 연결한다(이 태스크에서는 비워 둔다). `onConnectionState` → 터미널 위 상태 라벨(Global Constraints 문구, `.attached`면 숨김, `.connecting`/`.restartingShell`/`.unavailable`이면 입력 무시).
- 원격 pane: `projectId`는 생성 때 받은 값으로 고정(`refreshHeader`의 drift 갱신과 `GitHeadWatcher`를 건너뛰고 헤더는 `project: projectId, branch: nil`, `onHeaderChanged?(projectId, nil)`도 같은 값으로 불러 mission control 라벨이 `app@bdpc01`이 되게 한다).
- `applyActiveAppearance(_:)`에서 `hcBackend?.setFocused(active)`, 테마가 바뀌는 경로에서 `hcBackend?.sendDisplayFacts()`.
- `agentResumeRecord`는 hc pane이면 nil.
- `teardown`은 `teardownAction`대로: local → 지금처럼 `process.terminate()`, hc → `hcBackend?.kill()`, 종료 중이면 아무것도 하지 않음.
- `windowWillClose`: `AppLifecycle.isTerminating`이 아니면 `workspace.killHcPanes()` 후 `removeWindow`.
- `AppDelegate.applicationShouldTerminate(_:)` → `AppLifecycle.isTerminating = true`, `.terminateNow`. `applicationWillTerminate`의 0.5초 semaphore 안에서 autosave flush 뒤 `await HcSessionManager.shared.flushPendingKills(timeout: 0.3)`.

- [ ] **Step 1: 실패하는 테스트를 쓴다.**

```swift
func testTeardownAction() {
    XCTAssertEqual(Workspace.teardownAction(kind: .local, isTerminating: false), .terminateLocal)
    XCTAssertEqual(Workspace.teardownAction(kind: .hc, isTerminating: false), .killHc)
    XCTAssertEqual(Workspace.teardownAction(kind: .hc, isTerminating: true), .none)
}
func testForegroundEdges() {
    XCTAssertTrue(ForegroundEdges.transition(from: .claude, to: .codex) == (end: true, start: .codex))
    XCTAssertTrue(ForegroundEdges.transition(from: nil, to: .claude) == (end: false, start: .claude))
    XCTAssertTrue(ForegroundEdges.transition(from: .codex, to: nil) == (end: true, start: nil))
}
func testMidTurnCountExcludesHcPanes() { /* MissionControlModel: two live panes both isMidTurn; setHcPaneIds([B]) → midTurnPaneCount == 1 */ }
// HcPaneLifecycleIntegrationTests (scratch core, sentinel window kept open)
func testClosingHcPaneKillsTerminal() { /* Workspace.addPane(launch: .hc(machine: nil)) → wait attached → closeFocusedPane() → flushPendingKills → terminal.list lacks it */ }
func testWindowCloseKillsHcPanesUnlessTerminating() { /* isTerminating=false: windowWillClose → terminals gone; isTerminating=true: terminals remain (then stop core) */ }
func testPendingKillsFlushBeforeExit() { /* kill() then flushPendingKills(timeout: 0.3) returns only after terminal.list lacks address */ }
func testHcPaneExitClosesPane() { /* send "exit\r" → pane removed from workspace.panes within 5 s */ }
```

- [ ] **Step 2: 실패를 확인한다.** → 컴파일 실패.
- [ ] **Step 3: 구현한다.** `ForegroundProcessWatcher.tick`의 edge 판단을 `ForegroundEdges.transition`으로 바꾸고, 항목을 `enum Source { case pty(masterFd: Int32, shellPid: pid_t), pushed(AgentKind?) }`로 나눈다. 나머지는 위 동작 목록대로.
- [ ] **Step 4: 통과를 확인한다.** 새 테스트 + `ForegroundProcessWatcherTests`, `WorkspaceParkingTests`, `PaneShellEnvironmentTests`, `StartupInputSchedulerTests` → PASS.
- [ ] **Step 5: 전체 테스트를 돌린다.** `-only-testing` 없이 → `** TEST SUCCEEDED **`.
- [ ] **Step 6: 커밋한다.** `git commit -m "feat(hc): Pane·Workspace에서 hc pane을 만들고 닫는다"`

---

### Task 8: 7501 status를 pane 상태에 합친다

**Files:**
- Modify: `apps/termy/Sources/PaneState.swift`(`PaneSnapshot` :86, `PaneStateMachine.apply` :178)
- Modify: `apps/termy/Sources/HookDaemon.swift`(새 method)
- Modify: `apps/termy/Sources/Pane.swift`(`onStatus` 연결)
- Test: `apps/termy-tests/Sources/PaneProgramStatusTests.swift`

**Interfaces:**
- Consumes: Task 5 `HcStatus`, Task 7 `Pane.hcBackend`.
- Produces:
  - `PaneSnapshot.programStatusActive: Bool = false`(CodingKeys에 넣지 않는다)
  - `static func PaneStateMachine.applyProgramStatus(_ status: HcStatus?, to previous: PaneSnapshot, now: Date) -> PaneSnapshot`
  - `func HookDaemon.applyProgramStatus(paneId: String, projectId: String?, status: HcStatus?, now: Date = Date()) async` — `ingest`와 같이 `updateContinuation.yield`.

매핑(`status != nil`이면 `programStatusActive = true`, `updatedAt = now`, 상태가 바뀌면 `enteredStateAt = now`):

| status.state | 결과 |
|---|---|
| `working` | `.thinking`, `turnOpen = true`, `needsAttention = false` |
| `blocked` | `.waiting`, `needsAttention = true`, `waitSource`: kind `question` → `.askUserQuestion`, 그 밖(`permission`, `auth`, nil) → `.permission`, `notificationReason = kind ?? "permission"` |
| `done` | `.waiting`, `waitSource = .turnEnd`, `turnOpen = false` |
| `idle` | `turnOpen`이면 `done`과 같음. 아니고 이전이 `.waiting`이면 그대로. 아니면 `.idle` |
| `error` | `.errored`, `turnOpen = false` |
| 그 밖의 단어 | 상태 그대로(세부만 갱신) |
| `nil` | `programStatusActive = false`, 상태 그대로 |

`apply(_:to:)`: `previous.programStatusActive`이면 이벤트가 `.ptyExit` 또는 `.sessionEnd`가 아닌 한, 지금 규칙으로 계산한 결과에서 `state`, `needsAttention`, `notificationReason`, `waitSource`, `enteredStateAt`, `turnOpen`을 `previous` 값으로 되돌린다(세부 필드만 남는다). `.ptyExit`/`.sessionEnd`는 지금 규칙대로 적용하고 `programStatusActive = false`.

- [ ] **Step 1: 실패하는 테스트를 쓴다.** (Task 1에서 실제 값이 다르게 나왔으면 그 값으로 바꾼다.)

```swift
private func base() -> PaneSnapshot { .empty(paneId: "P", projectId: "app", agentKind: .claude) }
private func st(_ s: String, kind: String? = nil) -> HcStatus { HcStatus(state: s, kind: kind, msg: nil, app: "claude-code") }
func testWorkingThinks() { let n = PaneStateMachine.applyProgramStatus(st("working"), to: base(), now: Date()); XCTAssertEqual(n.state, .thinking); XCTAssertTrue(n.turnOpen); XCTAssertTrue(n.programStatusActive) }
func testBlockedQuestionWaitsForAnswer() { let n = PaneStateMachine.applyProgramStatus(st("blocked", kind: "question"), to: base(), now: Date()); XCTAssertEqual(n.state, .waiting); XCTAssertEqual(n.waitSource, .askUserQuestion); XCTAssertTrue(n.needsAttention) }
func testBlockedAuthUsesPermissionWithReason() { let n = PaneStateMachine.applyProgramStatus(st("blocked", kind: "auth"), to: base(), now: Date()); XCTAssertEqual(n.waitSource, .permission); XCTAssertEqual(n.notificationReason, "auth") }
func testDoneEndsTurn() { var p = base(); p.turnOpen = true; let n = PaneStateMachine.applyProgramStatus(st("done"), to: p, now: Date()); XCTAssertEqual(n.state, .waiting); XCTAssertEqual(n.waitSource, .turnEnd); XCTAssertFalse(n.turnOpen) }
func testIdleAfterWorkingEndsTurnOnce() {
    let working = PaneStateMachine.applyProgramStatus(st("working"), to: base(), now: Date())
    let idle1 = PaneStateMachine.applyProgramStatus(st("idle"), to: working, now: Date())
    let idle2 = PaneStateMachine.applyProgramStatus(st("idle"), to: idle1, now: Date())
    XCTAssertEqual(idle1.state, .waiting); XCTAssertEqual(idle2.state, .waiting)
    XCTAssertTrue(WaitAlertRule.shouldAlert(previous: .init(state: working.state, sessionId: nil), next: .init(state: idle1.state, sessionId: nil)))
    XCTAssertFalse(WaitAlertRule.shouldAlert(previous: .init(state: idle1.state, sessionId: nil), next: .init(state: idle2.state, sessionId: nil)))
}
func testNilStatusHandsBackToHooks() { let a = PaneStateMachine.applyProgramStatus(st("working"), to: base(), now: Date()); let n = PaneStateMachine.applyProgramStatus(nil, to: a, now: Date()); XCTAssertFalse(n.programStatusActive); XCTAssertEqual(n.state, .thinking) }
func testHookUpdatesDetailsOnlyWhileActive() { /* active idle snapshot + userPromptSubmit(prompt "hi") → state stays .idle, lastPrompt == "hi" */ }
func testPtyExitAppliesWhileProgramStatusActive() { /* active thinking + ptyExit(exitCode 1) → .errored, programStatusActive false */ }
```

- [ ] **Step 2: 실패를 확인한다.** → 컴파일 실패.
- [ ] **Step 3: 구현한다.** 위 표와 규칙대로. `Pane`에서 `hcBackend.onStatus = { status in Task.detached { await HookDaemon.shared.applyProgramStatus(paneId:, projectId:, status:) } }`.
- [ ] **Step 4: 통과를 확인한다.** `PaneProgramStatusTests` + 기존 `PaneState`/`HookDaemon`/`Notifier` 관련 테스트 → PASS.
- [ ] **Step 5: 커밋한다.** `git commit -m "feat(hc): 7501 status로 pane 상태를 정하고 hook은 세부 정보만 채운다"`

---

### Task 9: 세션 저장과 복원 — paneId, backend, hook 세부 정보, 고아 terminal

**Files:**
- Modify: `apps/termy/Sources/WorkspaceRecord.swift`(`PaneRecord` :68), `apps/termy/Sources/MainWindowController.swift`(`sessionWindowRecord` :267, `applySessionLayout` :302, `restore(workspace:)` :443), `apps/termy/Sources/WindowManager.swift`(`restoreSessionWindows` :31), `apps/termy/Sources/HookDaemon.swift`
- Create: `apps/termy/Sources/HcRestorePlanner.swift`
- Test: `apps/termy-tests/Sources/PaneRecordHcTests.swift`, `apps/termy-tests/Sources/HcRestorePlannerTests.swift`, `apps/termy-tests/Sources/HcRestoreIntegrationTests.swift`

**Interfaces:**
- Consumes: Task 7 `PaneLaunch`/`PaneBackendKind`/`Workspace.addPane(...)`, Task 6 `HcSessionManager`, Task 5 `HcEventStore.termyTerminals`.
- Produces:
  - `PaneRecord` 새 필드(모두 optional, 기본 `= nil`, `agentResume` 뒤에 이 순서로 선언해 memberwise init에서 생략할 수 있게 한다): `var paneId: String?`, `var backend: PaneBackendKind?`, `var machine: String?`, `var projectId: String?`, `var projectKey: String?`, `var hookDetails: PaneHookDetails?`
  - `struct PaneHookDetails: Codable, Equatable, Sendable { var lastSessionId: String?; var lastPrompt: String?; var lastAssistantMessage: String?; var lastCwd: String?; var agentKind: AgentKind? }`
  - `var PaneRecord.launch: PaneLaunch` — `backend == .hc` → `.hc(machine: machine)`, 아니면 `.local`
  - `func HookDaemon.restoreDetails(paneId: String, projectId: String?, details: PaneHookDetails) async` — 상태는 건드리지 않고 세부 필드만 채운 snapshot을 내보낸다.
  - `struct HcOrphan: Equatable { let paneId: String; let address: String; let machine: String?; let projectKey: String?; let cwd: String? }`
  - `enum HcRestorePlanner { static func orphans(live: [HcTerminal], knownPaneIds: Set<String>) -> [HcOrphan] }`
  - `func WindowManager.adoptHcOrphans() async` — `restoreSessionWindows` 뒤에, hc를 쓰는 pane이 하나라도 있었거나 로컬 hc 설정이 켜져 있을 때만 연결해서 실행. 고아마다 첫 창에 `addPane(cwd:, paneId:, launch: .hc(machine:), projectKey:)`.

규칙:
- `sessionWindowRecord`는 모든 pane에 `paneId`, `backend`, `machine`, `projectId`, `projectKey`를 쓰고, hc pane에만 `hookDetails`(snapshot에서)를 쓴다. `agentResume`은 local pane에만 쓴다.
- `applySessionLayout`/`restore(workspace:)`는 `paneId`(있으면 재사용), `record.launch`, `projectId`, `projectKey`를 `addPane`에 넘긴다. hc pane에 `hookDetails`가 있으면 `restoreDetails`.
- 복원한 hc pane은 연결에 실패해도 local로 바꾸지 않는다. `HcPaneBackend.start()`가 `.unavailable`로 두고, manager가 다시 연결하면 `reattach()`가 같은 paneId의 terminal을 찾아 붙거나 없으면 새로 띄운다.
- 예전 session.json(새 필드 없음)은 지금 동작 그대로다(새 UUID, local).

- [ ] **Step 1: 실패하는 테스트를 쓴다.**

```swift
func testOldPaneRecordDecodesAsLocal() throws {
    let r = try JSONDecoder().decode(PaneRecord.self, from: Data(#"{"cwd":"/tmp"}"#.utf8))
    XCTAssertNil(r.paneId); XCTAssertEqual(r.launch, .local)
}
func testHcPaneRecordRoundTrips() throws {
    let r = PaneRecord(cwd: "/srv/app", paneId: "P", backend: .hc, machine: "bdpc01", projectId: "app@bdpc01",
                       projectKey: "bdpc01:/srv/app", hookDetails: PaneHookDetails(lastSessionId: "s", lastPrompt: "p", lastAssistantMessage: nil, lastCwd: "/srv/app", agentKind: .claude))
    XCTAssertEqual(try JSONDecoder().decode(PaneRecord.self, from: JSONEncoder().encode(r)), r)
    XCTAssertEqual(r.launch, .hc(machine: "bdpc01"))
}
func testOrphansAreLiveTermyTerminalsNotInLayout() {
    let t = { (addr: String, pane: String) in HcTerminal(address: addr, state: "live", labels: ["termy.pane": pane, "termy.instance": "release", "termy.project": "bdpc01:/srv/app"], cwd: "/srv/app", exitCode: nil, reason: nil, status: nil, foreground: nil, cols: nil, rows: nil, title: nil) }
    let o = HcRestorePlanner.orphans(live: [t("t1", "A"), t("bdpc01/t2", "B")], knownPaneIds: ["A"])
    XCTAssertEqual(o, [HcOrphan(paneId: "B", address: "bdpc01/t2", machine: "bdpc01", projectKey: "bdpc01:/srv/app", cwd: "/srv/app")])
}
```

  통합(scratch core): `testRestoreReattachesSamePaneId`(hc pane 기록으로 복원 → 같은 address에 attach, `terminal.list` 개수 그대로, 화면에 이전 출력), `testHcPaneStaysUnavailableWhenCoreMissing`(Review Focus 4: endpointProvider가 nil을 돌려주는 manager로 복원 → pane의 `connectionState`가 `.unavailable`, `pane.launch == .hc(machine: nil)`, local 프로세스가 시작되지 않음 — `pane.terminal.process.running == false`), `testOrphanAdoptedIntoWindow`.
- [ ] **Step 2: 실패를 확인한다.** → 컴파일 실패.
- [ ] **Step 3: 구현한다.**
- [ ] **Step 4: 통과를 확인한다.** 새 테스트 + 기존 `SessionRecord`/`WorkspaceRecord`/`AgentResume` 테스트 → PASS.
- [ ] **Step 5: 커밋한다.** `git commit -m "feat(hc): hc pane을 저장하고 같은 terminal에 다시 붙인다"`

---

### Task 10: hc 설치 안내와 "Run local panes in herdr-core" 설정

**Files:**
- Create: `apps/termy/Sources/HcInstaller.swift`, `apps/termy/Sources/HcInstallSheet.swift`, `apps/termy/Sources/HcFeatureSettings.swift`
- Modify: `apps/termy/Sources/FontSettingsPanel.swift`(체크박스와 상태 줄), `apps/termy/Sources/Workspace.swift`(새 pane의 launch 결정)
- Test: `apps/termy-tests/Sources/HcFeatureSettingsTests.swift`, `apps/termy-tests/Sources/HcInstallerTests.swift`

**Interfaces:**
- Consumes: Task 4 `HcLocator`, Task 6 `HcSessionManager.availability`, Task 7 `PaneLaunch`.
- Produces:
  - `enum HcFeatureSettings { static let localPanesKey = "termy.herdrCore.localPanes"; static func localPanesEnabled(_ defaults: UserDefaults) -> Bool; static func setLocalPanesEnabled(_ on: Bool, _ defaults: UserDefaults) }`
  - `static func PaneLaunch.forNewLocalPane(defaults: UserDefaults) -> PaneLaunch` — 켜져 있으면 `.hc(machine: nil)`, 아니면 `.local`.
  - `enum HcInstaller { static let command = "curl -fsSL https://releases.herdr.dev/core/install.sh | sh"; static func run(output: @escaping @MainActor (String) -> Void) async -> Bool }` — `/bin/sh -c command`를 `HcEndpoint.minimalEnvironment(base: ProcessInfo.processInfo.environment)`로 실행, 끝난 뒤 `HcLocator.find`가 경로를 찾으면 true.
  - `@MainActor enum HcInstallSheet { static func ensureInstalled(over window: NSWindow?) async -> Bool }` — 이미 있으면 바로 true. 없으면 Global Constraints 문구의 alert → Install이면 출력 패널(읽기 전용 `NSTextView`)에 `HcInstaller.run` 출력을 흘리고 결과를 돌려준다. Cancel이면 false.

규칙:
- 사용자가 만드는 새 로컬 pane(새 pane / split 동작)만 `forNewLocalPane`을 따른다. 복원·고아·원격 pane은 기록이나 호출자가 준 launch를 쓴다.
- 설정 체크박스를 켤 때 `HcInstallSheet.ensureInstalled`가 false면 체크를 되돌린다. 상태 줄은 `availability`에 맞춰 Global Constraints 문구로 바뀐다(패널이 열릴 때 `ensureConnected`를 부르지 않는다. 이미 연결돼 있으면 그 상태를, 아니면 locator 결과만 보여 준다).
- 설정을 바꿔도 이미 열린 pane은 그대로다.

- [ ] **Step 1: 실패하는 테스트를 쓴다.**

```swift
func testLocalPanesDefaultOff() { let d = InMemoryUserDefaults(); XCTAssertFalse(HcFeatureSettings.localPanesEnabled(d)); XCTAssertEqual(PaneLaunch.forNewLocalPane(defaults: d), .local) }
func testLocalPanesOnLaunchesHc() { let d = InMemoryUserDefaults(); HcFeatureSettings.setLocalPanesEnabled(true, d); XCTAssertEqual(PaneLaunch.forNewLocalPane(defaults: d), .hc(machine: nil)) }
func testInstallerCommandIsOfficialScript() { XCTAssertEqual(HcInstaller.command, "curl -fsSL https://releases.herdr.dev/core/install.sh | sh") }
```

- [ ] **Step 2: 실패를 확인한다.** → 컴파일 실패.
- [ ] **Step 3: 구현한다.** 설치 스크립트를 테스트에서 실행하지 않는다.
- [ ] **Step 4: 통과를 확인한다.** → PASS. 전체 테스트 → `** TEST SUCCEEDED **`.
- [ ] **Step 5: 커밋한다.** `git commit -m "feat(hc): 설치 안내와 로컬 pane hc 설정"`

---

### Task 11: 원격 project — ⌘K에서 만들고 열기

**Files:**
- Create: `apps/termy/Sources/RemoteProject.swift`, `apps/termy/Sources/RemoteProjectSheet.swift`
- Modify: `apps/termy/Sources/WorkspaceRecord.swift`(`WorkspaceRecord` :27), `apps/termy/Sources/ProjectSwitcherPanel.swift`(footer 버튼, `onNewRemoteProject`), `apps/termy/Sources/MainWindowController.swift`(`showProjectSwitcher` :406, `restore(workspace:)` :443), `apps/termy/Sources/Workspace.swift`(새 pane이 원격 pane을 따르는 규칙)
- Test: `apps/termy-tests/Sources/RemoteProjectTests.swift`

**Interfaces:**
- Consumes: Task 6 `HcSessionManager.machines()/exec`, Task 7 `Workspace.addPane(...)`, Task 9 `PaneRecord` 새 필드, Task 10 `HcInstallSheet.ensureInstalled`.
- Produces:
  - `WorkspaceRecord.machine: String?`(optional, 기본 nil)
  - `enum RemoteProject { static func key(machine: String, folder: String) -> String; static func projectId(machine: String, folder: String) -> String; static func record(machine: String, folder: String, now: Date) -> WorkspaceRecord; static func machineLabel(_ m: HcMachine, isWindows: Bool) -> (title: String, enabled: Bool) }`
  - `static func Workspace.launchForNewPane(focused: (launch: PaneLaunch, cwd: String, projectId: String, projectKey: String)?, defaults: UserDefaults) -> (launch: PaneLaunch, cwd: String?, projectId: String?, projectKey: String?)` — 포커스된 pane이 원격이면 같은 machine·cwd·projectId·projectKey, 아니면 `(forNewLocalPane(defaults:), nil, nil, nil)`(지금 규칙으로 cwd/project 결정).
  - `@MainActor final class RemoteProjectSheet` — `static func present(over window: NSWindow, manager: HcSessionManager, onCreate: @escaping (WorkspaceRecord) -> Void)`

규칙:
- `record(machine:folder:now:)` = `WorkspaceRecord(schemaVersion: WorkspaceRecord.currentSchemaVersion, canonicalPath: key, displayLabel: projectId, updatedAt: now, panes: [PaneRecord(cwd: folder, backend: .hc, machine: machine, projectId: projectId, projectKey: key)], rows: nil, machine: machine)`.
- `machineLabel`: state `connected`이고 Windows가 아니면 `(name, true)`. `needs_login`/`unreachable`/`connecting`이면 이름 + 해당 접미사, `false`. Windows면 이름 + `" (Windows not supported)"`, `false`.
- Windows 판별: `exec(on: name, argv: ["uname"])`이 0이 아니거나 오류면 Windows로 본다. 머신 이름별로 메모리에 캐시.
- 시트: "New Remote Project…"를 누르면 먼저 `HcInstallSheet.ensureInstalled`(false면 닫음) → `ensureConnected` → `machines()`로 popup을 채운다(`needs_login` 머신을 고르면 Global Constraints 안내 문구를 보여 준다). Create를 누르면 `exec(on:, argv: ["test", "-d", folder])`가 0일 때만 `onCreate`, 아니면 `"Folder not found on <machine>."`.
- `onCreate` → `WorkspacePersistence.save(record)` → 기존 `restore(workspace:)`로 연다. `restore(workspace:)`는 `record.machine`이 있으면 각 pane을 `launch: .hc(machine:)`, `projectId: record.displayLabel`, `projectKey: record.canonicalPath`로 만든다.
- ⌘K 목록은 원격 project도 지금 행 모양 그대로 보여 준다(`displayLabel`이 `app@bdpc01`). 휴지통 삭제도 같다.

- [ ] **Step 1: 실패하는 테스트를 쓴다.**

```swift
func testKeyAndProjectId() {
    XCTAssertEqual(RemoteProject.key(machine: "bdpc01", folder: "/srv/app"), "bdpc01:/srv/app")
    XCTAssertEqual(RemoteProject.projectId(machine: "bdpc01", folder: "/srv/app"), "app@bdpc01")
}
func testRecordHasOneHcPane() {
    let r = RemoteProject.record(machine: "bdpc01", folder: "/srv/app", now: Date(timeIntervalSince1970: 0))
    XCTAssertEqual(r.machine, "bdpc01"); XCTAssertEqual(r.panes.first?.launch, .hc(machine: "bdpc01"))
}
func testOldWorkspaceRecordDecodesWithoutMachine() throws { /* JSON without "machine" → machine == nil */ }
func testMachineLabels() {
    let m = { (s: String) in HcMachine(name: "box", host: nil, state: s, why: nil) }
    XCTAssertTrue(RemoteProject.machineLabel(m("connected"), isWindows: false) == ("box", true))
    XCTAssertTrue(RemoteProject.machineLabel(m("needs_login"), isWindows: false) == ("box (needs login)", false))
    XCTAssertTrue(RemoteProject.machineLabel(m("connected"), isWindows: true) == ("box (Windows not supported)", false))
}
func testNewPaneFollowsFocusedRemotePane() {
    let r = Workspace.launchForNewPane(focused: (.hc(machine: "bdpc01"), "/srv/app/sub", "app@bdpc01", "bdpc01:/srv/app"), defaults: InMemoryUserDefaults())
    XCTAssertEqual(r.launch, .hc(machine: "bdpc01")); XCTAssertEqual(r.cwd, "/srv/app/sub"); XCTAssertEqual(r.projectKey, "bdpc01:/srv/app")
}
```

- [ ] **Step 2: 실패를 확인한다.** → 컴파일 실패.
- [ ] **Step 3: 구현한다.**
- [ ] **Step 4: 통과를 확인한다.** `RemoteProjectTests` + `ProjectSwitcher` 관련 기존 테스트 → PASS. 전체 테스트 → `** TEST SUCCEEDED **`.
- [ ] **Step 5: 커밋한다.** `git commit -m "feat(hc): ⌘K에서 원격 project를 만들고 연다"`

---

### Task 12: 실제 동작 확인 (사용자와 함께)

자동 테스트는 입력·IME·kitty 경로를 증명하지 못한다(메모: IME/kitty 변경은 실제로 띄워 확인). termy를 직접 띄우지 않고 사용자에게 요청한다.

**Files:**
- Modify: `docs/superpowers/specs/2026-11-01-herdr-core-backend-design.md`(§9 아래 `### 확인 결과` 추가)

- [ ] **Step 1: Debug 빌드를 만든다.** `xcodegen generate && xcodebuild build -project termy.xcodeproj -scheme termy -configuration Debug -derivedDataPath build/DerivedData-debug -skipPackagePluginValidation 2>&1 | tail -5` → `** BUILD SUCCEEDED **`.
- [ ] **Step 2: 사용자에게 확인 목록을 보낸다(한국어).** 실행은 `env -i HOME=$HOME USER=$USER PATH=/usr/bin:/bin open build/DerivedData-debug/Build/Products/Debug/termy.app`처럼 깨끗한 환경으로 하도록 안내한다(메모: agent 환경 누출). 목록은 spec §9 수용 기준 전부 + 다음:
  - 설정을 켠 로컬 hc pane에서 한글 입력(조합 중 표시, 커밋), Claude Code 안에서 Shift+Return, 큰 텍스트 붙여넣기, 마우스 선택, vim에서 화살표.
  - ⌘Q 후 다시 실행해 위 다섯 가지를 다시 확인(다시 attach한 뒤의 모드).
  - release termy를 함께 띄운 상태에서 Debug pane을 닫아도 release의 hc terminal이 그대로인지(`hc ls`).
  - bdpc01 원격 project를 만들고 Claude Code를 돌려 mission control 상태와 알림.
- [ ] **Step 3: 결과를 spec §9 아래에 적는다.** 실패 항목이 있으면 `superpowers:systematic-debugging`으로 원인을 찾고, 고친 태스크의 테스트를 더한 뒤 다시 확인한다.
- [ ] **Step 4: 커밋한다.** `git commit -m "docs(spec): herdr-core 백엔드 실제 동작 확인 결과"`
