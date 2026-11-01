import AppKit

// herdr-core가 없을 때 설치를 권하는 alert와 설치 출력 창. 원격 project를 처음 만들 때와 "Run local panes in
// herdr-core"를 켤 때만 부른다(hc pane을 여는 것만으로는 묻지 않는다). 이미 설치돼 있으면 아무것도 띄우지 않는다.

@MainActor
enum HcInstallSheet {
    static func ensureInstalled(over window: NSWindow?) async -> Bool {
        if HcLocator.find(environment: ProcessInfo.processInfo.environment) != nil { return true }

        let alert = NSAlert()
        alert.messageText = "herdr-core is required"
        alert.informativeText = "Remote projects and local panes that survive restarts run in herdr-core, a background program that keeps terminals alive. Install it now?"
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        let response: NSApplication.ModalResponse
        if let window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return false }
        return await InstallOutputWindow().run(over: window)
    }
}

/// 설치 출력을 흘려 보여 주는 창. 성공하면 닫히고, 실패하면 안내 문구와 Close 버튼을 남긴다.
@MainActor
private final class InstallOutputWindow: NSObject {
    private let panel: NSPanel
    private let textView: NSTextView
    private let statusLabel = NSTextField(labelWithString: "Installing herdr-core…")
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private var closed: CheckedContinuation<Void, Never>?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Install herdr-core"
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        super.init()

        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.isHidden = true
        closeButton.keyEquivalent = "\r"
        for v in [scroll, statusLabel, closeButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            panel.contentView?.addSubview(v)
        }
        guard let content = panel.contentView else { return }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            statusLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            closeButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -12)
        ])
    }

    func run(over window: NSWindow?) async -> Bool {
        if let window {
            window.beginSheet(panel, completionHandler: nil)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
        let ok = await HcInstaller.run { [weak self] text in self?.append(text) }
        if ok {
            dismiss(over: window)
            return true
        }
        statusLabel.stringValue = "Couldn't install herdr-core. See the output above."
        closeButton.isHidden = false
        await withCheckedContinuation { closed = $0 }
        dismiss(over: window)
        return false
    }

    private func append(_ text: String) {
        textView.textStorage?.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]))
        textView.scrollToEndOfDocument(nil)
    }

    @objc private func closeTapped() {
        closed?.resume()
        closed = nil
    }

    private func dismiss(over window: NSWindow?) {
        if let window { window.endSheet(panel) } else { panel.orderOut(nil) }
    }
}
