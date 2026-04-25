// MissionControlView.swift
//
// The visible hero of termy v1: a 44pt-tall horizontal bar at the top of the
// window showing one chip per live pane, sorted by who needs attention.
// Native macOS look — system colors so it adapts to light/dark/high-contrast
// automatically.
//
//   ┌─ termy ─ mycompany/api ─────────────────────────────┐
//   │ ● cc-1 WAIT  myapp    ● cc-2 THINK  api   ● cc-3 ... │  ← this view
//   ├─────────────────────────────────────────────────────┤
//   │ [tab: main*] [tab: review] [tab: debug] [+]         │
//   └─────────────────────────────────────────────────────┘

import SwiftUI
import AppKit

struct MissionControlView: View {
    let model: MissionControlModel
    let onFocusPane: (String) -> Void
    /// Reports the bar's adaptive height to AppKit so the hosting view's
    /// layout constraint can track it. Called on every height change.
    let onBarHeightChange: (CGFloat) -> Void

    /// Natural height of the `.full`-compression flow at the current bar
    /// width. Drives the adaptive bar height: ≤ single-row threshold → the
    /// 44pt compact bar; anything above → the 80pt two-row bar.
    @State private var fullFlowHeight: CGFloat = 0
    @State private var showsDashboardShortcutHints = false
    @Environment(\.colorScheme) private var colorScheme

    /// Switches between the 44pt (single-row) and 80pt (two-row) bar heights
    /// based on whether `.full` chips wrap. Fixed threshold avoids feedback
    /// loops — the measurement is of `.full` regardless of what
    /// `ViewThatFits` renders, so state transitions (WAIT→IDLE) alone don't
    /// flip the bar unless chip wrapping actually changes.
    private static let singleRowMaxHeight: CGFloat = 36
    private static let compactBarHeight: CGFloat = 44
    private static let twoRowBarHeight: CGFloat = 80

    private var barHeight: CGFloat {
        // Empty-state legend is always single-row height.
        if model.items.isEmpty { return Self.compactBarHeight }
        return fullFlowHeight <= Self.singleRowMaxHeight
            ? Self.compactBarHeight
            : Self.twoRowBarHeight
    }

    var body: some View {
        ZStack {
            // Outline-only: the pastel state chips inside carry the color, so
            // the bar itself stays transparent with a soft white stroke. A
            // filled brand color fought the blue THINKING chips and read
            // visually busy.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(chromeStrokeColor, lineWidth: 1)

            Group {
                if model.items.isEmpty {
                    emptyStateContent
                } else {
                    itemsContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .padding(.bottom, 4)
        .frame(height: barHeight)
        .background(alignment: .top) { measurementProbe }
        .background {
            DashboardShortcutHintMonitor { isVisible in
                showsDashboardShortcutHints = isVisible
            }
            .frame(width: 0, height: 0)
        }
        .animation(.easeInOut(duration: 0.18), value: barHeight)
        .onAppear { onBarHeightChange(barHeight) }
        .onChange(of: barHeight) { _, new in onBarHeightChange(new) }
    }

    private var chromeStrokeColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.5)
            : Color.black.opacity(0.14)
    }

    fileprivate static func keyCapFill(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.14)
            : Color.black.opacity(0.06)
    }

