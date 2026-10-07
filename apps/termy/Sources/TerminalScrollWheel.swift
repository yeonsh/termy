// TerminalScrollWheel.swift
//
// Distance-accurate wheel/trackpad scrolling for TermyTerminalView. The
// pinned SwiftTerm (f37922e) maps every wheel event to at least one row: it
// reads `deltaY` (which is `scrollingDeltaY / 10` on precise devices),
// truncates it, and feeds a step curve — 0–1 → 1 row, 2–5 → 3, 6–9 → 10,
// ≥10 → a full screen. A trackpad emits 60–120 small events per second
// including the momentum tail, so scroll distance tracked the event count
// instead of the finger, and a flick jumped whole screens per event.
//
// The accumulator follows upstream's fix (SwiftTerm 91863f0, #600); the speed
// follows Ghostty, the terminal termy is compared against day to day. Ghostty
// doubles precise deltas (SurfaceView_AppKit `scrollWheel`), moves 3 rows per
// wheel tick (`mouse-scroll-multiplier` default), and sends one wheel report
// or arrow key per row with no cap. Upstream's ×1 travel plus its report
// budget (5d3026a, #657) felt clearly slower in Claude Code side by side.
// Delete this file and the scroll-wheel monitor in TermyTerminalView once
// SwiftTerm is bumped past 5d3026a — then set its `scrollSensitivity` to match.

import AppKit

/// Where a wheel event over the terminal goes. Mirrors the three branches of
/// SwiftTerm's own `scrollWheel`.
enum TerminalScrollRoute: Equatable {
    /// The child enabled mouse tracking: send wheel button presses.
    case mouseReport
    /// Alternate screen without mouse tracking: send arrow keys.
    case cursorKeys
    /// Primary screen: move the viewport through scrollback.
    case scrollback

    static func route(mouseReporting: Bool, alternateBuffer: Bool) -> TerminalScrollRoute {
        if mouseReporting { return .mouseReport }
        return alternateBuffer ? .cursorKeys : .scrollback
    }
}

/// Turns wheel deltas into whole terminal rows, carrying sub-row travel to the
/// next event of the same gesture instead of rounding every event up to a row.
struct ScrollWheelLineAccumulator {
    /// Ghostty's macOS multiplier for trackpad / Magic Mouse travel.
    static let preciseMultiplier: CGFloat = 2
    /// Ghostty's default rows per classic wheel tick.
    static let rowsPerWheelTick: CGFloat = 3

    private(set) var remainder: CGFloat = 0
    private var route: TerminalScrollRoute?

    /// Signed row count for one event; positive scrolls toward older output.
    /// `delta` is `NSEvent.scrollingDeltaY`: points for precise devices,
    /// ticks for a classic wheel. `sensitivity` scales either.
    mutating func lines(
        delta: CGFloat,
        isPrecise: Bool,
        cellHeight: CGFloat,
        route: TerminalScrollRoute,
        sensitivity: CGFloat = 1
    ) -> Int {
        guard delta != 0, cellHeight > 0 else { return 0 }
        // Travel banked for one route must not surface in another: scrollback
        // travel turning into a wheel report once the child enables mouse
        // tracking would scroll the child by a row the user never moved.
        if route != self.route {
            remainder = 0
            self.route = route
        }
        let travel: CGFloat
        if isPrecise {
            travel = delta * Self.preciseMultiplier
        } else {
            // macOS reports a slow notch as a fraction of a tick and ramps the
            // value up for fast turns; a notch always counts as a whole tick.
            let ticks = delta > 0 ? max(delta, 1) : min(delta, -1)
            travel = ticks * cellHeight * Self.rowsPerWheelTick
        }
        remainder += travel * sensitivity
        let lines = Int(remainder / cellHeight)
        remainder -= CGFloat(lines) * cellHeight
        return lines
    }

    mutating func reset() {
        remainder = 0
        route = nil
    }
}

/// Live-tunable scale on top of the Ghostty-matched speed, read on every
/// event so `defaults write app.termy.macos termy.scrollSensitivity -float 1.5`
/// takes effect without relaunching (which would kill every pane's session).
enum TerminalScrollSensitivity {
    static let defaultsKey = "termy.scrollSensitivity"

    static func current() -> CGFloat {
        resolve(stored: UserDefaults.standard.double(forKey: defaultsKey))
    }

    /// Unset (0) or nonsensical values fall back to 1; the rest is clamped so
    /// a typo can't freeze or fling the terminal.
    static func resolve(stored: Double) -> CGFloat {
        guard stored > 0 else { return 1 }
        return CGFloat(min(max(stored, 0.1), 10))
    }
}

/// Decides whether a wheel event belongs to this terminal. A trackpad
/// gesture, momentum tail included, stays with the view it began over, the
/// way NSScrollView latches it. Re-hit-testing every event instead would
/// drop a flick's tail once the pointer drifted off the pane (leaving it to
/// whatever AppKit routes it to, possibly SwiftTerm's own `scrollWheel`) and
/// would steal the tail of a flick that began in another scroll view.
struct ScrollGestureLatch {
    private var latched = false

    /// `isOverView` runs only when a gesture begins or for a classic wheel
    /// notch, which has no gesture to latch.
    mutating func claims(
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase,
        isOverView: () -> Bool
    ) -> Bool {
        if phase.contains(.mayBegin) || phase.contains(.began) {
            latched = isOverView()
            return latched
        }
        guard phase.isEmpty, momentumPhase.isEmpty else {
            let claimed = latched
            if momentumPhase.contains(.ended) || momentumPhase.contains(.cancelled) {
                latched = false
            }
            return claimed
        }
        return isOverView()
    }
}
