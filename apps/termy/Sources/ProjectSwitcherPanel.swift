// ProjectSwitcherPanel.swift
//
// ⌘K command palette over persisted workspaces. Floating NSPanel with a
// search field on top and a table of matching projects below. Fuzzy match
// is a subsequence scorer (FuzzyMatch.score) — typing `api` surfaces
// `my-api`, `api-legacy`, and `apis` ranked by how tight the run is.
//
// Interaction grammar (per /autoplan Design phase D4–D7):
//   ⌘K            show / toggle
//   type          refilter (live)
//   ↑ / ↓         move selection
//   ⏎             pick → callback to MainWindowController
//   ⎋            close without picking
//   ⌘K again      close (if open with empty query — keeps user muscle
//                 memory from "⌘K is my return-to-work reflex")
//
// Row spec (D2): project label (primary, bold) + path tail (secondary,
// dim) + pane count + last-used (right-aligned, tabular). `⌘K` panel is
// scoped to SAVED workspaces only; the filter bar handles alive projects.
//
// Accessibility: each row gets a single-line VoiceOver label that
// concatenates every visible cell; the empty state has its own role.
// Reduced-motion support is inherent — this panel has no transitions.

import AppKit
import Foundation

@MainActor
final class ProjectSwitcherPanel: NSPanel {

    /// Fired when the user picks a row. Panel hides itself before invoking.
    var onPick: ((WorkspaceRecord) -> Void)?

    // Plain NSTextField instead of NSSearchField: the bezel-less NSSearchField
    // draws a magnifier glyph inside the cell's text rect, which overlaps the
    // placeholder. We re-add the magnifier manually (below) as a separate
    // NSImageView so text starts past it instead of on top of it.
    private let searchField = NSTextField()
    private let searchIcon = NSImageView()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let searchDelegate = SearchDelegate()

    private var records: [WorkspaceRecord] = []
    private var filteredIndices: [Int] = []   // index into `records`
    private let nowForDisplay = Date()

    // MARK: - Init

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        hidesOnDeactivate = true
        isMovableByWindowBackground = true
        // Borderless + layer-backed contentView gives us a proper
        // rounded-card appearance instead of a stubbed-out system titlebar.
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

    // MARK: - Public entry points

    /// Present over the given window with a freshly-loaded set of records.
    /// Clears the search field so every use starts from "show everything."
    func present(records: [WorkspaceRecord], over host: NSWindow?) {
        self.records = records
        searchField.stringValue = ""
        refilter()
        if filteredIndices.isEmpty == false {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        if let host {
            let hostFrame = host.frame
            let panelSize = frame.size
            let origin = NSPoint(
                x: hostFrame.midX - panelSize.width / 2,
                y: hostFrame.midY - panelSize.height / 2 + 80   // float a touch above center
            )
            setFrameOrigin(origin)
        } else {
            center()
        }
        makeKeyAndOrderFront(nil)
        searchField.becomeFirstResponder()
    }

    /// Toggle behavior for the ⌘K reflex: if already visible with no query,
    /// close; otherwise (re)present.
    func toggle(records: [WorkspaceRecord], over host: NSWindow?) {
        if isVisible && searchField.stringValue.isEmpty {
            close()
        } else {
            present(records: records, over: host)
        }
    }

    // MARK: - Content

    private func setupContent() {
        guard let content = contentView else { return }

        // Card appearance: rounded corners, thin accent border, subtle fill
        // so rows read as pressed into a surface instead of floating on air.
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 1

        searchField.font = NSFont.systemFont(ofSize: 18, weight: .regular)
        searchField.focusRingType = .none
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.isBordered = false
        searchField.textColor = .labelColor
        searchField.translatesAutoresizingMaskIntoConstraints = false
        // Attributed placeholder keeps the hint legible in both appearances.
        let placeholderAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.placeholderTextColor,
            .font: NSFont.systemFont(ofSize: 18, weight: .regular)
        ]
        searchField.placeholderAttributedString = NSAttributedString(
            string: "Type a project name…",
            attributes: placeholderAttrs
        )
        searchDelegate.owner = self
        searchField.delegate = searchDelegate

        // Standalone magnifier glyph so the text field's text rect is free
        // of any cell-drawn icon. SF Symbol falls back to a bundled glyph
        // if unavailable on older macOS.
        let magnifier = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
            ?? NSImage(named: NSImage.advancedName)
        searchIcon.image = magnifier
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.imageScaling = .scaleProportionallyUpOrDown
        searchIcon.translatesAutoresizingMaskIntoConstraints = false

        // Thin separator between the search field and the results list so the
        // two regions read as distinct even when the list is scrolled tight.
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("project"))
        column.resizingMask = .autoresizingMask
        column.width = 540
        tableView.headerView = nil
        tableView.addTableColumn(column)
        tableView.rowHeight = 48
        tableView.backgroundColor = .clear
        // .regular keeps AppKit calling drawSelection on row views; .none would
        // skip it entirely and the SelectableRowView highlight would never paint.
        tableView.selectionHighlightStyle = .regular
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // Overlay scroller lets row content extend the full width; the
        // scroller only appears during active scrolling and fades out.
        // Prevents the constant-visible legacy scroller from eating the
        // right-side "N mins ago" column.
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true

