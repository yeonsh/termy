# 멀티 윈도우 지원 — 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** termy의 단일 윈도우 구조를 멀티 윈도우(멀티 모니터 확장)로 확장하고, 전역 집계 대시보드 / 창 간 포커스 라우팅 / 전체 세션 복원을 구현한다.

**Architecture:** 앱 레벨 `WindowManager`가 모든 `MainWindowController`를 소유한다. `MissionControlModel`을 앱 싱글톤으로 승격해 `HookDaemon.updates`(단일 소비자 AsyncStream)를 한 번만 펌프하고, 모든 창이 동일한 `@Observable` 모델을 관찰한다. 신규 `SessionPersistence`/`SessionAutosaver`가 열린 창 집합을 `session.json`에 저장하고 재시작 시 복원한다.

**Tech Stack:** Swift 6, AppKit, SwiftUI(`NSHostingView` 아일랜드), XcodeGen(`project.yml`), XCTest.

**설계 문서:** `docs/superpowers/specs/2026-05-18-multi-window-design.md`

---

## 시작 전 참고 (모든 태스크 공통)

- **새 `.swift` 파일을 만들면 반드시 `xcodegen generate`를 실행**한다. XcodeGen은
  `apps/termy/Sources`·`apps/termy-tests/Sources` 디렉터리를 generate 시점에
  열거하므로, 재생성 전에는 새 파일이 `termy.xcodeproj`에 들어가지 않는다.
- 빌드: `xcodebuild build -project termy.xcodeproj -scheme termy -destination 'platform=macOS' 2>&1 | tail -15` → `** BUILD SUCCEEDED **` 확인.
- 테스트: `xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -only-testing:termy-tests/<Class> 2>&1 | tail -25` → `** TEST SUCCEEDED **` 확인. 첫 빌드는 SwiftTerm/Sparkle 컴파일로 수 분 걸린다.
- 프로젝트 규약(`CLAUDE.md`): 기존 심볼을 수정하기 전 `gitnexus_impact({target, direction: "upstream"})`로 blast radius를 확인하고, HIGH/CRITICAL이면 사용자에게 경고한다. GitNexus 인덱스가 stale이면 먼저 `npx gitnexus analyze`를 실행한다.
- 커밋 메시지에 `Co-Authored-By` 라인을 넣지 않는다(전역 규약).
- 작업 브랜치: `feat/multi-window` (이미 생성됨, 설계 문서 커밋됨).

## 파일 구조

**신규 파일:**

| 파일 | 책임 |
|------|------|
| `apps/termy/Sources/SessionRecord.swift` | 멀티 윈도우 세션 on-disk 스키마(`SessionRecord`/`WindowRecord`/`FrameRecord`) |
| `apps/termy/Sources/SessionPersistence.swift` | `session.json` atomic 읽기/쓰기 actor |
| `apps/termy/Sources/SessionAutosaver.swift` | 창/pane 변경에 디바운스 세션 저장 |
| `apps/termy/Sources/WindowManager.swift` | 모든 `MainWindowController` 소유, 창 생성/라우팅/세션 복원 |
| `apps/termy-tests/Sources/SessionRecordTests.swift` | `SessionRecord` round-trip 테스트 |
| `apps/termy-tests/Sources/SessionPersistenceTests.swift` | `SessionPersistence` 저장/로드/quarantine 테스트 |
| `apps/termy-tests/Sources/MissionControlModelTests.swift` | 멀티 윈도우 등록 로직 테스트 |
| `apps/termy-tests/Sources/WindowManagerTests.swift` | cascade/clamp 순수 함수 테스트 |

**수정 파일:**

| 파일 | 변경 |
|------|------|
| `apps/termy/Sources/MissionControlModel.swift` | 앱 싱글톤화, 창별 pane 등록 API |
| `apps/termy/Sources/MainWindowController.swift` | 멀티 인스턴스화, 공유 모델 사용, 세션 레코드/복원, 창 delegate |
| `apps/termy/Sources/AppDelegate.swift` | `WindowManager` 소유, ⌘N/⌘T 메뉴 재배선, Notifier 라우팅, 세션 복원/flush |

---

## Task 1: 세션 on-disk 스키마

**Files:**
- Create: `apps/termy/Sources/SessionRecord.swift`
- Test: `apps/termy-tests/Sources/SessionRecordTests.swift`

`PaneRecord`(이미 `WorkspaceRecord.swift`에 정의됨, `struct PaneRecord: Codable, Equatable { var cwd: String }`)를 재사용한다.

- [ ] **Step 1: 실패하는 테스트 작성**

`apps/termy-tests/Sources/SessionRecordTests.swift` 생성:

```swift
import XCTest
@testable import termy

final class SessionRecordTests: XCTestCase {
    func test_sessionRecord_roundTripsThroughJSON() throws {
        let record = SessionRecord(windows: [
            WindowRecord(
                frame: FrameRecord(x: 10, y: 20, width: 1200, height: 760),
                rows: [
                    [PaneRecord(cwd: "/a"), PaneRecord(cwd: "/b")],
                    [PaneRecord(cwd: "/c")]
                ],
                filterProjectId: "proj",
                focusedPaneIndex: 2
            )
        ])
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(SessionRecord.self, from: data)
        XCTAssertEqual(decoded, record)
    }

    func test_sessionRecord_defaultSchemaVersionIsCurrent() {
        let record = SessionRecord(windows: [])
        XCTAssertEqual(record.schemaVersion, SessionRecord.currentSchemaVersion)
    }

    func test_frameRecord_convertsToAndFromCGRect() {
        let rect = CGRect(x: 1, y: 2, width: 3, height: 4)
        XCTAssertEqual(FrameRecord(rect).cgRect, rect)
    }
}
```

- [ ] **Step 2: 새 파일 등록 후 테스트 실패 확인**

Run: `cd /Users/ysh/proj/termy && xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -only-testing:termy-tests/SessionRecordTests 2>&1 | tail -25`
Expected: 컴파일 실패 — `cannot find 'SessionRecord' in scope`.

- [ ] **Step 3: 스키마 구현**

`apps/termy/Sources/SessionRecord.swift` 생성:

