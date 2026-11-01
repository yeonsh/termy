import Foundation
import os

// termy 프로세스 하나에 herdr-core 연결 하나. hc pane들이 이 연결과 events 구독 하나를 나눠 쓴다.
// 필요할 때만 연결한다(처음 ensureConnected를 부를 때). 연결이 끊기면(core 재시작·업데이트, connect가 죽음)
// 0.5, 1, 2, 4, 8, 15초(이후 15초) 간격으로 다시 연결하고, seq가 새로 시작하므로 snapshot을 새로 받은 뒤
// 등록된 backend마다 reattach()를 부른다. backend는 같은 terminal에 다시 붙기만 하고 새 terminal을 만들지
// 않는다. events는 필터 없이 하나만 구독하고, 변화는 address로 해당 backend에 넘긴다.
// kill은 앱이 곧 끝날 때도 hc에 닿아야 하므로 보류 목록에 넣고, 쓰기는 main actor를 기다리지 않는 task에서
// 한다. AppDelegate는 종료 직전에 flushPendingKills로 응답을 기다린다.
// 원격 머신은 연결마다 그 머신이 연결된 것을 봤는지(machine.list의 connected, 그 머신의 terminal이나 `missed`)
// 기억한다. address를 모르는 원격 pane은 그 전에는 새 셸을 띄우지 않는다: 머신 줄이 다시 이어지기 전에는 살아
// 있는 그 pane의 terminal이 snapshot에 없어서, 띄우면 셸이 둘이 된다. "봤다"는 깨우는 신호일 뿐이고(줄이
// 이어진 뒤에도 그 머신의 terminal은 늦게 온다), 띄우기 직전에 backend가 terminal.list로 다시 확인한다.
// address를 모른 채 닫힌 pane의 terminal은 나중에 오는 대로 kill한다.

enum HcAvailability: Equatable, Sendable {
    case notInstalled, connecting, connected(version: String), unavailable(String)
}

struct HcMachine: Decodable, Sendable, Equatable {
    let name: String
    let host: String?
    let state: String
    let why: String?
}

@MainActor
final class HcSessionManager {
    /// 앱이 쓰는 manager. 통합 테스트는 scratch core나 endpoint 없는 manager로 바꿔 끼우고 되돌린다.
    static var shared = HcSessionManager(endpointProvider: {
        HcLocator.find(environment: ProcessInfo.processInfo.environment)
            .map { HcEndpoint(executable: $0, session: nil, extraEnvironment: [:]) }
    })

