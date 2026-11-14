import AppKit
import SwiftUI
import XCTest
@testable import termy

@MainActor
final class BlinkingDotViewTests: XCTestCase {
    func test_blinking_pulsesOpacityForever() throws {
        let view = BlinkingDotView()

        view.setBlinking(true)

        let pulse = try XCTUnwrap(view.dot.animation(forKey: BlinkingDotView.pulseKey) as? CABasicAnimation)
        XCTAssertEqual(pulse.keyPath, "opacity")
        XCTAssertEqual(pulse.fromValue as? Float, 1.0)
        XCTAssertEqual(pulse.toValue as? Float, 0.35)
        XCTAssertTrue(pulse.autoreverses)
        XCTAssertEqual(pulse.repeatCount, .infinity)
        XCTAssertFalse(pulse.isRemovedOnCompletion)
    }

    func test_steadyDot_hasNoPulse() {
        let view = BlinkingDotView()

        view.setBlinking(true)
        view.setBlinking(false)

        XCTAssertNil(view.dot.animation(forKey: BlinkingDotView.pulseKey))
        XCTAssertEqual(view.dot.opacity, 1.0)
    }

    /// SwiftUI calls updateNSView on every re-render; each one must not
    /// restart the pulse (the dot would visibly jump back to full opacity).
    func test_repeatedBlinking_keepsRunningPulse() throws {
        let view = BlinkingDotView()
        view.setBlinking(true)
        let first = try XCTUnwrap(view.dot.animation(forKey: BlinkingDotView.pulseKey))

        view.setBlinking(true)

        XCTAssertTrue(view.dot.animation(forKey: BlinkingDotView.pulseKey) === first)
    }

    func test_movingToWindow_reinstallsDroppedPulse() {
        let view = BlinkingDotView()
        view.setBlinking(true)
        view.dot.removeAllAnimations()

        view.viewDidMoveToWindow()

        XCTAssertNotNil(view.dot.animation(forKey: BlinkingDotView.pulseKey))
    }

    func test_color_fillsDot() {
        let view = BlinkingDotView()

        view.color = .systemOrange

        let expected = NSColor.systemOrange.usingColorSpace(.sRGB)
        let actual = view.dot.backgroundColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }
        XCTAssertNotNil(expected)
        XCTAssertNotNil(actual)
        if let expected, let actual {
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.05)
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.05)
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.05)
        }
    }

    /// Regression for the 100% main-thread hotloop: a THINK / WAIT chip used a
    /// SwiftUI `TimelineView(.animation)` dot, which re-ran
    /// `NSHostingView.layout()` every display frame (~60–120/s) and with it the
    /// whole dashboard measurement. The blink must not drive SwiftUI layout.
    func test_blinkingChip_doesNotDriveHostingViewLayoutEveryFrame() {
        let model = MissionControlModel(startPump: false)
        let windowId = UUID()
        model.setLivePaneIds(["p1", "p2"], forWindow: windowId)
        model.applySnapshot(Self.snapshot(paneId: "p1", state: .thinking))
        model.applySnapshot(Self.snapshot(paneId: "p2", state: .waiting))
        XCTAssertEqual(model.items.count, 2)

        let host = LayoutCountingHostingView(rootView: MissionControlView(
            model: model,
            onFocusPane: { _ in },
            onBarHeightChange: { _ in }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 44)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 44),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        Self.retainedWindows.append(window)
        // Hide by alpha, never orderOut: hiding the host's last visible
        // window counts as "last window closed" and the XCTest host quits,
        // failing the next test in the process.
        defer {
            window.alphaValue = 0
            window.ignoresMouseEvents = true
        }

        // Let the initial layout settle, then count layouts over a window
        // in which a per-frame animation would produce dozens of passes.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let before = host.layoutCount
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let perSecond = host.layoutCount - before

        XCTAssertLessThan(perSecond, 10, "blinking dot re-ran NSHostingView.layout() \(perSecond)×/s")
    }

    // The XCTest host app quits when its last window is released or hidden.
    private static var retainedWindows: [NSWindow] = []

    private static func snapshot(paneId: String, state: PaneState) -> PaneSnapshot {
        PaneSnapshot(
            paneId: paneId,
            projectId: "proj-\(paneId)",
            state: state,
            needsAttention: state == .waiting,
            notificationReason: nil,
            waitSource: nil,
            lastSessionId: "sess-\(paneId)",
            lastCwd: "/x",
            lastPrompt: nil,
            lastAssistantMessage: nil,
            updatedAt: Date(timeIntervalSince1970: 1_000),
            enteredStateAt: Date(timeIntervalSince1970: 1_000),
            agentKind: .claude,
            lastPtyActivityAt: nil
        )
    }
}

private final class LayoutCountingHostingView<Content: View>: NSHostingView<Content> {
    private(set) var layoutCount = 0

    override func layout() {
        layoutCount += 1
        super.layout()
    }
}
