# pane 끌어 옮기기 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** pane header를 끌어 같은 창 안의 다른 자리로 옮기고, 놓기 전에 그림자 상자로 놓일 위치·크기를 보여 준다. 이를 위해 배치 모델을 열 목록(`rows`)에서 프로젝트별 자유 분할 tree로 바꾼다.

**Architecture:** tree 값 타입(`PaneLayoutNode`)과 그 연산·영역 판정·미리보기 frame 계산(`PaneDropPlanner`)·떠난 자리 기억(`ProjectPaneLayout`)·자동 배치(`PanePlacement`)는 AppKit과 떨어진 순수 코드로 만들어 단위 테스트한다. `Workspace`는 `projectId → ProjectPaneLayout`을 배치의 유일한 출처로 삼아 중첩 NSSplitView를 그리고, 비율(weight)대로 divider를 놓는다. 끌기는 header mouseDown에서 `window.trackEvents`로 추적하고, 끄는 동안에는 overlay 뷰만 그린다.

**Tech Stack:** Swift 6, AppKit(NSSplitView, CALayer), XCTest, Codable(JSON).

**Spec:** `docs/superpowers/specs/2026-11-12-pane-drag-rearrange-design.md` (동작 기준 프로토타입: `docs/superpowers/specs/2026-11-12-pane-drag-rearrange-prototype.html` — 영역 판정·크기 계산의 기준 구현이 그 안의 JS `hitTest`·`applyDrop`·`layout`·`shape`다.)

## Global Constraints

- 작업 브랜치: `feat/pane-drag-rearrange` (main에서 분기). 커밋 메시지는 한국어, `Co-Authored-By` 줄 없음.
- Swift 6 동시성: `Workspace`·`Pane`·뷰는 `@MainActor`. 새 순수 타입은 값 타입이고 `Leaf: Sendable`이면 `Sendable`.
- 좌표: 순수 코드(`frames`, `PaneDropPlanner`)는 **y가 아래로 커지는** 좌표(원점 = Workspace 왼쪽 위)를 쓴다. Workspace(비-flipped)에서 넘길 때 `y' = bounds.height - y`.
- 배치 상수(스펙·프로토타입 값 그대로): divider 두께(틈) `8`, Workspace 바깥 여백 `4`, 바깥 테두리 영역 `16`, 사이 틈 영역 중심선 ±`14`, 가운데 영역 = 사방에서 `0.3`씩 들어간 사각형, 끌기 시작 거리 `4`pt.
- 영역 판정 순서: ① 바깥 테두리 → ② 사이 틈(중심선에 더 가까운 것, 같으면 더 깊은 split) → ③ 가운데(자리 바꾸기, 항상 켜짐) → ④ 대각선 네 삼각형(그 pane만 나누기).
- 크기 규칙: 가장자리 = 대상 몫을 반씩 / 사이 틈 = 1/(n+1), 나머지 × n/(n+1) / 바깥 테두리 = root가 같은 방향이면 1/(n+1) 끼우기, 아니면 root와 0.5·0.5로 감싸기 / 빼기 = 형제가 비율대로 나눠 가짐, 자식 하나 남은 split은 없앰, 같은 방향 중첩은 펼침. 결과는 "자리에 먼저 넣고 원래 자리에서 뺀다".
- 제자리: 결과의 구조(비율 제외)가 같으면 미리보기 없음·놓아도 아무것도 안 바뀜. 자리 바꾸기는 자기 자신이 아니면 항상 유효.
- 미리보기: 그림자 상자 하나(강조색 `NSColor.controlAccentColor` 테두리 2pt + 같은 색 alpha 0.16 채움 + 그림자, 모서리 10 — `Pane`의 `layer.cornerRadius`와 같다). 원래 pane `alphaValue = 0.35`. 커서 closed hand. 터미널 내용은 그리지 않는다.
- **끄는 동안 relayout 금지**(PTY SIGWINCH 없음). tree는 놓는 순간 한 번만 바뀐다.
- 사용자에게 보이는 문자열은 영어(앱 관례): 메뉴 ⌘D `Split Right`, ⌘⇧D `Split Down`; 단축키 패널 ⌘D `Split pane right`, ⌘⇧D `Split pane down`.
- 저장 형식: 스키마 버전을 올리지 않고 optional 필드만 더한다. `rows`는 계속 쓰고, **`rows`를 펼친 순서 == tree 잎 읽는 순서**를 지킨다(`focusedPaneIndex`가 이 순서의 index).
- 테스트 실행: `cd /Users/ysh/proj/termy && xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation -only-testing:termy-tests/<Class> 2>&1 | tail -25`
- Workspace 통합 테스트는 `WorkspaceParkingTests`의 패턴을 따른다: 닫지 않는 static `NSWindow`(테스트 호스트는 마지막 창이 닫히면 끝난다), `settle()`, 임시 project 폴더.

## Review Focus

- **끄는 도중 pane이 닫히거나(셸 종료) 새 pane이 생김**: 예전 계획(plan)을 그대로 적용하면 없는 pane을 가리키거나 다른 pane을 덮는다. 세대(generation)가 바뀐 plan은 버려야 한다 → 태스크 7 `test_staleGeneration_dropIsIgnored`.
- **복원된 pane의 실제 project가 저장된 것과 다름**(폴더가 지워져 홈으로 열림, agent resume이 cwd를 바꿈): 그래도 모든 pane이 정확히 한 layout에 들어 있어 자기 project 뷰에서 보여야 한다 → 태스크 4 `test_applyRestoredLayout_paneInAnotherProject_staysPlaced`.
- **새 빌드가 쓴 session.json을 예전 빌드가 읽음**(Debug·release 공유): `rows`가 있고 그 펼친 순서가 layouts 잎 순서와 같아야 예전 빌드가 pane과 포커스를 잃지 않는다 → 태스크 6 `test_windowRecord_rowsFlattenInLayoutReadingOrder`.
- **git 밖에서 `cd`를 거듭하거나, 떠나 있는 동안 pane을 닫음**: 남은 "떠남" 잎이 다른 pane 자리를 차지하거나, 떠남 잎만 남은 project가 빈 화면을 만들면 안 된다 → 태스크 3 `test_forgetAway_removesOnlyThatLeaf`, 태스크 4 `test_paneClosedWhileAway_leavesNoGhostSlot`.
- **pane이 아주 작음**(창이 작거나 pane이 많음): 사이 틈 영역(±14)이 pane보다 넓어져 영역이 겹친다. 판정이 죽거나 음수 frame을 내면 안 된다 → 태스크 2 `test_tinyPanes_planIsSane`.

---

### Task 1: 분할 tree 값 타입과 연산

**Files:**
- Create: `apps/termy/Sources/PaneLayoutTree.swift`
- Create: `apps/termy-tests/Sources/PaneLayoutTestSupport.swift` (테스트 공용 helper)
- Test: `apps/termy-tests/Sources/PaneLayoutTreeTests.swift`

