import AppKit
import XCTest
@testable import termy

@MainActor
final class ThinkingActivityBarTests: XCTestCase {
    func test_displaysAsThinking_matchesMissionControlThinkPill() {
        let cases: [(PaneState, Bool)] = [
            (.thinking, true),
            (.possiblyWaiting, true),
            (.waiting, false),
            (.idle, false),
            (.initializing, false),
            (.errored, false),
        ]
        for (state, want) in cases {
            XCTAssertEqual(state.displaysAsThinking, want, "\(state)")
        }
    }

    func test_activating_bouncesSegmentEdgeToEdge() throws {
        let bar = makeBar(width: 300)

        bar.setActive(true)

        XCTAssertFalse(bar.isHidden)
        let bounce = try XCTUnwrap(bar.segment.animation(forKey: ThinkingActivityBar.bounceKey) as? CABasicAnimation)
        let half = bar.segment.bounds.width / 2
        XCTAssertLessThan(bar.segment.bounds.width, 300)
        XCTAssertEqual(bounce.keyPath, "position.x")
        XCTAssertEqual(bounce.fromValue as? CGFloat, half)
        XCTAssertEqual(bounce.toValue as? CGFloat, 300 - half)
        XCTAssertTrue(bounce.autoreverses)
        XCTAssertEqual(bounce.repeatCount, .infinity)
    }

    func test_inactiveBar_isHiddenWithoutBounce() {
        let bar = makeBar(width: 300)
        XCTAssertTrue(bar.isHidden)

        bar.setActive(true)
        bar.setActive(false)

        XCTAssertTrue(bar.isHidden)
        XCTAssertNil(bar.segment.animation(forKey: ThinkingActivityBar.bounceKey))
    }

    /// Hook events keep arriving while the agent thinks; each one must not
    /// restart the bounce (that would make the segment jump back to the left).
    func test_repeatedActivation_keepsRunningBounce() throws {
        let bar = makeBar(width: 300)
        bar.setActive(true)
        let first = try XCTUnwrap(bar.segment.animation(forKey: ThinkingActivityBar.bounceKey))

        bar.setActive(true)

        XCTAssertTrue(bar.segment.animation(forKey: ThinkingActivityBar.bounceKey) === first)
    }

    func test_resize_retargetsBounceToNewWidth() throws {
        let bar = makeBar(width: 300)
        bar.setActive(true)

        bar.setFrameSize(NSSize(width: 600, height: 3))

        let bounce = try XCTUnwrap(bar.segment.animation(forKey: ThinkingActivityBar.bounceKey) as? CABasicAnimation)
        XCTAssertEqual(bounce.toValue as? CGFloat, 600 - bar.segment.bounds.width / 2)
    }

    func test_reduceMotion_showsStaticFullWidthBar() {
        let bar = makeBar(width: 300, reduceMotion: true)

        bar.setActive(true)

        XCTAssertFalse(bar.isHidden)
        XCTAssertNil(bar.segment.animation(forKey: ThinkingActivityBar.bounceKey))
        XCTAssertEqual(bar.segment.frame, CGRect(x: 0, y: 0, width: 300, height: 3))
    }

    func test_paneHeader_thinkingBarIsOpaqueProjectAccent() throws {
        let appearance = NSAppearance(named: .darkAqua)
        let header = PaneHeaderView()
        header.configure(project: "thinking-bar-project", branch: nil, appearance: appearance)

        header.setThinking(true)

        XCTAssertTrue(header.activityBar.isActive)
        let accent = PaneStyling.accentColor(for: "thinking-bar-project", appearance: appearance)
        let painted = try XCTUnwrap(header.activityBar.segment.backgroundColor)
        XCTAssertEqual(painted, accent.withAlphaComponent(1).cgColor)
    }

    private func makeBar(width: CGFloat, reduceMotion: Bool = false) -> ThinkingActivityBar {
        let bar = ThinkingActivityBar(reduceMotion: { reduceMotion })
        bar.frame = NSRect(x: 0, y: 0, width: width, height: 3)
        return bar
    }
}
