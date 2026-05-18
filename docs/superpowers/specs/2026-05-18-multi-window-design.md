# 멀티 윈도우 지원 — 설계 문서

- 날짜: 2026-05-18
- 상태: 승인됨 (구현 계획 작성 대기)
- 범위: termy의 단일 윈도우 구조를 멀티 윈도우로 확장

## 1. 목표와 동기

termy는 현재 `AppDelegate`가 단일 `MainWindowController`를 소유하는 단일 윈도우
앱이다. 핵심 사용 시나리오는 **멀티 모니터 확장** — 사용자가 여러 모니터에
걸쳐 termy 창을 펼쳐 두고 에이전트 작업을 분산하는 것이다.

성공 기준:

- ⌘N으로 독립된 새 창을 열 수 있다.
- 각 창은 자기 pane 그리드 / 프로젝트 필터 / split 동작을 독립적으로 가진다.
- 하단 Mission Control 대시보드는 **모든 창의 pane을 전역 집계**해서 보여준다.
  어느 창에서든 다른 창의 pane 칩을 클릭하면 그 창이 앞으로 나오고 포커스된다.
- WAITING 알림 배너 탭이 어느 창의 pane이든 정확히 라우팅된다.
- 앱을 종료했다 다시 켜면 열려 있던 모든 창이 frame + pane 레이아웃까지
  복원된다(전체 세션 복원).

## 2. 비목표 (v1 제외)

- 창 간 pane 이동 / detach / 드래그. 살아있는 SwiftTerm 뷰 + PTY 재패런팅은
  위험하므로 후속 작업으로 미룬다. v1에서 한 pane은 생성된 창에 평생 속한다.
- 창별 테마 / 창별 폰트. 외관·폰트는 전역 설정으로 유지한다.
- 탭. termy는 이미 탭을 pane 그리드로 대체했으며 그대로 둔다.

## 3. 현재 구조 (출발점)

- `AppDelegate`가 단일 `mainWindowController`를 소유. `activeController`는 이미
  `NSApp.keyWindow` 기반으로 동작(멀티 윈도우 일부 대비됨).
- `MainWindowController`가 `Workspace`(pane 그리드), `MissionControlModel`(대시
  보드), `WorkspaceAutosaver`, 창별 패널들을 소유.
- `MissionControlModel`이 `HookDaemon.shared.updates`(AsyncStream)를 펌프한다.
  **AsyncStream은 단일 소비자만 허용** — 두 개의 `for await`는 이벤트를 갈라
  먹는다(코드 주석에 명시).
- `Notifier.shared.onFocusPane`은 단일 컨트롤러로만 라우팅된다.
- `WorkspacePersistence`는 **프로젝트별**(canonicalPath 키) pane 레이아웃 레코드를
  저장한다. ⌘K 프로젝트 스위처가 이를 읽어 복원한다. 윈도우/세션 개념은 없다.
- `Pane.paneId`는 `UUID().uuidString` — 창 간 전역 고유.

## 4. 접근 방식

선택: **명시적 WindowManager + 앱 레벨 공유 상태.**

기각된 대안:

- *창마다 완전 독립 모델* — `HookDaemon.updates`의 단일 소비자 제약으로 두 창이
  이벤트를 갈라 먹고, 대시보드가 창-로컬이 되어 "전역 집계" 목표와 모순된다.
- *SwiftUI WindowGroup 재작성* — termy는 AppKit 루트(`TermyWindow` 서브클래스,
  `NSHostingView` 아일랜드)라 침습적이라 기각.

## 5. 컴포넌트 설계

### 5.1 신규 `WindowManager`

`@MainActor final class`, `AppDelegate`가 소유한다.

책임:

- `controllers: [MainWindowController]` 배열 소유. 창 생성·등록·해제.
- `newWindow()` — `MainWindowController` 생성 + HOME pane 시드 + cascade 배치
  (직전 창 대비 약간 오프셋해 정확히 겹치지 않게) + 등록 + 표시.
- `removeWindow(_ controller:)` — 컨트롤러 등록 해제, 공유 모델에서 해당 창
  엔트리 제거.