    /// `termy.instance` label 값. Debug와 release termy가 같은 core를 써도 서로의 terminal을 건드리지 않게 한다.
    nonisolated static var instanceLabel: String {
        if let value = ProcessInfo.processInfo.environment["TERMY_INSTANCE"], !value.isEmpty { return value }
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    nonisolated private static let reconnectDelays: [Double] = [0.5, 1, 2, 4, 8, 15]

    /// attempt번째(0부터) 재연결 시도 전에 기다리는 초.
    nonisolated static func reconnectDelay(attempt: Int) -> Double {
        reconnectDelays[min(max(attempt, 0), reconnectDelays.count - 1)]
    }

    nonisolated private static let log = Logger(subsystem: "app.termy", category: "hc")

    private(set) var availability: HcAvailability = .unavailable("not connected")
    var onAvailabilityChange: ((HcAvailability) -> Void)?
    private(set) var store = HcEventStore(seq: 0, terminals: [])
    /// 연결이 새로 될 때마다 1씩 오른다. backend는 자기 attach가 지금 연결의 것인지 이것으로 안다.
    private(set) var epoch = 0

    private let endpointProvider: () -> HcEndpoint?
    private var connection: HcConnection?
    private var connectTask: Task<Void, Error>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var isShutDown = false
    private var backends: [ObjectIdentifier: WeakBackend] = [:]
    /// kill할 address → 지금 연결에서 terminal.kill을 보내 응답을 기다리는 중인지.
    private var pendingKills: [String: Bool] = [:]
    /// address를 모르는 채 닫힌 pane(연결 전·unavailable). 연결되면 label로 찾아 kill한다.
    private var pendingPaneKills: Set<String> = []
    /// address를 모른 채 닫힌 pane들(앱이 도는 동안). 끊겨 있던 머신의 terminal은 줄이 다시 이어진 뒤에야
    /// (`missed`·`created`) 오므로, 그때 이 label의 terminal을 kill한다. 종료 때 기다리는 kill에는 세지 않는다.
    private var closedPaneIds: Set<String> = []
    private var flushWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// 지금 연결(구독)에서 연결된 것을 본 원격 머신. 연결이 바뀌면 비운다.
    private var seenMachines: Set<String> = []
    /// 지금 연결에서 machine.list가 마지막으로 알려 준 머신 줄 상태(connecting, connected, needs_login, unreachable).
    private var machineLines: [String: String] = [:]
    private var machineRefresh: Task<Void, Never>?
    /// machine.list가 도는 사이에 다시 요청이 왔다(그사이 머신이 붙었을 수 있다): 끝나면 한 번 더 부른다.
    private var machineRefreshAgain = false

    private struct WeakBackend { weak var value: HcPaneBackend? }

    init(endpointProvider: @escaping () -> HcEndpoint?) {
        self.endpointProvider = endpointProvider
    }

    /// 지금 쓸 수 있는 연결과 그 epoch. backend가 한 attach의 호출을 모두 같은 연결로 보내는 데 쓴다.
    var liveConnection: (connection: HcConnection, epoch: Int)? {
        connection.map { ($0, epoch) }
    }

    // MARK: - 연결

    func ensureConnected() async throws {
        if connection != nil { return }
        if let connectTask { return try await connectTask.value }
        let task = Task { try await self.connect() }
        connectTask = task
        defer { if connectTask == task { connectTask = nil } }
        do {
            try await task.value
        } catch {
            scheduleReconnect()
            throw error
        }
    }

    private func connect() async throws {
        guard !isShutDown else { throw HcError.disconnected }
        guard let endpoint = endpointProvider() else {
            setAvailability(.notInstalled)
            connectFailed(HcError.notInstalled)
            throw HcError.notInstalled
        }
        setAvailability(.connecting)
        let conn = HcConnection(endpoint: endpoint)
        let hello: HcHello
        let subscription: HcSubscribeResult
        let channel: UInt32
        let events: AsyncStream<HcStreamEvent>
        do {
            hello = try await conn.open()
            subscription = try await conn.call("events.subscribe", HcEmptyParams())
            guard let subscribed = subscription.channel else {
                throw HcError.protocolViolation("events.subscribe returned no channel")
            }
            channel = subscribed
            events = await conn.stream(channel)
            guard !isShutDown else { throw HcError.disconnected }
        } catch {
            await conn.close()
            if !isShutDown {
                setAvailability(.unavailable(Self.describe(error)))
                connectFailed(error)
            }
            throw error
        }

        // 여기부터 await 없이 한 번에 바꾼다: 새 연결, 새 snapshot, 그다음 backend들.
        epoch += 1
        connection = conn
        reconnectAttempt = 0
        store = HcEventStore(seq: subscription.seq, terminals: subscription.terminals)
        seenMachines = Self.machines(of: subscription.terminals)
        machineLines = [:]
        readEvents(events, channel: channel, on: conn, epoch: epoch)
        watchDisconnect(conn)
        setAvailability(.connected(version: hello.version))
        resolvePaneKills()
        for address in pendingKills.keys where pendingKills[address] == false { sendKill(address, on: conn) }
        for backend in liveBackends { backend.reattach() }
    }

    private func connectFailed(_ error: Error) {
        let reason = Self.describe(error)
        for backend in liveBackends { backend.connectionFailed(reason) }
    }

    private func watchDisconnect(_ conn: HcConnection) {
        let disconnected = conn.disconnected
        Task { [weak self] in
            for await reason in disconnected {
                if let reason { Self.log.info("hc connection ended: \(String(describing: reason), privacy: .public)") }
                break
            }
            self?.connectionDropped(conn)
        }
    }

    private func connectionDropped(_ conn: HcConnection) {
        guard connection === conn else { return }
        connection = nil
        seenMachines = []
        machineLines = [:]
        Task { await conn.close() }   // 이미 끊겼어도 닫아 두고 참조를 놓는다(fd는 해제될 때 닫힌다)
        guard !isShutDown else { return }
        setAvailability(.connecting)
        for backend in liveBackends { backend.connectionLost() }
        scheduleReconnect()
    }

    /// 연결이 없고 기다리는 pane이나 kill이 있으면 간격을 늘려 가며 다시 연결한다.
    private func scheduleReconnect() {
        guard reconnectTask == nil, !isShutDown, needsConnection, connection == nil else { return }
        reconnectTask = Task { [weak self] in
            while true {
                // 기다리는 동안 manager를 붙잡지 않는다(테스트가 바꿔 끼운 manager가 풀리게).
                guard let delay = self?.nextReconnectDelay() else { break }
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                guard connection == nil, needsConnection, !isShutDown else { break }
                if (try? await ensureConnected()) != nil { break }
            }
            self?.reconnectTask = nil
        }
    }

    private func nextReconnectDelay() -> Double? {
        guard !isShutDown, needsConnection, connection == nil else { return nil }
        defer { reconnectAttempt += 1 }
        return Self.reconnectDelay(attempt: reconnectAttempt)
    }

    private var needsConnection: Bool {
        !liveBackends.isEmpty || !pendingKills.isEmpty || !pendingPaneKills.isEmpty
    }

    /// 연결을 닫고 다시 연결하지 않는다. 테스트가 scratch core를 멈추기 전에 부른다.
    func shutdown() async {
        isShutDown = true
        reconnectTask?.cancel()
        reconnectTask = nil
        let conn = connection
        connection = nil
        for backend in liveBackends { backend.connectionLost() }
        let waiters = flushWaiters
        flushWaiters = [:]
        for waiter in waiters.values { waiter.resume() }
        await conn?.close()
    }

    /// 테스트 전용: connect 프로세스를 끝내 core 재시작 때처럼 연결이 끊기게 한다.
    func _debugTerminateConnection() async {
        await connection?._debugTerminateProcess()
    }

    private func setAvailability(_ value: HcAvailability) {
        guard value != availability else { return }
        availability = value
        onAvailabilityChange?(value)
    }

    // MARK: - events

    /// events channel의 DATA frame 하나는 `\n`으로 끝나는 JSON-RPC 알림 한 줄이다(줄이 frame에 걸칠 수도 있게
    /// 모아서 나눈다). 읽은 바이트만큼 CREDIT을 돌려주지 않으면 256 KiB 뒤 이벤트가 멈춘다.
    private func readEvents(_ events: AsyncStream<HcStreamEvent>, channel: UInt32, on conn: HcConnection, epoch: Int) {
        Task { [weak self] in
            var pending = Data()
            for await event in events {
                guard case .data(let chunk) = event else {
                    // core가 구독 channel을 닫았다. 연결이 끊겨 stream이 끝난 경우는 watchDisconnect가 맡는다.
                    await self?.eventsClosed(conn)
                    return
                }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = Data(pending[pending.startIndex..<newline])
                    pending.removeSubrange(pending.startIndex...newline)
                    self?.handleEventLine(line, epoch: epoch)
                }
                await conn.send(.credit(channel: channel, bytes: UInt32(chunk.count)))
            }
        }
    }

