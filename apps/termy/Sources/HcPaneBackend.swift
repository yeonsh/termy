import AppKit

// hc pane 하나의 수명. pane의 프로세스는 termy가 아니라 herdr-core 안에 있고, termy는 그 terminal에 attach한
// viewer다. 그래서 termy가 꺼지거나 core 연결이 끊겨도 셸과 agent는 살아 있고, 다시 붙으면 같은 terminal을
// 이어서 본다. pane ↔ terminal 대응은 address가 아니라 `termy.pane` label이 기준이다(address는 캐시).
// attach 뒤에는 view의 입력·크기를 DATA·RESIZE frame으로, stream의 바이트를 view로 옮기고 받은 만큼 CREDIT을
// 돌려준다. 보내는 frame은 한 task가 순서대로 쓴다(키 입력 순서가 바뀌면 안 된다).
// 종료는 CLOSE의 reason으로 가른다: exited/killed는 프로그램이 끝난 것(onExit), kept terminal의 loss는
// `restarted`를 기다려 다시 attach하고, server_stop 같은 나머지는 pane을 닫지 않고 상태로 보여 준다.

struct HcLaunch: Equatable, Sendable {
    var machine: String?
    var cwd: String
    var shell: String
}

enum HcPaneConnectionState: Equatable {
    case connecting, attached, restartingShell, unavailable(String)
}

enum HcCloseOutcome: Equatable {
    case exited(Int32), unavailable(String)
}

/// 원격 pane이 띄우기 전에 묻는 `terminal.list`의 labels 필터.
struct HcPaneLookupParams: Encodable, Sendable {
    let labels: [String: String]
}

/// `terminal.list` 결과. machines에는 연결되지 않은 머신도 기다리지 않고 그 줄 상태와 함께 나온다.
/// hc 0.1.16은 schema가 필수라고 적은 배열도 비어 있으면 뺀다(머신이 없으면 `machines`). 맞는 terminal이 없는
/// 새 원격 pane의 조회가 decode 오류로 끝나지 않게 둘 다 없으면 비어 있는 것으로 읽는다.
struct HcPaneLookup: Decodable, Sendable {
    let terminals: [HcTerminal]
    let machines: [HcMachine]?

    private enum CodingKeys: String, CodingKey { case terminals, machines }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terminals = try c.decodeIfPresent([HcTerminal].self, forKey: .terminals) ?? []
        machines = try c.decodeIfPresent([HcMachine].self, forKey: .machines)
    }
}

/// `terminal.run` 인자. labels는 termy 쪽에서 `"k=v"`로 다루고, wire에서는 hc가 받는 `{k: v}` 객체로 쓴다.
struct HcRunParams: Encodable, Equatable, Sendable {
    var argv: [String]?
    var cwd: String
    var env: [String: String]
    var labels: [String]
    var keep: Bool
    var on: String?
    var no_parent: Bool
    var no_notify: Bool

    private enum CodingKeys: String, CodingKey {
        case argv, cwd, env, labels, keep, on, no_parent, no_notify
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(argv, forKey: .argv)   // 없으면 그 머신의 셸
        try c.encode(cwd, forKey: .cwd)
        try c.encode(env, forKey: .env)
        var object: [String: String] = [:]
        for label in labels {
            let parts = label.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            object[String(parts[0])] = parts.count > 1 ? String(parts[1]) : ""
        }
        try c.encode(object, forKey: .labels)
        try c.encode(keep, forKey: .keep)
        try c.encodeIfPresent(on, forKey: .on)
        try c.encode(no_parent, forKey: .no_parent)
        try c.encode(no_notify, forKey: .no_notify)
    }
}

@MainActor
final class HcPaneBackend {
    static let termProgram = "termy"

    /// 붙여넣기 같은 큰 입력을 이 크기로 나눠 보낸다(frame payload 상한 16 MiB보다 한참 작게).
    private static let inputChunk = 1 << 20
    private static let restoreHistory = 10_000