    fileprivate static func keyCapStroke(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.32)
            : Color.black.opacity(0.14)
    }

    /// Invisible `.full`-compression flow that reports its natural height
    /// via a `GeometryReader`. Sits behind the visible bar at the same
    /// width (including matching horizontal padding) so the measurement
    /// reflects what `.full` would take if rendered in the viewport.
    @ViewBuilder private var measurementProbe: some View {
        if !model.items.isEmpty {
            itemsFlow(.full)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .padding(.horizontal, 4)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { recordFullHeight(geo.size.height) }
                            .onChange(of: geo.size.height) { _, new in
                                recordFullHeight(new)
                            }
                    }
                )
        }
    }

    private func recordFullHeight(_ h: CGFloat) {
        guard abs(h - fullFlowHeight) > 0.5 else { return }
        fullFlowHeight = h
    }

    private var emptyStateContent: some View {
        HStack(spacing: 18) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.split.2x1")
                    .foregroundColor(.secondary)
                Text("No active agents")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }

            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.6))
                .frame(width: 1, height: 16)

            KeyHint(combos: [["⌘", "N"]], label: "New pane")
            KeyHint(combos: [["⌘", "G"]], label: "Next waiting")
            KeyHint(combos: [["⌘", "/"]], label: "Shortcuts")
        }
        .padding(.horizontal, 14)
    }

    /// Dashboard rows — cascade compression levels via ViewThatFits. The
    /// first variant that fits within the proposed 2-row height wins. If
    /// every variant overflows (32 panes on a tiny window), the tightest
    /// variant is used and the last row gets clipped by the parent frame.
    private var itemsContent: some View {
        ViewThatFits(in: .vertical) {
            itemsFlow(.full)
            itemsFlow(.noBranch)
            itemsFlow(.truncated)
            itemsFlow(.minimal)
        }
    }

    private func itemsFlow(_ compression: ChipCompression) -> some View {
        CenteredFlow(spacing: 8, rowSpacing: 4) {
            ForEach(Array(model.items.enumerated()), id: \.element.paneId) { index, item in
                DashboardItem(
                    snapshot: item,
                    label: model.label(for: item),
                    compression: compression,
                    shortcutHint: dashboardShortcutHint(at: index)
                ) {
                    onFocusPane(item.paneId)
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private func dashboardShortcutHint(at index: Int) -> String? {
        guard showsDashboardShortcutHints, index < 9 else { return nil }
        return "\(index + 1)"
    }
}

// MARK: - Hotkey hint chip

private struct KeyHint: View {
    /// Each inner array is one modifier+key combo; multiple combos in the
    /// outer array render as a "either/or" pair (e.g. prev / next cyclers).
    let combos: [[String]]
    let label: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                ForEach(Array(combos.enumerated()), id: \.offset) { idx, combo in
                    if idx > 0 {
                        Text("/")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    }
                    HStack(spacing: 3) {
                        ForEach(Array(combo.enumerated()), id: \.offset) { _, key in
                            keyCap(key)
                        }
                    }
                }
            }
            Text(label)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.secondary)
        }
    }

    private func keyCap(_ key: String) -> some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(.primary)
            .frame(minWidth: 14)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(MissionControlView.keyCapFill(for: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(MissionControlView.keyCapStroke(for: colorScheme), lineWidth: 1)
            )
    }
}

// MARK: - Dashboard item

/// Progressive compression levels for dashboard chips. Higher levels drop
/// content so more chips fit per row when the dashboard gets crowded.
enum ChipCompression: Int, CaseIterable {
    case full       // project / branch, natural width
    case noBranch   // project only
    case truncated  // project capped at 10 chars, middle-truncated
    case minimal    // project capped at 6 chars + ellipsis if longer
}

private struct DashboardItem: View {
    let snapshot: PaneSnapshot
    let label: PaneDisplayLabel
    let compression: ChipCompression
    let shortcutHint: String?
    let onClick: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Text(projectText)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if compression == .full,
                       let branch = label.branch, !branch.isEmpty {
                        Text("/")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        Text(branch)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(Color(nsColor: .secondaryLabelColor))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                StatePill(state: snapshot.state)
            }
            .padding(.leading, 14)
            .padding(.trailing, 5)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(chipBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(chipStrokeColor, lineWidth: 1)
            )
            .overlay(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(projectAccentColor)
                    .frame(width: 3)
                    .padding(.vertical, 5)
                    .padding(.leading, 4)
            }
            .overlay(alignment: .topLeading) {
                if let shortcutHint {
                    ShortcutNumberBadge(text: shortcutHint)
                        .offset(x: -5, y: -5)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: snapshot.state)
            .animation(.easeInOut(duration: 0.18), value: snapshot.needsAttention)
            .animation(.easeInOut(duration: 0.12), value: isHovering)
            .animation(.easeInOut(duration: 0.10), value: shortcutHint)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(tooltip(for: snapshot))
    }

