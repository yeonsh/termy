// IssueRefPickerPanel.swift
//
// Cmd+click한 자리에 뜨는 "어느 프로젝트로 열까" 메뉴. ProjectSwitcherPanel(⌘K)을 본뜬
// borderless NSPanel: 회색 제목, 검색 칸, 줄 목록. ↑↓ 이동, ⏎ 선택, ⎋ 취소, 바깥 클릭은 취소.

import AppKit

@MainActor
final class IssueRefPickerPanel: NSPanel {
    static let shared = IssueRefPickerPanel()

    private static let panelWidth: CGFloat = 360
    private static let rowHeight: CGFloat = 28
    private static let maxVisibleRows = 8
    private static let chromeHeight: CGFloat = 12 + 18 + 8 + 28 + 6 + 1 + 6 + 6

    private let titleLabel = NSTextField(labelWithString: "")
    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let searchDelegate = SearchDelegate()

    private var model: IssueRefPickerModel?
    private var rows: [IssueRefPickerRow] = []
    private var showAll = false
    private var onPick: ((RepoWebURL) -> Void)?

    var visibleRows: [IssueRefPickerRow] { rows }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 200),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .modalPanel

        let themed = AppearanceAwareView(frame: NSRect(origin: .zero, size: frame.size))
        themed.autoresizingMask = [.width, .height]
        themed.wantsLayer = true
        contentView = themed
        themed.onAppearanceChange = { [weak self] _ in self?.applyTheme() }

        setupContent()
        applyTheme()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Public

    /// `screenPoint`에 왼쪽 위 모서리를 두고 연다. 이미 떠 있으면 요청과 콜백을 바꾼다.
    func present(request: IssueRefMenuRequest, allRepos: [RepoWebURL], at screenPoint: NSPoint,
                 onPick: @escaping (RepoWebURL) -> Void) {
        self.onPick = onPick
        model = IssueRefPickerModel(request: request, allRepos: allRepos)
        showAll = false
        titleLabel.stringValue = request.title
        searchField.stringValue = ""
        refilter()

        let visibleCount = min(max(rows.count, 1), Self.maxVisibleRows)
        let height = Self.chromeHeight + CGFloat(visibleCount) * (Self.rowHeight + 2)
        var origin = NSPoint(x: screenPoint.x, y: screenPoint.y - height)
        let screen = NSScreen.screens.first { $0.frame.contains(screenPoint) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            origin.x = min(max(origin.x, area.minX), max(area.minX, area.maxX - Self.panelWidth))
            origin.y = min(max(origin.y, area.minY), max(area.minY, area.maxY - height))
        }
        setFrame(NSRect(x: origin.x, y: origin.y, width: Self.panelWidth, height: height), display: true)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(searchField)
    }

    func commitSelection() {
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count else { return }
        switch rows[row].action {
        case .showAll:
            showAll = true
            searchField.stringValue = ""
            refilter()
        case .pick(let repo):
            let callback = onPick
            finish()
            callback?(repo)
        }
    }

    func cancelAndClose() {
        finish()
    }

    override func resignKey() {
        super.resignKey()
        if isVisible { finish() }
    }

    // MARK: - Internals

    private func finish() {
        onPick = nil
        orderOut(nil)
    }

    private func refilter() {
        rows = model?.rows(query: searchField.stringValue, showAll: showAll) ?? []
        tableView.reloadData()
        if !rows.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    /// 테스트용: 검색 칸에 글자를 넣고 delegate와 같은 갱신 경로를 탄다.
    func setSearchTextForTesting(_ text: String) {
        searchField.stringValue = text
        searchTextChanged()
    }

    fileprivate func searchTextChanged() {
        refilter()
    }

    fileprivate func moveSelection(delta: Int) {
        guard !rows.isEmpty else { return }
        let next = min(max(tableView.selectedRow + delta, 0), rows.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    @objc private func handleClick() {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        commitSelection()
    }

    private func setupContent() {
        guard let content = contentView else { return }
        content.layer?.cornerRadius = 10
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 1

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        searchField.font = .systemFont(ofSize: 14)
        searchField.focusRingType = .none
        searchField.isBezeled = false
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.textColor = .labelColor
        searchField.placeholderAttributedString = NSAttributedString(
            string: "Search projects…",
            attributes: [.foregroundColor: NSColor.placeholderTextColor, .font: NSFont.systemFont(ofSize: 14)])
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchDelegate.owner = self
        searchField.delegate = searchDelegate

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("repo"))
        column.resizingMask = .autoresizingMask
        column.width = Self.panelWidth - 8
        tableView.headerView = nil
        tableView.addTableColumn(column)
        tableView.rowHeight = Self.rowHeight
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.allowsEmptySelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(handleClick)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(titleLabel)
        content.addSubview(searchField)
        content.addSubview(separator)
        content.addSubview(scrollView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),

            searchField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            searchField.heightAnchor.constraint(equalToConstant: 28),

            separator.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6)
        ])
    }

    private func applyTheme() {
        let theme = PaneStyling.theme(for: effectiveAppearance)
        contentView?.layer?.backgroundColor = theme.panelBackgroundColor.cgColor
        contentView?.layer?.borderColor = theme.panelBorderColor.cgColor
    }

    // MARK: - Search field delegate

    private final class SearchDelegate: NSObject, NSTextFieldDelegate {
        weak var owner: IssueRefPickerPanel?

        func controlTextDidChange(_ obj: Notification) {
            owner?.searchTextChanged()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let owner else { return false }
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                owner.moveSelection(delta: -1)
            case #selector(NSResponder.moveDown(_:)):
                owner.moveSelection(delta: 1)
            case #selector(NSResponder.insertNewline(_:)):
                owner.commitSelection()
            case #selector(NSResponder.cancelOperation(_:)):
                owner.cancelAndClose()
            default:
                return false
            }
            return true
        }
    }
}