    /// 구독 channel이 연결보다 먼저 끝나면 그 연결로는 변화를 더 받지 못한다. 닫아서 재연결 경로를 탄다.
    private func eventsClosed(_ conn: HcConnection) async {
        guard connection === conn else { return }
        Self.log.error("hc events channel closed while the connection was open; reconnecting")
        await conn.close()
    }

    /// `machine`은 schema에 없지만 원격 머신의 `missed`가 그 이름을 실어 오면 쓴다.
    private struct MissedParams: Decodable { let seq: UInt64; let terminals: [HcTerminal]; let machine: String? }

    private func handleEventLine(_ line: Data, epoch: Int) {
        guard epoch == self.epoch, line.contains(where: { $0 != 0x20 && $0 != 0x0D }) else { return }
        guard case .notification(let method, let raw)? = try? HcRPC.parse(line) else {
            Self.log.error("hc: unreadable events line: \(String(decoding: line.prefix(256), as: UTF8.self), privacy: .public)")
            return
        }
        switch method {
        case "event":
            guard let event = try? HcEvent.decode(notification: raw) else {
                Self.log.error("hc: undecodable event: \(String(decoding: raw.prefix(256), as: UTF8.self), privacy: .public)")
                return
            }
            if let change = store.apply(event) { route(change) }
            // 원격 terminal의 이벤트가 왔다: 그 머신의 줄이 이어져 있다.
            if let address = event.terminal, let machine = HcAddress.machine(of: address) { markMachinesSeen([machine]) }
        case "missed":
            guard let missed = try? HcRPC.decodeParams(MissedParams.self, from: raw) else {
                Self.log.error("hc: undecodable missed notification")
                return
            }
            store.resetFromMissed(seq: missed.seq, terminals: missed.terminals)
            killTerminalsOfClosedPanes(missed.terminals)
            // 원격 머신의 구독이 (다시) 이어질 때도 `missed`로 온다. 이름이 없으면 waiting pane이 machine.list로 다시 본다.
            markMachinesSeen(Self.machines(of: missed.terminals).union(missed.machine.map { [$0] } ?? []))
            for backend in liveBackends { backend.resync() }
        default:
            break   // heartbeat
        }
    }