- `focusPane(byId:)` — paneId를 소유한 컨트롤러를 찾아 그 창을
  `makeKeyAndOrderFront` + `NSApp.activate`한 뒤 해당 창에서 pane을 포커스.
  소유자 조회는 각 컨트롤러의 `workspace.panes`를 스캔한다(창 소수 × pane ≤32
  이라 별도 레지스트리 불필요).
- 세션 저장/복원 진입점 보유(5.4 참조).

### 5.2 `MissionControlModel` → 앱 싱글톤

`MissionControlModel.shared`로 승격한다. 각 `MainWindowController`는 자체 모델을
만들지 않고 `.shared`를 사용한다. 모든 창의 `MissionControlView`가 동일한
`@Observable` 인스턴스를 관찰 → 전역 집계 대시보드.

`HookDaemon.updates` 펌프는 그대로 둔다. 이제 소비자가 정확히 하나라 단일-소비자
제약이 자연히 충족된다.

변경되는 API:

- `setLivePaneIds(_ ids:)` → `setLivePaneIds(_ ids:, forWindow: UUID)`.
  모델이 `[UUID: [String]]`(창별 pane 순서)를 보관하고, 글로벌 `paneOrder`를
  **창 생성순 → 창 내 pane 생성순**으로 평탄화한다.
- `livePaneIds`는 전 창 합집합.
- `labelsByPaneId` 정리(현재 `setLivePaneIds`에서 수행)는 합집합 기준으로 한다.
- `removeWindow(_ windowId: UUID)` 추가 — 창이 닫힐 때 해당 창 엔트리 제거 후
  `recomputeItems()`.

`maxDashboardItems = 32`는 v1에서 유지하되 의미가 "per-window"에서 **전역 캡**으로
바뀌므로 주석을 갱신한다.

`onSnapshotUpdate → Notifier` 연결은 컨트롤러 init이 아니라 앱 init에서 1회만
설정한다.

### 5.3 `MainWindowController` 멀티 인스턴스화

- `let windowId = UUID()` 추가 — 공유 모델 키, 세션 레코드 키.
- 자체 `MissionControlModel` 생성 제거 → `MissionControlModel.shared` 사용.
- `workspace.onPanesChanged`에서 `missionControlModel.setLivePaneIds(...)`를
  `setLivePaneIds(orderedIds, forWindow: windowId)`로 호출.
- `focusPane(byId:)`는 `WindowManager.focusPane(byId:)`로 위임한다. (현재
  `workspace.focusPane(byId:)`는 자기 창의 pane만 찾으므로 다른 창 pane을
  대상으로 한 `cycleDashboardItem`/`selectDashboardItem`이 무동작이 됨.)
- `windowWillClose(_:)` 신설: WindowManager에서 등록 해제,
  `MissionControlModel.shared.removeWindow(windowId)`, 자기 autosaver
  `flushSync`, `Notifier`의 waiting pane prune.
- 창은 멀티 인스턴스이므로 init 시 cascade 위치를 받을 수 있어야 한다.

### 5.4 세션 영속화

신규 타입 (`WorkspacePersistence`의 atomic temp+rename, schema-versioned,
quarantine 패턴을 그대로 따른다):

- `SessionRecord: Codable` — `schemaVersion`, `windows: [WindowRecord]`.
- `WindowRecord: Codable` — `frame`(x/y/width/height 4 double), `rows:
  [[PaneRecord]]`(기존 `PaneRecord` 재사용), `filter`(직렬화 가능한 표현),
  포커스 pane 인덱스(옵셔널).
- `SessionPersistence` — `~/Library/Application Support/termy/session.json`에
  단일 파일로 저장. atomic 쓰기, schema 미래 버전 quarantine.

신규 `SessionAutosaver`(앱 레벨, `@MainActor`):

- 디바운스 저장(`WorkspaceAutosaver`의 500ms 패턴 차용).
- 트리거: pane 추가/닫힘, 창 이동(`windowDidMove`), 리사이즈
  (`windowDidResize`), 창 추가/닫힘.
- 저장 시 모든 컨트롤러를 순회해 `WindowRecord`를 만든다.

복원 (`applicationDidFinishLaunching`):

- `session.json`을 읽는다.
- 비어있지 않으면 각 `WindowRecord`마다 창을 재생성 — frame 적용, pane
  레이아웃(`rows`)을 `MainWindowController.restore`와 동일한 row/column 축
  재생 로직으로 복원, 필터 복원.
