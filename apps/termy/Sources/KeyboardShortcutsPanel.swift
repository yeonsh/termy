// KeyboardShortcutsPanel.swift
//
// ⌘/ overlay listing every termy keyboard chord in one place. Addresses
// the /autoplan DX phase finding "keyboard grammar is hidden." Each key
// renders as its own pill (matching the dashboard's empty-state hint
// styling) rather than a flat monospace string, so `⌘⇧D` reads as three
// distinct caps instead of one blob.
//
// Interaction:
//   ⌘/       toggle
//   ⎋        close
//   click    close (anywhere inside the panel)

import AppKit

@MainActor
final class KeyboardShortcutsPanel: NSPanel {

    struct Shortcut {
        /// Each inner array is one chord sequence — e.g. `["⌘", "⇧", "D"]`.
        /// Multiple chords in the outer array render as `chord₁ / chord₂`
        /// (previous / next style pairs).
        let combos: [[String]]
        let description: String
    }

    struct Section {
        let title: String
        let entries: [Shortcut]
    }

    static let sections: [Section] = [
        Section(title: "Panes", entries: [
            Shortcut(combos: [["⌘", "N"]], description: "New pane"),
            Shortcut(combos: [["⌘", "D"]], description: "Split horizontally (add to same row)"),
            Shortcut(combos: [["⌘", "⇧", "D"]], description: "Split vertically (new row)"),
            Shortcut(combos: [["⌘", "W"]], description: "Close focused pane"),
            Shortcut(combos: [["⌘", "↵"]], description: "Toggle maximize / restore")
        ]),
        Section(title: "Focus", entries: [
            Shortcut(combos: [["⌘", "["], ["⌘", "]"]], description: "Previous / next pane"),
            // Four chords (⌘⌥ + each arrow) don't fit the fixed combo column;
            // use the `arrows` sentinel to render a 2x2 arrow keycap grid.
            Shortcut(
                combos: [["⌘", "⌥", "arrows"]],
                description: "Focus pane in direction"
            ),
            Shortcut(combos: [["⌘", "G"]], description: "Jump to next WAITING pane"),
            Shortcut(combos: [["⌘", "⌥", "1–9"]], description: "Jump to dashboard item N")
        ]),
        Section(title: "Projects", entries: [
            Shortcut(combos: [["⌘", "K"]], description: "Switch project (fuzzy search)"),
            Shortcut(combos: [["⌘", "⇧", "["], ["⌘", "⇧", "]"]], description: "Previous / next project filter"),
            Shortcut(combos: [["⌘", "0"]], description: "Show all panes"),
            Shortcut(combos: [["⌘", "1–9"]], description: "Jump to project filter N")
        ]),
        Section(title: "Appearance", entries: [
            Shortcut(combos: [["⌘", "⇧", "T"]], description: "Cycle theme (System → Light → Dark)")
        ]),
        Section(title: "Window", entries: [
            Shortcut(combos: [["⌘", "M"]], description: "Minimize"),
            Shortcut(combos: [["⌘", "⇧", "W"]], description: "Close window"),
            Shortcut(combos: [["⌘", "Q"]], description: "Quit termy")
        ]),
        Section(title: "Help", entries: [
            Shortcut(combos: [["⌘", ","]], description: "Terminal font settings"),
            Shortcut(combos: [["⌘", "/"]], description: "This shortcut overlay")
        ])
    ]

    // MARK: - Init

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        hidesOnDeactivate = true
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .modalPanel

        let themedContent = AppearanceAwareView(
            frame: NSRect(origin: .zero, size: contentRect(forFrameRect: frame).size)
        )
        themedContent.autoresizingMask = [.width, .height]
        themedContent.wantsLayer = true
        contentView = themedContent
        themedContent.onAppearanceChange = { [weak self] _ in
            self?.applyTheme()
        }
        setupContent()
        applyTheme()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Entry points

    func toggle(over host: NSWindow?) {
        if isVisible {
            close()
            return
        }
        if let host {
            let hf = host.frame
            let size = frame.size
            setFrameOrigin(NSPoint(
                x: hf.midX - size.width / 2,
                y: hf.midY - size.height / 2 + 40
            ))
        } else {
            center()
        }
        makeKeyAndOrderFront(nil)
    }

    // MARK: - Content