    private func route(_ change: HcTerminalChange) {
        switch change {
        case .upserted(let t):
            killTerminalsOfClosedPanes([t])
            (backend(for: t.address) ?? waitingBackend(for: t))?.terminalUpserted(t)
        case .removed: break   // 붙어 있었다면 stream CLOSE가 따로 온다
        case .status(let address, let status): backend(for: address)?.statusChanged(status)
        case .foreground(let address, let fg): backend(for: address)?.foregroundChanged(fg)
        case .lost(let address, _): backend(for: address)?.terminalLost()
        case .restarted(let t):
            killTerminalsOfClosedPanes([t])
            backend(for: t.address)?.terminalRestarted()
        case .finished(let address, let code, let reason): backend(for: address)?.terminalFinished(exitCode: code, reason: reason)
        }
    }

    // MARK: - backend 등록

    func register(_ backend: HcPaneBackend) {
        backends = backends.filter { $0.value.value != nil }
        backends[ObjectIdentifier(backend)] = WeakBackend(value: backend)
        closedPaneIds.remove(backend.paneId)   // 같은 id로 다시 연 pane의 terminal은 kill하지 않는다
    }

    func unregister(_ backend: HcPaneBackend) {
        backends[ObjectIdentifier(backend)] = nil
    }

    private var liveBackends: [HcPaneBackend] { backends.values.compactMap(\.value) }

    private func backend(for address: String) -> HcPaneBackend? {
        liveBackends.first { $0.address == address }
    }

    /// 아직 address를 모르는 backend(복원 때 머신이 끊겨 있던 원격 pane 등) 가운데 이 terminal의 pane.
    private func waitingBackend(for terminal: HcTerminal) -> HcPaneBackend? {
        guard terminal.labels["termy.instance"] == Self.instanceLabel, let pane = terminal.labels["termy.pane"] else { return nil }
        return liveBackends.first { $0.address == nil && $0.paneId == pane }
    }

    // MARK: - 호출

    func call<R: Decodable & Sendable>(_ method: String, _ params: some Encodable & Sendable) async throws -> R {
        try await ensureConnected()
        guard let conn = connection else { throw HcError.disconnected }
        return try await conn.call(method, params)
    }

    private struct MachineList: Decodable, Sendable { let machines: [HcMachine] }

    func machines() async throws -> [HcMachine] {
        let result: MachineList = try await call("machine.list", HcEmptyParams())
        return result.machines
    }

    // MARK: - 원격 머신을 봤는지