- frame이 현재 보이는 스크린 밖이면 보이는 스크린으로 클램프. 스크린이
  사라졌으면 메인 스크린에 배치.
- 파일 없음 / 빈 세션 / 읽기 실패면 현행 동작(창 1개, HOME pane 1개).

기존 프로젝트별 `WorkspacePersistence`(⌘K 스위처)는 **변경하지 않는다** —
세션 복원과 직교하는 별개 기능이다.

## 6. 창 간 라우팅

다음 진입점이 모두 `WindowManager.focusPane(byId:)`로 통일된다:

- `MissionControlView`의 칩 클릭(`onFocusPane`).
- `MainWindowController.cycleDashboardItem` / `selectDashboardItem` /
  `cycleWaitingPane` (이제 전역 대시보드 항목을 대상으로 함).
- `Notifier.shared.onFocusPane` — `AppDelegate`에서 한 번만 WindowManager로
  연결(현재는 단일 컨트롤러 클로저).

`AppDelegate.activeController`는 기존 `NSApp.keyWindow` 기반 로직을 유지하고,
fallback만 단일 `mainWindowController`에서 "WindowManager의 첫 컨트롤러"로
바꾼다.

## 7. 단축키 / 메뉴 변경

- **⌘N → New Window** (`WindowManager.newWindow()`).
- **⌘T → New Pane** (기존 ⌘N의 New Pane 로직).
- Split은 ⌘D / ⌘⇧D 그대로.
- macOS 표준 Window 메뉴는 `NSApp.windowsMenu` 등록으로 열린 창 목록을 자동
  표시한다(이미 `windowsMenu` 설정됨).
- `AppDelegate`의 File 메뉴 항목 재배선 — "New Pane"을 ⌘T로, "New Window"를
  ⌘N으로 신설.

## 8. 종료 처리

`applicationWillTerminate`:

- 모든 컨트롤러의 `WorkspaceAutosaver.flushSync`를 **동시에**(병렬 Task) 실행.
- `SessionAutosaver`의 동기 flush도 실행.
- 작업이 병렬이므로 기존 0.5s 예산 안에서 처리 가능.

`applicationShouldTerminateAfterLastWindowClosed`는 `true` 유지 — 마지막 창이
닫히면 앱 종료.

## 9. 엣지 케이스

- **AsyncStream 단일 소비자**: `MissionControlModel.shared` 하나만
  `HookDaemon.updates`를 펌프 → 해결.
- **창별 패널**(ProjectSwitcher / KeyboardShortcuts / FontSettings): 컨트롤러별
  유지. 이미 `over: window`로 동작.
- **폰트 / 외관 변경**: 이미 전역(`TerminalFontPreference.shared`,
  `AppAppearancePreference`) — 알림으로 모든 창에 자동 반영. 변경 불필요.
- **두 인스턴스 동시 실행**: 세션 파일 last-writer-wins. 기존
  `WorkspacePersistence`와 동일한 알려진 제약. v1 허용.
- **마지막 pane 닫힘**: 그 창만 닫힘. 마지막 창이 닫히면 앱 종료.
- **빈 / 손상 세션 파일**: quarantine 후 현행 단일 창 동작으로 폴백.

## 10. 테스트 전략

- `MissionControlModel`: 다중 창 등록/해제 시 글로벌 `paneOrder` 평탄화,
  `livePaneIds` 합집합, `removeWindow` 후 항목 정리에 대한 단위 테스트.
- `SessionRecord` / `SessionPersistence`: round-trip 인코딩, schema 버전
  quarantine, atomic 쓰기 단위 테스트.
- frame 클램핑: 스크린 밖 frame이 보이는 영역으로 보정되는지 단위 테스트.
- `WindowManager.focusPane(byId:)`: 소유 컨트롤러 조회 로직 단위 테스트.
- 라이브 검증(메모리 노트: termy의 윈도우/포커스 동작은 유닛 테스트만으로는
  배선이 증명되지 않음): ⌘N 새 창, 창 간 칩 클릭 라우팅, WAITING 배너 라우팅,
  종료 후 멀티 창 세션 복원을 실제로 실행해 확인.