**Interfaces:**
- Produces (모두 `PaneLayoutTree.swift`):
  - `enum PaneLayoutAxis: String, Codable, Sendable { case leftToRight, topToBottom }` — leftToRight = 좌우로 늘어놓음(NSSplitView `isVertical = true`), topToBottom = 위아래로 쌓음.
  - `enum PaneEdge: String, Sendable { case left, right, top, bottom }` + `var axis: PaneLayoutAxis`(left/right → leftToRight), `var isLeading: Bool`(left/top).
  - `indirect enum PaneLayoutNode<Leaf> { case leaf(Leaf); case split(PaneLayoutAxis, [PaneLayoutBranch<Leaf>]) }`
  - `struct PaneLayoutBranch<Leaf> { var node: PaneLayoutNode<Leaf>; var weight: Double }`
  - 둘 다 `Equatable where Leaf: Equatable`, `Sendable where Leaf: Sendable`, `Codable where Leaf: Codable`.
  - `enum PaneLayoutMove<Leaf> { case besideLeaf(Leaf, PaneEdge); case intoSplit(path: [Int], before: Int); case outerEdge(PaneEdge); case swap(with: Leaf) }` (`Equatable where Leaf: Equatable`).
  - `extension PaneLayoutNode`:
    - `var leaves: [Leaf]` — 읽는 순서(깊이 우선, 자식 순서대로).
    - `func map<T>(_ transform: (Leaf) throws -> T) rethrows -> PaneLayoutNode<T>` — transform을 읽는 순서대로 부른다(복원이 이 순서로 pane을 만든다).
    - `func removing(where shouldRemove: (Leaf) -> Bool) -> PaneLayoutNode?` — 남는 잎이 없으면 nil. 결과는 정규화돼 있다.
    - `func normalized() -> PaneLayoutNode` — 자식 하나인 split은 그 자식으로, 같은 방향 자식 split은 펼침(비율 곱), 비율 합 1.
    - `func settingWeights(_ weights: [Double], atSplitPath path: [Int]) -> PaneLayoutNode` — path는 root부터 자식 index. 합 1로 맞춘다.
    - `static func fromColumns(_ columns: [[Leaf]]) -> PaneLayoutNode?` — 빈 열은 버리고 균등 비율. 열 하나면 그 열(잎 하나면 잎).
    - `func approximateColumns() -> [[Leaf]]` — root가 leftToRight split이면 자식마다 한 열(그 자식의 `leaves`), 아니면 `[leaves]`. 펼치면 언제나 `leaves`와 같다.
  - `extension PaneLayoutNode where Leaf: Equatable`:
    - `func contains(_ leaf: Leaf) -> Bool`
    - `func splitting(_ target: Leaf, edge: PaneEdge, with new: Leaf) -> PaneLayoutNode`
    - `func inserting(_ new: Leaf, intoSplitAt path: [Int], before index: Int) -> PaneLayoutNode`
    - `func inserting(_ new: Leaf, atOuterEdge edge: PaneEdge) -> PaneLayoutNode`
    - `func swapping(_ a: Leaf, _ b: Leaf) -> PaneLayoutNode`
    - `func moving(_ source: Leaf, to move: PaneLayoutMove<Leaf>) -> PaneLayoutNode` — swap은 `swapping`, 나머지는 자리에 자리표시를 먼저 넣고 `source`를 뺀 뒤 자리표시를 `source`로 바꾼다(내부에서 `enum Slot { case existing(Leaf), placeholder }`로 map). `source`가 유일한 잎이면 그대로 돌려준다.
    - `func hasSameStructure(as other: PaneLayoutNode) -> Bool` — 비율 무시.
- JSON 모양: 잎 `{"pane": <Leaf>}`, split `{"axis": "leftToRight", "children": [{"weight": 0.5, "node": {...}}, …]}`.

- [ ] **Step 1: 테스트 helper를 만든다**

`apps/termy-tests/Sources/PaneLayoutTestSupport.swift`:

```swift
@testable import termy

/// 프로토타입 출력과 같은 모양: row(A:0.333,col(B:0.500,C:0.500):0.333,D:0.333)
func layoutSignature(_ node: PaneLayoutNode<String>) -> String {
    switch node {
    case .leaf(let id): return id
    case .split(let axis, let branches):
        let name = axis == .leftToRight ? "row" : "col"
        let inner = branches.map { "\(layoutSignature($0.node)):\(String(format: "%.3f", $0.weight))" }
        return "\(name)(\(inner.joined(separator: ",")))"
    }
}

/// 스펙 5.4의 기본 배치 `A | B/C | D` (열 셋 각 1/3).
func abcdLayout() -> PaneLayoutNode<String> {
    PaneLayoutNode.fromColumns([["A"], ["B", "C"], ["D"]])!
}
```

- [ ] **Step 2: 실패하는 테스트를 쓴다**

`apps/termy-tests/Sources/PaneLayoutTreeTests.swift` — 아래 기대값은 프로토타입을 node로 돌려 얻은 값이다.

```swift
import XCTest
@testable import termy

final class PaneLayoutTreeTests: XCTestCase {
    func test_fromColumns_buildsRowOfColumns() {
        XCTAssertEqual(layoutSignature(abcdLayout()), "row(A:0.333,col(B:0.500,C:0.500):0.333,D:0.333)")
        XCTAssertEqual(PaneLayoutNode.fromColumns([["A"]]), .leaf("A"))
        XCTAssertEqual(PaneLayoutNode.fromColumns([[], ["A", "B"]]).map(layoutSignature), "col(A:0.500,B:0.500)")
        XCTAssertNil(PaneLayoutNode<String>.fromColumns([]))
    }

    func test_leaves_and_approximateColumns_shareReadingOrder() {
        let tree = abcdLayout().splitting("C", edge: .right, with: "E")   // row(A, col(B, row(C,E)), D)
        XCTAssertEqual(tree.leaves, ["A", "B", "C", "E", "D"])
        XCTAssertEqual(tree.approximateColumns(), [["A"], ["B", "C", "E"], ["D"]])
        XCTAssertEqual(PaneLayoutNode.fromColumns([["A", "B"]])!.approximateColumns(), [["A", "B"]])
        XCTAssertEqual(PaneLayoutNode.leaf("A").approximateColumns(), [["A"]])
    }

    func test_removing_redistributesProportionallyAndCollapses() {
        let tree = PaneLayoutNode<String>.split(.leftToRight, [
            .init(node: .leaf("A"), weight: 0.5),
            .init(node: .split(.topToBottom, [
                .init(node: .leaf("B"), weight: 0.5),
                .init(node: .split(.leftToRight, [.init(node: .leaf("C"), weight: 0.5), .init(node: .leaf("D"), weight: 0.5)]), weight: 0.5),
            ]), weight: 0.5),
        ])
        XCTAssertEqual(tree.removing { $0 == "B" }.map(layoutSignature), "row(A:0.500,C:0.250,D:0.250)")
        XCTAssertEqual(tree.removing { $0 == "A" }.map(layoutSignature), "col(B:0.500,row(C:0.500,D:0.500):0.500)")
        XCTAssertNil(PaneLayoutNode.leaf("A").removing { $0 == "A" })
    }

    func test_moving_matchesPrototype() {
        let t = abcdLayout()
        XCTAssertEqual(layoutSignature(t.moving("C", to: .besideLeaf("B", .right))), "row(A:0.333,B:0.167,C:0.167,D:0.333)")
        XCTAssertEqual(layoutSignature(t.moving("D", to: .besideLeaf("A", .bottom))), "row(col(A:0.500,D:0.500):0.500,col(B:0.500,C:0.500):0.500)")
        XCTAssertEqual(layoutSignature(t.moving("A", to: .intoSplit(path: [1], before: 1))), "row(col(B:0.333,A:0.333,C:0.333):0.500,D:0.500)")
        XCTAssertEqual(layoutSignature(t.moving("B", to: .intoSplit(path: [], before: 1))), "row(A:0.250,B:0.250,C:0.250,D:0.250)")
        XCTAssertEqual(layoutSignature(t.moving("A", to: .outerEdge(.bottom))), "col(row(col(B:0.500,C:0.500):0.500,D:0.500):0.500,A:0.500)")
        XCTAssertEqual(layoutSignature(t.moving("A", to: .swap(with: "D"))), "row(D:0.333,col(B:0.500,C:0.500):0.333,A:0.333)")
    }

    func test_hasSameStructure_ignoresWeights() {
        let t = abcdLayout()
        XCTAssertTrue(t.moving("C", to: .besideLeaf("B", .bottom)).hasSameStructure(as: t))
        XCTAssertTrue(t.settingWeights([0.6, 0.2, 0.2], atSplitPath: []).hasSameStructure(as: t))
        XCTAssertFalse(t.moving("C", to: .besideLeaf("B", .right)).hasSameStructure(as: t))
    }

    func test_settingWeights_normalizesAtPath() {
        let t = abcdLayout().settingWeights([7, 3], atSplitPath: [1])
        XCTAssertEqual(layoutSignature(t), "row(A:0.333,col(B:0.700,C:0.300):0.333,D:0.333)")
    }

    func test_codable_roundTripsAndUsesDocumentedKeys() throws {
        let t = abcdLayout()
        let data = try JSONEncoder().encode(t)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"axis\":\"leftToRight\""))
        XCTAssertTrue(json.contains("\"pane\":\"A\""))
        XCTAssertTrue(json.contains("\"weight\""))
        XCTAssertEqual(try JSONDecoder().decode(PaneLayoutNode<String>.self, from: data), t)
    }
}
```