```swift
// SessionRecord.swift
//
// On-disk schema for the full multi-window session — the set of windows
// open at quit time and each window's pane layout / frame / filter.
// Written by `SessionAutosaver`, read by `WindowManager` on launch.
// Schema-versioned like `WorkspaceRecord`: a newer-than-known file is
// quarantined by `SessionPersistence` rather than partially decoded.

import Foundation

struct SessionRecord: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var windows: [WindowRecord]

    init(schemaVersion: Int = Self.currentSchemaVersion, windows: [WindowRecord]) {
        self.schemaVersion = schemaVersion
        self.windows = windows
    }
}

/// One window's restorable state.
struct WindowRecord: Codable, Equatable {
    /// Window frame (screen coordinates) at save time. Restored frames are
    /// clamped to the visible screen area first — see `WindowManager`.
    var frame: FrameRecord
    /// Row-major pane grid: row 0 is the top row, each inner array a
    /// horizontal row of panes. Mirrors `Workspace.rows`.
    var rows: [[PaneRecord]]
    /// Active project filter: `nil` = `.all`, a value = `.project(id)`.
    var filterProjectId: String?
    /// Index of the focused pane into the flattened `rows` (creation order).
    /// `nil` when the window had no focused pane.
    var focusedPaneIndex: Int?

    init(
        frame: FrameRecord,
        rows: [[PaneRecord]],
        filterProjectId: String? = nil,
        focusedPaneIndex: Int? = nil
    ) {
        self.frame = frame
        self.rows = rows
        self.filterProjectId = filterProjectId
        self.focusedPaneIndex = focusedPaneIndex
    }
}

/// Plain-`Double` window frame. `CGRect` is Codable, but an explicit struct
/// keeps the JSON shape stable and human-readable.
struct FrameRecord: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.size.width)
        self.height = Double(rect.size.height)
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -only-testing:termy-tests/SessionRecordTests 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: 커밋**

```bash
git add apps/termy/Sources/SessionRecord.swift apps/termy-tests/Sources/SessionRecordTests.swift termy.xcodeproj
git commit -m "feat(session): add multi-window session on-disk schema"
```

---

## Task 2: 세션 영속화 actor

**Files:**
- Create: `apps/termy/Sources/SessionPersistence.swift`
- Test: `apps/termy-tests/Sources/SessionPersistenceTests.swift`

`WorkspacePersistence`의 atomic temp+rename, schema-probe, quarantine 패턴을 단일 파일(`session.json`) 버전으로 따른다.

- [ ] **Step 1: 실패하는 테스트 작성**

`apps/termy-tests/Sources/SessionPersistenceTests.swift` 생성:

```swift
import XCTest
@testable import termy

final class SessionPersistenceTests: XCTestCase {
    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("termy-session-test-\(UUID().uuidString)", isDirectory: true)
    }

    func test_saveThenLoad_roundTrips() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SessionPersistence(rootDir: root)
        let record = SessionRecord(windows: [
            WindowRecord(
                frame: FrameRecord(x: 0, y: 0, width: 100, height: 100),
                rows: [[PaneRecord(cwd: "/x")]]
            )
        ])
        try await persistence.save(record)
        guard case .loaded(let loaded) = await persistence.load() else {
            return XCTFail("expected .loaded")
        }
        XCTAssertEqual(loaded, record)
    }

    func test_load_missingFile_returnsMissing() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SessionPersistence(rootDir: root)
        guard case .missing = await persistence.load() else {
            return XCTFail("expected .missing")
        }
    }

    func test_load_newerSchema_quarantines() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SessionPersistence(rootDir: root)
        let future = #"{"schemaVersion": 999, "windows": []}"#
        try Data(future.utf8).write(to: root.appendingPathComponent("session.json"))
        guard case .quarantined = await persistence.load() else {
            return XCTFail("expected .quarantined")
        }
        // Quarantine moves the file out of the way — a second load is .missing.
        guard case .missing = await persistence.load() else {
            return XCTFail("expected .missing after quarantine")
        }
    }
}
```

- [ ] **Step 2: 새 파일 등록 후 테스트 실패 확인**

Run: `cd /Users/ysh/proj/termy && xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -only-testing:termy-tests/SessionPersistenceTests 2>&1 | tail -25`
Expected: 컴파일 실패 — `cannot find 'SessionPersistence' in scope`.

- [ ] **Step 3: 영속화 actor 구현**

`apps/termy/Sources/SessionPersistence.swift` 생성:

```swift
// SessionPersistence.swift
//
// Serial reader/writer for the single multi-window session file at
// `~/Library/Application Support/termy/session.json`. Every save is an
// atomic temp+rename so a mid-write crash can't leave half-written JSON.
// On read, a `schemaVersion` newer than known — or an undecodable file —
// is moved to `_quarantine/` and load returns a non-`.loaded` outcome, so
// the caller falls back to a fresh single window rather than corrupting
// state. Mirrors `WorkspacePersistence`'s discipline for a single file.

import Foundation

enum SessionPersistenceError: Error {
    case directoryCreateFailed(Error)
    case writeFailed(Error)
    case renameFailed(POSIXErrorCode)
    case encodeFailed(Error)
}

enum SessionLoadOutcome {
    case loaded(SessionRecord)
    case missing
    case quarantined(reason: String)
}

actor SessionPersistence {
    nonisolated let fileURL: URL
    nonisolated let quarantineDir: URL

    static var defaultRootDir: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("termy", isDirectory: true)
    }

    init(rootDir: URL = SessionPersistence.defaultRootDir) throws {
        self.fileURL = rootDir.appendingPathComponent("session.json")
        self.quarantineDir = rootDir.appendingPathComponent("_quarantine", isDirectory: true)

        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: rootDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fm.createDirectory(
                at: quarantineDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw SessionPersistenceError.directoryCreateFailed(error)
        }
    }

    /// Atomic write: encode → temp → `rename(2)`. Final file is `0600`.
    func save(_ record: SessionRecord) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(record)
        } catch {
            throw SessionPersistenceError.encodeFailed(error)
        }

        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".tmp-session-\(UUID().uuidString).json")
        do {
            try data.write(to: tempURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: tempURL.path
            )
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw SessionPersistenceError.writeFailed(error)
        }

        let ok = rename(tempURL.path, fileURL.path)
        if ok != 0 {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? FileManager.default.removeItem(at: tempURL)
            throw SessionPersistenceError.renameFailed(code)
        }
    }

    /// Read the session file. `.missing` if absent, `.quarantined` if it was
    /// archived (corrupt or newer schema), `.loaded` on success.
    func load() -> SessionLoadOutcome {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .missing
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            return quarantine(reason: "unreadable")
        }
        struct Probe: Codable { let schemaVersion: Int }
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data) else {
            return quarantine(reason: "undecodable")
        }
        if probe.schemaVersion > SessionRecord.currentSchemaVersion {
            return quarantine(reason: "v\(probe.schemaVersion)")
        }
        guard let record = try? JSONDecoder().decode(SessionRecord.self, from: data) else {
            return quarantine(reason: "decode-failed")
        }
        return .loaded(record)
    }

    @discardableResult
    private func quarantine(reason: String) -> SessionLoadOutcome {
        let dest = quarantineDir.appendingPathComponent("session-\(reason).json")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(at: fileURL, to: dest)
        return .quarantined(reason: reason)
    }

    func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -only-testing:termy-tests/SessionPersistenceTests 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: 커밋**