    /// Project name after applying the current compression cap. Middle
    /// truncation is applied as an ellipsis so both prefix and suffix of the
    /// name stay visible at the tightest levels.
    private var projectText: String {
        let raw = label.project
        switch compression {
        case .full, .noBranch:
            return raw
        case .truncated:
            return Self.midTruncate(raw, max: 10)
        case .minimal:
            return Self.midTruncate(raw, max: 6)
        }
    }

    private static func midTruncate(_ s: String, max: Int) -> String {
        guard s.count > max else { return s }
        let keep = max - 1 // reserve 1 for ellipsis
        let front = keep / 2 + keep % 2
        let back = keep / 2
        let start = s.prefix(front)
        let end = s.suffix(back)
        return "\(start)…\(end)"
    }

    /// Neutral chip surface — the per-pane state color sits in the right-side
    /// pill, the project hue sits in the left accent bar, and the chip body
    /// reads as a calm container in both light and dark modes.
    private var chipBackgroundColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(isHovering ? 0.10 : 0.06)
            : Color.white.opacity(isHovering ? 0.95 : 0.78)
    }

    private var chipStrokeColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.14)
            : Color.black.opacity(0.10)
    }

    private var projectAccentColor: Color {
        let key = snapshot.projectId ?? label.project
        return Color(nsColor: PaneStyling.accentColor(for: key))
    }

    private func tooltip(for snapshot: PaneSnapshot) -> String {
        var parts: [String] = []
        parts.append("state: \(snapshot.state.rawValue)")
        if let cwd = snapshot.lastCwd { parts.append("cwd: \(cwd)") }
        if snapshot.needsAttention, let reason = snapshot.notificationReason {
            parts.append("needs attention: \(reason)")
        }
        if let prompt = snapshot.lastPrompt {
            parts.append("last prompt: \(prompt.prefix(120))")
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: - State pill

/// Right-side capsule that carries the state color: blinking dot + label.
/// The dot blinks for THINK and WAIT (Claude is actively working / blocked
/// on the user); IDLE / INIT / ERR show a steady dot.
private struct StatePill: View {
    let state: PaneState

    var body: some View {
        HStack(spacing: 4) {
            BlinkingDot(color: stateColor, blinks: shouldBlink)
            Text(stateLabel)
                .font(.system(size: 10, weight: .heavy))
                .foregroundColor(stateColor)
                .tracking(0.4)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(stateColor.opacity(0.18))
        )
    }

    private var shouldBlink: Bool {
        state == .thinking || state == .waiting
    }

    private var stateColor: Color {
        switch state {
        case .thinking:     return Color(nsColor: .systemBlue)
        case .waiting:      return Color(nsColor: .systemOrange)
        case .errored:      return Color(nsColor: .systemRed)
        case .idle:         return Color(nsColor: .systemGray)
        case .initializing: return Color(nsColor: .systemGray)
        }
    }

    private var stateLabel: String {
        switch state {
        case .initializing: return "INIT"
        case .thinking:     return "THINK"
        case .waiting:      return "WAIT"
        case .idle:         return "IDLE"
        case .errored:      return "ERR"
        }
    }
}

/// Smoothly-pulsing dot driven by `TimelineView(.animation)` so the phase
/// keeps advancing without a stateful animation token (which is fragile
/// across `repeatForever` start/stop transitions in SwiftUI). When `blinks`
/// is false the view collapses to a steady circle and stops scheduling
/// per-frame updates.
private struct BlinkingDot: View {
    let color: Color
    let blinks: Bool

    var body: some View {
        Group {
            if blinks {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    // ~1.3s period, opacity oscillates between 0.35 and 1.0.
                    let phase = (sin(t * .pi / 0.65) + 1) / 2
                    Circle()
                        .fill(color)
                        .opacity(0.35 + phase * 0.65)
                }
            } else {
                Circle()
                    .fill(color)
            }
        }
        .frame(width: 5, height: 5)
    }
}

private struct ShortcutNumberBadge: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(Color.black.opacity(0.82))
            .frame(width: 15, height: 14)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.88 : 0.90))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(
                        colorScheme == .dark
                            ? Color.white.opacity(0.52)
                            : Color.black.opacity(0.22),
                        lineWidth: 1
                    )
            )
    }
}

