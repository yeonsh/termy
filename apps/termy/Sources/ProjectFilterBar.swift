// ProjectFilterBar.swift
//
// Custom scrollable project filter hosted in the titlebar row. We no longer
// use NSSegmentedControl because it kept fighting the titlebar layout and
// truncating labels. Each filter is a small toggle button sized to its label;
// the row scrolls horizontally when the total width exceeds the available
// titlebar space.

import AppKit

final class ProjectFilterBar: NSView {
    private let scrollView = NSScrollView()
    private let stripView = FilterStripView()
    private weak var workspace: Workspace?
    private var options: [WorkspaceFilter] = []
    private var commandFlagsMonitor: Any?
    private var commandKeyMonitor: Any?
    private var appResignObserver: NSObjectProtocol?
    private var pendingShortcutHint: DispatchWorkItem?
    private var isCommandKeyDown = false
    private var showsShortcutHints = false

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(frame: .zero)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.verticalScrollElasticity = .none
        // .fullSizeContentView lets the bar sit in the titlebar zone, but the
        // scrollView reads the titlebar height as a safe-area inset and shoves
        // its document view 28pt down — chips end up rendered outside the bar.
        // Disable auto-adjustment.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = .init()
        scrollView.documentView = stripView
        stripView.frame = NSRect(x: 0, y: 0, width: 0, height: 28)
        stripView.onReorder = { [weak self] from, to in
            self?.reorderProject(from: from, to: to)
        }

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 28)
    }

    // Empty regions of the bar pass mouse-down to the window for drag, so
    // the filter row doubles as a titlebar handle. NSButton subviews override
    // back to false (default), so chip clicks still work.
    override var mouseDownCanMoveWindow: Bool { true }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            uninstallShortcutHintObservers()
        } else {
            installShortcutHintObservers()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
    }

    override func layout() {
        super.layout()
        stripView.viewportHeight = bounds.height
        stripView.viewportWidth = scrollView.contentSize.width
    }

    /// Re-derives buttons from Workspace.filterOptions. Call after add/close
    /// and after filter changes.
    func rebuild() {
        guard let ws = workspace else { return }
        options = ws.filterOptions
        let selectedIndex = options.firstIndex(of: ws.filter) ?? 0

        let buttons = options.enumerated().map { index, option in
            makeButton(
                title: label(for: option),
                index: index,
                shortcutHint: WorkspaceFilterOptions.shortcutHint(
                    for: option,
                    projectIds: ws.knownProjectIds
                ),
                selected: index == selectedIndex
            )
        }

        stripView.setButtons(buttons)
        stripView.firstMovableIndex = projectChipOffset
        stripView.viewportHeight = bounds.height > 0 ? bounds.height : 28

        DispatchQueue.main.async { [weak self] in
            self?.scrollSelectedButtonIntoView(index: selectedIndex)
        }
    }

    /// Chip index of the first project filter. The ALL chip, when present,
    /// occupies index 0 and is not a project — the strip reports drag indices
    /// in chip space, so they shift by this to address the project list.
    private var projectChipOffset: Int {
        options.first?.isAll == true ? 1 : 0
    }

    private func reorderProject(from: Int, to: Int) {
        guard let ws = workspace else { return }
        let offset = projectChipOffset
        ws.moveProject(from: from - offset, to: to - offset)
    }

    @objc private func buttonClicked(_ sender: NSButton) {
        guard let ws = workspace else { return }
        let index = sender.tag
        guard index >= 0, index < options.count else { return }
        ws.filter = options[index]
    }

    private func installShortcutHintObservers() {
        guard commandFlagsMonitor == nil, commandKeyMonitor == nil, appResignObserver == nil else { return }
        commandFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        commandKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
            return event
        }
        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.resetShortcutHintState()
            }
        }
    }

    private func uninstallShortcutHintObservers() {
        if let commandFlagsMonitor {
            NSEvent.removeMonitor(commandFlagsMonitor)
            self.commandFlagsMonitor = nil
        }
        if let commandKeyMonitor {
            NSEvent.removeMonitor(commandKeyMonitor)
            self.commandKeyMonitor = nil
        }
        if let appResignObserver {
            NotificationCenter.default.removeObserver(appResignObserver)
            self.appResignObserver = nil
        }
        resetShortcutHintState()
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard event.window == nil || event.window === window else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        setCommandKeyDown(flags.contains(.command) && !flags.contains(.option))
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard event.window == nil || event.window === window else { return }
        guard isCommandKeyDown || showsShortcutHints || pendingShortcutHint != nil else { return }
        resetShortcutHintState()
    }

    private func setCommandKeyDown(_ isDown: Bool) {
        guard isCommandKeyDown != isDown else { return }
        isCommandKeyDown = isDown
        pendingShortcutHint?.cancel()
        pendingShortcutHint = nil

        if isDown {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isCommandKeyDown else { return }
                self.setShortcutHintsVisible(true)
            }
            pendingShortcutHint = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300), execute: work)
        } else {
            setShortcutHintsVisible(false)
        }
    }

    private func resetShortcutHintState() {
        isCommandKeyDown = false
        pendingShortcutHint?.cancel()
        pendingShortcutHint = nil
        setShortcutHintsVisible(false)
    }

    private func setShortcutHintsVisible(_ visible: Bool) {
        guard showsShortcutHints != visible else { return }
        showsShortcutHints = visible
        for button in stripView.buttons {
            (button as? FilterChipButton)?.setShortcutHintVisible(visible)
        }
    }

    private func makeButton(title: String, index: Int, shortcutHint: String?, selected: Bool) -> NSButton {
        let button = FilterChipButton(title: title)
        button.tag = index
        button.setButtonType(.toggle)
        button.isBordered = false
        button.state = selected ? .on : .off
        button.target = self
        button.action = #selector(buttonClicked(_:))
        button.lineBreakMode = .byTruncatingTail
        button.translatesAutoresizingMaskIntoConstraints = true
        button.autoresizingMask = []
        button.applyStyle(
            accent: accentColor(for: options[index]),
            neutral: isNeutralOption(options[index]),
            selected: selected
        )
        button.setShortcutHint(shortcutHint, visible: showsShortcutHints)
        button.frame.size = NSSize(
            width: Self.buttonWidth(for: title, hasShortcutHint: shortcutHint != nil),
            height: FilterStripView.buttonHeight
        )
        return button
    }

    private func label(for option: WorkspaceFilter) -> String {
        switch option {
        case .all:
            return "ALL"
        case .project(let id):
            return id
        }
    }

    private func scrollSelectedButtonIntoView(index: Int) {
        guard index >= 0, index < stripView.buttons.count else { return }
        let button = stripView.buttons[index]
        let target = button.frame.insetBy(dx: -12, dy: 0)
        stripView.scrollToVisible(target)
    }

    private static func buttonWidth(for title: String, hasShortcutHint: Bool = false) -> CGFloat {
        let font = TermyTypography.medium()
        let textWidth = title.size(withAttributes: [.font: font]).width
        let shortcutReserve: CGFloat = hasShortcutHint ? 22 : 0
        return max(56 + shortcutReserve, ceil(textWidth + 22 + shortcutReserve))
    }

    private func accentColor(for option: WorkspaceFilter) -> NSColor {
        switch option {
        case .all:
            return NSColor.systemGray
        case .project(let id):
            return PaneStyling.accentColor(for: id, appearance: effectiveAppearance)
        }
    }

    private func isNeutralOption(_ option: WorkspaceFilter) -> Bool {
        if case .all = option { return true }
        return false
    }
}