- [ ] **Step 3: 실패를 확인한다**

Run: 테스트 명령, `<Class>` = `PaneLayoutTreeTests`
Expected: 컴파일 실패(`PaneLayoutNode` 없음)

- [ ] **Step 4: `PaneLayoutTree.swift`를 구현한다**

위 Interfaces 그대로. `Codable`은 수동 구현(CodingKeys `pane`, `axis`, `children`; branch는 `weight`, `node`). `Equatable`의 Double 비교는 그대로 `==`(테스트는 signature 문자열로 비교한다).

- [ ] **Step 5: 통과를 확인한다**

Run: 같은 명령 → Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add apps/termy/Sources/PaneLayoutTree.swift apps/termy-tests/Sources/PaneLayoutTestSupport.swift apps/termy-tests/Sources/PaneLayoutTreeTests.swift
git commit -m "feat(layout): pane 배치용 분할 tree 값 타입과 연산을 더한다"
```

---

### Task 2: frame 계산과 놓는 자리 판정

**Files:**
- Create: `apps/termy/Sources/PaneDropPlanner.swift`
- Test: `apps/termy-tests/Sources/PaneDropPlannerTests.swift`

**Interfaces:**
- Consumes: Task 1의 `PaneLayoutNode`, `PaneLayoutMove`, `moving`, `hasSameStructure`.
- Produces:
  - `struct PaneLayoutSplitFrame: Equatable { var path: [Int]; var axis: PaneLayoutAxis; var frame: CGRect; var childFrames: [CGRect]; var depth: Int }`
  - `struct PaneLayoutFrames<Leaf> { var leaves: [(leaf: Leaf, frame: CGRect)]; var splits: [PaneLayoutSplitFrame] }` + `func frame(of leaf: Leaf) -> CGRect? where Leaf: Equatable`
  - `extension PaneLayoutNode { func frames(in rect: CGRect, gap: CGFloat) -> PaneLayoutFrames<Leaf> }` — split 안에서 `total = (leftToRight ? w : h) - gap*(n-1)`, 자식 크기 `total*weight`, 앞에서부터 차례로 + gap. NSSplitView에 `setPosition`으로 놓는 위치와 같은 식이다.
  - `enum PaneDropPlanner` — `static let gap: CGFloat = 8, inset: CGFloat = 4, outerZone: CGFloat = 16, gapZone: CGFloat = 14, centerInset: CGFloat = 0.3`
    - `static func contentRect(for bounds: CGSize) -> CGRect` — `(4, 4, w-8, h-8)`.
    - `static func move(at point: CGPoint, bounds: CGSize, layout: PaneLayoutNode<String>) -> PaneLayoutMove<String>?` — bounds 밖이면 nil. 판정 순서는 Global Constraints.
    - `static func plan(moving source: String, to point: CGPoint, bounds: CGSize, layout: PaneLayoutNode<String>) -> PaneDropPlan?` — nil = 밖이거나 제자리.
  - `struct PaneDropPlan: Equatable { var move: PaneLayoutMove<String>; var result: PaneLayoutNode<String>; var previewFrame: CGRect }` — `previewFrame` = `result.frames(in: contentRect, gap: 8)`에서 `source`의 frame.

기준 좌표(테스트 공통): bounds `1000×600` → content `(4,4,992,592)`. `abcdLayout()`에서 열 너비 `(992-16)/3 = 325.333`. A `(4,4,325.333,592)`, B `(337.333,4,325.333,292)`, C `(337.333,304,325.333,292)`, D `(670.667,4,325.333,592)`. A↔열 틈 중심선 x = `333.333`, B↔C 틈 중심선 y = `300`.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

```swift
import XCTest
@testable import termy

final class PaneDropPlannerTests: XCTestCase {
    private let bounds = CGSize(width: 1000, height: 600)
    private func move(_ x: CGFloat, _ y: CGFloat) -> PaneLayoutMove<String>? {
        PaneDropPlanner.move(at: CGPoint(x: x, y: y), bounds: bounds, layout: abcdLayout())
    }
    private func assertRect(_ r: CGRect?, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        guard let r else { return XCTFail("nil frame", file: file, line: line) }
        for (a, b) in [(r.minX, x), (r.minY, y), (r.width, w), (r.height, h)] { XCTAssertEqual(a, b, accuracy: 0.01, file: file, line: line) }
    }

    func test_frames_matchSplitViewGeometry() {
        let f = abcdLayout().frames(in: PaneDropPlanner.contentRect(for: bounds), gap: 8)
        assertRect(f.frame(of: "A"), 4, 4, 325.333, 592)
        assertRect(f.frame(of: "B"), 337.333, 4, 325.333, 292)
        assertRect(f.frame(of: "C"), 337.333, 304, 325.333, 292)
        assertRect(f.frame(of: "D"), 670.667, 4, 325.333, 592)
    }

    func test_zones_inPriorityOrder() {
        XCTAssertEqual(move(5, 300), .outerEdge(.left))
        XCTAssertEqual(move(333.333, 300), .intoSplit(path: [], before: 1))
        XCTAssertEqual(move(500, 300), .intoSplit(path: [1], before: 1))
        XCTAssertEqual(move(166, 300), .swap(with: "A"))
        XCTAssertEqual(move(300, 300), .besideLeaf("A", .right))
        XCTAssertEqual(move(166, 580), .besideLeaf("A", .bottom))
        XCTAssertNil(move(-5, 300))
    }

    func test_plan_previewIsSourceFrameInResult() {
        let t = abcdLayout()
        let c = PaneDropPlanner.plan(moving: "C", to: CGPoint(x: 300, y: 300), bounds: bounds, layout: t)
        XCTAssertEqual(c.map { layoutSignature($0.result) }, "row(A:0.167,C:0.167,B:0.333,D:0.333)")
        assertRect(c?.previewFrame, 173.333, 4, 161.333, 592)

        let d = PaneDropPlanner.plan(moving: "D", to: CGPoint(x: 166, y: 580), bounds: bounds, layout: t)
        assertRect(d?.previewFrame, 4, 304, 492, 292)

        let swap = PaneDropPlanner.plan(moving: "A", to: CGPoint(x: 833.333, y: 300), bounds: bounds, layout: t)
        assertRect(swap?.previewFrame, 670.667, 4, 325.333, 592)

        let edge = PaneDropPlanner.plan(moving: "B", to: CGPoint(x: 995, y: 300), bounds: bounds, layout: t)
        XCTAssertEqual(edge.map { layoutSignature($0.result) }, "row(A:0.250,C:0.250,D:0.250,B:0.250)")
        assertRect(edge?.previewFrame, 754, 4, 242, 592)
    }