private struct DashboardShortcutHintMonitor: NSViewRepresentable {
    let onVisibilityChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onVisibilityChange: onVisibilityChange)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onVisibilityChange = onVisibilityChange
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        var onVisibilityChange: (Bool) -> Void
        private weak var view: NSView?
        private var flagsMonitor: Any?
        private var keyMonitor: Any?
        private var appResignObserver: NSObjectProtocol?

        init(onVisibilityChange: @escaping (Bool) -> Void) {
            self.onVisibilityChange = onVisibilityChange
        }

        func attach(to view: NSView) {
            self.view = view
            install()
        }

        func install() {
            guard flagsMonitor == nil, keyMonitor == nil, appResignObserver == nil else { return }
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handleFlagsChanged(event)
                return event
            }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleKeyDown(event)
                return event
            }
            appResignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.setVisible(false)
            }
        }

        func uninstall() {
            if let flagsMonitor {
                NSEvent.removeMonitor(flagsMonitor)
                self.flagsMonitor = nil
            }
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
            if let appResignObserver {
                NotificationCenter.default.removeObserver(appResignObserver)
                self.appResignObserver = nil
            }
            setVisible(false)
        }

        private func handleFlagsChanged(_ event: NSEvent) {
            guard event.window == nil || event.window === view?.window else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            setVisible(flags.contains(.command) && flags.contains(.option))
        }

        private func handleKeyDown(_ event: NSEvent) {
            guard event.window == nil || event.window === view?.window else { return }
            setVisible(false)
        }

        private func setVisible(_ isVisible: Bool) {
            onVisibilityChange(isVisible)
        }
    }
}

// MARK: - Centered flow layout

/// Flows subviews into as many rows as needed, each row centered
/// horizontally within the container. sizeThatFits reports the true natural
/// height so an enclosing `ViewThatFits` can detect when the content spills
/// past a target (e.g. 2-row) height and swap to a more compressed variant.
private struct CenteredFlow: Layout {
    var spacing: CGFloat
    var rowSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = computeRows(width: width, subviews: subviews)
        let rowHeight = rows.first?.height ?? 0
        let totalHeight = CGFloat(rows.count) * rowHeight
            + CGFloat(max(0, rows.count - 1)) * rowSpacing
        let widest = rows.map(\.width).max() ?? 0
        let resolvedWidth = width.isFinite ? width : widest
        return CGSize(width: resolvedWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        let rows = computeRows(width: bounds.width, subviews: subviews)
        let rowHeight = rows.first?.height ?? 0
        let totalHeight = CGFloat(rows.count) * rowHeight
            + CGFloat(max(0, rows.count - 1)) * rowSpacing
        var y = bounds.minY + max(0, (bounds.height - totalHeight) / 2)
        for row in rows {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for idx in row.indices {
                let size = subviews[idx].sizeThatFits(.unspecified)
                subviews[idx].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += rowHeight + rowSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for idx in subviews.indices {
            let size = subviews[idx].sizeThatFits(.unspecified)
            let tentative = current.indices.isEmpty
                ? size.width
                : current.width + spacing + size.width
            if !current.indices.isEmpty, tentative > width {
                rows.append(current)
                current = Row(
                    indices: [idx],
                    width: size.width,
                    height: size.height
                )
            } else {
                current.indices.append(idx)
                current.width = tentative
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }
}