enum ProjectFilterLayout {
    static let minimumButtonWidth: CGFloat = 48

    static func leadingInset(contentWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        guard viewportWidth > contentWidth else { return 0 }
        return floor((viewportWidth - contentWidth) / 2)
    }

    static func documentWidth(contentWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        max(contentWidth, viewportWidth)
    }

    static func buttonWidths(
        naturalWidths: [CGFloat],
        spacing: CGFloat,
        viewportWidth: CGFloat,
        minimumWidth: CGFloat = minimumButtonWidth
    ) -> [CGFloat] {
        guard !naturalWidths.isEmpty else { return [] }
        let totalSpacing = CGFloat(max(0, naturalWidths.count - 1)) * spacing
        let naturalContentWidth = naturalWidths.reduce(0, +) + totalSpacing
        guard viewportWidth > totalSpacing, naturalContentWidth > viewportWidth else {
            return naturalWidths
        }

        let availableButtonWidth = viewportWidth - totalSpacing
        let equalWidth = floor(availableButtonWidth / CGFloat(naturalWidths.count))
        guard equalWidth >= minimumWidth else {
            return naturalWidths.map { min($0, minimumWidth) }
        }
        return naturalWidths.map { min($0, equalWidth) }
    }
}

private final class FilterStripView: NSView {
    static let buttonHeight: CGFloat = 24
    static let underlineHeight: CGFloat = 2
    /// Breathing room between the chip's bottom edge and the underline so the
    /// bar reads as a separate indicator rather than a seam of the chip fill.
    static let underlineGap: CGFloat = 2