// MARK: - NSTableView plumbing

extension IssueRefPickerPanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = IssueRefPickerRowView()
        cell.configure(rows[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        IssueRefPickerSelectionRowView()
    }
}

private final class IssueRefPickerRowView: NSTableCellView {
    private let nameField = NSTextField(labelWithString: "")
    private let tagField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        nameField.font = .systemFont(ofSize: 13, weight: .medium)
        nameField.lineBreakMode = .byTruncatingTail
        tagField.font = .systemFont(ofSize: 11)
        tagField.textColor = .secondaryLabelColor
        detailField.font = .systemFont(ofSize: 11)
        detailField.textColor = .tertiaryLabelColor
        detailField.alignment = .right
        detailField.lineBreakMode = .byTruncatingHead
        for f in [nameField, tagField, detailField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            addSubview(f)
        }
        nameField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        tagField.setContentCompressionResistancePriority(.required, for: .horizontal)
        detailField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            nameField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            tagField.leadingAnchor.constraint(equalTo: nameField.trailingAnchor, constant: 6),
            tagField.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailField.leadingAnchor.constraint(greaterThanOrEqualTo: tagField.trailingAnchor, constant: 8),
            detailField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            detailField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ row: IssueRefPickerRow) {
        nameField.stringValue = row.title
        tagField.stringValue = row.tagLabel ?? ""
        detailField.stringValue = row.detail
        if row.action == .showAll { nameField.textColor = .secondaryLabelColor }
        setAccessibilityLabel([row.title, row.tagLabel, row.detail.isEmpty ? nil : row.detail]
            .compactMap { $0 }.joined(separator: ", "))
    }
}

private final class IssueRefPickerSelectionRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set { }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6)
        let alpha: CGFloat = PaneStyling.variant(for: effectiveAppearance) == .dark ? 0.65 : 0.28
        NSColor.controlAccentColor.withAlphaComponent(alpha).setFill()
        path.fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {}
}
