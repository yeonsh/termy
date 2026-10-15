// ThinkingActivityBar.swift
//
// Ghostty-style indeterminate progress bar for a pane header: while the
// agent is in THINK, a short segment bounces left ↔ right along the
// header's bottom edge. The bounce is a Core Animation on `segment`, so it
// runs on the render server — no per-frame main-thread work, unlike a
// SwiftUI TimelineView. With Reduce Motion on, the bar sits still at full
// width instead.

import AppKit

final class ThinkingActivityBar: NSView {
    static let bounceKey = "termy.thinking.bounce"

    /// Share of the bar's width the moving segment covers.
    private static let segmentFraction: CGFloat = 0.28
    private static let minSegmentWidth: CGFloat = 24
    /// One left → right sweep; the reverse sweep takes the same time.
    private static let sweepDuration: CFTimeInterval = 1.1

    let segment = CALayer()
    private(set) var isActive = false
    var color: NSColor = .controlAccentColor {
        didSet { withoutImplicitAnimation { segment.backgroundColor = color.cgColor } }
    }

    private let reduceMotion: () -> Bool
    /// Bar width the running bounce was built for; a resize rebuilds it.
    private var bounceWidth: CGFloat?

    init(reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.reduceMotion = reduceMotion
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
        segment.backgroundColor = color.cgColor
        layer?.addSublayer(segment)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Show or hide the bar. Repeating the current value is a no-op, so the
    /// stream of hook events during a turn never restarts the bounce.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        isHidden = !active
        if active {
            updateSegment()
        } else {
            stopBounce()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if isActive { updateSegment() }
    }

    /// Core Animation can drop animations when the layer tree is rebuilt
    /// (e.g. a window move); reinstall if ours went missing.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if isActive, segment.animation(forKey: Self.bounceKey) == nil {
            bounceWidth = nil
            updateSegment()
        }
    }

    private func updateSegment() {
        let width = bounds.width
        let height = bounds.height
        if reduceMotion() {
            stopBounce()
            withoutImplicitAnimation {
                segment.frame = CGRect(x: 0, y: 0, width: width, height: height)
                segment.cornerRadius = 0
            }
            return
        }

        let segmentWidth = min(width, max(Self.minSegmentWidth, width * Self.segmentFraction))
        withoutImplicitAnimation {
            segment.bounds = CGRect(x: 0, y: 0, width: segmentWidth, height: height)
            segment.position = CGPoint(x: segmentWidth / 2, y: height / 2)
            segment.cornerRadius = height / 2
        }
        guard bounceWidth != width else { return }
        bounceWidth = width

        let bounce = CABasicAnimation(keyPath: "position.x")
        bounce.fromValue = segmentWidth / 2
        bounce.toValue = width - segmentWidth / 2
        bounce.duration = Self.sweepDuration
        bounce.autoreverses = true
        bounce.repeatCount = .infinity
        bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bounce.isRemovedOnCompletion = false
        segment.add(bounce, forKey: Self.bounceKey)
    }

    private func stopBounce() {
        segment.removeAnimation(forKey: Self.bounceKey)
        bounceWidth = nil
    }

    private func withoutImplicitAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
