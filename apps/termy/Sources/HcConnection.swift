import Foundation

// termy와 herdr-core(hc) 사이의 연결 하나. 소켓을 직접 열지 않고 `herdr-core connect` 자식 프로세스의
// stdin/stdout으로 말한다. connect는 core가 없으면 띄우고, 원격 core도 같은 모양(`ssh box hc connect`)이다.
// plain mode에서 hello 한 줄을 주고받은 뒤 framed mode로 바뀐다. channel 0은 JSON-RPC, 나머지 channel은
// attach/events 스트림이다. attach 응답과 그 channel의 first paint는 연달아 와서 호출부가 stream(_:)을
// 부르기 전에 도착하므로, 아직 아무도 받지 않는 channel의 frame도 버리지 않고 모아 둔다.

struct HcHello: Decodable, Sendable {
    let generation: Int
    let methods: [String]
    let version: String
    let features: [String]
}

enum HcError: Error, Equatable {
    case notInstalled
    case launchFailed(String)
    case incompatibleGeneration(Int)
    case missingMethods([String])
    case rpc(kind: String?, message: String)
    case disconnected
    case protocolViolation(String)
}

enum HcStreamEvent: Sendable {
    case data(Data)
    /// core가 보낸 CLOSE의 JSON(`{"reason":"exited","exit_code":0,…}`). viewer CLOSE에 대한 빈 CLOSE면 nil.
    case closed(Data?)
}

/// params가 없는 method에 보내는 `{}`.
struct HcEmptyParams: Encodable, Sendable {}