```bash
git add apps/termy/Sources/SessionPersistence.swift apps/termy-tests/Sources/SessionPersistenceTests.swift termy.xcodeproj
git commit -m "feat(session): add session.json persistence actor"
```

---

## Task 3: MissionControlModel 창별 등록

**Files:**
- Modify: `apps/termy/Sources/MissionControlModel.swift`
- Modify: `apps/termy/Sources/MainWindowController.swift` (최소 변경: `windowId` 추가 + 호출부 1곳)
- Test: `apps/termy-tests/Sources/MissionControlModelTests.swift`

`HookDaemon.updates`(단일 소비자)를 한 번만 펌프하도록 모델을 앱 싱글톤으로 만들고, 창별 pane 집합을 받아 글로벌 순서로 평탄화한다. 이 태스크에서 `MainWindowController`는 여전히 자체 `MissionControlModel()` 인스턴스를 쓰지만 — 호출부 시그니처만 맞춘다(전면 전환은 Task 4).

> `gitnexus_impact({target: "MissionControlModel", direction: "upstream"})`로 호출부를 먼저 확인할 것.

- [ ] **Step 1: 실패하는 테스트 작성**

`apps/termy-tests/Sources/MissionControlModelTests.swift` 생성:

```swift
import XCTest
@testable import termy

@MainActor
final class MissionControlModelTests: XCTestCase {
    func test_setLivePaneIds_flattensWindowsInRegistrationOrder() {
        let model = MissionControlModel(startPump: false)
        let winA = UUID()
        let winB = UUID()
        model.setLivePaneIds(["p1", "p2"], forWindow: winA)
        model.setLivePaneIds(["p3"], forWindow: winB)
        XCTAssertEqual(model.livePaneIds, ["p1", "p2", "p3"])
        XCTAssertEqual(model.paneOrder, ["p1": 0, "p2": 1, "p3": 2])
    }

    func test_removeWindow_dropsThatWindowsPanes() {
        let model = MissionControlModel(startPump: false)
        let winA = UUID()
        let winB = UUID()
        model.setLivePaneIds(["p1", "p2"], forWindow: winA)
        model.setLivePaneIds(["p3"], forWindow: winB)
        model.removeWindow(winA)
        XCTAssertEqual(model.livePaneIds, ["p3"])
        XCTAssertEqual(model.paneOrder, ["p3": 0])
    }

    func test_setLivePaneIds_reRegisteringWindowReplacesItsPanes() {
        let model = MissionControlModel(startPump: false)
        let winA = UUID()
        model.setLivePaneIds(["p1", "p2"], forWindow: winA)
        model.setLivePaneIds(["p1"], forWindow: winA)
        XCTAssertEqual(model.livePaneIds, ["p1"])
        XCTAssertEqual(model.paneOrder, ["p1": 0])
    }
}
```

- [ ] **Step 2: 새 테스트 파일 등록 후 실패 확인**

Run: `cd /Users/ysh/proj/termy && xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -only-testing:termy-tests/MissionControlModelTests 2>&1 | tail -25`
Expected: 컴파일 실패 — `extra argument 'forWindow'` / `value of type 'MissionControlModel' has no member 'removeWindow'`.

- [ ] **Step 3: MissionControlModel 싱글톤화 + 창별 등록 구현**

`MissionControlModel.swift`에서 다음을 변경한다.

(a) `livePaneIds` / `paneOrder`를 테스트에서 읽을 수 있도록 `private` → `private(set)`로 바꾸고, 창별 상태를 추가한다. 현재:

```swift
    private var livePaneIds: Set<String> = []
```
```swift
    private var paneOrder: [String: Int] = [:]
```

다음으로 바꾼다:

```swift
    /// Union of every registered window's pane IDs. Drives chip filtering.
    private(set) var livePaneIds: Set<String> = []
```
```swift
    /// Global chip position: window-registration order, then pane order
    /// within each window. Flattened from `paneIdsByWindow` on every change.
    private(set) var paneOrder: [String: Int] = [:]

    /// Window registration order — windows appear on the bar in the order
    /// they were first registered.
    private var windowOrder: [UUID] = []

    /// Per-window ordered pane IDs, keyed by `MainWindowController.windowId`.
    private var paneIdsByWindow: [UUID: [String]] = [:]
```

(b) `init()`를 펌프 시작을 끌 수 있게 바꾸고 싱글톤을 추가한다. 현재:

```swift
    init() {
        pumpTask = Task { [weak self] in
            await self?.pumpUpdates()
        }
    }
```

다음으로 바꾼다:

```swift
    /// Single app-wide instance. Every window's `MissionControlView`
    /// observes this one model, and it is the sole consumer of
    /// `HookDaemon.shared.updates` (an AsyncStream allows only one).
    static let shared = MissionControlModel()

    /// `startPump: false` is used by unit tests so a throwaway model does
    /// not race the shared instance for `HookDaemon.updates` events.
    init(startPump: Bool = true) {
        if startPump {
            pumpTask = Task { [weak self] in
                await self?.pumpUpdates()
            }
        }
    }
```

(c) `setLivePaneIds(_:)`를 창별 버전으로 교체한다. 현재 메서드 전체:

```swift
    func setLivePaneIds(_ orderedIds: [String]) {
        livePaneIds = Set(orderedIds)
        paneOrder = Dictionary(
            uniqueKeysWithValues: orderedIds.enumerated().map { ($1, $0) }
        )
        // Drop labels for panes that no longer exist.
        labelsByPaneId = labelsByPaneId.filter { livePaneIds.contains($0.key) }
        recomputeItems()
    }
```

다음으로 교체한다:

```swift
    /// Register (or replace) one window's ordered pane list. Called by each
    /// `MainWindowController` whenever its workspace pane set changes.
    /// `windowId` is `MainWindowController.windowId`.
    func setLivePaneIds(_ orderedIds: [String], forWindow windowId: UUID) {
        if !windowOrder.contains(windowId) {
            windowOrder.append(windowId)
        }
        paneIdsByWindow[windowId] = orderedIds
        rebuildGlobalOrder()
    }

    /// Drop a window's panes from the dashboard when its window closes.
    func removeWindow(_ windowId: UUID) {
        windowOrder.removeAll { $0 == windowId }
        paneIdsByWindow.removeValue(forKey: windowId)
        rebuildGlobalOrder()
    }

    /// Flatten every window's pane list into the global `livePaneIds` /
    /// `paneOrder`, then drop stale labels and recompute the chips.
    private func rebuildGlobalOrder() {
        var flat: [String] = []
        for windowId in windowOrder {
            flat.append(contentsOf: paneIdsByWindow[windowId] ?? [])
        }
        livePaneIds = Set(flat)
        paneOrder = Dictionary(
            uniqueKeysWithValues: flat.enumerated().map { ($1, $0) }
        )
        labelsByPaneId = labelsByPaneId.filter { livePaneIds.contains($0.key) }
        recomputeItems()
    }
```