    private let spacing: CGFloat = 6
    var viewportHeight: CGFloat = 28 {
        didSet {
            guard abs(oldValue - viewportHeight) > 0.5 else { return }
            needsLayout = true
        }
    }
    var viewportWidth: CGFloat = 0 {
        didSet {
            guard abs(oldValue - viewportWidth) > 0.5 else { return }
            needsLayout = true
        }
    }

    private(set) var buttons: [NSButton] = []
    private var naturalButtonWidths: [CGFloat] = []
    /// Sibling views, one per button, painted over each chip's bottom edge
    /// when the chip is the active filter. They live in the strip (not in
    /// the chip) so the chip's `cornerRadius`+`masksToBounds` mask doesn't
    /// clip them down to a hair-width sliver at the rounded corners.
    private var underlines: [NSView] = []

    /// Index of the first chip the user may drag. Chips before it — the ALL
    /// filter, when present — stay pinned to the leading edge.
    var firstMovableIndex = 0
    /// Reports a settled reorder as (from, to) indices into `buttons`.
    var onReorder: ((Int, Int) -> Void)?
    /// Non-nil only while a chip is being dragged. Doubles as the flag that
    /// suspends `layout()`.
    private var draggingButton: NSButton?
    /// Bumped on every `setButtons`. A drag captures the value it started
    /// with so it can tell that the chips underneath it were replaced.
    private var buttonsGeneration = 0
    /// Pointer travel that separates a filter click from a reorder drag.
    private static let dragThreshold: CGFloat = 4
    private static let dragSettleDuration: TimeInterval = 0.14

    override var isFlipped: Bool { true }

    // The strip is the deepest hit-test target between the chips, so this
    // is what AppKit consults when deciding whether a click in empty space
    // should drag the window.
    override var mouseDownCanMoveWindow: Bool { true }

    func setButtons(_ newButtons: [NSButton]) {
        buttonsGeneration &+= 1
        // Drop the drag's hold on `layout()` right away; the tracking loop
        // notices the generation bump on its next tick and unwinds the rest.
        draggingButton = nil
        buttons.forEach { $0.removeFromSuperview() }
        underlines.forEach { $0.removeFromSuperview() }
        buttons = newButtons
        naturalButtonWidths = newButtons.map(\.frame.width)
        underlines = newButtons.map { _ in Self.makeUnderlineView() }
        // Add buttons first so underlines sit above them in z-order — the
        // 2pt bar visually replaces the chip's rounded bottom corners with a
        // flat tab indicator.
        buttons.forEach(addSubview)
        underlines.forEach(addSubview)
        updateDocumentFrame()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private static func makeUnderlineView() -> NSView {
        let v = NSView(frame: .zero)
        v.wantsLayer = true
        v.isHidden = true
        return v
    }

    override func layout() {
        super.layout()
        // A drag owns every chip frame until it settles; re-running the
        // slot layout mid-drag would yank the chip out from under the cursor.
        guard draggingButton == nil else { return }

        let widths = laidOutWidths()
        var x = contentStartX(widths: widths)
        let y = chipY()

        for (index, button) in buttons.enumerated() {
            let width = widths[index]
            let frame = NSRect(x: x, y: y, width: width, height: Self.buttonHeight)
            button.frame = frame

            let underline = underlines[index]
            underline.frame = underlineFrame(chipFrame: frame)
            if let chip = button as? FilterChipButton, let color = chip.activeUnderlineColor {
                underline.layer?.backgroundColor = color.cgColor
                underline.isHidden = false
            } else {
                underline.isHidden = true
            }

            x += width + spacing
        }

        updateDocumentFrame(totalWidth: contentWidth(of: widths))
    }

    // MARK: - Slot geometry

    private func laidOutWidths() -> [CGFloat] {
        ProjectFilterLayout.buttonWidths(
            naturalWidths: naturalButtonWidths,
            spacing: spacing,
            viewportWidth: viewportWidth
        )
    }

    private func contentWidth(of widths: [CGFloat]) -> CGFloat {
        widths.reduce(CGFloat(0), +) + CGFloat(max(0, widths.count - 1)) * spacing
    }

    private func contentStartX(widths: [CGFloat]) -> CGFloat {
        ProjectFilterLayout.leadingInset(
            contentWidth: contentWidth(of: widths),
            viewportWidth: viewportWidth
        )
    }

    private func chipY() -> CGFloat {
        let stackHeight = Self.buttonHeight + Self.underlineGap + Self.underlineHeight
        return max(0, floor((viewportHeight - stackHeight) / 2))
    }

    /// Strip is `isFlipped = true`, so larger y = visually lower. Sit the bar
    /// `underlineGap` below the chip so it reads as its own indicator, not a
    /// stripe of the chip fill. The bar is 80% of the chip width, centered —
    /// narrower than the chip so it reads as an accent tick, not a second
    /// border.
    private func underlineFrame(chipFrame: NSRect) -> NSRect {
        let underlineWidth = floor(chipFrame.width * 0.8)
        return NSRect(
            x: chipFrame.minX + floor((chipFrame.width - underlineWidth) / 2),
            y: chipFrame.minY + Self.buttonHeight + Self.underlineGap,
            width: underlineWidth,
            height: Self.underlineHeight
        )
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: contentWidth(of: laidOutWidths()), height: viewportHeight)
    }