    func test_plan_inPlaceDropsAreNil() {
        let t = abcdLayout()
        XCTAssertNil(PaneDropPlanner.plan(moving: "A", to: CGPoint(x: 166, y: 300), bounds: bounds, layout: t), "own centre")
        XCTAssertNil(PaneDropPlanner.plan(moving: "C", to: CGPoint(x: 500, y: 300), bounds: bounds, layout: t), "own neighbouring gap")
        XCTAssertNil(PaneDropPlanner.plan(moving: "C", to: CGPoint(x: 500, y: 250), bounds: bounds, layout: t), "B's bottom: structure unchanged")
        XCTAssertNil(PaneDropPlanner.plan(moving: "A", to: CGPoint(x: 5, y: 300), bounds: bounds, layout: t), "already leftmost")
    }

    func test_tinyPanes_planIsSane() {
        let many = PaneLayoutNode.fromColumns((0..<40).map { ["P\($0)"] })!
        for x in stride(from: 0, through: 1000, by: 7) {
            let plan = PaneDropPlanner.plan(moving: "P0", to: CGPoint(x: CGFloat(x), y: 300), bounds: bounds, layout: many)
            if let f = plan?.previewFrame { XCTAssertGreaterThanOrEqual(f.width, 0); XCTAssertGreaterThanOrEqual(f.height, 0) }
        }
    }
}
```

- [ ] **Step 2: 실패를 확인한다** — `<Class>` = `PaneDropPlannerTests`, Expected: 컴파일 실패.

- [ ] **Step 3: `PaneDropPlanner.swift`를 구현한다**

사이 틈 판정: 각 split frame의 이웃한 자식 쌍마다 중심선 = `(앞 자식 끝 + 뒤 자식 시작)/2`, 거리 ≤ 14이고 커서가 그 split의 직교 범위 안이면 후보 `intoSplit(path:, before: i)`. 삼각형: `dx = (x - midX)/(w/2)`, `dy = (y - midY)/(h/2)`, `|dx| > |dy|`면 좌/우, 아니면 위/아래. `plan`: `besideLeaf`·`swap` 대상이 `source`면 nil, swap이 아니고 `result.hasSameStructure(as: layout)`이면 nil.

- [ ] **Step 4: 통과를 확인한다** — Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add apps/termy/Sources/PaneDropPlanner.swift apps/termy-tests/Sources/PaneDropPlannerTests.swift
git commit -m "feat(layout): 놓는 자리 판정과 미리보기 frame 계산을 더한다"
```

---

### Task 3: 떠난 자리 기억과 자동 배치

**Files:**
- Create: `apps/termy/Sources/ProjectPaneLayout.swift`
- Test: `apps/termy-tests/Sources/ProjectPaneLayoutTests.swift`

**Interfaces:**
- Consumes: Task 1, Task 2(`frames`, `PaneDropPlanner.contentRect`, `gap`), 기존 `BalancedPanePlacementPlanner`·`BalancedPaneLayoutRow`(Workspace.swift, 그대로 둔다).
- Produces:
  - `struct ProjectPaneLayout: Equatable` (잎 = paneId `String`)
    - `init(tree: PaneLayoutNode<String>? = nil)`
    - `private(set) var tree: PaneLayoutNode<String>?`, `private(set) var awayPaneIds: Set<String>`
    - `var visibleTree: PaneLayoutNode<String>?` — tree에서 떠난 잎을 뺀 것.
    - `var isEmpty: Bool` — `tree == nil`.
    - `mutating func materialize()` — `tree = visibleTree; awayPaneIds = []`.
    - `mutating func replaceVisibleTree(_ new: PaneLayoutNode<String>?)` — materialize 후 대입. 배치를 손대는 모든 동작은 이것으로 쓴다.
    - `mutating func markAway(_ paneId: String)` — 잎은 남기고 떠남 표시.
    - `mutating func returnFromAway(_ paneId: String) -> Bool` — 떠남 잎이 있으면 표시만 지우고 true.
    - `mutating func removePane(_ paneId: String)` — 보이는 pane이 닫힘: materialize 후 잎 제거.
    - `mutating func forgetAway(_ paneId: String)` — 다른 곳에서 닫힌 pane의 떠남 잎만 지움(다른 떠남 잎은 그대로).
  - `enum PanePlacement`
    - `static func columnCounts(of tree: PaneLayoutNode<String>) -> [Int]?` — 잎 → `[1]`; topToBottom split of leaves → `[n]`; leftToRight split의 자식이 모두 잎이거나 "잎만 가진 topToBottom split"이면 열마다 개수; 그 밖은 nil.
    - `static func balanced(_ new: String, into tree: PaneLayoutNode<String>?, workspaceSize: CGSize) -> PaneLayoutNode<String>` — nil → `.leaf(new)`. 열 모양이면 `BalancedPanePlacementPlanner.placement(rows:workspaceSize:preferredRow: nil)`: `.append(toRow: i)` → 열 i 끝에 끼움(열이 잎이면 `splitting(잎, .bottom)`, 아니면 `inserting(intoSplitAt:)`); `.insertRow(after: i)` → root가 leftToRight면 `inserting(intoSplitAt: [], before: i+1)`, 아니면 `inserting(atOuterEdge: .right)`. 열 모양이 아니면 `frames(in: contentRect)`에서 넓이가 가장 큰 잎(같으면 읽는 순서상 앞)을 긴 쪽으로 나눈다(너비 ≥ 높이면 `.right`, 아니면 `.bottom`).

- [ ] **Step 1: 실패하는 테스트를 쓴다**

```swift
import XCTest
@testable import termy

final class ProjectPaneLayoutTests: XCTestCase {
    private let row3 = PaneLayoutNode.fromColumns([["A"], ["B"], ["C"]])!

    func test_awayAndBack_restoresSameSlot() {
        var l = ProjectPaneLayout(tree: row3)
        l.markAway("B")
        XCTAssertEqual(l.visibleTree.map(layoutSignature), "row(A:0.500,C:0.500)")
        XCTAssertTrue(l.returnFromAway("B"))
        XCTAssertEqual(l.visibleTree, row3)
    }

    func test_editWhileAway_forgetsSlot() {
        var l = ProjectPaneLayout(tree: row3)
        l.markAway("B")
        l.replaceVisibleTree(l.visibleTree!.splitting("A", edge: .bottom, with: "N"))
        XCTAssertFalse(l.returnFromAway("B"))
        XCTAssertFalse(l.tree!.contains("B"))
    }

    func test_removePane_dropsAwayLeavesToo() {
        var l = ProjectPaneLayout(tree: row3)
        l.markAway("B")
        l.removePane("C")
        XCTAssertEqual(l.tree, .leaf("A"))
        XCTAssertTrue(l.awayPaneIds.isEmpty)
    }

    func test_forgetAway_removesOnlyThatLeaf() {
        var l = ProjectPaneLayout(tree: row3)
        l.markAway("A"); l.markAway("B")
        l.forgetAway("A")
        XCTAssertEqual(l.awayPaneIds, ["B"])
        XCTAssertTrue(l.returnFromAway("B"))
        XCTAssertEqual(l.visibleTree.map(layoutSignature), "row(B:0.500,C:0.500)")
    }

    func test_onlyAwayLeavesLeft_visibleTreeIsNil() {
        var l = ProjectPaneLayout(tree: .leaf("A"))
        l.markAway("A")
        XCTAssertNil(l.visibleTree)
        XCTAssertFalse(l.isEmpty)
    }

    func test_balanced_matchesColumnPlannerOnColumnShapes() {
        let wide = CGSize(width: 1000, height: 600), tall = CGSize(width: 600, height: 1000)
        XCTAssertEqual(PanePlacement.balanced("N", into: nil, workspaceSize: wide), .leaf("N"))
        XCTAssertEqual(layoutSignature(PanePlacement.balanced("N", into: .leaf("A"), workspaceSize: wide)), "row(A:0.500,N:0.500)")
        XCTAssertEqual(layoutSignature(PanePlacement.balanced("N", into: .leaf("A"), workspaceSize: tall)), "col(A:0.500,N:0.500)")
        let two = PaneLayoutNode.fromColumns([["A"], ["B"]])!   // BalancedPanePlacementTests.test_twoSideBySidePanes_splitLeftmostTallPaneOnTie
        XCTAssertEqual(layoutSignature(PanePlacement.balanced("N", into: two, workspaceSize: wide)), "row(col(A:0.500,N:0.500):0.500,B:0.500)")
    }

    func test_balanced_nonColumnShape_splitsLargestPaneAlongLongerSide() {
        let t = PaneLayoutNode.fromColumns([["A"], ["B", "C"]])!.splitting("C", edge: .right, with: "D")
        XCTAssertNil(PanePlacement.columnCounts(of: t))
        // 1000×600: A 492×592 가 가장 넓고 세로가 더 길다 → 아래로 나눈다.
        XCTAssertEqual(layoutSignature(PanePlacement.balanced("N", into: t, workspaceSize: CGSize(width: 1000, height: 600))),
                       "row(col(A:0.500,N:0.500):0.500,col(B:0.500,row(C:0.500,D:0.500):0.500):0.500)")
    }
}
```