(d) `maxDashboardItems` 주석을 갱신한다. 현재 주석 끝부분:

```swift
    /// legibly even at maximum compression — older items (creation order)
    /// win, newer ones are hidden from the bar. 32 also matches the outer
    /// per-window pane limit we expect in practice.
    static let maxDashboardItems = 32
```

다음으로 바꾼다:

```swift
    /// legibly even at maximum compression — older items (creation order)
    /// win, newer ones are hidden from the bar. With multi-window this is a
    /// global cap across every window's panes combined.
    static let maxDashboardItems = 32
```

- [ ] **Step 4: MainWindowController 호출부 맞추기**

`MainWindowController.swift`에서 `private let workspace = Workspace()` 줄 바로 아래에 `windowId`를 추가한다:

```swift
    private let workspace = Workspace()
    /// Stable identity for this window — keys the shared `MissionControlModel`
    /// pane registry and the session record.
    let windowId = UUID()
```

그리고 `onPanesChanged()` 안의 다음 줄:

```swift
        missionControlModel.setLivePaneIds(orderedIds)
```

을 다음으로 바꾼다:

```swift
        missionControlModel.setLivePaneIds(orderedIds, forWindow: windowId)
```

- [ ] **Step 5: 테스트 + 빌드 통과 확인**

Run: `xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -only-testing:termy-tests/MissionControlModelTests 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **` (그리고 앱 타겟이 함께 빌드되어 `MainWindowController` 호출부 변경도 컴파일 검증됨).

- [ ] **Step 6: 커밋**

```bash
git add apps/termy/Sources/MissionControlModel.swift apps/termy/Sources/MainWindowController.swift apps/termy-tests/Sources/MissionControlModelTests.swift termy.xcodeproj
git commit -m "feat(dashboard): make MissionControlModel an app-wide multi-window model"
```

---

## Task 4: WindowManager + MainWindowController 멀티 인스턴스화

**Files:**
- Create: `apps/termy/Sources/WindowManager.swift`
- Create: `apps/termy-tests/Sources/WindowManagerTests.swift`
- Modify: `apps/termy/Sources/MainWindowController.swift`
- Modify: `apps/termy/Sources/AppDelegate.swift` (한 줄: `onSnapshotUpdate` 배선 이동)

이 태스크가 끝나면 `WindowManager`는 존재하지만 `AppDelegate`는 아직 단일 윈도우 경로를 쓴다(동작 변화 없음). `MainWindowController`는 멀티 인스턴스로 안전해진다. 세션 저장은 Task 5.

> `gitnexus_impact({target: "MainWindowController", direction: "upstream"})`로 호출부(특히 `AppDelegate`)를 확인할 것.

- [ ] **Step 1: WindowManager 순수 헬퍼 실패 테스트 작성**

`apps/termy-tests/Sources/WindowManagerTests.swift` 생성:

```swift
import XCTest
@testable import termy

@MainActor
final class WindowManagerTests: XCTestCase {
    func test_nextCascadeFrame_stepsDownAndRight() {
        let prev = CGRect(x: 100, y: 200, width: 1200, height: 760)
        let next = WindowManager.nextCascadeFrame(after: prev)
        XCTAssertEqual(next.origin.x, 128)
        XCTAssertEqual(next.origin.y, 172)
        XCTAssertEqual(next.size, prev.size)
    }

    func test_clampedFrame_keepsOnscreenFrameUnchanged() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertEqual(WindowManager.clampedFrame(frame, toVisible: [screen]), frame)
    }

    func test_clampedFrame_recentersFullyOffscreenFrame() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let offscreen = CGRect(x: 5000, y: 5000, width: 800, height: 600)
        let clamped = WindowManager.clampedFrame(offscreen, toVisible: [screen])
        XCTAssertTrue(screen.intersects(clamped))
        XCTAssertEqual(clamped.size, offscreen.size)
    }
}
```

- [ ] **Step 2: WindowManager 구현**

`apps/termy/Sources/WindowManager.swift` 생성:

```swift
// WindowManager.swift
//
// App-level owner of every MainWindowController. Creates windows (⌘N and
// session restore), routes cross-window pane focus, and — once wired in
// Task 5 — drives session save/restore. Owned by AppDelegate; exactly one
// instance exists.

import AppKit

@MainActor
final class WindowManager {
    private(set) var controllers: [MainWindowController] = []

    init() {}

    // MARK: - Window creation

    /// Open a fresh window with a single HOME pane, cascaded off the
    /// front-most existing window so it doesn't land exactly on top.
    @discardableResult
    func newWindow() -> MainWindowController {
        let frame = controllers.last?.window?.frame
            .map { WindowManager.nextCascadeFrame(after: $0) }
        let controller = MainWindowController(initialFrame: frame, sessionLayout: nil)
        register(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return controller
    }

    /// Recreate a window from a saved `WindowRecord`, clamping its frame to
    /// the currently visible screen area.
    @discardableResult
    func restoreWindow(from record: WindowRecord) -> MainWindowController {
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        let frame = WindowManager.clampedFrame(record.frame.cgRect, toVisible: visibleFrames)
        let controller = MainWindowController(initialFrame: frame, sessionLayout: record)
        register(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    private func register(_ controller: MainWindowController) {
        controller.windowManager = self
        controllers.append(controller)
    }

    /// Called from `MainWindowController.windowWillClose`.
    func removeWindow(_ controller: MainWindowController) {
        controllers.removeAll { $0 === controller }
        MissionControlModel.shared.removeWindow(controller.windowId)
    }

    // MARK: - Cross-window routing

    /// Focus the pane with `paneId` wherever it lives: bring its window to
    /// the front, activate the app, then focus the pane inside that window.
    /// No-op when no window owns the pane.
    func focusPane(byId paneId: String) {
        guard let owner = controllers.first(where: { $0.containsPane(id: paneId) }) else {
            return
        }
        owner.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        _ = owner.focusLocalPane(byId: paneId)
    }

    // MARK: - Cascade / clamp (pure helpers — unit tested)

    static let defaultWindowSize = CGSize(width: 1200, height: 760)
    static let cascadeStep: CGFloat = 28

    /// Frame for the next window: stepped down-right from `previous`.
    static func nextCascadeFrame(after previous: CGRect) -> CGRect {
        CGRect(
            x: previous.origin.x + cascadeStep,
            y: previous.origin.y - cascadeStep,
            width: previous.width,
            height: previous.height
        )
    }

    /// Clamp `frame` to the visible screen area. If it already intersects
    /// some visible screen it is returned unchanged; otherwise it is
    /// re-centered on the first visible screen (size capped to that screen).
    static func clampedFrame(_ frame: CGRect, toVisible visibleFrames: [CGRect]) -> CGRect {
        guard let primary = visibleFrames.first else { return frame }
        if visibleFrames.contains(where: { $0.intersects(frame) }) {
            return frame
        }
        let width = min(frame.width, primary.width)
        let height = min(frame.height, primary.height)
        return CGRect(
            x: primary.origin.x + (primary.width - width) / 2,
            y: primary.origin.y + (primary.height - height) / 2,
            width: width,
            height: height
        )
    }
}
```