        emptyLabel.stringValue = """
            Nothing saved yet.

            termy remembers a project the first time you run `claude` in it.
            Open a folder, run your agent, and it'll show up here next time you
            hit ⌘K — even after a quit. Your panes, sizes, and last command
            are restored too.
            """
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = NSFont.systemFont(ofSize: 13)
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(searchIcon)
        content.addSubview(searchField)
        content.addSubview(separator)
        content.addSubview(scrollView)
        content.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            searchIcon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            // The magnifier glyph's visual weight sits below its bounding box
            // center, so mathematical centering reads as a slight downward
            // drift. Nudge up 2pt for optical balance against the text.
            searchIcon.centerYAnchor.constraint(equalTo: searchField.centerYAnchor, constant: -2),
            searchIcon.widthAnchor.constraint(equalToConstant: 16),
            searchIcon.heightAnchor.constraint(equalToConstant: 16),

            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            searchField.heightAnchor.constraint(equalToConstant: 32),

            separator.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),

            emptyLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 40),
            emptyLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -40),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])
    }

    private func applyTheme() {
        let theme = PaneStyling.theme(for: effectiveAppearance)
        contentView?.layer?.backgroundColor = theme.panelBackgroundColor.cgColor
        contentView?.layer?.borderColor = theme.panelBorderColor.cgColor
    }

    // MARK: - Filter / sort

    private func refilter() {
        let query = searchField.stringValue
        var ranked: [(score: Int, index: Int)] = []
        for (i, rec) in records.enumerated() {
            // Match against project label first (primary), fall back to path
            // tail so users can find a repo by typing the parent dir name.
            let label = rec.displayLabel
            let tail = (rec.canonicalPath as NSString).lastPathComponent
            if let s1 = FuzzyMatch.score(query: query, text: label) {
                ranked.append((s1, i))
            } else if let s2 = FuzzyMatch.score(query: query, text: rec.canonicalPath) {
                // Path match gets a penalty so label matches always sort first.
                ranked.append((s2 + 1000, i))
            } else {
                _ = tail // unused; kept for potential future weighting.
            }
        }
        // Secondary sort: most-recently-used first within same score.
        ranked.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            return records[lhs.index].updatedAt > records[rhs.index].updatedAt
        }
        filteredIndices = ranked.map(\.index)

        emptyLabel.isHidden = !records.isEmpty || !query.isEmpty
        scrollView.isHidden = records.isEmpty && query.isEmpty
        tableView.reloadData()
        if !filteredIndices.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    // MARK: - Picking

    @objc private func handleDoubleClick() {
        commitSelection()
    }

    fileprivate func commitSelection() {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredIndices.count else { return }
        let record = records[filteredIndices[row]]
        close()
        onPick?(record)
    }

    fileprivate func moveSelection(delta: Int) {
        let count = filteredIndices.count
        guard count > 0 else { return }
        var next = tableView.selectedRow + delta
        if next < 0 { next = 0 }
        if next >= count { next = count - 1 }
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    fileprivate func cancelAndClose() {
        close()
    }

    // MARK: - Search field delegate (shuttle class)

    private final class SearchDelegate: NSObject, NSSearchFieldDelegate {
        weak var owner: ProjectSwitcherPanel?

        func controlTextDidChange(_ obj: Notification) {
            owner?.refilter()
        }

        /// Keyboard handling: arrows move selection, Enter commits, Esc closes.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let owner else { return false }
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                owner.moveSelection(delta: -1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                owner.moveSelection(delta: 1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                owner.commitSelection()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                owner.cancelAndClose()
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - NSTableView plumbing

extension ProjectSwitcherPanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredIndices.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let record = records[filteredIndices[row]]
        let cell = ProjectSwitcherRowView()
        cell.configure(record: record, now: nowForDisplay)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SelectableRowView()
    }
}

// MARK: - Row view

private final class ProjectSwitcherRowView: NSTableCellView {
    private let labelField = NSTextField(labelWithString: "")
    private let pathField = NSTextField(labelWithString: "")
    private let paneCountField = NSTextField(labelWithString: "")
    private let lastUsedField = NSTextField(labelWithString: "")
    private static let dateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        labelField.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        labelField.textColor = .labelColor
        pathField.font = NSFont.systemFont(ofSize: 12)
        pathField.textColor = .secondaryLabelColor
        pathField.lineBreakMode = .byTruncatingMiddle
        paneCountField.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        paneCountField.textColor = .secondaryLabelColor
        // Shrink pane count horizontally before clipping the timestamp
        paneCountField.lineBreakMode = .byClipping
        paneCountField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        paneCountField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        lastUsedField.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        lastUsedField.textColor = .tertiaryLabelColor
        lastUsedField.alignment = .right
        lastUsedField.setContentCompressionResistancePriority(.required, for: .horizontal)
        lastUsedField.setContentHuggingPriority(.required, for: .horizontal)

        for v in [labelField, pathField, paneCountField, lastUsedField] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            labelField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            labelField.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            labelField.trailingAnchor.constraint(lessThanOrEqualTo: paneCountField.leadingAnchor, constant: -10),

            pathField.leadingAnchor.constraint(equalTo: labelField.leadingAnchor),
            pathField.topAnchor.constraint(equalTo: labelField.bottomAnchor, constant: 2),
            pathField.trailingAnchor.constraint(lessThanOrEqualTo: paneCountField.leadingAnchor, constant: -10),

            paneCountField.centerYAnchor.constraint(equalTo: centerYAnchor),
            paneCountField.trailingAnchor.constraint(equalTo: lastUsedField.leadingAnchor, constant: -12),

            lastUsedField.centerYAnchor.constraint(equalTo: centerYAnchor),
            // -24 leaves a comfortable gap for the overlay scroller thumb
            // when it appears during active scrolling without nudging the
            // timestamp in the idle state.
            lastUsedField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            // 84pt fits "12 mins ago" comfortably (with the abbreviated style
            // that's actually "12m ago"). Was 56, which clipped "7m ago".
            lastUsedField.widthAnchor.constraint(greaterThanOrEqualToConstant: 84)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configure(record: WorkspaceRecord, now: Date) {
        labelField.stringValue = record.displayLabel
        // Path tail — show the parent dir + basename for disambiguation
        // between same-named repos in different parents.
        let parent = (record.canonicalPath as NSString).deletingLastPathComponent
        let shortParent = shorten(path: parent)
        pathField.stringValue = shortParent.isEmpty ? record.canonicalPath : "\(shortParent)/\(record.displayLabel)"
        paneCountField.stringValue = "\(record.panes.count) pane\(record.panes.count == 1 ? "" : "s")"
        lastUsedField.stringValue = Self.dateFormatter.localizedString(for: record.updatedAt, relativeTo: now)

        toolTip = "\(record.canonicalPath)\n\(record.panes.count) panes · updated \(record.updatedAt.formatted(date: .abbreviated, time: .shortened))"

        setAccessibilityRole(.row)
        setAccessibilityLabel(
            "\(record.displayLabel), at \(record.canonicalPath), "
            + "\(record.panes.count) pane\(record.panes.count == 1 ? "" : "s"), "
            + "last used \(Self.dateFormatter.localizedString(for: record.updatedAt, relativeTo: now))"
        )
    }

    /// Replace `$HOME` with `~` for a more recognizable row.
    private func shorten(path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

// Custom selection rendering — the default NSTableView selection draws a
// hairline-sharp full-width blue bar which fights the rounded-card chrome.
// We want a pill-shaped highlight inset from the panel edges.
private final class SelectableRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }   // keep the accent color even when a child is first responder
        set { }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let inset = bounds.insetBy(dx: 8, dy: 1)
        let path = NSBezierPath(roundedRect: inset, xRadius: 8, yRadius: 8)
        let alpha: CGFloat = PaneStyling.variant(for: effectiveAppearance) == .dark ? 0.65 : 0.28
        NSColor.controlAccentColor.withAlphaComponent(alpha).setFill()
        path.fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        // No row-level background — content layer already has one.
    }
}
