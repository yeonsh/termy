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
        scrollView.documentView = stripView
        stripView.frame = NSRect(x: 0, y: 0, width: 0, height: 28)

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
        stripView.viewportHeight = bounds.height > 0 ? bounds.height : 28

        DispatchQueue.main.async { [weak self] in
            self?.scrollSelectedButtonIntoView(index: selectedIndex)
        }
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

    override var isFlipped: Bool { true }

    func setButtons(_ newButtons: [NSButton]) {
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
        let widths = ProjectFilterLayout.buttonWidths(
            naturalWidths: naturalButtonWidths,
            spacing: spacing,
            viewportWidth: viewportWidth
        )
        let totalWidth = widths.reduce(CGFloat(0), +)
            + CGFloat(max(0, widths.count - 1)) * spacing
        var x = ProjectFilterLayout.leadingInset(
            contentWidth: totalWidth,
            viewportWidth: viewportWidth
        )
        let stackHeight = Self.buttonHeight + Self.underlineGap + Self.underlineHeight
        let y = max(0, floor((viewportHeight - stackHeight) / 2))

        for (index, button) in buttons.enumerated() {
            let width = widths[index]
            button.frame = NSRect(x: x, y: y, width: width, height: Self.buttonHeight)

            let underline = underlines[index]
            // Strip is `isFlipped = true`, so larger y = visually lower.
            // Sit the bar `underlineGap` below the chip so it reads as its
            // own indicator, not a stripe of the chip fill. The bar is 80%
            // of the chip width, centered — narrower than the chip so it
            // reads as an accent tick, not a second border.
            let underlineWidth = floor(width * 0.8)
            underline.frame = NSRect(
                x: x + floor((width - underlineWidth) / 2),
                y: y + Self.buttonHeight + Self.underlineGap,
                width: underlineWidth,
                height: Self.underlineHeight
            )
            if let chip = button as? FilterChipButton, let color = chip.activeUnderlineColor {
                underline.layer?.backgroundColor = color.cgColor
                underline.isHidden = false
            } else {
                underline.isHidden = true
            }

            x += width + spacing
        }

        updateDocumentFrame(totalWidth: totalWidth)
    }

    override var intrinsicContentSize: NSSize {
        let widths = ProjectFilterLayout.buttonWidths(
            naturalWidths: naturalButtonWidths,
            spacing: spacing,
            viewportWidth: viewportWidth
        )
        let totalWidth = widths.reduce(CGFloat(0), +)
            + CGFloat(max(0, widths.count - 1)) * spacing
        return NSSize(width: totalWidth, height: viewportHeight)
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