actor HcConnection {
    static let protocolGeneration = 1
    static let requiredMethods = ["terminal.run", "terminal.attach", "terminal.kill", "terminal.list",
                                  "events.subscribe", "machine.list", "machine.exec"]
    private static let helloTimeout: Duration = .seconds(10)
    /// 프로세스가 끝났는데 stdout EOF가 오지 않을 때(손자 프로세스가 fd를 물려받은 경우) 기다리는 시간.
    private static let exitGrace: Duration = .seconds(1)

    /// 연결이 끝나면 한 번 내보내고 끝난다. 프로세스가 끝나거나 읽기/쓰기가 실패하면 `.disconnected`,
    /// frame이 깨지면 `.protocolViolation`, `open()`이 실패하면 그 오류, `close()`로 닫으면 nil.
    nonisolated let disconnected: AsyncStream<HcError?>
    private let disconnectedContinuation: AsyncStream<HcError?>.Continuation

    private enum State { case idle, opening, open, closed }

    private let endpoint: HcEndpoint
    private var state = State.idle
    private var process: Process?
    private var stdin: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var input: AsyncStream<Data>.Continuation?
    private var helloLine = Data()            // plain mode: hello 응답 줄을 모은다
    private var decoder: HcFrameDecoder?      // hello 응답 뒤 framed mode
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var streams: [UInt32: AsyncStream<HcStreamEvent>.Continuation] = [:]
    /// stream(_:)을 아직 부르지 않은 channel에 온 이벤트. 처음 stream(_:)을 부를 때 순서대로 넘긴다.
    private var early: [UInt32: [HcStreamEvent]] = [:]

    init(endpoint: HcEndpoint) {
        self.endpoint = endpoint
        let (stream, continuation) = AsyncStream.makeStream(of: HcError?.self)
        disconnected = stream
        disconnectedContinuation = continuation
    }

    func open() async throws -> HcHello {
        guard state == .idle else { throw HcError.protocolViolation("open() called twice") }
        let id = takeID()
        let hello = try HcRPC.request(id: id, method: "hello",
                                      params: HelloParams(generation: Self.protocolGeneration, framed: true)) + Data([0x0A])
        state = .opening

        let proc = Process()
        proc.executableURL = endpoint.executable
        proc.arguments = ["connect"]
        proc.environment = endpoint.processEnvironment()
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        // connect가 먼저 끝나도 쓰기가 SIGPIPE로 앱을 끝내지 않고 EPIPE 오류로 돌아오게 한다.
        _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        // readabilityHandler는 직렬로 불리지만 청크마다 Task를 만들면 actor에 닿는 순서가 바뀔 수 있다.
        // 하나의 AsyncStream으로 모아 한 task가 순서대로 decoder에 넣는다.
        let (chunks, input) = AsyncStream.makeStream(of: Data.self)
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                input.finish()
            } else {
                input.yield(chunk)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            Self.log("herdr-core connect: " + String(decoding: chunk, as: UTF8.self))
        }
        proc.terminationHandler = { [weak self] _ in
            Task { await self?.processExited() }
        }
        process = proc
        stdin = inPipe.fileHandleForWriting
        stdoutHandle = outPipe.fileHandleForReading
        stderrHandle = errPipe.fileHandleForReading
        self.input = input
        Task { [weak self] in
            for await chunk in chunks {
                guard let self else { return }
                await self.ingest(chunk)
            }
            await self?.tearDown(.disconnected)
        }

        do {
            try proc.run()
        } catch {
            let reason = HcError.launchFailed(error.localizedDescription)
            tearDown(reason)
            throw reason
        }

        let timeout = Task { [weak self] in
            try await Task.sleep(for: Self.helloTimeout)
            await self?.failPending(id, .launchFailed("no hello reply from herdr-core connect"))
        }
        defer { timeout.cancel() }
        do {
            let raw: Data = try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                write(hello)
            }
            let result: HcHello
            do { result = try HcRPC.decodeResult(HcHello.self, from: raw) } catch {
                throw HcError.protocolViolation("hello result: \(error)")
            }
            guard result.generation == Self.protocolGeneration else {
                throw HcError.incompatibleGeneration(result.generation)
            }
            let missing = Self.requiredMethods.filter { !result.methods.contains($0) }
            guard missing.isEmpty else { throw HcError.missingMethods(missing) }
            guard state == .opening else { throw HcError.disconnected }
            state = .open
            return result
        } catch {
            let reason: HcError
            switch error {
            case HcError.disconnected: reason = .launchFailed("herdr-core connect ended before hello")
            case let e as HcError: reason = e
            default: reason = .protocolViolation("hello: \(error)")
            }
            tearDown(reason)
            throw reason
        }
    }

    func call<R: Decodable & Sendable>(_ method: String, _ params: some Encodable & Sendable) async throws -> R {
        guard state == .open else { throw HcError.disconnected }
        let id = takeID()
        let body: Data
        do { body = try HcRPC.request(id: id, method: method, params: params) } catch {
            throw HcError.protocolViolation("\(method) params: \(error)")
        }
        let raw: Data = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            write(HcFrame(channel: 0, kind: .data, payload: body).encoded())
        }
        do { return try HcRPC.decodeResult(R.self, from: raw) } catch {
            throw HcError.protocolViolation("\(method) result: \(error)")
        }
    }

    /// channel의 DATA/CLOSE. 그 전에 온 frame부터 순서대로 받는다. CLOSE나 연결 끊김에서 끝난다.
    func stream(_ channel: UInt32) -> AsyncStream<HcStreamEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: HcStreamEvent.self)
        guard state != .closed else {
            continuation.finish()
            return stream
        }
        streams.removeValue(forKey: channel)?.finish()
        streams[channel] = continuation
        for event in early.removeValue(forKey: channel) ?? [] { deliver(event, on: channel) }
        return stream
    }

    func send(_ frame: HcFrame) {
        guard state == .open else { return }
        write(frame.encoded())
    }

    func close() {
        tearDown(nil)
    }

    /// 테스트 전용: connect 프로세스만 끝낸다. core 재시작처럼 EOF로 끊기는 경로를 그대로 탄다.
    func _debugTerminateProcess() {
        if let process, process.isRunning { process.terminate() }
    }

    // MARK: - 읽기

    private func ingest(_ chunk: Data) {
        guard state == .opening || state == .open else { return }
        guard decoder == nil else { return decodeFrames(chunk) }
        // plain mode: hello 응답은 `\n`으로 끝나는 한 줄이고 frame 바이트가 같은 청크에 이어 올 수 있다.
        helloLine.append(chunk)
        guard let newline = helloLine.firstIndex(of: 0x0A) else { return }
        let line = Data(helloLine[helloLine.startIndex..<newline])
        let rest = Data(helloLine[helloLine.index(after: newline)...])
        helloLine = Data()
        decoder = HcFrameDecoder()
        handleMessage(line)
        if !rest.isEmpty { decodeFrames(rest) }
    }

    private func decodeFrames(_ bytes: Data) {
        let frames: [HcFrame]
        do { frames = try decoder?.append(bytes) ?? [] } catch {
            Self.log("hc: bad frame from herdr-core connect: \(error)")
            tearDown(.protocolViolation("bad frame: \(error)"))
            return
        }
        for frame in frames where state != .closed { route(frame) }
    }

    private func route(_ frame: HcFrame) {
        if frame.channel == 0 {
            if frame.kind == .data { handleMessage(frame.payload) } else {
                Self.log("hc: ignoring \(frame.kind) frame on channel 0")
            }
            return
        }
        switch frame.kind {
        case .data: deliver(.data(frame.payload), on: frame.channel)
        case .close: deliver(.closed(frame.payload.isEmpty ? nil : frame.payload), on: frame.channel)
        case .credit, .resize, .focus, .facts:
            Self.log("hc: ignoring \(frame.kind) frame on channel \(frame.channel)")
        }
    }

    private func deliver(_ event: HcStreamEvent, on channel: UInt32) {
        guard let continuation = streams[channel] else {
            early[channel, default: []].append(event)
            return
        }
        continuation.yield(event)
        if case .closed = event {
            continuation.finish()
            streams[channel] = nil
        }
    }

    private func handleMessage(_ payload: Data) {
        let message: HcRPCIncoming
        do { message = try HcRPC.parse(payload) } catch {
            // 응답 모양이 예상과 달라도 그 call이 매달리지 않게, id를 읽을 수 있으면 그 call을 끝낸다.
            Self.log("hc: unparseable channel-0 message (\(error)): " + String(decoding: payload.prefix(512), as: UTF8.self))
            if let id = Self.messageID(payload) {
                failPending(id, .protocolViolation("unparseable reply to call \(id)"))
            }
            return
        }
        switch message {
        case .response(let id, let raw):
            guard let continuation = pending.removeValue(forKey: id) else {
                return Self.log("hc: reply to unknown call \(id)")
            }
            continuation.resume(returning: raw)
        case .error(let id, let payload):
            failPending(id, .rpc(kind: payload.kind, message: payload.message))
        case .notification:
            break   // framed mode의 이벤트와 heartbeat는 events.subscribe가 준 channel로 온다
        }
    }

    // MARK: - 쓰기와 정리

    private func write(_ data: Data) {
        guard let stdin else { return }
        do { try stdin.write(contentsOf: data) } catch {
            Self.log("hc: write to herdr-core connect failed: \(error)")
            tearDown(.disconnected)
        }
    }

    private func failPending(_ id: Int, _ error: HcError) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func processExited() {
        guard state != .closed else { return }
        // 보통은 stdout EOF가 곧 와서 남은 frame을 다 읽은 뒤 끊긴다. EOF가 오지 않으면 읽기 stream을 끝낸다.
        // AsyncStream은 이미 받은 청크를 다 넘긴 뒤 끝나므로 reader task가 그것까지 처리하고 끊는다.
        Task { [weak self] in
            try? await Task.sleep(for: Self.exitGrace)
            await self?.finishInput()
        }
    }

    private func finishInput() {
        input?.finish()
    }

    private func tearDown(_ reason: HcError?) {
        guard state != .closed else { return }
        state = .closed
        let calls = pending
        pending = [:]
        for continuation in calls.values { continuation.resume(throwing: HcError.disconnected) }
        for continuation in streams.values { continuation.finish() }
        streams = [:]
        early = [:]
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        input?.finish()
        input = nil
        try? stdin?.close()
        stdin = nil
        if let process, process.isRunning { process.terminate() }
        disconnectedContinuation.yield(reason)
        disconnectedContinuation.finish()
    }

    private func takeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    private static func messageID(_ payload: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        return object["id"] as? Int
    }

    private static func log(_ message: String) {
        NSLog("%@", message)
    }

    private struct HelloParams: Encodable, Sendable {
        let generation: Int
        let framed: Bool
    }
}