    /// 지금 연결에서 이 머신이 연결된 것을 봤는지. address를 모르는 원격 pane을 깨우는 신호일 뿐이고, 띄울지는
    /// 띄우기 직전에 terminal.list로 다시 확인한다(HcPaneBackend.remoteRunCheck).
    func hasSeenMachine(_ name: String) -> Bool {
        seenMachines.contains(name)
    }

    /// machine.list가 마지막으로 알려 준 이 머신의 줄 상태. 아직 모르면 nil.
    func machineLineState(_ name: String) -> String? {
        machineLines[name]
    }

    nonisolated static func machines(of terminals: [HcTerminal]) -> Set<String> {
        Set(terminals.compactMap { HcAddress.machine(of: $0.address) })
    }

    /// 머신을 기다리는 pane이 부른다. 지금 연결에서 machine.list를 읽어 connected인 머신을 본 것으로 친다.
    func refreshMachines() {
        guard let conn = connection else { return }   // 연결되면 backend들이 다시 plan을 돌린다
        if machineRefresh != nil {
            machineRefreshAgain = true
            return
        }
        let epoch = self.epoch
        machineRefresh = Task { [weak self] in
            let result: MachineList? = try? await conn.call("machine.list", HcEmptyParams())
            self?.machinesListed(result?.machines, epoch: epoch)
        }
    }

    private func machinesListed(_ machines: [HcMachine]?, epoch: Int) {
        machineRefresh = nil
        if let machines, epoch == self.epoch, connection != nil {
            for machine in machines { machineLines[machine.name] = machine.state }
            markMachinesSeen(Set(machines.filter { $0.state == "connected" }.map(\.name)))
            // 아직 기다리는 pane에는 그 머신의 줄 상태(로그인 필요·닿지 않음)를 보여 준다.
            for backend in liveBackends where backend.address == nil { backend.machineLineChanged() }
        }
        if machineRefreshAgain {
            machineRefreshAgain = false
            refreshMachines()
        }
    }

    /// 새로 본 머신이 있으면 그 머신을 기다리던 pane(address 없음)을 다시 붙인다.
    private func markMachinesSeen(_ names: Set<String>) {
        let new = names.subtracting(seenMachines)
        guard !new.isEmpty else { return }
        seenMachines.formUnion(new)
        for backend in liveBackends where backend.address == nil {
            if let machine = backend.launch.machine, new.contains(machine) { backend.reattach() }
        }
    }

    private struct ExecParams: Encodable, Sendable { let argv: [String]; let on: String?; let timeout: Int }
    private struct ExecResult: Decodable, Sendable { let code: Int32? }

    /// exit code만 돌려준다. signal로 끝났거나 시간이 다 돼 code가 없으면 -1.
    func exec(on machine: String?, argv: [String], timeout: Int = 10) async throws -> Int32 {
        let result: ExecResult = try await call("machine.exec", ExecParams(argv: argv, on: machine, timeout: timeout))
        return result.code ?? -1
    }

    // MARK: - kill

    private struct KillParams: Encodable, Sendable { let terminal: String }
    /// 응답 본문(terminal 레코드)은 쓰지 않는다. 모양이 바뀌어도 kill이 실패로 남지 않게 아무것도 읽지 않는다.
    private struct Ignored: Decodable, Sendable { init(from decoder: Decoder) {} }

    func kill(address: String) {
        guard pendingKills[address] == nil else { return }
        pendingKills[address] = false
        if let conn = connection {
            sendKill(address, on: conn)
        } else {
            Task { try? await self.ensureConnected() }
        }
    }

    /// address를 모르는 pane을 닫을 때. 연결되면 그 pane label의 살아 있는 terminal을 kill하고, 아직 오지 않은
    /// terminal(끊겨 있던 원격 머신의 것)은 나중에 오는 대로 kill한다.
    func killPane(paneId: String) {
        pendingPaneKills.insert(paneId)
        if connection != nil {
            resolvePaneKills()
        } else {
            Task { try? await self.ensureConnected() }
        }
    }

