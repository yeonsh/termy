import Foundation

// events.subscribe의 snapshot에 event를 차례로 적용해 terminal 사실을 최신으로 유지한다.
// 적용 규칙은 hc README의 events 표 "apply" 열을 따른다. seq가 이미 본 값 이하이면 무시하고,
// `missed`를 받으면 새 snapshot으로 통째로 바꾼다. pane에 알릴 변화는 HcTerminalChange로 돌려주고,
// 저장만 하는 event(title, size, turn, keep, labels)는 nil이다.

struct HcEventStore: Sendable {
    private(set) var seq: UInt64
    private(set) var terminals: [String: HcTerminal]

    init(seq: UInt64, terminals: [HcTerminal]) {
        self.seq = seq
        self.terminals = Dictionary(terminals.map { ($0.address, $0) }, uniquingKeysWith: { $1 })
    }

    mutating func resetFromMissed(seq: UInt64, terminals: [HcTerminal]) {
        self.seq = seq
        self.terminals = Dictionary(terminals.map { ($0.address, $0) }, uniquingKeysWith: { $1 })
    }

    func termyTerminals(instance: String) -> [HcTerminal] {
        terminals.values
            .filter { $0.state == "live" && $0.labels["termy.instance"] == instance && $0.labels["termy.pane"] != nil }
            .sorted { $0.address < $1.address }
    }

    private struct StatusData: Decodable { let status: HcStatus? }
    private struct TitleData: Decodable { let title: String? }
    private struct SizeData: Decodable { let cols: Int?; let rows: Int? }
    private struct LabelsData: Decodable { let labels: [String: String]?; let record: HcTerminal? }
    private struct EndData: Decodable {
        let reason: String?
        let exitCode: Int32?
        private enum CodingKeys: String, CodingKey { case reason; case exitCode = "exit_code" }
    }

    mutating func apply(_ event: HcEvent) -> HcTerminalChange? {
        guard event.seq > seq else { return nil }
        seq = event.seq
        let decoder = JSONDecoder()

        switch event.type {
        case "created":
            guard let t = try? decoder.decode(HcTerminal.self, from: event.data) else { return nil }
            terminals[t.address] = t
            return .upserted(t)
        case "restarted":
            guard let t = try? decoder.decode(HcTerminal.self, from: event.data) else { return nil }
            terminals[t.address] = t
            return .restarted(t)
        case "removed":
            guard let id = event.terminal, terminals.removeValue(forKey: id) != nil else { return nil }
            return .removed(id)
        case "labels":
            guard let d = try? decoder.decode(LabelsData.self, from: event.data) else { return nil }
            if let record = d.record {
                terminals[record.address] = record
                return .upserted(record)
            }
            if let id = event.terminal, let labels = d.labels { terminals[id]?.labels = labels }
            return nil
        default:
            break
        }

        guard let id = event.terminal, terminals[id] != nil else { return nil }
        switch event.type {
        case "status":
            guard let d = try? decoder.decode(StatusData.self, from: event.data) else { return nil }
            terminals[id]?.status = d.status
            return .status(id, d.status)
        case "foreground":
            // data가 null이면 디코딩 결과도 nil이라 foreground가 지워진다.
            let fg = try? decoder.decode(HcForeground.self, from: event.data)
            terminals[id]?.foreground = fg
            return .foreground(id, fg)
        case "lost":
            guard let d = try? decoder.decode(EndData.self, from: event.data) else { return nil }
            terminals[id]?.exitCode = d.exitCode
            terminals[id]?.reason = d.reason
            terminals[id]?.foreground = nil
            return .lost(id, reason: d.reason ?? "")
        case "finished":
            guard let d = try? decoder.decode(EndData.self, from: event.data) else { return nil }
            terminals[id]?.state = "finished"
            terminals[id]?.exitCode = d.exitCode
            terminals[id]?.reason = d.reason
            terminals[id]?.foreground = nil
            return .finished(id, exitCode: d.exitCode, reason: d.reason ?? "")
        case "title":
            if let d = try? decoder.decode(TitleData.self, from: event.data) { terminals[id]?.title = d.title }
            return nil
        case "size":
            if let d = try? decoder.decode(SizeData.self, from: event.data) {
                terminals[id]?.cols = d.cols
                terminals[id]?.rows = d.rows
            }
            return nil
        default:
            // turn, keep, doc 등은 termy가 쓰지 않는다.
            return nil
        }
    }
}