    // MARK: - Drag to reorder

    /// Owns the whole mouse-down..mouse-up cycle for a chip. Below the drag
    /// threshold it forwards a plain click, so a tap still switches filters;
    /// past it the chip detaches and the rest of the strip opens a slot.
    /// Tracking the events ourselves (rather than letting NSButton handle
    /// mouseDown) is what keeps those two gestures from eating each other.
    func handleMouseDown(on button: NSButton, with event: NSEvent) {
        guard let window,
              let index = buttons.firstIndex(where: { $0 === button })
        else { return }

        // `min` keeps the range valid if a stale `firstMovableIndex` outruns a
        // freshly shortened chip list.
        let movable = min(firstMovableIndex, buttons.count)..<buttons.count
        guard movable.contains(index), movable.count > 1 else {
            button.performClick(nil)
            return
        }

        let widths = buttons.map(\.frame.width)
        let downInStrip = convert(event.locationInWindow, from: nil)
        let grabOffsetX = downInStrip.x - button.frame.minX
        let generation = buttonsGeneration
        var order = Array(buttons.indices)
        var started = false
        var location = event.locationInWindow

        // Timeout ticks drive edge auto-scroll while the pointer sits still
        // against the end of a strip that's wider than its viewport.
        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: 1.0 / 60.0,
            mode: .eventTracking
        ) { trackedEvent, stop in
            if let trackedEvent {
                location = trackedEvent.locationInWindow
            }

            // An agent state change (pane opened, `cd`, header relabel) can
            // rebuild the strip mid-drag, which replaces every chip. The
            // indices we captured no longer address the same buttons, so
            // abandon rather than reorder — or index — by stale index. This
            // has to come before the mouse-up branch, which does both.
            guard generation == self.buttonsGeneration else {
                stop.pointee = true
                self.cancelDrag(wasDragging: started)
                return
            }

            if trackedEvent?.type == .leftMouseUp {
                stop.pointee = true
                if started {
                    self.finishDrag(index: index, order: order, widths: widths)
                } else {
                    button.performClick(nil)
                }
                return
            }

            if !started {
                let travel = abs(self.convert(location, from: nil).x - downInStrip.x)
                guard travel > Self.dragThreshold else { return }
                started = true
                self.beginDrag(button: button, at: index)
            }

            self.autoscroll(towards: location)
            order = self.updateDrag(
                index: index,
                pointerX: self.convert(location, from: nil).x,
                grabOffsetX: grabOffsetX,
                order: order,
                widths: widths
            )
        }
    }

    private func beginDrag(button: NSButton, at index: Int) {
        draggingButton = button
        // Lift the chip and its underline above the siblings they slide past.
        // No layer shadow here: the chip clips its title to the pill with
        // `masksToBounds`, which would clip the shadow away too, and turning
        // the mask off lets a truncated label bleed past the chip's edges.
        addSubview(button, positioned: .above, relativeTo: nil)
        addSubview(underlines[index], positioned: .above, relativeTo: nil)
        button.alphaValue = 0.9
        NSCursor.closedHand.push()
    }

    /// Abandon an in-flight drag without reordering, restoring the chips to
    /// whatever the current layout says.
    private func cancelDrag(wasDragging: Bool) {
        guard wasDragging else { return }
        draggingButton?.alphaValue = 1
        draggingButton = nil
        NSCursor.pop()
        needsLayout = true
    }

    /// Follows the pointer with the dragged chip and, when its center crosses
    /// a neighbour's, slides the rest into the arrangement that would result.
    /// Returns the (possibly new) chip order.
    private func updateDrag(
        index: Int,
        pointerX: CGFloat,
        grabOffsetX: CGFloat,
        order: [Int],
        widths: [CGFloat]
    ) -> [Int] {
        let startX = contentStartX(widths: widths)
        let width = widths[index]

        // The dragged chip stays inside the movable span: it can't be pushed
        // ahead of a pinned chip, nor past the trailing edge of the strip.
        let pinnedWidth = widths[0..<firstMovableIndex]
            .reduce(CGFloat(0)) { $0 + $1 + spacing }
        let lowerBound = startX + pinnedWidth
        let upperBound = startX + contentWidth(of: widths) - width
        let x = min(max(pointerX - grabOffsetX, lowerBound), max(lowerBound, upperBound))

        let frame = NSRect(x: x, y: chipY(), width: width, height: Self.buttonHeight)
        buttons[index].frame = frame
        underlines[index].frame = underlineFrame(chipFrame: frame)

        let others = order.filter { $0 != index }
        var origins: [CGFloat] = []
        var slotX = startX
        for other in others {
            origins.append(slotX)
            slotX += widths[other] + spacing
        }
        let insertion = ProjectOrder.insertionIndex(
            draggedCenterX: frame.midX,
            otherOrigins: origins,
            otherWidths: others.map { widths[$0] },
            firstMovable: firstMovableIndex
        )

        var reordered = others
        reordered.insert(index, at: insertion)
        guard reordered != order else { return order }

        layoutSlots(order: reordered, widths: widths, skipping: index, animated: true)
        return reordered
    }

    private func finishDrag(index: Int, order: [Int], widths: [CGFloat]) {
        buttons[index].alphaValue = 1
        NSCursor.pop()

        let destination = order.firstIndex(of: index) ?? index
        // Let the chip settle into its slot before handing the new order up —
        // the callback rebuilds the whole strip, which would cut the animation.
        // `draggingButton` stays set until then so `layout()` doesn't reclaim
        // the frames mid-settle.
        layoutSlots(order: order, widths: widths, skipping: nil, animated: true) {
            self.draggingButton = nil
            guard destination != index else { return }
            self.onReorder?(index, destination)
        }
    }

    private func layoutSlots(
        order: [Int],
        widths: [CGFloat],
        skipping: Int?,
        animated: Bool,
        completion: (() -> Void)? = nil
    ) {
        var x = contentStartX(widths: widths)
        let y = chipY()
        var targets: [(index: Int, frame: NSRect)] = []
        for index in order {
            let width = widths[index]
            if index != skipping {
                targets.append((index, NSRect(x: x, y: y, width: width, height: Self.buttonHeight)))
            }
            x += width + spacing
        }

        guard animated else {
            for target in targets {
                buttons[target.index].frame = target.frame
                underlines[target.index].frame = underlineFrame(chipFrame: target.frame)
            }
            completion?()
            return
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.dragSettleDuration
            ctx.allowsImplicitAnimation = true
            for target in targets {
                buttons[target.index].animator().frame = target.frame
                underlines[target.index].animator().frame = underlineFrame(chipFrame: target.frame)
            }
        }, completionHandler: completion)
    }

    /// Scrolls the strip when the pointer nears a viewport edge, so a chip can
    /// be dragged past the chips currently scrolled out of sight.
    private func autoscroll(towards locationInWindow: NSPoint) {
        guard let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        let point = clip.convert(locationInWindow, from: nil)
        let edge: CGFloat = 24
        let step: CGFloat = 8

        let delta: CGFloat
        if point.x < clip.bounds.minX + edge {
            delta = -step
        } else if point.x > clip.bounds.maxX - edge {
            delta = step
        } else {
            return
        }

        let maxOriginX = max(0, frame.width - clip.bounds.width)
        let originX = min(max(0, clip.bounds.origin.x + delta), maxOriginX)
        guard abs(originX - clip.bounds.origin.x) > 0.01 else { return }
        clip.scroll(to: NSPoint(x: originX, y: clip.bounds.origin.y))
        scrollView.reflectScrolledClipView(clip)
    }

    private func updateDocumentFrame(totalWidth: CGFloat? = nil) {
        let contentWidth = totalWidth ?? {
            let widths = ProjectFilterLayout.buttonWidths(
                naturalWidths: naturalButtonWidths,
                spacing: spacing,
                viewportWidth: viewportWidth
            )
            return widths.reduce(CGFloat(0), +)
                + CGFloat(max(0, widths.count - 1)) * spacing
        }()
        let width = ProjectFilterLayout.documentWidth(
            contentWidth: contentWidth,
            viewportWidth: viewportWidth
        )
        let target = NSRect(x: 0, y: 0, width: width, height: viewportHeight)
        if frame != target {
            frame = target
        }
    }
}

