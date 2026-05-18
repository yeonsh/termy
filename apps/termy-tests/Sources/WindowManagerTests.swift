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