    private func resolvePaneKills() {
        closedPaneIds.formUnion(pendingPaneKills)
        pendingPaneKills = []
        killTerminalsOfClosedPanes(Array(store.terminals.values))
        resumeFlushWaitersIfDone()
    }

    private func killTerminalsOfClosedPanes(_ terminals: [HcTerminal]) {
        for address in Self.terminalsOfClosedPanes(closedPaneIds, in: terminals, instance: Self.instanceLabel) {
            kill(address: address)
        }
    }

    /// 닫은 pane(`closed`)의 label이 붙은, 이 instance의 살아 있는 terminal 주소.
    nonisolated static func terminalsOfClosedPanes(_ closed: Set<String>, in terminals: [HcTerminal], instance: String) -> [String] {
        guard !closed.isEmpty else { return [] }
        return terminals.filter {
            $0.state == "live" && $0.labels["termy.instance"] == instance && closed.contains($0.labels["termy.pane"] ?? "")
        }.map(\.address)
    }

    /// main actor가 막혀 있어도(앱 종료 중) 쓰기가 나가도록 actor 밖의 task에서 보낸다.
    private func sendKill(_ address: String, on conn: HcConnection) {
        pendingKills[address] = true
        Task.detached { [weak self] in
            var done = true
            do {
                let _: Ignored = try await conn.call("terminal.kill", KillParams(terminal: address))
            } catch HcError.rpc(let kind, let message) {
                // not_found 등: 이미 없는 terminal이다. 다시 보낼 것이 없다.
                Self.log.info("hc: terminal.kill \(address, privacy: .public): \(kind ?? "", privacy: .public) \(message, privacy: .public)")
            } catch {
                done = false   // 연결이 끊겼다: 다음 연결에서 다시 보낸다
            }
            await self?.killFinished(address, done: done)
        }
    }

    private func killFinished(_ address: String, done: Bool) {
        if done {
            pendingKills[address] = nil
            resumeFlushWaitersIfDone()
        } else if pendingKills[address] != nil {
            pendingKills[address] = false
            if let conn = connection { sendKill(address, on: conn) } else { scheduleReconnect() }
        }
    }

    /// 이 terminal에 kill을 보냈거나 보낼 참인지(pane은 이미 닫혔다).
    func isKilling(address: String) -> Bool {
        pendingKills[address] != nil
    }

    /// 응답을 기다리는 kill이 있는지. 종료 직전 AppDelegate가 기다릴지 정하는 데 쓴다.
    var hasPendingKills: Bool { !pendingKills.isEmpty || !pendingPaneKills.isEmpty }

    /// 보류 중인 kill이 모두 hc의 응답을 받거나 timeout이 지날 때까지 기다린다.
    func flushPendingKills(timeout: TimeInterval) async {
        guard hasPendingKills, !isShutDown else { return }
        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            flushWaiters[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.flushWaiters.removeValue(forKey: id)?.resume()
            }
        }
    }

    private func resumeFlushWaitersIfDone() {
        guard !hasPendingKills else { return }
        let waiters = flushWaiters
        flushWaiters = [:]
        for waiter in waiters.values { waiter.resume() }
    }

    // MARK: - 표시

    /// pane 상태 줄("herdr-core unavailable: <reason>")과 설정 화면에 쓰는 짧은 이유.
    nonisolated static func describe(_ error: Error) -> String {
        guard let error = error as? HcError else { return error.localizedDescription }
        switch error {
        case .notInstalled: return "not installed"
        case .launchFailed(let message): return message
        case .incompatibleGeneration(let generation):
            return "protocol generation \(generation) is not supported; update termy"
        case .missingMethods(let methods):
            return "herdr-core is too old (missing \(methods.joined(separator: ", "))); run `hc update`"
        case .rpc(_, let message): return message
        case .disconnected: return "disconnected"
        case .protocolViolation(let message): return "protocol error: \(message)"
        }
    }
}

/// framed mode의 `events.subscribe` 결과.
struct HcSubscribeResult: Decodable, Sendable {
    let channel: UInt32?
    let seq: UInt64
    let terminals: [HcTerminal]
}
