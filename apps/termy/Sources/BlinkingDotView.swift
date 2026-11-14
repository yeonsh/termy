// BlinkingDotView.swift
//
// The state dot inside a Mission Control chip. THINK / WAIT pulse its
// opacity with a Core Animation on `dot`, so the pulse runs on the render
// server: no per-frame main-thread work. The SwiftUI version used
// `TimelineView(.animation)`, which re-ran `NSHostingView.layout()` every
// display frame and, through it, the whole dashboard measurement
// (ViewThatFits × CenteredFlow) — a blinking chip alone pegged the main
// thread at 100%.

import AppKit
import SwiftUI

final class BlinkingDotView: NSView {
    static let pulseKey = "termy.dot.pulse"

    /// ~1.3s full cycle (0.65s each way), opacity 1.0 ↔ 0.35 — same rhythm
    /// as the former TimelineView sine.
    private static let halfPeriod: CFTimeInterval = 0.65
    private static let dimOpacity: Float = 0.35

    let dot = CALayer()
    private(set) var isBlinking = false
    var color: NSColor = .systemGray {
        didSet { applyColor() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(dot)
        applyColor()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Repeating the current value is a no-op so SwiftUI re-renders never
    /// restart the pulse.
    func setBlinking(_ blinking: Bool) {
        guard blinking != isBlinking else { return }
        isBlinking = blinking
        if blinking {
            startPulse()
        } else {
            dot.removeAnimation(forKey: Self.pulseKey)
        }
    }

    override func layout() {
        super.layout()
        withoutImplicitAnimation {
            dot.frame = bounds
            dot.cornerRadius = min(bounds.width, bounds.height) / 2
        }
    }

    /// Core Animation can drop animations when the layer tree is rebuilt
    /// (e.g. a window move); reinstall if ours went missing.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if isBlinking, dot.animation(forKey: Self.pulseKey) == nil {
            startPulse()
        }
    }

    /// System colors are dynamic; re-resolve the CGColor on light/dark flips.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    private func startPulse() {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = Float(1.0)
        pulse.toValue = Self.dimOpacity
        pulse.duration = Self.halfPeriod
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.isRemovedOnCompletion = false
        dot.add(pulse, forKey: Self.pulseKey)
    }

    private func applyColor() {
        var cgColor = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            cgColor = color.cgColor
        }
        withoutImplicitAnimation { dot.backgroundColor = cgColor }
    }

    private func withoutImplicitAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

/// SwiftUI wrapper used by the chip's state pill.
struct BlinkingDot: NSViewRepresentable {
    let color: NSColor
    let blinks: Bool

    func makeNSView(context: Context) -> BlinkingDotView {
        let view = BlinkingDotView()
        view.color = color
        view.setBlinking(blinks)
        return view
    }

    func updateNSView(_ view: BlinkingDotView, context: Context) {
        if view.color != color { view.color = color }
        view.setBlinking(blinks)
    }
}
