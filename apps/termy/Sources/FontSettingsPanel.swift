// FontSettingsPanel.swift
//
// ⌘, panel for picking the terminal font. Two pickers and a size stepper:
//
//   ┌────────────────────────────────────────┐
//   │  Terminal font                         │
//   │                                        │
//   │  Primary  [Fira Code   ▾]  [14 ▾]      │
//   │  Korean   [D2Coding    ▾]              │
//   │                                        │
//   │  ABC abc 123 가나다 漢字 안녕           │
//   │                                        │
//   │  [Restore Defaults]            [Done]  │
//   └────────────────────────────────────────┘
//
// Changes apply live — every pane re-resolves its font as soon as the
// picker value changes. Mirrors macOS's standard NSFontPanel behavior so
// the user can eyeball the result before committing.

import AppKit

@MainActor
final class FontSettingsPanel: NSPanel {

    private let preference = TerminalFontPreference.shared

    private var primaryPopUp: NSPopUpButton!
    private var sizePopUp: NSPopUpButton!
    private var cjkPopUp: NSPopUpButton!
    private var previewLabel: NSTextField!

    private static let sizeChoices: [CGFloat] = [10, 11, 12, 13, 14, 15, 16, 18, 20, 24]

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 280),
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
        syncFromPreference()
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
        // Refresh the picker selections from the live preference in case it
        // changed while the panel was hidden (e.g. defaults reset).
        syncFromPreference()
        makeKeyAndOrderFront(nil)
    }

    // MARK: - Content

    private func setupContent() {
        guard let content = contentView else { return }
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 1

        let header = NSTextField(labelWithString: "Terminal font")
        header.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        header.textColor = .labelColor
        header.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "Changes apply immediately")
        hint.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .right
        hint.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        primaryPopUp = makeFontPopUp(items: TerminalFontPreference.availableMonospacedFontNames())
        primaryPopUp.target = self
        primaryPopUp.action = #selector(primaryFontChanged(_:))

        sizePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        sizePopUp.translatesAutoresizingMaskIntoConstraints = false
        for size in Self.sizeChoices {
            let title = String(format: "%g pt", Double(size))
            sizePopUp.addItem(withTitle: title)
            sizePopUp.lastItem?.representedObject = size
        }
        sizePopUp.target = self
        sizePopUp.action = #selector(sizeChanged(_:))
        sizePopUp.widthAnchor.constraint(equalToConstant: 86).isActive = true

        cjkPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        cjkPopUp.translatesAutoresizingMaskIntoConstraints = false
        cjkPopUp.addItem(withTitle: "System default")
        cjkPopUp.lastItem?.representedObject = TerminalFontPreference.systemCJKFallback
        for name in TerminalFontPreference.availableCJKFallbackNames() {
            cjkPopUp.addItem(withTitle: TerminalFontPreference.displayName(for: name))
            cjkPopUp.lastItem?.representedObject = name
        }
        cjkPopUp.target = self
        cjkPopUp.action = #selector(cjkChanged(_:))

        let primaryLabel = makeFieldLabel("Primary")
        let cjkLabel = makeFieldLabel("CJK fallback")

        let primaryRow = NSStackView(views: [primaryPopUp, sizePopUp])
        primaryRow.orientation = .horizontal
        primaryRow.spacing = 8
        primaryRow.translatesAutoresizingMaskIntoConstraints = false

        let grid = NSGridView(views: [
            [primaryLabel, primaryRow],
            [cjkLabel, cjkPopUp]
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill

        previewLabel = NSTextField(labelWithString: "ABC abc 123 가나다 漢字 안녕")
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.alignment = .center
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.textColor = .labelColor

        let previewBox = NSView()
        previewBox.translatesAutoresizingMaskIntoConstraints = false
        previewBox.wantsLayer = true
        previewBox.layer?.cornerRadius = 8
        previewBox.layer?.borderWidth = 1
        previewBox.addSubview(previewLabel)
        NSLayoutConstraint.activate([
            previewLabel.centerXAnchor.constraint(equalTo: previewBox.centerXAnchor),
            previewLabel.centerYAnchor.constraint(equalTo: previewBox.centerYAnchor),
            previewLabel.leadingAnchor.constraint(greaterThanOrEqualTo: previewBox.leadingAnchor, constant: 12),
            previewLabel.trailingAnchor.constraint(lessThanOrEqualTo: previewBox.trailingAnchor, constant: -12),
            previewBox.heightAnchor.constraint(equalToConstant: 56)
        ])
        // Theme-aware colors set in applyTheme().

        let restoreButton = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults(_:)))
        restoreButton.bezelStyle = .rounded
        restoreButton.translatesAutoresizingMaskIntoConstraints = false

        let doneButton = NSButton(title: "Done", target: self, action: #selector(closePanel(_:)))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [restoreButton, NSView(), doneButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.distribution = .fill

        content.addSubview(header)
        content.addSubview(hint)
        content.addSubview(separator)
        content.addSubview(grid)
        content.addSubview(previewBox)
        content.addSubview(buttonRow)

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

            grid.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 18),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            previewBox.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 18),
            previewBox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            previewBox.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            buttonRow.topAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: 18),
            buttonRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
    }

    private func makeFontPopUp(items: [String]) -> NSPopUpButton {
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.translatesAutoresizingMaskIntoConstraints = false
        for name in items {
            popUp.addItem(withTitle: TerminalFontPreference.displayName(for: name))
            popUp.lastItem?.representedObject = name
        }
        return popUp
    }

    private func makeFieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    // MARK: - Sync

    private func syncFromPreference() {
        let primaryName = preference.primaryFontName.isEmpty
            ? (preference.resolvedFont().fontName)
            : preference.primaryFontName
        selectItem(primaryPopUp, matching: primaryName)

        let pointSize = preference.pointSize
        if let item = sizePopUp.itemArray.first(where: { ($0.representedObject as? CGFloat) == pointSize }) {
            sizePopUp.select(item)
        } else {
            // Custom size persisted from elsewhere — show the closest choice
            // and still respect the actual size in the preview.
            let closest = Self.sizeChoices.min(by: { abs($0 - pointSize) < abs($1 - pointSize) }) ?? TerminalFontPreference.defaultPointSize
            if let item = sizePopUp.itemArray.first(where: { ($0.representedObject as? CGFloat) == closest }) {
                sizePopUp.select(item)
            }
        }

        let cjk = preference.cjkFallbackName
        if cjk.isEmpty {
            cjkPopUp.selectItem(at: 0)
        } else if !selectItem(cjkPopUp, matching: cjk) {
            cjkPopUp.selectItem(at: 0)
        }

        refreshPreview()
    }

    @discardableResult
    private func selectItem(_ popUp: NSPopUpButton, matching value: String) -> Bool {
        for item in popUp.itemArray {
            if let stored = item.representedObject as? String, stored == value {
                popUp.select(item)
                return true
            }
        }
        return false
    }

    private func refreshPreview() {
        previewLabel.font = preference.resolvedFont(size: max(preference.pointSize, 14))
    }

    // MARK: - Actions

    @objc private func primaryFontChanged(_ sender: NSPopUpButton) {
        guard let name = sender.selectedItem?.representedObject as? String else { return }
        preference.update(
            primaryName: name,
            pointSize: preference.pointSize,
            cjkFallbackName: preference.cjkFallbackName
        )
        refreshPreview()
    }

    @objc private func sizeChanged(_ sender: NSPopUpButton) {
        guard let size = sender.selectedItem?.representedObject as? CGFloat else { return }
        preference.update(
            primaryName: preference.primaryFontName,
            pointSize: size,
            cjkFallbackName: preference.cjkFallbackName
        )
        refreshPreview()
    }

    @objc private func cjkChanged(_ sender: NSPopUpButton) {
        guard let name = sender.selectedItem?.representedObject as? String else { return }
        preference.update(
            primaryName: preference.primaryFontName,
            pointSize: preference.pointSize,
            cjkFallbackName: name
        )
        refreshPreview()
    }

    @objc private func restoreDefaults(_ sender: Any?) {
        preference.update(
            primaryName: "",
            pointSize: TerminalFontPreference.defaultPointSize,
            cjkFallbackName: TerminalFontPreference.systemCJKFallback
        )
        syncFromPreference()
    }

    @objc private func closePanel(_ sender: Any?) {
        close()
    }

    // MARK: - Dismissal

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            close()
            return
        }
        super.keyDown(with: event)
    }

    private func applyTheme() {
        let theme = PaneStyling.theme(for: effectiveAppearance)
        contentView?.layer?.backgroundColor = theme.panelBackgroundColor.cgColor
        contentView?.layer?.borderColor = theme.panelBorderColor.cgColor

        // Find the preview box (the only NSView with a layer-borderWidth of 1
        // besides contentView) and tint it.
        for sub in contentView?.subviews ?? [] where sub.layer?.borderWidth == 1 && !(sub is NSBox) {
            sub.layer?.borderColor = theme.panelBorderColor.cgColor
            sub.layer?.backgroundColor = theme.panelBackgroundColor.cgColor
        }
    }
}
