import AppKit

// ⌘K "New Remote Project…" 시트. 원격 project는 머신 + 폴더다(spec §6.8): hc `machine.list`에서 머신을 고르고
// 그 머신의 폴더를 적는다. 머신 추가와 로그인은 `hc machine add`·`hc machine login`·Herdr.app에 맡기고 여기서는
// 줄 상태만 보여 준다. 로그인이 필요한 머신은 고를 수 있게 두어 로그인 안내를 보이고, 닿지 않거나 연결 중이거나
// Windows인 머신은 이유와 함께 비활성이다(Windows: SwiftTerm에 win32-input-mode 인코더가 없다).
// herdr-core가 없으면 먼저 설치를 권한다(원격 project를 처음 만들 때가 설치를 묻는 때다). 폴더는 그 머신에서
// `test -d`가 0을 돌려줄 때만 만든다. 없는 폴더로 만들면 pane이 엉뚱한 곳에서 열리거나 실패한다.

@MainActor
final class RemoteProjectSheet: NSObject, NSTextFieldDelegate {
    /// 떠 있는 시트. 다시 누르면 새로 띄우지 않고 그것을 앞으로 가져온다.
    private static var current: RemoteProjectSheet?
    /// 머신 이름 → Windows인지. 그 머신이 `uname`에 확실히 답한 것만 앱이 도는 동안 기억한다.
    private(set) static var rememberedWindows: [String: Bool] = [:]