- [ ] **Step 3: MainWindowController 멀티 인스턴스화 — 프로퍼티와 init**

`MainWindowController.swift`에서:

(a) `private let missionControlModel = MissionControlModel()` 줄을 다음으로 바꾼다 (모든 호출부는 그대로 둔 채 공유 인스턴스로 위임):

```swift
    /// Shared app-wide dashboard model — every window observes the same one.
    private var missionControlModel: MissionControlModel { .shared }
```

(b) `private var filterBar: ProjectFilterBar?` 근처(프로퍼티 영역)에 추가:

```swift
    /// Set by `WindowManager` when this controller is registered. Used to
    /// route cross-window pane focus.
    weak var windowManager: WindowManager?
```

(c) `init()`를 designated/convenience 쌍으로 바꾼다. 현재 `init()` 시그니처와 윈도우 생성/`center()` 부분:

```swift
    init() {
        let window = TermyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "termy"
        window.minSize = NSSize(width: 800, height: 480)
        window.center()
        window.titlebarAppearsTransparent = true
```

다음으로 바꾼다:

```swift
    /// Convenience for callers that want a default-placed, freshly-seeded
    /// window. `WindowManager` uses the designated init directly.
    convenience init() {
        self.init(initialFrame: nil, sessionLayout: nil)
    }

    /// - Parameters:
    ///   - initialFrame: window frame to apply; `nil` centers the window.
    ///   - sessionLayout: when present, the window replays this saved pane
    ///     layout instead of seeding a single HOME pane.
    init(initialFrame: NSRect?, sessionLayout: WindowRecord?) {
        let window = TermyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "termy"
        window.minSize = NSSize(width: 800, height: 480)
        if let initialFrame {
            window.setFrame(initialFrame, display: false)
        } else {
            window.center()
        }
        window.titlebarAppearsTransparent = true
```

(d) init 안의 `onSnapshotUpdate` 배선 블록을 삭제한다. 현재:

```swift
        // Single funnel for pane-state updates: HookDaemon → MissionControlModel
        // → Notifier. AsyncStream only supports one `for await`, so Notifier
        // receives events via this forward instead of subscribing directly.
        missionControlModel.onSnapshotUpdate = { snap in
            Notifier.shared.handle(snap)
        }

        // Seed the first pane using HOME.
        workspace.addPane()
    }
```

다음으로 바꾼다 (배선은 `AppDelegate`로 이동 — Step 6; HOME pane 시드는 세션 복원과 분기):

```swift
        // Seed the first pane, or replay a saved layout for a restored window.
        if let sessionLayout {
            applySessionLayout(sessionLayout)
        } else {
            workspace.addPane()
        }
    }
```

- [ ] **Step 4: MainWindowController — 라우팅/세션 메서드 추가**

`MainWindowController.swift`의 `focusPane(byId:)`를 교체한다. 현재:

```swift
    /// Dashboard-click routing: find the pane by id, focus it (auto-switches
    /// filter if needed).
    func focusPane(byId paneId: String) {
        _ = workspace.focusPane(byId: paneId)
    }
```

다음으로 바꾼다:

```swift
    /// Dashboard-click / banner-tap routing. Delegates to `WindowManager` so
    /// a pane in another window brings that window forward. Falls back to a
    /// local focus when this controller isn't registered (single-window).
    func focusPane(byId paneId: String) {
        if let windowManager {
            windowManager.focusPane(byId: paneId)
        } else {
            _ = workspace.focusPane(byId: paneId)
        }
    }

    /// Focus a pane known to live in *this* window's workspace. Called by
    /// `WindowManager.focusPane(byId:)` after fronting the window — never
    /// re-routes, so it can't recurse.
    @discardableResult
    func focusLocalPane(byId paneId: String) -> Bool {
        workspace.focusPane(byId: paneId)
    }

    /// True when this window's workspace owns the pane.
    func containsPane(id paneId: String) -> Bool {
        workspace.panes.contains { $0.paneId == paneId }
    }

    /// Snapshot this window's restorable state. Returns nil for a paneless
    /// window (nothing worth restoring).
    func sessionWindowRecord() -> WindowRecord? {
        guard let window, !workspace.panes.isEmpty else { return nil }
        let rows: [[PaneRecord]] = workspace.rows.map { row in
            row.map { PaneRecord(cwd: $0.currentCwd) }
        }
        if rows.flatMap({ $0 }).isEmpty { return nil }
        let filterProjectId: String?
        switch workspace.filter {
        case .all: filterProjectId = nil
        case .project(let id): filterProjectId = id
        }
        let focusedIndex = workspace.focusedPane.flatMap { focused in
            workspace.panes.firstIndex { $0 === focused }
        }
        return WindowRecord(
            frame: FrameRecord(window.frame),
            rows: rows,
            filterProjectId: filterProjectId,
            focusedPaneIndex: focusedIndex
        )
    }

    /// Rebuild this window's panes from a saved `WindowRecord`. Mirrors the
    /// row/column replay used by the ⌘K project switcher: the first pane of
    /// each saved row goes in with `.row` axis, the rest with `.column`.
    private func applySessionLayout(_ record: WindowRecord) {
        for savedRow in record.rows {
            for (colIdx, paneRec) in savedRow.enumerated() {
                let axis: SplitAxis = (colIdx == 0) ? .row : .column
                workspace.addPane(cwd: paneRec.cwd, splitAxis: axis)
            }
        }
        // Defensive: an empty saved record would leave a paneless window.
        if workspace.panes.isEmpty {
            workspace.addPane()
            return
        }
        if let projectId = record.filterProjectId {
            workspace.filter = .project(projectId)
        }
        if let idx = record.focusedPaneIndex,
           idx >= 0, idx < workspace.panes.count {
            workspace.focus(pane: workspace.panes[idx])
        }
    }
```

- [ ] **Step 5: MainWindowController — windowWillClose delegate**

`MainWindowController.swift`의 `// MARK: - Window delegate` 아래 빈 `windowDidResize`를 다음으로 바꾼다. 현재:

```swift
    // MARK: - Window delegate

    func windowDidResize(_ notification: Notification) {}
```

다음으로 바꾼다:

```swift
    // MARK: - Window delegate

    func windowDidResize(_ notification: Notification) {}

    /// Deregister from the app-wide window/dashboard registries when this
    /// window closes. `removeWindow` is idempotent, so a close triggered by
    /// the last-pane path and an explicit ⌘⇧W both land here safely.
    func windowWillClose(_ notification: Notification) {
        windowManager?.removeWindow(self)
    }
```