    let paneId: String
    let projectKey: String
    let projectId: String
    let launch: HcLaunch
    private let view: TermyTerminalView
    private let manager: HcSessionManager

    private(set) var address: String?
    private(set) var connectionState: HcPaneConnectionState = .connecting

    var onExit: ((Int32) -> Void)?
    var onStatus: ((HcStatus?) -> Void)?
    var onForeground: ((HcForeground?) -> Void)?
    var onConnectionState: ((HcPaneConnectionState) -> Void)?

    private enum Lifecycle { case idle, running, exited, killed, detached }
    private var lifecycle = Lifecycle.idle
    private var focused: Bool?
    private var attachTask: Task<Void, Never>?
    /// attach가 도는 중에 `restarted`가 오면, 끝난 뒤 그 결과를 버리고 다시 붙는다.
    private var reattachForced = false
    private var session: Session?
    private var nextSessionID = 0

    /// 붙어 있는 stream 하나. 연결(epoch)이 바뀌거나 CLOSE가 오면 버린다.
    private struct Session {
        let id: Int
        let epoch: Int
        let channel: UInt32
        let outbox: AsyncStream<HcFrame>.Continuation
        let reader: Task<Void, Never>
    }

    init(paneId: String, projectKey: String, projectId: String, launch: HcLaunch,
         view: TermyTerminalView, manager: HcSessionManager = .shared) {
        self.paneId = paneId
        self.projectKey = projectKey
        self.projectId = projectId
        self.launch = launch
        self.view = view
        self.manager = manager
    }

    // MARK: - terminal.run 인자와 CLOSE 해석

    /// local 셸을 감싸는 스크립트. `env`는 core 환경에 덧붙기만 하므로, core가 agent 안에서 처음 떴을 때
    /// 물려받은 agent 세션 표식과 `GIT_EDITOR=true`를 여기서 지운다(`Pane.shellEnvironment`와 같은 규칙).
    private static let localShellScript =
        "unset " + Pane.agentSessionMarkerEnvKeys.joined(separator: " ") + "; "
        + #"[ "${GIT_EDITOR-}" = true ] && unset GIT_EDITOR; exec "$1" -l"#