    private func setupContent() {
        guard let content = contentView else { return }
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 1

        let header = NSTextField(labelWithString: "Keyboard shortcuts")
        header.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        header.textColor = .labelColor
        header.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "⎋ or click anywhere to close")
        hint.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .right
        hint.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 18
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for section in Self.sections {
            stack.addArrangedSubview(makeSectionView(section))
        }

        let scrollView = NSScrollView()
        scrollView.documentView = stack
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(header)
        content.addSubview(hint)
        content.addSubview(separator)
        content.addSubview(scrollView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),

            hint.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: header.trailingAnchor, constant: 12),

            separator.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])
    }

    private func makeSectionView(_ section: Section) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6
        container.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: section.title.uppercased())
        title.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        title.textColor = .tertiaryLabelColor
        container.addArrangedSubview(title)

        for entry in section.entries {
            container.addArrangedSubview(makeShortcutRow(entry))
        }
        return container
    }

    private func makeShortcutRow(_ entry: Shortcut) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false

        let combosView = makeCombosView(entry.combos)
        // Fixed-width left column keeps descriptions aligned across rows.
        combosView.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let desc = NSTextField(labelWithString: entry.description)
        desc.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        desc.textColor = .labelColor
        desc.lineBreakMode = .byTruncatingTail

        row.addArrangedSubview(combosView)
        row.addArrangedSubview(desc)
        return row
    }

    /// Horizontal stack: chord₁'s caps, optional "/", chord₂'s caps, ...
    private func makeCombosView(_ combos: [[String]]) -> NSView {
        let outer = NSStackView()
        outer.orientation = .horizontal
        outer.alignment = .centerY
        outer.spacing = 6
        outer.translatesAutoresizingMaskIntoConstraints = false

        for (idx, combo) in combos.enumerated() {
            if idx > 0 {
                let slash = NSTextField(labelWithString: "/")
                slash.font = NSFont.systemFont(ofSize: 11, weight: .regular)
                slash.textColor = .tertiaryLabelColor
                outer.addArrangedSubview(slash)
            }
            let comboStack = NSStackView()
            comboStack.orientation = .horizontal
            comboStack.alignment = .centerY
            comboStack.spacing = 3
            for key in combo {
                if key == "arrows" {
                    comboStack.addArrangedSubview(ArrowClusterView())
                } else {
                    comboStack.addArrangedSubview(KeyCapView(key: key))
                }
            }
            outer.addArrangedSubview(comboStack)
        }
        return outer
    }

    // MARK: - Dismissal

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            close()
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        close()
    }

    private func applyTheme() {
        let theme = PaneStyling.theme(for: effectiveAppearance)
        contentView?.layer?.backgroundColor = theme.panelBackgroundColor.cgColor
        contentView?.layer?.borderColor = theme.panelBorderColor.cgColor
    }
}

// MARK: - Key cap

/// Single rounded pill representing one key. Matches the
/// `MissionControlView.KeyHint` dashboard treatment so both surfaces read
/// as the same visual vocabulary.
private final class KeyCapView: NSView {
    init(key: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        layer?.borderWidth = 1

        let label = NSTextField(labelWithString: key)
        // System font, not SF Mono: SF Mono lacks the arrow glyphs (←→↑↓)
        // and renders them as blank pills.
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 18)
        ])
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        switch PaneStyling.variant(for: effectiveAppearance) {
        case .dark:
            layer?.backgroundColor = NSColor(white: 1, alpha: 0.14).cgColor
            layer?.borderColor = NSColor(white: 1, alpha: 0.32).cgColor
        case .light:
            layer?.backgroundColor = NSColor(white: 0, alpha: 0.06).cgColor
            layer?.borderColor = NSColor(white: 0, alpha: 0.14).cgColor
        }
    }
}

// MARK: - Arrow cluster (2x2 grid of arrow keycaps)

/// Renders the four arrow keys in a 2x2 grid — horizontal pair on top,
/// vertical pair on bottom — so "⌘⌥ + any arrow" fits the combo column
/// without the four chords overflowing into one long row.
private final class ArrowClusterView: NSView {
    init() {
        super.init(frame: .zero)
        // Clockwise from top-left: → ↓ ← ↑.
        let top = NSStackView(views: [KeyCapView(key: "→"), KeyCapView(key: "↓")])
        top.orientation = .horizontal
        top.spacing = 2
        let bottom = NSStackView(views: [KeyCapView(key: "↑"), KeyCapView(key: "←")])
        bottom.orientation = .horizontal
        bottom.spacing = 2

        let grid = NSStackView(views: [top, bottom])
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 2
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
}