- [ ] **Step 2: 실패를 확인한다** — `<Class>` = `ProjectPaneLayoutTests`.
- [ ] **Step 3: `ProjectPaneLayout.swift`를 구현한다** (Interfaces 그대로).
- [ ] **Step 4: 통과를 확인한다** — 같은 명령, 그리고 `BalancedPanePlacementTests`도 그대로 통과해야 한다.
- [ ] **Step 5: Commit**

```bash
git add apps/termy/Sources/ProjectPaneLayout.swift apps/termy-tests/Sources/ProjectPaneLayoutTests.swift
git commit -m "feat(layout): 떠난 자리 기억과 tree 자동 배치를 더한다"
```

---

### Task 4: Workspace를 프로젝트별 tree로 옮긴다

배치의 출처를 `rows`에서 `layouts: [String: ProjectPaneLayout]`로 바꾼다. 저장 형식은 아직 `rows`(호환용 계산 프로퍼티)로 쓰고, 복원은 `rows`를 tree로 바꿔 세운다. 이 태스크가 끝나면 끌기 없이도 앱 전체가 새 모델로 돈다.

**Files:**
- Modify: `apps/termy/Sources/Workspace.swift` (`rows` 저장 프로퍼티, `place`, `placeBalanced`, `locate`, `teardown`, `handlePaneProjectChanged`, `visiblePanesInLayoutOrder`, `relayout`, `populate*`, `equalize*`)
- Modify: `apps/termy/Sources/MainWindowController.swift` (`applySessionLayout`, `restore(workspace:)`)
- Modify: `apps/termy/Sources/AppDelegate.swift:593-606` (메뉴 제목), `apps/termy/Sources/KeyboardShortcutsPanel.swift:35-36` (설명)
- Test: `apps/termy-tests/Sources/WorkspaceLayoutTests.swift` (새 파일)

**Interfaces:**
- Consumes: Task 1~3 전부.
- Produces (Workspace, `@MainActor`):
  - `func layoutTree(forProject projectId: String) -> PaneLayoutNode<String>?` — 보이는 tree(떠난 잎 제외).
  - `func layoutSnapshot() -> [(projectId: String, tree: PaneLayoutNode<Pane>)]` — `knownProjectIds` 순서, 보이는 tree만.
  - `func applyRestoredLayout(_ tree: PaneLayoutNode<Pane>)` — 잎들의 실제 `projectId`마다 그 project의 잎만 남긴 tree를 만들고, 그 project의 지금 보이는 pane 집합이 그 잎 집합과 **같을 때만** 그 project의 layout으로 바꾼다(아니면 자동 배치 그대로 둔다). 끝에 relayout.
  - `var rows: [[Pane]]` — **임시 호환용 계산 프로퍼티**: `layoutSnapshot().flatMap { $0.tree.approximateColumns() }`. Task 6에서 지운다.
  - `var displayedProjectId: String?` — tree를 그리는 project(프로젝트 필터, 또는 project가 하나뿐인 ALL). 여러 project ALL이면 nil.
- 불변식(테스트로 고정): 모든 pane은 `layouts[pane.projectId]`의 보이는 잎으로 정확히 한 번 있다. 떠난 잎은 다른 project layout에만 있다.

동작:
- `place`: `.row`(⌘D, `splitRow`) → 포커스된 pane이 새 pane과 같은 project면 `splitting(focused, .right)`; `.column`(⌘⇧D) → `.bottom`; 그 밖(`.balanced`, 포커스 없음, 다른 project) → `PanePlacement.balanced(..., workspaceSize: bounds.size)`. 모두 `replaceVisibleTree`로 쓴다.
- `teardown`: `layouts[P].removePane(id)`, 다른 모든 layout에 `forgetAway(id)`, 비면(`isEmpty`) 지운다.
- `handlePaneProjectChanged`: 옛 project O = 그 pane id를 보이는 잎으로 가진 layout. `layouts[O].markAway(id)`. 새 project N에서 `returnFromAway(id)`가 false면 `PanePlacement.balanced`로 넣는다. 그다음 지금의 필터 따라가기 로직.
- 그리기: 최대화면 그 pane 하나. `displayedProjectId`가 있으면 그 tree를 중첩 `GapSplitView`로(잎이 root면 자식 하나인 split), 각 split은 `isVertical = (axis == .leftToRight)`. 초기 frame은 `frames(in:gap:)`(y 반전)로 넣어 `populateColumns`처럼 첫 배치 흔들림을 줄인다. 여러 project ALL 그리드는 지금 코드 그대로, 채우는 순서는 `PaneGridOrder.readingOrder(columns: knownProjectIds.map { 그 project 보이는 tree의 잎 → Pane }, …)`.
- `equalizeSplits` → `applySplitWeights()`로 이름과 동작을 바꾼다: `splitWeights: [ObjectIdentifier: [Double]]`(그리기 때 등록, 없으면 균등)대로 `setPosition(start + Σ(total·w) + i·8, ofDividerAt: i)`, `total = 길이 - 8·(n-1)`. 지금 equalize를 부르는 자리(install 직후·`layout()`의 지연 패스)에서 그대로 부른다.
- `visiblePanesInLayoutOrder`: 위와 같은 `readingOrder` 입력에 `isVisible` 필터.
- 복원(`MainWindowController`): `applySessionLayout` = `PaneLayoutNode.fromColumns(record.rows)`를 `map`으로 돌며 `addRestoredPane(..., splitAxis: .balanced, ...)`로 pane을 만들고 `workspace.applyRestoredLayout(created)`. `focusedPaneIndex`는 그렇게 만든 순서(`created.leaves`)의 index. `restore(workspace:)`도 `fromColumns(record.effectiveRows)`로 같은 방식.
- 메뉴: ⌘D `"Split Right"`, ⌘⇧D `"Split Down"`. 단축키 패널: ⌘D `"Split pane right"`, ⌘⇧D `"Split pane down"`.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`WorkspaceLayoutTests.swift` — `WorkspaceParkingTests`의 window·`settle()`·`makeProjectDir` 패턴을 복사하고, 다음 helper를 더한다:

