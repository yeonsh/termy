import XCTest
@testable import termy

// ForegroundProcessWatcher가 tick마다 "감지한 agent"가 바뀔 때 보내는 synthetic SessionEnd/Start.
// local pane(tcgetpgrp)과 hc pane(hc foreground 이벤트로 받은 값)이 같은 규칙을 탄다.

final class ForegroundEdgesTests: XCTestCase {
    func testForegroundEdges() {
        XCTAssertTrue(ForegroundEdges.transition(from: .claude, to: .codex) == (end: true, start: .codex))
        XCTAssertTrue(ForegroundEdges.transition(from: nil, to: .claude) == (end: false, start: .claude))
        XCTAssertTrue(ForegroundEdges.transition(from: .codex, to: nil) == (end: true, start: nil))
    }

    func testNoEdgeWhenUnchanged() {
        XCTAssertTrue(ForegroundEdges.transition(from: nil, to: nil) == (end: false, start: nil))
        XCTAssertTrue(ForegroundEdges.transition(from: .claude, to: .claude) == (end: false, start: nil))
    }
}