- [ ] **Step 6: AppDelegate — onSnapshotUpdate 배선 이동 (한 줄)**

`AppDelegate.swift`의 `applicationDidFinishLaunching`에서, `Notifier.shared.start()` 호출 바로 위에 다음을 추가한다 (Step 3에서 `MainWindowController`가 더 이상 이 배선을 하지 않으므로):

```swift
        // Single funnel for pane-state updates: HookDaemon → the shared
        // MissionControlModel → Notifier. Wired once, app-wide.
        MissionControlModel.shared.onSnapshotUpdate = { snapshot in
            Notifier.shared.handle(snapshot)
        }
```

- [ ] **Step 7: 새 파일 등록 + 빌드 + 헬퍼 테스트 통과 확인**

Run: `cd /Users/ysh/proj/termy && xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -only-testing:termy-tests/WindowManagerTests 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **` (앱 타겟 전체가 빌드되므로 `MainWindowController`/`WindowManager`/`AppDelegate` 변경이 모두 컴파일 검증됨).

- [ ] **Step 8: 단일 윈도우 동작 무회귀 확인 (라이브)**

앱을 빌드·실행한다: `xcodebuild build -project termy.xcodeproj -scheme termy -destination 'platform=macOS' 2>&1 | tail -5` 후 빌드 산출물 `.app`을 실행.
Expected: 기존과 동일 — 창 하나가 HOME pane으로 뜨고, pane 추가/split/대시보드 칩 클릭/필터가 정상. (멀티 윈도우는 아직 미배선.)

- [ ] **Step 9: 커밋**

```bash
git add apps/termy/Sources/WindowManager.swift apps/termy/Sources/MainWindowController.swift apps/termy/Sources/AppDelegate.swift apps/termy-tests/Sources/WindowManagerTests.swift termy.xcodeproj
git commit -m "feat(window): add WindowManager and make MainWindowController multi-instance safe"
```

---

## Task 5: SessionAutosaver + AppDelegate 통합

**Files:**
- Create: `apps/termy/Sources/SessionAutosaver.swift`
- Modify: `apps/termy/Sources/WindowManager.swift`
- Modify: `apps/termy/Sources/MainWindowController.swift`
- Modify: `apps/termy/Sources/AppDelegate.swift`

이 태스크가 끝나면 ⌘N 새 창, 창 간 라우팅, 전체 세션 복원이 모두 살아난다.

> `gitnexus_impact({target: "AppDelegate", direction: "upstream"})` 및 `gitnexus_impact({target: "newPane", direction: "upstream"})`로 메뉴 셀렉터 호출부를 확인할 것.

- [ ] **Step 1: SessionAutosaver 구현**

`apps/termy/Sources/SessionAutosaver.swift` 생성:

```swift
// SessionAutosaver.swift
//
// Debounced bridge between live window/pane mutations and the on-disk
// `SessionPersistence`. Mirrors `WorkspaceAutosaver`'s 500ms coalescing:
// pane added/closed, window moved/resized, and window added/closed all
// call `requestSave()`, which collapses bursts into one write.

import Foundation

@MainActor
final class SessionAutosaver {
    let persistence: SessionPersistence
    private weak var windowManager: WindowManager?
    private let debounceNanos: UInt64
    private var pendingTask: Task<Void, Never>?
    private var inFlightFlush: Task<Void, Never>?

    init(
        persistence: SessionPersistence,
        windowManager: WindowManager,
        debounceMillis: Int = 500
    ) {
        self.persistence = persistence
        self.windowManager = windowManager
        self.debounceNanos = UInt64(debounceMillis) * 1_000_000
    }

    /// Coalescing save request — call on any session-relevant mutation.
    func requestSave() {
        pendingTask?.cancel()
        let nanos = debounceNanos
        pendingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await self?.performSave()
        }
    }

    /// Synchronous flush for shutdown. Joins an in-flight flush instead of
    /// starting a redundant second write.
    func flushSync() async {
        if let inFlight = inFlightFlush {
            await inFlight.value
            return
        }
        pendingTask?.cancel()
        pendingTask = nil
        let task = Task { @MainActor in await self.performSave() }
        inFlightFlush = task
        await task.value
        inFlightFlush = nil
    }

    private func performSave() async {
        guard let windowManager else { return }
        let records = windowManager.controllers.compactMap { $0.sessionWindowRecord() }
        let session = SessionRecord(windows: records)
        try? await persistence.save(session)
    }
}
```

- [ ] **Step 2: WindowManager — 세션 영속화 배선**

`WindowManager.swift`에서:

(a) 프로퍼티와 `init`을 바꾼다. 현재:

```swift
    private(set) var controllers: [MainWindowController] = []

    init() {}
```

다음으로 바꾼다:

```swift
    private(set) var controllers: [MainWindowController] = []
    private let sessionPersistence: SessionPersistence?
    private(set) var sessionAutosaver: SessionAutosaver?

    init() {
        // Persistence init can fail if app-support is unwritable — session
        // restore/save then silently degrades to no-op (best-effort feature).
        self.sessionPersistence = try? SessionPersistence()
        self.sessionAutosaver = nil
        if let sessionPersistence {
            self.sessionAutosaver = SessionAutosaver(
                persistence: sessionPersistence,
                windowManager: self
            )
        }
    }

    /// Restore saved windows. Returns true if at least one window opened.
    func restoreSessionWindows() async -> Bool {
        guard let sessionPersistence else { return false }
        guard case .loaded(let record) = await sessionPersistence.load(),
              !record.windows.isEmpty else {
            return false
        }
        for windowRecord in record.windows {
            restoreWindow(from: windowRecord)
        }
        return true
    }
```

(b) `newWindow()` 끝에 세션 저장 요청을 추가한다. 현재 끝부분:

```swift
        NSApp.activate(ignoringOtherApps: true)
        return controller
    }
```

다음으로 바꾼다:

```swift
        NSApp.activate(ignoringOtherApps: true)
        sessionAutosaver?.requestSave()
        return controller
    }
```

(c) `removeWindow(_:)`에 세션 저장 + Notifier prune을 추가한다. 현재:

```swift
    func removeWindow(_ controller: MainWindowController) {
        controllers.removeAll { $0 === controller }
        MissionControlModel.shared.removeWindow(controller.windowId)
    }
```

다음으로 바꾼다:

```swift
    func removeWindow(_ controller: MainWindowController) {
        controllers.removeAll { $0 === controller }
        MissionControlModel.shared.removeWindow(controller.windowId)
        // The closed window's panes are gone — drop any WAITING entries for
        // panes that no longer exist anywhere.
        Notifier.shared.pruneWaitingPanes(livePaneIds: MissionControlModel.shared.livePaneIds)
        sessionAutosaver?.requestSave()
    }
```