```swift
/// Workspace 기준 y-아래 좌표의 pane frame.
private func frame(of pane: Pane) -> CGRect {
    let r = pane.convert(pane.bounds, to: workspace)
    return CGRect(x: r.minX, y: workspace.bounds.height - r.maxY, width: r.width, height: r.height)
}
/// pane id → 짧은 이름으로 바꾼 보이는 tree의 signature.
private func signature(_ projectId: String, _ names: [Pane: String]) -> String? {
    let byId = Dictionary(uniqueKeysWithValues: names.map { ($0.key.paneId, $0.value) })
    return workspace.layoutTree(forProject: projectId).map { layoutSignature($0.map { byId[$0] ?? "?" }) }
}
/// OSC 7과 같은 길로 cwd를 바꾸고 projectId가 바뀔 때까지 기다린다. 셸은 프롬프트 때만 OSC 7을 보낼 수 있으므로,
/// 첫 프롬프트가 그려진 뒤(버퍼 첫 줄이 비지 않을 때까지, 최대 5초) 0.3초 더 기다리고 나서 바꾼다 — 테스트 셸이 늦게
/// 보낸 자기 cwd가 시뮬레이션한 drift를 덮지 않게.
private func drift(_ pane: Pane, to dir: String) {
    let promptDeadline = Date().addingTimeInterval(5)
    while (pane.terminal.getTerminal().getLine(row: 0)?.translateToString(trimRight: true) ?? "").isEmpty,
          Date() < promptDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    let before = pane.projectId
    pane.hostCurrentDirectoryUpdate(source: pane.terminal, directory: URL(fileURLWithPath: dir).absoluteString)
    let deadline = Date().addingTimeInterval(3)
    while pane.projectId == before && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    settle()
}
```

테스트(이름과 단언):

```swift
func test_splitRight_splitsOnlyFocusedPane() throws {
    let dir = try makeProjectDir("alpha")
    let a = workspace.addPane(cwd: dir)
    let b = workspace.addPane(cwd: dir, splitAxis: .column)     // ⌘⇧D: a 아래
    workspace.focus(pane: a)
    let c = workspace.addPane(cwd: dir, splitAxis: .row)        // ⌘D: a만 좌우로
    settle()
    XCTAssertEqual(signature(a.projectId, [a: "a", b: "b", c: "c"]), "col(row(a:0.500,c:0.500):0.500,b:0.500)")
    XCTAssertEqual(frame(of: c).minY, frame(of: a).minY, accuracy: 1)
    XCTAssertEqual(frame(of: c).width, frame(of: a).width, accuracy: 1)
    XCTAssertEqual(frame(of: b).width, frame(of: a).width * 2 + 8, accuracy: 1)
}

func test_closingPane_collapsesItsSplit() throws  // 위 배치에서 c를 닫으면 layoutTree 잎 == [a, b], a 너비 == b 너비(±1)

func test_driftOutAndBack_returnsToSameSlotAndSize() throws
// alpha에 a|b|c(.row 두 번 → 균등 아님: a .5, b .25, c .25), b를 beta 폴더로 drift → alpha 보이는 잎 [a, c];
// 다시 alpha로 drift → layoutTree(alpha)가 drift 전과 ==, b frame이 drift 전과 같음(±1).

func test_driftOut_editAlpha_thenBack_autoPlaces() throws
// b가 떠난 동안 alpha에 pane 하나 추가 → 돌아온 b는 drift 전 자리가 아님(layoutTree가 drift 전 tree와 hasSameStructure false), 잎 개수 4.

func test_paneClosedWhileAway_leavesNoGhostSlot() throws
// b가 beta로 떠난 뒤 b를 닫음 → alpha 보이는 tree 잎 == [a, c], beta layoutTree == nil; filterOptions에 beta 없음.

func test_applyRestoredLayout_installsExactTree() throws
// 같은 폴더 pane 4개를 만들고 applyRestoredLayout(.split(.leftToRight, [A, col(B,C), D] 비율 1/3)) → layoutTree가 그 tree(id로) 와 ==,
// frame(of: B)가 PaneDropPlanner 계산(Task 2 기준값, 이 창 크기로 다시 계산)과 ±1.

func test_applyRestoredLayout_paneInAnotherProject_staysPlaced() throws
// alpha 2개 + beta 1개를 한 tree로 넘김 → alpha layout은 넘긴 tree에서 beta를 뺀 것, beta pane은 beta layoutTree의 잎. 모든 pane이 자기 project 뷰에서 보임.

func test_cycleFocus_walksTreeReadingOrder() throws
// applyRestoredLayout으로 [A, col(B,C), D] → focus A에서 cycleFocus(delta: 1)을 세 번: B, C, D.
```

- [ ] **Step 2: 실패를 확인한다** — `<Class>` = `WorkspaceLayoutTests`.

- [ ] **Step 3: Workspace·MainWindowController·메뉴·패널을 위 동작대로 고친다**

`BalancedPanePlacementPlanner`·`PaneGridOrder`는 그대로 둔다(Task 3과 그리기가 쓴다).

- [ ] **Step 4: 통과를 확인한다**

Run: `WorkspaceLayoutTests`, `WorkspaceParkingTests`, `BalancedPanePlacementTests`, `PaneGridOrderTests`, `HcRestoreIntegrationTests`, `PaneRecordHcTests` 각각 → 모두 `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add apps/termy/Sources/Workspace.swift apps/termy/Sources/MainWindowController.swift apps/termy/Sources/AppDelegate.swift apps/termy/Sources/KeyboardShortcutsPanel.swift apps/termy-tests/Sources/WorkspaceLayoutTests.swift
git commit -m "feat(layout): Workspace 배치를 프로젝트별 분할 tree로 바꾼다"
```

---

### Task 5: 경계선으로 바꾼 크기를 기억한다

**Files:**
- Modify: `apps/termy/Sources/Workspace.swift` (`GapSplitView`, 그리기 때 split ↔ tree path 등록, 새 콜백)
- Modify: `apps/termy/Sources/MainWindowController.swift:117-128` (콜백 연결)
- Test: `apps/termy-tests/Sources/WorkspaceLayoutTests.swift` (추가)

**Interfaces:**
- Produces:
  - `GapSplitView.onUserResizeEnded: ((NSSplitView) -> Void)?` — `override func mouseDown(with:)`에서 `super.mouseDown(with:)`(NSSplitView의 divider 추적 루프, 놓을 때 돌아온다) 뒤에 부른다. NSSplitView는 divider 위 클릭만 받는다.
  - `Workspace.var onLayoutChanged: (() -> Void)?` — 배치만 바뀌었을 때(경계선, 이후 Task 7의 놓기). `MainWindowController`가 `autosaver?.requestSave()`와 `windowManager?.sessionAutosaver?.requestSave()`로 잇는다.
  - `Workspace.func captureUserResize(of split: NSSplitView)` (internal, 테스트가 직접 부른다) — 그 split이 tree에서 그린 것(`splitPaths[ObjectIdentifier]`에 있음)이면 arranged subview들의 축 방향 길이 비율로 `layouts[displayed].replaceVisibleTree(visible.settingWeights(w, atSplitPath: path))`, `splitWeights` 갱신, `onLayoutChanged?()`. 여러 project ALL 그리드의 split은 무시(비율 기억 없음).
  - `Workspace.private(set) var rootSplit` — 테스트가 읽을 수 있게 `private` → `private(set)`.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

```swift
func test_userResize_isRememberedAcrossRelayout() throws {
    let dir = try makeProjectDir("alpha")
    let a = workspace.addPane(cwd: dir)
    _ = workspace.addPane(cwd: dir, splitAxis: .row)
    settle()
    var saves = 0
    workspace.onLayoutChanged = { saves += 1 }
    let root = try XCTUnwrap(workspace.rootSplit)
    root.setPosition(300, ofDividerAt: 0)
    workspace.captureUserResize(of: root)
    XCTAssertEqual(saves, 1)
    workspace.toggleMaximize(); workspace.toggleMaximize(); settle()   // relayout 두 번
    XCTAssertEqual(frame(of: a).width, 300, accuracy: 1)
}
```