    let panel: NSPanel
    let titleLabel = NSTextField(labelWithString: "New Remote Project")
    let machineLabel = NSTextField(labelWithString: "Machine")
    let folderLabel = NSTextField(labelWithString: "Folder")
    let machinePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let folderField = NSTextField()
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    let createButton = NSButton(title: "Create", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private let manager: HcSessionManager
    private let onCreate: (WorkspaceRecord) -> Void
    private var machines: [HcMachine] = []
    private var choices: [(title: String, enabled: Bool)] = []
    private weak var host: NSWindow?
    /// 머신 목록을 한 번이라도 채웠는지. 그 전에는 안내 줄을 load가 정한다(연결 중·연결 실패).
    private var listed = false
    private var isChecking = false
    /// Cancel로 닫혔다. 그사이 끝난 폴더 확인은 project를 만들지 않는다.
    private var isDismissed = false

    /// "New Remote Project…"를 눌렀을 때. herdr-core가 없어 설치하지 않으면 아무것도 띄우지 않는다.
    static func present(over window: NSWindow, manager: HcSessionManager, onCreate: @escaping (WorkspaceRecord) -> Void) {
        if let current {
            guard !current.panel.isVisible else {
                current.panel.makeKeyAndOrderFront(nil)
                return
            }
            current.dismiss()   // 창이 닫히며 시트도 사라졌다
        }
        Task { @MainActor in
            guard await HcInstallSheet.ensureInstalled(over: window), Self.current == nil else { return }
            let sheet = RemoteProjectSheet(manager: manager, onCreate: onCreate)
            Self.current = sheet
            sheet.host = window
            window.beginSheet(sheet.panel, completionHandler: nil)
            await sheet.load()
        }
    }

    init(manager: HcSessionManager, onCreate: @escaping (WorkspaceRecord) -> Void) {
        self.manager = manager
        self.onCreate = onCreate
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 210),
                        styleMask: [.titled], backing: .buffered, defer: true)
        super.init()
        panel.title = "New Remote Project"
        panel.isReleasedWhenClosed = false
        layout()
        refresh()
    }

    private func layout() {
        titleLabel.font = NSFont.boldSystemFont(ofSize: 13)
        for label in [machineLabel, folderLabel] { label.alignment = .right }
        machinePopup.autoenablesItems = false
        machinePopup.target = self
        machinePopup.action = #selector(machineChanged)
        folderField.placeholderString = "/path/on/machine"
        folderField.delegate = self
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.font = NSFont.systemFont(ofSize: 12)
        messageLabel.isSelectable = true
        createButton.target = self
        createButton.action = #selector(createClicked)
        createButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.keyEquivalent = "\u{1b}"

        guard let content = panel.contentView else { return }
        let views: [NSView] = [titleLabel, machineLabel, machinePopup, folderLabel, folderField, messageLabel,
                               createButton, cancelButton]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),

            machineLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            machineLabel.widthAnchor.constraint(equalToConstant: 60),
            machineLabel.centerYAnchor.constraint(equalTo: machinePopup.centerYAnchor),
            machinePopup.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            machinePopup.leadingAnchor.constraint(equalTo: machineLabel.trailingAnchor, constant: 8),
            machinePopup.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            folderLabel.leadingAnchor.constraint(equalTo: machineLabel.leadingAnchor),
            folderLabel.widthAnchor.constraint(equalTo: machineLabel.widthAnchor),
            folderLabel.centerYAnchor.constraint(equalTo: folderField.centerYAnchor),
            folderField.topAnchor.constraint(equalTo: machinePopup.bottomAnchor, constant: 12),
            folderField.leadingAnchor.constraint(equalTo: machinePopup.leadingAnchor),
            folderField.trailingAnchor.constraint(equalTo: machinePopup.trailingAnchor),

            messageLabel.topAnchor.constraint(equalTo: folderField.bottomAnchor, constant: 10),
            messageLabel.leadingAnchor.constraint(equalTo: folderField.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: folderField.trailingAnchor),

            createButton.topAnchor.constraint(greaterThanOrEqualTo: messageLabel.bottomAnchor, constant: 12),
            createButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            createButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            createButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            cancelButton.centerYAnchor.constraint(equalTo: createButton.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: createButton.leadingAnchor, constant: -8),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
    }

    // MARK: - 머신 목록

    /// core에 연결해 머신과 그 줄 상태를 읽고, 연결된 머신은 Windows인지 확인한 뒤 목록을 채운다.
    func load() async {
        messageLabel.stringValue = "Connecting to herdr-core…"
        let machines: [HcMachine]
        do {
            try await manager.ensureConnected()
            machines = try await manager.machines()
        } catch {
            messageLabel.stringValue = "herdr-core unavailable: \(HcSessionManager.describe(error))"
            return
        }
        let connected = machines.filter { $0.state == "connected" }.map(\.name)
        var windows = await Self.windowsMachines(connected, manager: manager)
        // 지금 연결되지 않은 머신도 전에 Windows로 답했으면 그렇게 보인다.
        windows.formUnion(machines.map(\.name).filter { Self.rememberedWindows[$0] == true })
        show(machines: machines, windows: windows)
    }

    func show(machines: [HcMachine], windows: Set<String>) {
        self.machines = machines
        listed = true
        choices = machines.map { RemoteProject.machineLabel($0, isWindows: windows.contains($0.name)) }
        machinePopup.removeAllItems()
        for (machine, choice) in zip(machines, choices) {
            machinePopup.addItem(withTitle: choice.title)
            machinePopup.lastItem?.isEnabled = choice.enabled || Self.showsLoginHint(machine, windows: windows)
        }
        let pick = choices.firstIndex { $0.enabled } ?? machines.firstIndex { Self.showsLoginHint($0, windows: windows) }
        if let pick { machinePopup.selectItem(at: pick) } else { machinePopup.select(nil) }
        refresh()
    }

    /// 로그인이 필요한 머신은 골라서 로그인 안내를 볼 수 있게 둔다(만들기는 막는다).
    private static func showsLoginHint(_ machine: HcMachine, windows: Set<String>) -> Bool {
        machine.state == "needs_login" && !windows.contains(machine.name)
    }

    /// 고른 머신. 목록에서 고를 수 없는 머신이면 nil.
    private var selected: (machine: HcMachine, enabled: Bool)? {
        let index = machinePopup.indexOfSelectedItem
        guard index >= 0, index < machines.count, machinePopup.selectedItem?.isEnabled == true else { return nil }
        return (machines[index], choices[index].enabled)
    }

    /// 안내 줄과 Create 버튼을 지금 고른 머신과 폴더에 맞춘다.
    private func refresh() {
        if listed {
            if machines.isEmpty {
                messageLabel.stringValue = "No machines yet. Run `hc machine add` in a terminal, then try again."
            } else if let selected, !selected.enabled {
                messageLabel.stringValue = RemoteProject.loginHint(machine: selected.machine.name)
            } else {
                messageLabel.stringValue = ""
            }
        }
        let hasFolder = !folderField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        createButton.isEnabled = !isChecking && hasFolder && selected?.enabled == true
        machinePopup.isEnabled = !isChecking && !machines.isEmpty
    }

    @objc private func machineChanged() {
        refresh()
    }

    func controlTextDidChange(_ obj: Notification) {
        refresh()
    }

    // MARK: - Windows 확인

    /// 연결된 머신들을 함께 확인한다. 하나가 느려도 나머지를 기다리게 하지 않는다.
    static func windowsMachines(_ names: [String], manager: HcSessionManager) async -> Set<String> {
        // 모두 먼저 띄운 뒤 기다린다(RPC를 기다리는 동안 main actor는 다른 확인을 돌린다).
        let checks = names.map { name in
            Task { @MainActor in await isWindows(machine: name, manager: manager) ? name : nil }
        }
        var result = Set<String>()
        for check in checks {
            if let name = await check.value { result.insert(name) }
        }
        return result
    }

    /// `uname`이 0이 아니거나 실패하면 Windows로 본다. 그 머신이 답한 판정은 이름별로 기억한다.
    static func isWindows(machine: String, manager: HcSessionManager) async -> Bool {
        if let remembered = rememberedWindows[machine] { return remembered }
        let result: Result<HcExecResult, any Error>
        do {
            result = .success(try await manager.exec(on: machine, argv: ["uname"], timeout: 5))
        } catch {
            result = .failure(error)
        }
        let verdict = RemoteProject.windowsVerdict(result)
        if verdict.cache { rememberedWindows[machine] = verdict.isWindows }
        return verdict.isWindows
    }

    // MARK: - 만들기

    @objc private func createClicked() {
        Task { await create() }
    }

    /// 그 머신에 폴더가 있을 때만 기록을 만들어 넘기고 시트를 닫는다. 없거나 확인하지 못하면 이유를 보여 준다.
    func create() async {
        guard !isChecking, let selected, selected.enabled else { return }
        let name = selected.machine.name
        guard let folder = RemoteProject.normalizedFolder(folderField.stringValue) else {
            messageLabel.stringValue = RemoteProject.folderNotFound(machine: name)
            return
        }
        isChecking = true
        refresh()
        // 시간이 다 돼 끝난 확인은 폴더가 있다는 답이 아니다(exitCode가 nil).
        let code = (try? await manager.exec(on: name, argv: ["test", "-d", folder]))?.exitCode
        guard !isDismissed else { return }
        isChecking = false
        refresh()
        guard code == 0 else {
            messageLabel.stringValue = RemoteProject.folderNotFound(machine: name)
            return
        }
        dismiss()
        onCreate(RemoteProject.record(machine: name, folder: folder, now: Date()))
    }

    @objc private func cancelClicked() {
        dismiss()
    }

    private func dismiss() {
        isDismissed = true
        if let host, host.attachedSheet === panel { host.endSheet(panel) } else { panel.orderOut(nil) }
        if Self.current === self { Self.current = nil }
    }
}