- [ ] **Step 3: MainWindowController — 창 이동/리사이즈/pane 변경 시 세션 저장**

`MainWindowController.swift`에서:

(a) `workspace.onPanesChanged` 클로저에 세션 저장을 추가한다. 현재:

```swift
        workspace.onPanesChanged = { [weak self] in
            self?.onPanesChanged()
            self?.autosaver?.requestSave()
        }
```

다음으로 바꾼다:

```swift
        workspace.onPanesChanged = { [weak self] in
            self?.onPanesChanged()
            self?.autosaver?.requestSave()
            self?.windowManager?.sessionAutosaver?.requestSave()
        }
```

(b) `workspace.onPaneHeaderChanged` 클로저에도 추가한다. 현재:

```swift
        workspace.onPaneHeaderChanged = { [weak self] paneId, project, branch in
            self?.missionControlModel.setLabel(paneId: paneId, project: project, branch: branch)
            // `cd` drifted the pane's cwd — persist the new location.
            self?.autosaver?.requestSave()
        }
```

다음으로 바꾼다:

```swift
        workspace.onPaneHeaderChanged = { [weak self] paneId, project, branch in
            self?.missionControlModel.setLabel(paneId: paneId, project: project, branch: branch)
            // `cd` drifted the pane's cwd — persist the new location.
            self?.autosaver?.requestSave()
            self?.windowManager?.sessionAutosaver?.requestSave()
        }
```

(c) 창 이동/리사이즈 delegate를 세션 저장에 연결한다. 현재:

```swift
    func windowDidResize(_ notification: Notification) {}
```

다음으로 바꾼다:

```swift
    func windowDidResize(_ notification: Notification) {
        windowManager?.sessionAutosaver?.requestSave()
    }

    func windowDidMove(_ notification: Notification) {
        windowManager?.sessionAutosaver?.requestSave()
    }
```

- [ ] **Step 4: AppDelegate — WindowManager 소유로 전환**

`AppDelegate.swift`에서 `private var mainWindowController: MainWindowController?` 줄을 다음으로 바꾼다:

```swift
    private let windowManager = WindowManager()
```

- [ ] **Step 5: AppDelegate — 실행 시 세션 복원**

`applicationDidFinishLaunching`에서 단일 윈도우 생성 블록을 교체한다. 현재:

```swift
        let controller = MainWindowController()
        mainWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.center()
        NSApp.activate(ignoringOtherApps: true)

        // WAITING notifications — route banner taps back through the window
        // controller so the clicked pane becomes focused.
        Notifier.shared.onFocusPane = { [weak controller] paneId in
            controller?.focusPane(byId: paneId)
        }
        Notifier.shared.start()
```

다음으로 바꾼다:

```swift
        // WAITING notifications — route banner taps through WindowManager so
        // the clicked pane's window comes forward and the pane is focused.
        Notifier.shared.onFocusPane = { [weak self] paneId in
            self?.windowManager.focusPane(byId: paneId)
        }
        MissionControlModel.shared.onSnapshotUpdate = { snapshot in
            Notifier.shared.handle(snapshot)
        }
        Notifier.shared.start()

        // Restore the saved multi-window session, or open one fresh window
        // when there is nothing to restore.
        Task { @MainActor in
            let restored = await self.windowManager.restoreSessionWindows()
            if !restored {
                self.windowManager.newWindow()
            }
        }
```

(Step 4 이전에 Task 4 Step 6에서 추가했던 `MissionControlModel.shared.onSnapshotUpdate` 줄이 이미 있다면, 위 교체가 그 줄을 포함하므로 기존 한 줄은 삭제해 중복을 없앤다.)

- [ ] **Step 6: AppDelegate — activeController / cycleAppearance fallback**

`activeController` 계산 프로퍼티의 fallback을 바꾼다. 현재:

```swift
    private var activeController: MainWindowController? {
        if let winCtrl = NSApp.keyWindow?.windowController as? MainWindowController {
            return winCtrl
        }
        return mainWindowController
    }
```

다음으로 바꾼다:

```swift
    private var activeController: MainWindowController? {
        if let winCtrl = NSApp.keyWindow?.windowController as? MainWindowController {
            return winCtrl
        }
        return windowManager.controllers.first
    }
```

그리고 `cycleAppearance(_:)`의 `mainWindowController?.window` 참조를 바꾼다. 현재:

```swift
        AppearanceBanner.shared.show(next, over: NSApp.keyWindow ?? mainWindowController?.window)
```

다음으로 바꾼다:

```swift
        AppearanceBanner.shared.show(
            next,
            over: NSApp.keyWindow ?? windowManager.controllers.first?.window
        )
```

- [ ] **Step 7: AppDelegate — newWindow 액션 + File 메뉴 ⌘N/⌘T 재배선**

`@IBAction func newPane(_ sender: Any?)` 바로 위에 새 액션을 추가한다:

```swift
    @IBAction func newWindow(_ sender: Any?) {
        windowManager.newWindow()
    }

```

그리고 `makeFileMenu()`의 "New Pane" 항목을 "New Window"(⌘N) + "New Pane"(⌘T)로 바꾼다. 현재:

```swift
        let newPane = menu.addItem(
            withTitle: "New Pane",
            action: #selector(AppDelegate.newPane(_:)),
            keyEquivalent: "n"
        )
        newPane.target = self
        newPane.keyEquivalentModifierMask = [.command]
```

다음으로 바꾼다:

```swift
        let newWindow = menu.addItem(
            withTitle: "New Window",
            action: #selector(AppDelegate.newWindow(_:)),
            keyEquivalent: "n"
        )
        newWindow.target = self
        newWindow.keyEquivalentModifierMask = [.command]

        let newPane = menu.addItem(
            withTitle: "New Pane",
            action: #selector(AppDelegate.newPane(_:)),
            keyEquivalent: "t"
        )
        newPane.target = self
        newPane.keyEquivalentModifierMask = [.command]
```

- [ ] **Step 8: AppDelegate — 종료 시 전 창 + 세션 flush**

`applicationWillTerminate(_:)`를 교체한다. 현재:

```swift
    func applicationWillTerminate(_ notification: Notification) {
        // Flush pending workspace autosave, then stop the hook daemon. Both
        // are async; block briefly so the process doesn't exit mid-write.
        // 0.5s cap — `MainWindowController` pre-emptively kicks `flushSync`
        // when the last pane closes, so by the time we get here the disk
        // write is usually already in flight or done. Atomic temp-rename
        // means a lost flush at worst regresses layout by one debounce
        // interval, not a corrupt file. The 2s budget that used to live
        // here visibly stalled the window-close finalization.
        let sem = DispatchSemaphore(value: 0)
        let autosaver = mainWindowController?.autosaver
        Task { @MainActor in
            if let autosaver {
                await autosaver.flushSync()
            }
            await HookDaemon.shared.stop()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 0.5)
    }
```