- [ ] **Step 2: 실패를 확인한다.**
- [ ] **Step 3: 구현한다.** `applySplitWeights` 도중 `captureUserResize`가 다시 불리지 않게 `isApplyingSplitWeights` 가드를 둔다.
- [ ] **Step 4: 통과를 확인한다** — `WorkspaceLayoutTests`, `WorkspaceParkingTests`.
- [ ] **Step 5: Commit**

```bash
git add apps/termy/Sources/Workspace.swift apps/termy/Sources/MainWindowController.swift apps/termy-tests/Sources/WorkspaceLayoutTests.swift
git commit -m "feat(layout): 경계선을 끌어 바꾼 pane 크기를 기억한다"
```

---

### Task 6: 새 배치를 저장하고 복원한다

**Files:**
- Modify: `apps/termy/Sources/SessionRecord.swift` (`WindowRecord`, `restorable(instance:)`)
- Modify: `apps/termy/Sources/WorkspaceRecord.swift`
- Modify: `apps/termy/Sources/WorkspaceAutosaver.swift` (`performSave`, `records`)
- Modify: `apps/termy/Sources/MainWindowController.swift` (`sessionWindowRecord`, `applySessionLayout`, `restore(workspace:)`)
- Modify: `apps/termy/Sources/Workspace.swift` (임시 `rows` 삭제)
- Test: `apps/termy-tests/Sources/SessionRecordTests.swift`, `PaneRecordHcTests.swift`, `RemoteProjectTests.swift`(autosave 두 테스트를 새 API로), `WorkspacePersistenceTests.swift`

**Interfaces:**
- Consumes: Task 1(`Codable`, `approximateColumns`, `removing`, `fromColumns`, `map`), Task 4(`layoutSnapshot`, `applyRestoredLayout`).
- Produces:
  - `struct ProjectLayoutRecord: Codable, Equatable { var projectId: String; var root: PaneLayoutNode<PaneRecord> }` (SessionRecord.swift)
  - `WindowRecord.layouts: [ProjectLayoutRecord]?` (init 인자 기본 nil) + `var layoutTrees: [PaneLayoutNode<PaneRecord>]` — `layouts`가 있으면 그 root들, 없으면 `fromColumns(rows)` 하나.
  - `WindowRecord.restorable(instance:)` — `rows`와 같은 `kept` 기준으로 `layouts`의 각 root에 `removing`, 빈 것은 버린다. `focusedPaneIndex` 계산은 그대로(`rows` 펼친 순서 == 잎 순서).
  - `WorkspaceRecord.layout: PaneLayoutNode<PaneRecord>?` (init 인자 기본 nil) + `var effectiveLayout: PaneLayoutNode<PaneRecord>?` — `layout ?? fromColumns(effectiveRows)`.
  - `WorkspaceAutosaver.records(layouts: [PaneLayoutNode<PaneInfo>], now: Date) -> [WorkspaceRecord]` — `records(rows:)`를 대신한다. tree마다 `PaneInfo.key`별로 `removing { $0.key != key }`한 tree를 만들어 `panes = leaves`, `rows = approximateColumns()`, `layout = map(\.paneRecord)`. 같은 key가 여러 tree에서 나오면 그 tree들을 `.split(.leftToRight, 균등)`으로 묶어 `normalized()`.
  - 저장(`sessionWindowRecord`): `layoutSnapshot()`을 지금의 Pane→PaneRecord 클로저로 `map`해 `layouts`, `rows = layouts.flatMap { $0.root.approximateColumns() }`, `focusedPaneIndex` = 포커스된 pane의 잎 순서 index.
  - 복원: `applySessionLayout`은 `record.layoutTrees`마다, `restore(workspace:)`는 `record.effectiveLayout`으로 Task 4와 같은 `map` + `applyRestoredLayout`.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

```swift
// SessionRecordTests
func test_windowRecord_layoutsRoundTrip() throws
// layouts = [ProjectLayoutRecord(projectId: "api", root: [A | B/C] PaneRecord 잎)] → encode/decode ==.

func test_windowRecord_legacyJSONWithoutLayouts_buildsTreeFromRows() throws
// PaneRecordHcTests.testOldSessionFileDecodesWithLocalPanes의 legacy JSON → layoutTrees.count == 1,
// layoutTrees[0].leaves.map(\.cwd) == ["/a", "/b", "/c"], 구조 == fromColumns([[a,b],[c]]).

func test_windowRecord_rowsFlattenInLayoutReadingOrder() throws
// 저장 경로가 쓰는 것과 같은 방식으로 만든 record(layouts 두 project) → rows.flatMap{$0} == layouts.flatMap{$0.root.leaves},
// JSON에 "rows" 키가 있다.

// PaneRecordHcTests
func testRestorableDropsOtherInstanceHcPanesFromLayouts()
// layouts에 release instance hc 잎이 섞인 record → restorable(instance: "debug")의 layouts 잎에 그 pane 없음, 남은 tree 정규화(자식 하나 split 없음),
// rows 펼친 순서 == layouts 잎 순서 유지.

// RemoteProjectTests — 두 autosave 테스트를 records(layouts:)로 옮기고 기대값에 layout 추가:
// testAutosaveGroupsLocalPanesByWorktreeAsBefore: layouts = [fromColumns([[api, api/docs, web]])] →
//   "/p/api" 기록 rows == [[api, api/docs]], layout == fromColumns([[api, api/docs]])
// testAutosaveSavesRemotePanesAsARemoteRecord: layouts = [fromColumns([[remote(/srv/app)], [remote(/srv/app/sub)]])] (원격 project tree),
//   [fromColumns([[local /p/api]])] → 원격 기록 rows == [[app],[app/sub]] 그대로.

// WorkspacePersistenceTests
func test_effectiveLayout_prefersLayoutThenRows()
```

- [ ] **Step 2: 실패를 확인한다** — 위 네 클래스.
- [ ] **Step 3: 구현한다.** Workspace의 임시 `rows`를 지우고, 컴파일 에러가 나는 호출처를 `layoutSnapshot()`으로 옮긴다.
- [ ] **Step 4: 통과를 확인한다** — 위 네 클래스 + `HcRestoreIntegrationTests`, `WorkspaceLayoutTests`.
- [ ] **Step 5: Commit**

```bash
git add apps/termy/Sources/SessionRecord.swift apps/termy/Sources/WorkspaceRecord.swift apps/termy/Sources/WorkspaceAutosaver.swift apps/termy/Sources/MainWindowController.swift apps/termy/Sources/Workspace.swift apps/termy-tests/Sources/SessionRecordTests.swift apps/termy-tests/Sources/PaneRecordHcTests.swift apps/termy-tests/Sources/RemoteProjectTests.swift apps/termy-tests/Sources/WorkspacePersistenceTests.swift
git commit -m "feat(layout): 분할 tree와 비율을 세션·프로젝트 기록에 저장하고 복원한다"
```

---

### Task 7: header를 끌어 옮긴다

**Files:**
- Create: `apps/termy/Sources/PaneDragOverlayView.swift`
- Modify: `apps/termy/Sources/Pane.swift` (`PaneHeaderView`, `Pane` 콜백)
- Modify: `apps/termy/Sources/Workspace.swift` (끌기 추적, 세대, 놓기)
- Test: `apps/termy-tests/Sources/WorkspaceDragTests.swift`