    static func runParams(paneId: String, projectKey: String, projectId: String, launch: HcLaunch,
                          instance: String, baseEnvironment: [String: String]) -> HcRunParams {
        var env = [
            "TERMY_PANE_ID": paneId,
            "TERMY_PROJECT_ID": projectId,
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": termProgram,
        ]
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            env["TERM_PROGRAM_VERSION"] = version
        }
        var argv: [String]?
        if launch.machine == nil {
            env["LC_ALL"] = baseEnvironment["LC_ALL"] ?? "en_US.UTF-8"
            argv = ["/bin/sh", "-c", localShellScript, "termy-shell", launch.shell]
        }
        return HcRunParams(argv: argv, cwd: launch.cwd, env: env,
                           labels: ["termy.pane=\(paneId)", "termy.project=\(projectKey)", "termy.instance=\(instance)"],
                           keep: true, on: launch.machine, no_parent: true, no_notify: true)
    }

    private struct CloseReason: Decodable {
        let reason: String?
        let exitCode: Int32?
        private enum CodingKeys: String, CodingKey { case reason; case exitCode = "exit_code" }
    }

    static func closeOutcome(json: Data?) -> HcCloseOutcome {
        guard let json, let close = try? JSONDecoder().decode(CloseReason.self, from: json) else {
            return .unavailable("closed")
        }
        return outcome(reason: close.reason, exitCode: close.exitCode)
    }

    /// terminal 레코드와 `finished` 이벤트의 reason도 같은 규칙으로 읽는다.
    static func outcome(reason: String?, exitCode: Int32?) -> HcCloseOutcome {
        switch reason {
        case "exited", "killed": return .exited(exitCode ?? -1)
        default: return .unavailable(reason ?? "closed")
        }
    }

    // MARK: - 수명

    func start() {
        guard lifecycle == .idle else { return }
        lifecycle = .running
        view.remoteInput = { [weak self] bytes in self?.sendInput(bytes) }
        view.onGridSizeChanged = { [weak self] cols, rows in self?.sendResize(cols: cols, rows: rows) }
        manager.register(self)
        onConnectionState?(connectionState)
        Task { [weak self] in
            guard let manager = self?.manager else { return }
            do {
                try await manager.ensureConnected()
            } catch {
                self?.connectionFailed(HcSessionManager.describe(error))
                return
            }
            self?.reattach()
        }
    }

    /// 지금 연결에서 자기 terminal에 붙어 있게 한다. 이미 붙어 있거나 붙는 중이면 아무것도 하지 않는다.
    func reattach() {
        attach(force: false)
    }

    func setFocused(_ focused: Bool) {
        self.focused = focused
        guard let session else { return }
        session.outbox.yield(.focus(channel: session.channel, focused))
    }

    func sendDisplayFacts() {
        guard let session, let payload = try? JSONEncoder().encode(displayFacts()) else { return }
        session.outbox.yield(HcFrame(channel: session.channel, kind: .facts, payload: payload))
    }

    /// 사용자가 pane을 닫았다. terminal을 끝낸다(onExit은 부르지 않는다).
    func kill() {
        guard lifecycle != .exited, lifecycle != .killed else { return }
        lifecycle = .killed
        dropSession(sendClose: false)   // kill이 core 쪽에서 stream을 닫는다
        manager.unregister(self)
        if let address {
            manager.kill(address: address, paneId: paneId)
        } else {
            // 아직 붙지 못했다(연결 전·unavailable). terminal.run이 도는 중이면 performAttach가 끝난 뒤 kill한다.
            manager.killPane(paneId: paneId)
        }
    }

    /// 앱 종료처럼 terminal은 살려 두고 viewer만 떠날 때.
    func detach() {
        guard lifecycle == .running else { return }
        lifecycle = .detached
        dropSession(sendClose: true)
        manager.unregister(self)
    }

    // MARK: - manager가 부르는 것

    func connectionLost() {
        guard lifecycle == .running else { return }
        dropSession(sendClose: false)
        setState(.connecting)
    }

    func connectionFailed(_ reason: String) {
        guard lifecycle == .running, session == nil else { return }
        setState(.unavailable(reason))
    }

    func terminalUpserted(_ terminal: HcTerminal) {
        // 원격 머신이 다시 연결되면 그사이 바뀐 terminal이 `created`로 다시 온다.
        guard lifecycle == .running, session == nil, terminal.state == "live" else { return }
        reattach()
    }

    /// machine.list로 기다리는 머신의 줄 상태를 새로 알았다. 머신을 보기 전(address 없음, 붙는 중 아님)에만 보여 준다.
    func machineLineChanged() {
        guard lifecycle == .running, session == nil, attachTask == nil, address == nil,
              let machine = launch.machine, !manager.hasSeenMachine(machine) else { return }
        setState(Self.waitingState(machine: machine, lineState: manager.machineLineState(machine)))
    }

    func statusChanged(_ status: HcStatus?) {
        guard lifecycle == .running else { return }
        onStatus?(status)
    }

    func foregroundChanged(_ foreground: HcForeground?) {
        guard lifecycle == .running else { return }
        onForeground?(foreground)
    }

    /// kept terminal의 프로그램이 죽었다. core가 attach stream을 닫고, 새 셸이 뜨면 `restarted`가 온다.
    func terminalLost() {
        guard lifecycle == .running else { return }
        setState(.restartingShell)
    }

    func terminalRestarted() {
        guard lifecycle == .running else { return }
        // 보통은 loss가 옛 stream을 이미 닫았다. 그사이 새 셸에 붙은 stream이면 떠나야 하므로 CLOSE를 보낸다
        // (이미 닫힌 channel의 CLOSE에 core는 빈 CLOSE로 답할 뿐이다. hc 0.1.16에서 확인).
        dropSession(sendClose: true)
        attach(force: true)
    }

    func terminalFinished(exitCode: Int32?, reason: String) {
        // 붙어 있거나 붙는 중이면 stream CLOSE(또는 attach의 `finished` 오류)가 같은 사실을 알려 준다.
        guard lifecycle == .running, session == nil, attachTask == nil else { return }
        programEnded(exitCode: exitCode, reason: reason)
    }

    /// `missed`로 snapshot이 바뀐 뒤 자기 terminal을 다시 확인한다.
    func resync() {
        guard lifecycle == .running else { return }
        if let address, let record = manager.store.terminals[address] {
            onStatus?(record.status)
            onForeground?(record.foreground)
            if record.state == "finished" {
                if session == nil, attachTask == nil { programEnded(exitCode: record.exitCode, reason: record.reason) }
                return
            }
        }
        if session == nil { reattach() }
    }

    // MARK: - attach

    /// force: 도는 중인 attach가 있으면 그 결과(옛 셸의 stream일 수 있다)를 버리고 끝난 뒤 다시 붙는다.
    private func attach(force: Bool) {
        guard lifecycle == .running else { return }
        if attachTask != nil {
            if force { reattachForced = true }
            return
        }
        guard let live = manager.liveConnection else { return }   // 연결되면 manager가 다시 부른다
        if let session, session.epoch == live.epoch { return }
        dropSession(sendClose: false)   // 끊긴 연결의 session
        attachTask = Task { [weak self] in
            await self?.performAttach(on: live.connection, epoch: live.epoch)
            guard let self else { return }
            attachTask = nil
            let forced = reattachForced
            reattachForced = false
            if forced {
                dropSession(sendClose: true)
                attach(force: false)
            } else if session == nil, let now = manager.liveConnection, now.epoch != live.epoch {
                attach(force: false)   // 도는 사이에 연결이 바뀌었다(그 사이의 reattach 요청은 건너뛰었다)
            }
        }
    }

    enum AttachPlan: Equatable {
        case attach(String), run, finished(HcTerminal)
        /// 아는 원격 address의 레코드가 없다: 그 머신이 끊겨 있다(unavailable로 보여 준다).
        case waitForMachine(String)
        /// address를 모르는 원격 pane(복원 직후): 그 머신이 연결된 것을 아직 못 봤다(connecting으로 기다린다).
        case awaitMachine(String)
    }

    /// 아는 address가 있으면 그 레코드, 없으면 같은 pane label의 살아 있는 terminal, 그것도 없으면 새로 띄운다.
    /// 원격 pane(machine 있음)은 지금 구독에서 그 머신이 연결된 것을 본 뒤에만 새로 띄운다(machineSeen). 그 전에는
    /// 머신 줄이 아직 이어지지 않아 살아 있는 자기 terminal이 snapshot에 없을 수 있고, 띄우면 셸이 둘이 된다.
    /// `.run`이어도 원격 pane은 띄우기 직전에 `remoteRunCheck`로 hc에 다시 묻는다.
    nonisolated static func plan(paneId: String, address: String?, machine: String?, machineSeen: Bool,
                                 store: HcEventStore, instance: String) -> AttachPlan {
        if let address {
            if let record = store.terminals[address] {
                return record.state == "finished" ? .finished(record) : .attach(address)
            }
            // 원격 terminal은 그 머신의 줄이 다시 이어질 때까지 snapshot에 없을 수 있다(core 재시작 직후 등).
            // 그 머신에서는 살아 있으므로 새로 띄우면 셸이 둘이 된다. `created`가 다시 오면 붙는다.
            if let machine = HcAddress.machine(of: address) { return .waitForMachine(machine) }
        }
        let mine = store.termyTerminals(instance: instance).first { $0.labels["termy.pane"] == paneId }
        if let mine { return .attach(mine.address) }
        if let machine, !machineSeen { return .awaitMachine(machine) }
        return .run
    }

    enum RemoteRunCheck: Equatable {
        case attach(String), wait(HcPaneConnectionState), run
    }

    /// address를 모르는 원격 pane이 terminal.run 직전에 하는 확인(`terminal.list {labels}`의 결과로 정한다).
    /// 머신을 "봤다"는 신호는 그 머신의 terminal이 store에 오기 전에도 올 수 있다(줄이 이어진 것과 그 머신의 구독이
    /// 이어진 것은 따로 온다). 그래서 hc에 직접 묻는다: 이 pane의 살아 있는 terminal이 있으면 붙고, 그 머신이
    /// connected가 아니면 기다리고, 둘 다 아니면 띄운다. 필터를 모르는 core가 다 돌려줘도 label을 다시 본다.
    nonisolated static func remoteRunCheck(paneId: String, instance: String, machine: String,
                                           terminals: [HcTerminal], machines: [HcMachine]) -> RemoteRunCheck {
        let mine = terminals.first {
            $0.state == "live" && $0.labels["termy.pane"] == paneId && $0.labels["termy.instance"] == instance
        }
        if let mine { return .attach(mine.address) }
        if let line = machines.first(where: { $0.name == machine }), line.state != "connected" {
            return .wait(waitingState(machine: machine, lineState: line.state))
        }
        return .run
    }

    /// 머신을 기다리는 원격 pane의 상태. 로그인이 필요하거나 닿지 않으면 머신 이름과 이유를 보여 주고, 연결 중이거나
    /// 아직 모르면 연결 중으로 둔다.
    nonisolated static func waitingState(machine: String, lineState: String?) -> HcPaneConnectionState {
        switch lineState {
        case "needs_login": return .unavailable("\(machine) needs login")
        case "unreachable": return .unavailable("\(machine) unreachable")
        default: return .connecting
        }
    }

    static func paneLookupParams(paneId: String, instance: String) -> HcPaneLookupParams {
        HcPaneLookupParams(labels: ["termy.pane": paneId, "termy.instance": instance])
    }

    /// 원격 pane의 terminal.run 직전 확인. nil이면 이번 attach를 그만둔다(호출 실패·머신 대기·pane이 닫힘;
    /// 상태는 여기서 정했다).
    private func checkBeforeRemoteRun(machine: String, on conn: HcConnection) async -> RemoteRunCheck? {
        setState(.connecting)
        let instance = HcSessionManager.instanceLabel
        let lookup: HcPaneLookup
        do {
            lookup = try await conn.call("terminal.list", Self.paneLookupParams(paneId: paneId, instance: instance))
        } catch {
            attachFailed(error, address: nil)
            return nil
        }
        let check = Self.remoteRunCheck(paneId: paneId, instance: instance, machine: machine,
                                        terminals: lookup.terminals, machines: lookup.machines ?? [])
        if lifecycle == .killed, case .attach(let found) = check {
            manager.kill(address: found, paneId: paneId)   // 묻는 사이에 pane이 닫혔다
        }
        guard lifecycle == .running else { return nil }
        if case .wait(let state) = check {
            setState(state)
            return nil
        }
        return check
    }

    private func plan() -> AttachPlan {
        Self.plan(paneId: paneId, address: address, machine: launch.machine,
                  machineSeen: launch.machine.map { manager.hasSeenMachine($0) } ?? true,
                  store: manager.store, instance: HcSessionManager.instanceLabel)
    }

    private struct AttachParams: Encodable, Sendable {
        let terminal: String
        let cols: UInt16
        let rows: UInt16
        let history: Int
        let display: Display
    }

    private struct AttachResult: Decodable, Sendable {
        let channel: UInt32
        let terminal: HcTerminal
    }

    struct Display: Encodable, Sendable {
        let bg: String
        let fg: String
        let cursor: String
        let cell: [Int]
    }

    private func performAttach(on conn: HcConnection, epoch: Int) async {
        let target: String
        var history = Self.restoreHistory
        switch plan() {
        case .finished(let record):
            programEnded(exitCode: record.exitCode, reason: record.reason)
            return
        case .waitForMachine(let machine):
            setState(.unavailable("\(machine) is not connected"))
            return
        case .awaitMachine(let machine):
            // manager가 그 머신을 보면(machine.list, 그 머신의 terminal이나 `missed`) 다시 부른다.
            setState(Self.waitingState(machine: machine, lineState: manager.machineLineState(machine)))
            manager.refreshMachines()
            return
        case .attach(let found):
            target = found
        case .run:
            if let machine = launch.machine {
                guard let check = await checkBeforeRemoteRun(machine: machine, on: conn) else { return }
                if case .attach(let found) = check {
                    target = found
                    break
                }
            }
            let params = Self.runParams(paneId: paneId, projectKey: projectKey, projectId: projectId, launch: launch,
                                        instance: HcSessionManager.instanceLabel,
                                        baseEnvironment: ProcessInfo.processInfo.environment)
            let record: HcTerminal
            do {
                record = try await conn.call("terminal.run", params)
            } catch {
                attachFailed(error, address: nil)
                return
            }
            if lifecycle == .killed {
                manager.kill(address: record.address, paneId: paneId)   // run이 도는 사이에 pane이 닫혔다
                return
            }
            target = record.address
            history = 0
        }
        guard lifecycle == .running else { return }
        address = target

        // 처음 크기는 지금 grid에서 바로 읽는다(onGridSizeChanged는 이후 변화에만 불린다).
        let grid = view.getTerminal()
        let params = AttachParams(terminal: target, cols: UInt16(clamping: grid.cols), rows: UInt16(clamping: grid.rows),
                                  history: history, display: displayFacts())
        let result: AttachResult
        do {
            result = try await conn.call("terminal.attach", params)
        } catch {
            attachFailed(error, address: target)
            return
        }
        let stream = await conn.stream(result.channel)
        guard lifecycle == .running, manager.liveConnection?.connection === conn else {
            // 기다리는 사이에 pane이 닫혔거나 연결이 바뀌었다. 받은 channel을 놓는다.
            Task { await conn.send(.close(channel: result.channel)) }
            return
        }
        openSession(stream, channel: result.channel, on: conn, epoch: epoch)
        // 응답을 기다리는 사이 grid가 바뀌었으면 그 RESIZE는 session이 없어 버려졌다(view는 이미 알렸다고 기억한다).
        // 지금 크기를 한 번 보낸다. 그러지 않으면 프로그램이 attach 때의 크기에 머문다.
        let now = view.getTerminal()
        if UInt16(clamping: now.cols) != params.cols || UInt16(clamping: now.rows) != params.rows {
            sendResize(cols: now.cols, rows: now.rows)
        }
        setState(.attached)
        if focused == true { setFocused(true) }
        onStatus?(result.terminal.status)
        onForeground?(result.terminal.foreground)
    }

    private func attachFailed(_ error: Error, address target: String?) {
        guard lifecycle == .running else { return }
        switch error {
        case HcError.rpc(kind: "finished", _):
            // 붙기 전에 끝났다. exit code는 레코드에서(아직 모르면 -1).
            finish(exitCode: target.flatMap { manager.store.terminals[$0]?.exitCode } ?? -1)
        case HcError.rpc(kind: "unavailable", _):
            setState(.restartingShell)   // lost 뒤 새 셸을 기다리는 중: `restarted`가 오면 다시 붙는다
        case HcError.disconnected:
            break   // manager가 다시 연결한 뒤 reattach를 부른다
        default:
            setState(.unavailable(HcSessionManager.describe(error)))
        }
    }

    // MARK: - stream

    private func openSession(_ stream: AsyncStream<HcStreamEvent>, channel: UInt32, on conn: HcConnection, epoch: Int) {
        nextSessionID += 1
        let id = nextSessionID
        let (outbox, outboxContinuation) = AsyncStream.makeStream(of: HcFrame.self)
        Task.detached {
            for await frame in outbox { await conn.send(frame) }
        }
        let reader = Task { [weak self] in
            for await event in stream {
                guard let self, session?.id == id else { break }
                switch event {
                case .data(let bytes):
                    view.receiveRemote(ArraySlice(bytes))
                    outboxContinuation.yield(.credit(channel: channel, bytes: UInt32(bytes.count)))
                case .closed(let json):
                    streamClosed(id: id, json: json)
                }
            }
            self?.streamEnded(id: id)
        }
        session = Session(id: id, epoch: epoch, channel: channel, outbox: outboxContinuation, reader: reader)
    }

    private func streamClosed(id: Int, json: Data?) {
        guard session?.id == id else { return }
        dropSession(sendClose: false)
        switch Self.closeOutcome(json: json) {
        case .exited(let code):
            finish(exitCode: code)
        case .unavailable(let reason):
            // kept terminal의 loss면 레코드는 live로 남는다: 새 셸(`restarted`)을 기다린다.
            if let address, manager.store.terminals[address]?.state == "live" {
                setState(.restartingShell)
            } else {
                setState(.unavailable(reason))
            }
        }
    }

    /// CLOSE 없이 stream이 끝났다(연결이 끊김). 상태는 manager의 connectionLost가 정한다.
    private func streamEnded(id: Int) {
        guard session?.id == id else { return }
        dropSession(sendClose: false)
    }

    private func dropSession(sendClose: Bool) {
        guard let session else { return }
        self.session = nil
        if sendClose { session.outbox.yield(.close(channel: session.channel)) }
        session.outbox.finish()   // writer는 이미 넣은 frame(CLOSE 포함)을 다 쓰고 끝난다
        session.reader.cancel()
    }

    private func sendInput(_ bytes: ArraySlice<UInt8>) {
        guard let session else { return }   // 붙어 있지 않으면 버린다(pane이 이유를 보여 준다)
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let end = bytes.index(start, offsetBy: Self.inputChunk, limitedBy: bytes.endIndex) ?? bytes.endIndex
            session.outbox.yield(HcFrame(channel: session.channel, kind: .data, payload: Data(bytes[start..<end])))
            start = end
        }
    }

    private func sendResize(cols: Int, rows: Int) {
        guard let session else { return }   // 다음 attach가 그때의 크기를 보낸다
        session.outbox.yield(.resize(channel: session.channel, cols: UInt16(clamping: cols), rows: UInt16(clamping: rows)))
    }

    // MARK: - 끝

    private func programEnded(exitCode: Int32?, reason: String?) {
        switch Self.outcome(reason: reason, exitCode: exitCode) {
        case .exited(let code):
            finish(exitCode: code)
        case .unavailable(let why):
            dropSession(sendClose: false)
            setState(.unavailable(why))
        }
    }

    private func finish(exitCode: Int32) {
        guard lifecycle == .running else { return }
        lifecycle = .exited
        dropSession(sendClose: false)
        manager.unregister(self)
        onExit?(exitCode)
    }

    private func setState(_ state: HcPaneConnectionState) {
        guard lifecycle == .running, state != connectionState else { return }
        connectionState = state
        onConnectionState?(state)
    }

    // MARK: - display facts

    private func displayFacts() -> Display {
        let grid = view.getTerminal()
        let cursorColor = [view.pinnedCaretColor, view.caretColor].compactMap { $0 }
            .first { $0.alphaComponent > 0 } ?? view.nativeForegroundColor
        return Display(bg: Self.hex(view.nativeBackgroundColor), fg: Self.hex(view.nativeForegroundColor),
                       cursor: Self.hex(cursorColor),
                       cell: [Int((view.frame.width / CGFloat(max(grid.cols, 1))).rounded()),
                              Int((view.frame.height / CGFloat(max(grid.rows, 1))).rounded())])
    }

    static func hex(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "#000000" }
        func byte(_ v: CGFloat) -> Int { min(255, max(0, Int((v * 255).rounded()))) }
        return String(format: "#%02x%02x%02x", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}