다음으로 바꾼다:

```swift
    func applicationWillTerminate(_ notification: Notification) {
        // Flush every window's workspace autosave plus the session autosave,
        // then stop the hook daemon. All async; block briefly so the process
        // doesn't exit mid-write. 0.5s cap — per-project saves are debounced
        // and usually already on disk, and atomic temp-rename means a lost
        // flush at worst regresses layout by one debounce interval.
        let sem = DispatchSemaphore(value: 0)
        let controllers = windowManager.controllers
        let sessionAutosaver = windowManager.sessionAutosaver
        Task { @MainActor in
            for controller in controllers {
                await controller.autosaver?.flushSync()
            }
            await sessionAutosaver?.flushSync()
            await HookDaemon.shared.stop()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 0.5)
    }
```

- [ ] **Step 9: 새 파일 등록 + 빌드 + 전체 테스트 통과 확인**

Run: `cd /Users/ysh/proj/termy && xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **` — 신규 4개 테스트 클래스 + 기존 `TermyTerminalViewTests` 모두 통과.

- [ ] **Step 10: 커밋**

```bash
git add apps/termy/Sources/SessionAutosaver.swift apps/termy/Sources/WindowManager.swift apps/termy/Sources/MainWindowController.swift apps/termy/Sources/AppDelegate.swift termy.xcodeproj
git commit -m "feat(window): wire multi-window — new window, cross-window routing, session restore"
```

---

## Task 6: 라이브 검증

**Files:** 없음 (수동 검증). 회귀 발견 시 해당 태스크로 돌아가 수정.

> 메모리 노트: termy의 윈도우/포커스/IME 배선은 유닛 테스트만으로 증명되지 않는다 — 반드시 실제 실행으로 확인한다.

- [ ] **Step 1: 빌드 후 앱 실행**

Run: `cd /Users/ysh/proj/termy && xcodebuild build -project termy.xcodeproj -scheme termy -destination 'platform=macOS' 2>&1 | tail -5`
빌드 산출물 경로를 확인하고(`xcodebuild -showBuildSettings ... | grep BUILT_PRODUCTS_DIR`) `termy.app`을 실행한다.

- [ ] **Step 2: 새 창 (⌘N)**

⌘N을 눌러 새 창이 직전 창에서 28pt cascade된 위치에 뜨는지, HOME pane 하나로 시작하는지 확인. ⌘T로 현재 창에 pane이 추가되는지 확인. ⌘D / ⌘⇧D split이 정상인지 확인.

- [ ] **Step 3: 전역 집계 대시보드**

두 창 각각에서 pane을 만들고, **양쪽 창의 하단 대시보드가 모든 창의 pane 칩을 동일하게** 보여주는지 확인. 창 A의 대시보드에서 창 B 소속 pane 칩을 클릭 → 창 B가 앞으로 나오고 해당 pane이 포커스되는지 확인.

- [ ] **Step 4: WAITING 알림 라우팅**

한 창의 에이전트를 WAITING 상태로 만들고(에이전트가 입력 대기), 알림 배너를 탭 → 다른 창에 있어도 그 창이 앞으로 나오고 정확한 pane이 포커스되는지 확인.

- [ ] **Step 5: 전체 세션 복원**

창 2개를 서로 다른 위치/크기로 두고 각각 pane 여러 개를 만든 뒤 ⌘Q로 종료. 앱을 다시 실행 → 창 2개가 frame·pane 레이아웃·필터까지 복원되는지 확인. 모든 창을 닫고 종료 후 재실행 → 빈 세션이므로 HOME pane 창 하나로 시작하는지 확인.

- [ ] **Step 6: 창 닫기 동작**

여러 창 중 한 창을 ⌘⇧W로 닫아도 앱이 종료되지 않고, 마지막 창을 닫으면 앱이 종료되는지 확인. 한 창의 마지막 pane을 ⌘W로 닫으면 그 창만 닫히는지 확인.

- [ ] **Step 7: 회귀 점검 + 커밋 전 검사**

기존 단일 창 기능(필터 ⌘1–9, 폰트 ⌘+/⌘−, 외관 ⌘⇧T, 프로젝트 스위처 ⌘K)이 모든 창에서 정상인지 확인. `gitnexus_detect_changes()`로 변경 범위가 예상과 일치하는지 확인. 발견된 회귀는 원인 태스크에서 수정 후 재검증한다.

---

## 자체 점검 결과

**1. Spec 커버리지:**
- §5.1 WindowManager → Task 4, 5. §5.2 MissionControlModel 싱글톤 → Task 3. §5.3 MainWindowController 멀티 인스턴스 → Task 3(windowId), 4. §5.4 세션 영속화 → Task 1, 2, 5. §6 창 간 라우팅 → Task 4(focusPane), 5(Notifier 배선). §7 단축키/메뉴 → Task 5 Step 7. §8 종료 처리 → Task 5 Step 8. §9 엣지 케이스 → Task 2(quarantine), 4(focusPane 소유자 없음 no-op), 5(removeWindow Notifier prune). §10 테스트 → Task 1–4 유닛 + Task 6 라이브. 누락 없음.
- 종료 시 flush: 설계 문서는 "동시(병렬)"라 했으나 계획은 순차 flush를 채택했다 — 각 flush는 디바운스로 보통 이미 디스크에 있고 빠른 쓰기이며, 순차가 Swift 6 동시성 측면에서 더 견고하다. 0.5s 예산 내. 의도된 단순화.

**2. Placeholder 스캔:** "TBD"/"TODO"/"적절히 처리" 없음. 모든 코드 스텝에 완전한 코드 포함.

**3. 타입 일관성:** `SessionRecord`/`WindowRecord`/`FrameRecord`/`PaneRecord`(기존 재사용), `SessionLoadOutcome`(.loaded/.missing/.quarantined), `setLivePaneIds(_:forWindow:)`/`removeWindow(_:)`, `MissionControlModel.shared`/`init(startPump:)`/`livePaneIds`/`paneOrder`, `WindowManager.newWindow()`/`restoreWindow(from:)`/`removeWindow(_:)`/`focusPane(byId:)`/`nextCascadeFrame(after:)`/`clampedFrame(_:toVisible:)`/`controllers`/`sessionAutosaver`/`restoreSessionWindows()`, `MainWindowController.windowId`/`windowManager`/`focusLocalPane(byId:)`/`containsPane(id:)`/`sessionWindowRecord()`/`init(initialFrame:sessionLayout:)`, `SessionAutosaver.requestSave()`/`flushSync()`/`persistence` — 태스크 간 시그니처 일치 확인 완료.