**Interfaces:**
- Consumes: Task 2(`PaneDropPlanner.plan`, `PaneDropPlan`), Task 4(`layoutTree`, `displayedProjectId`), Task 5(`onLayoutChanged`).
- Produces:
  - `PaneHeaderView.onMouseDown: ((NSEvent) -> Void)?` (`override func mouseDown`가 부른다, super 호출 없음), `PaneHeaderView.title: String` — 라벨과 같은 `project  /  branch`(branch 없으면 project).
  - `Pane.onHeaderMouseDown: ((NSEvent) -> Void)?`, `Pane.headerTitle: String`.
  - `final class PaneDragOverlayView: NSView` — `isFlipped = true`, `hitTest` → nil. `func showPreview(_ frame: CGRect?)`(nil이면 숨김; 그림자 상자 스타일은 Global Constraints), `func showChip(title: String, at point: CGPoint)`(커서 오른쪽 아래 +14/+12, 둥근 배경 + 라벨).
  - Workspace:
    - `private(set) var layoutGeneration: Int` — relayout, layouts 변경, `setFrameSize`마다 +1.
    - `func canBeginPaneDrag(_ pane: Pane) -> Bool` — 최대화 아님, `displayedProjectId != nil`, pane이 그 보이는 tree의 잎, 잎 2개 이상.
    - `func dragPlan(moving pane: Pane, toFlippedPoint point: CGPoint) -> PaneDropPlan?` — `PaneDropPlanner.plan(moving: pane.paneId, to: point, bounds: bounds.size, layout: 보이는 tree)`.
    - `@discardableResult func applyDrop(_ plan: PaneDropPlan, generation: Int) -> Bool` — `generation != layoutGeneration`이면 false·변화 없음. 아니면 `replaceVisibleTree(plan.result)`, relayout, `focus(pane:)`(끌린 pane), `onLayoutChanged?()`, true.
    - `private func handleHeaderMouseDown(on pane: Pane, event: NSEvent)` — 먼저 `focus(pane:)`. `canBeginPaneDrag`가 false면 끝(클릭). 아니면 그때의 `layoutGeneration`을 잡고 `window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown], timeout: .infinity, mode: .eventTracking)`(`ProjectFilterBar.handleMouseDown`과 같은 모양): 세대가 바뀌면 취소, keyCode 53(Esc)이면 취소, 4pt 넘게 움직이면 시작(alpha 0.35, overlay를 맨 위 subview로 추가, `NSCursor.closedHand.push()`), 움직일 때마다 `dragPlan` → `showPreview(plan?.previewFrame)` + `showChip`, mouseUp이면 plan이 있을 때 `applyDrop`. 끝나면 alpha 1, cursor pop, overlay 제거. 추적 중에는 relayout을 부르지 않는다.
  - `addPane`에서 `pane.onHeaderMouseDown`을 `handleHeaderMouseDown`에 잇는다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`WorkspaceDragTests.swift` (window·settle·폴더 helper는 Task 4 파일과 같은 패턴, `frame(of:)` 포함):

```swift
/// 미리보기 상자 == 놓은 뒤 실제 frame (스펙 "하면 실패인 것" 2번).
func test_dropPreviewMatchesActualFrame() throws {
    // 같은 폴더 pane 4개 → applyRestoredLayout([A | B/C | D], 비율 1/3)
    // 대상 점(Workspace y-아래 좌표, 실제 pane frame에서 계산):
    //   A 오른쪽 삼각형(midX + w*0.4, midY), 사이 틈 A↔열(A.maxX + 4, midY),
    //   B↔C 틈(B.midX, B.maxY + 4), D 가운데(D.midX, D.midY), 바깥 아래(midX, bounds.height - 5)
    // 각 점마다: 레이아웃을 다시 [A | B/C | D]로 되돌리고, plan = dragPlan(moving: C(가운데 점이면 A), toFlippedPoint:)
    //   → XCTUnwrap, applyDrop(plan, generation: workspace.layoutGeneration) == true, settle,
    //   frame(of: 끌린 pane)이 plan.previewFrame과 minX/minY/width/height 모두 ±1.
}

func test_staleGeneration_dropIsIgnored() throws {
    // [A | B/C | D] → plan = dragPlan(moving: C, A 오른쪽 점), gen = layoutGeneration
    // D를 닫는다 → XCTAssertFalse(applyDrop(plan, generation: gen)); layoutTree 잎 == [A, B, C]
}

func test_cannotDrag_singlePane_maximized_multiProjectAll() throws {
    // pane 하나 → false; 두 개(같은 project) → true; toggleMaximize 후 → false;
    // 다른 project pane 추가 + filter = .all(project 2개) → false; filter = .project(alpha) → true
}

func test_headerMouseDown_reachesPaneCallback() throws {
    // pane.onHeaderMouseDown을 테스트 클로저로 바꾸고, header 가운데에 leftMouseDown을 WorkspaceParkingTests.click(at:)처럼 보내 → 불림.
}
```

- [ ] **Step 2: 실패를 확인한다** — `<Class>` = `WorkspaceDragTests`.
- [ ] **Step 3: 구현한다** (Interfaces 그대로).
- [ ] **Step 4: 통과를 확인한다** — `WorkspaceDragTests`, `WorkspaceLayoutTests`, `WorkspaceParkingTests`, `TermyTerminalViewTests`(클릭·선택 경로 회귀).
- [ ] **Step 5: Commit**

```bash
git add apps/termy/Sources/PaneDragOverlayView.swift apps/termy/Sources/Pane.swift apps/termy/Sources/Workspace.swift apps/termy-tests/Sources/WorkspaceDragTests.swift
git commit -m "feat(layout): pane header를 끌어 자리를 옮기고 놓일 자리를 미리 보여 준다"
```

---

### Task 8: 전체 테스트와 실제 앱 확인

**Files:** 없음(확인만). 고칠 것이 나오면 해당 태스크 파일을 고치고 그 태스크의 테스트를 더한다.

- [ ] **Step 1: 전체 테스트**

Run: `cd /Users/ysh/proj/termy && xcodegen generate && xcodebuild test -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-tests -skipPackagePluginValidation 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 2: Debug 빌드를 띄운다**

Run: `xcodebuild -project termy.xcodeproj -scheme termy -destination 'platform=macOS' -derivedDataPath build/DerivedData-debug build 2>&1 | tail -5` 후 `env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" open build/DerivedData-debug/Build/Products/Debug/termy.app` (에이전트 세션의 환경 변수가 pane에 새지 않게). 이 세션이 termy 안에서 돌고 있으면(`$TERM_PROGRAM`/`$TERMY_PANE_ID`) 두 번째 인스턴스가 hook socket과 session.json을 공유하므로, 확인은 사용자에게 맡기고 아래 목록을 넘긴다.

- [ ] **Step 3: 손으로 확인한다** (프로토타입과 나란히)

  - `A | B/C | D`와 중첩 배치에서 네 자리(가장자리·사이 틈·바깥 테두리·가운데)를 끌어 보고, 상자와 놓은 뒤 위치·크기가 같다.
  - 끄는 동안 claude/codex pane 화면이 다시 그려지지 않는다(PTY 크기 그대로). 놓은 뒤 한 번만 다시 그린다.
  - header 클릭만 하면 포커스, 터미널 안 클릭·더블클릭 단어 선택·드래그 선택이 그대로다.
  - Esc·창 밖에서 놓기 → 그대로. 끄는 중 다른 pane이 `exit`로 닫히면 취소된다.
  - 여러 project ALL 뷰와 최대화 중에는 끌기가 시작되지 않는다.
  - ⌘D는 포커스된 pane만 오른쪽으로, ⌘⇧D는 아래로 나눈다. 메뉴 제목이 Split Right / Split Down.
  - 경계선을 끌어 바꾼 크기와 옮긴 배치가 앱 재시작(session.json)과 ⌘K 다시 열기 후에도 그대로다.
  - git 밖 폴더에서 `cd`로 나갔다 돌아온 pane이 원래 자리·크기로 돌아온다. 그 사이 배치를 바꾸면 자동 배치로 들어간다.

- [ ] **Step 4: 결과를 정리해 보고한다** — 통과한 항목과 사용자가 직접 확인해야 하는 항목을 나눠 적는다.
