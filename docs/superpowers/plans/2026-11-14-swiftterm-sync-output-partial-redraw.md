# SwiftTerm: 동기화 출력이 끝날 때 화면 전체를 다시 그리지 않는다

## 배경

Claude Code는 화면을 갱신할 때마다 `ESC[?2026h … ESC[?2026l`(DEC 2026, synchronized output)로 감싼다.
SwiftTerm의 `Terminal.endSynchronizedOutput()`이 `refresh (startRow: 0, endRow: rows - 1)`를 불러
화면 전체를 dirty로 표시하므로, spinner 한 줄만 바뀌어도 매 프레임 전체 행을 다시 그린다.
측정(62행, 12행 갱신, 12.5Hz): 동기화 출력이 있으면 63행·13ms/회·CPU 23%, 그 줄을 빼면 13행·6ms/회·CPU 13%.

이 줄은 2026 지원이 snapshot 방식이던 때(upstream 64a96cc)의 흔적이다. 9446f60에서 snapshot이 빠지고
"view가 그리기를 멈추는 flag"로 바뀐 뒤로는 필요 없다. 동기화 출력 중에는 `AppleTerminalView.updateDisplay`가
`clearUpdateRange()` 전에 return하므로, 그동안 쌓인 update range(합집합, scroll은 scrollTop…scrollBottom 기록)가
끝날 때 그대로 남아 있다.

## Global Constraints

- SwiftTerm 작업은 `~/proj/SwiftTerm`의 브랜치 `termy/1.20`에서 한다 (현재 HEAD f896d9d). 1.x 계열 유지, 2.0(main)으로 올리지 않는다.
- termy 작업은 `/Users/ysh/proj/termy`의 `main`에서 한다 (이 저장소의 관례).
- 커밋 메시지는 한국어, Co-Authored-By 줄 없음. 형식은 기존 커밋을 따른다 (예: `fix(terminal): …`).
- SwiftTerm `swift test`는 `MetalRendererStatusTests` 5개가 항상 실패한다 (SPM CLI에서 shader resource를 못 읽음, 기존 문제). 그 외 실패는 회귀다.
- termy의 command-line `xcodebuild`에는 항상 `-skipPackagePluginValidation`을 붙인다.

## Task 1: SwiftTerm — `endSynchronizedOutput()`의 전체 refresh 제거 + 테스트

**파일:**
- 수정: `~/proj/SwiftTerm/Sources/SwiftTerm/Terminal.swift` — `private func endSynchronizedOutput ()`
- 수정: `~/proj/SwiftTerm/Tests/SwiftTermTests/SynchronizedOutputTests.swift`

**변경:** `endSynchronizedOutput()`에서 아래 한 줄을 지운다. 나머지(flag 해제, timeout 취소, delegate 호출)는 그대로 둔다.

```swift
        refresh (startRow: 0, endRow: rows - 1)
```

그 자리에 이유를 남기는 짧은 주석을 둔다 (영어, 기존 파일 주석 스타일):
동기화 출력 중 view는 update range를 지우지 않으므로 끝날 때 쌓인 범위만 다시 그리면 된다,
전체 refresh는 매 프레임 화면 전체를 다시 그리게 했다(BSU/ESU로 프레임을 감싸는 TUI).

**테스트 (`SynchronizedOutputTests`에 추가, swift-testing `@Test`, 기존 `TestDelegate` 사용):**

1. `testEndingSyncOnlyRefreshesRowsChangedDuringSync`
   - `Terminal(delegate: TestDelegate(), options: TerminalOptions(cols: 20, rows: 10, scrollback: 0))`
   - `feed(text: "\u{1b}[2J\u{1b}[H")`로 화면을 비우고 `terminal.clearUpdateRange()`
   - `feed(text: "\u{1b}[?2026h")` → `feed(text: "\u{1b}[5;1HX")` (5번째 줄, 0-based row 4) → `feed(text: "\u{1b}[?2026l")`
   - 기대: `terminal.getUpdateRange()`의 `startY == 4`, `endY == 4` (수정 전에는 `0…9`라 실패해야 한다)
2. `testScrollDuringSyncStillRefreshesScrollRegion`
   - 같은 10행 터미널, 화면 비우고 `clearUpdateRange()`
   - `?2026h` → 커서를 마지막 줄로 (`\u{1b}[10;1H`) 옮긴 뒤 `"A\r\nB"`를 써서 한 줄 scroll → `?2026l`
   - 기대: `getUpdateRange()`가 `0…9` 전체를 덮는다 (scroll은 scrollTop…scrollBottom을 기록하므로 수정 후에도 통과)

**검증:** `cd ~/proj/SwiftTerm && swift test 2>&1 | tail -30` — 새 테스트 2개 통과, 실패는 `MetalRendererStatusTests` 5개뿐.
수정 전 상태에서 테스트 1이 실패하는 것을 먼저 확인한다 (red → green).

**커밋 (`termy/1.20`, push는 하지 않는다):**
`fix(terminal): 동기화 출력이 끝날 때 바뀐 줄만 다시 그린다`
본문에 원인(2026 snapshot 시절의 전체 refresh가 남아 BSU/ESU 프레임마다 화면 전체를 다시 그림)과 측정값을 적는다.

## Task 2: termy — 새 SwiftTerm revision 고정

**전제:** Task 1 커밋이 `fork` remote(`https://github.com/yeonsh/SwiftTerm.git`)의 `termy/1.20`에 push되어 있다 (controller가 한다).

**파일:**
- 수정: `/Users/ysh/proj/termy/project.yml` — `packages.SwiftTerm.revision`을 Task 1 커밋의 전체 SHA로 바꾼다.
  위 주석의 patch 목록(괄호 안)에 "synchronized output 끝에 화면 전체를 다시 그리지 않음"을 한 구절로 덧붙인다.
- 삭제: `termy.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (gitignore된 생성물, 재해석용)

**검증:**
```
cd /Users/ysh/proj/termy && xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation 2>&1 | grep -E "Executed [0-9]+ tests|Failing tests|\*\* TEST" | tail -5
```
`build/DerivedData-tests/SourcePackages/checkouts/SwiftTerm`의 HEAD가 새 SHA인지 확인한다. 전체 테스트 통과.

**커밋 (`main`):** `chore(swiftterm): 동기화 출력 끝의 전체 다시 그리기를 뺀 fork revision으로 올린다`

## 이후 (controller, 사람 필요)

Release 빌드 → `/Applications/termy.app` 교체(백업 유지) → agent가 출력하는 동안 CPU와 `sample`로
`TerminalView.draw` 비중이 줄었는지 확인한다.