private final class FilterChipButton: NSButton {
    /// Color FilterStripView paints the sibling underline with — non-nil
    /// only while this chip is the active filter. Lives on the chip (not
    /// the strip) because `applyStyle` is the single source of truth for
    /// per-chip styling decisions.
    private(set) var activeUnderlineColor: NSColor?
    private let shortcutHintBadge = ShortcutHintBadge()
    private var shortcutHint: String?

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        wantsLayer = true
        layer?.cornerRadius = 6
        // Clip the title to the rounded-rect shape so narrow chips truncate
        // the label inside the pill instead of bleeding text past both edges.
        layer?.masksToBounds = true
        imagePosition = .imageOnly
        focusRingType = .none
        shortcutHintBadge.isHidden = true
        addSubview(shortcutHintBadge)
    }

    required init?(coder: NSCoder) { fatalError() }

    // Hand the gesture to the strip, which owns click-vs-reorder-drag for the
    // whole row. Letting NSButton run its own mouse-down tracking here would
    // swallow the drag before the strip ever sees it.
    override func mouseDown(with event: NSEvent) {
        guard let strip = superview as? FilterStripView else {
            super.mouseDown(with: event)
            return
        }
        strip.handleMouseDown(on: self, with: event)
    }

    override func layout() {
        super.layout()
        let width: CGFloat = 15
        let height: CGFloat = 14
        shortcutHintBadge.frame = NSRect(
            x: 5,
            y: floor((bounds.height - height) / 2),
            width: width,
            height: height
        )
        addSubview(shortcutHintBadge, positioned: .above, relativeTo: nil)
    }

    func applyStyle(accent: NSColor, neutral: Bool, selected: Bool) {
        let fontWeight: NSFont.Weight = selected ? .semibold : .medium
        // Paragraph style is required for attributedTitle to respect
        // lineBreakMode; without it NSButton's cell-level mode is ignored.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .center
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: TermyTypography.font(weight: fontWeight),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        )
        // Unselected project pill matches the pane header tint so a pane and
        // its filter pill read as the same visual family. Selected pill is a
        // half-step brighter to call out the active filter.
        let unselected = PaneStyling.theme(for: effectiveAppearance).headerTintAlpha
        let selectedAlpha = min(0.95, unselected + 0.16)
        let fillAlpha: CGFloat = neutral
            ? (selected ? selectedAlpha : unselected)
            : (selected ? selectedAlpha : unselected)
        let borderAlpha: CGFloat = neutral
            ? (selected ? 0.82 : 0.50)
            : (selected ? 0.70 : 0.45)
        layer?.backgroundColor = accent.withAlphaComponent(fillAlpha).cgColor
        layer?.borderColor = accent.withAlphaComponent(borderAlpha).cgColor
        layer?.borderWidth = 1
        activeUnderlineColor = selected ? accent.withAlphaComponent(0.95) : nil
    }

    func setShortcutHint(_ hint: String?, visible: Bool) {
        shortcutHint = hint
        shortcutHintBadge.text = hint ?? ""
        setShortcutHintVisible(visible)
    }

    func setShortcutHintVisible(_ visible: Bool) {
        shortcutHintBadge.isHidden = !visible || shortcutHint == nil
    }
}

private final class ShortcutHintBadge: NSView {
    private let label = NSTextField(labelWithString: "")
    private var strokeColor = NSColor(white: 0, alpha: 0.22)

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        strokeColor.setStroke()
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 4,
            yRadius: 4
        )
        path.lineWidth = 1
        path.fill()
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        switch PaneStyling.variant(for: effectiveAppearance) {
        case .dark:
            strokeColor = NSColor(white: 1, alpha: 0.52)
            label.textColor = NSColor(white: 0, alpha: 0.84)
        case .light:
            strokeColor = NSColor(white: 0, alpha: 0.22)
            label.textColor = NSColor(white: 0, alpha: 0.72)
        }
        needsDisplay = true
    }
}
