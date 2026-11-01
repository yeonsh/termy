import Foundation

// hc가 알려 주는 terminal 사실. 필드 이름은 termy 쪽 이름이고, JSON 키는 hc 레코드(snake_case)를 따른다.
// 레코드에 있어도 termy가 쓰지 않는 값(pid, turn, keep, records 등)은 담지 않는다.
// memberwise init은 테스트와 pane 쪽이 직접 쓰므로, decoder는 extension에 둬서 합성 init을 지킨다.

struct HcStatus: Codable, Sendable, Equatable {
    var state: String
    var kind: String?
    var msg: String?
    var app: String?
}

struct HcForeground: Codable, Sendable, Equatable {
    var pid: Int?
    var name: String?
    var argv: [String]?
    var cwd: String?
}

struct HcTerminal: Codable, Sendable, Equatable {
    var address: String
    var state: String
    var labels: [String: String]
    var cwd: String?
    var exitCode: Int32?
    var reason: String?
    var status: HcStatus?
    var foreground: HcForeground?
    var cols: Int?
    var rows: Int?
    var title: String?
}

extension HcTerminal {
    private enum CodingKeys: String, CodingKey {
        case address, state, labels, cwd, reason, status, foreground, cols, rows, title
        case exitCode = "exit_code"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        address = try c.decode(String.self, forKey: .address)
        state = try c.decode(String.self, forKey: .state)
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        exitCode = try c.decodeIfPresent(Int32.self, forKey: .exitCode)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        status = try c.decodeIfPresent(HcStatus.self, forKey: .status)
        foreground = try c.decodeIfPresent(HcForeground.self, forKey: .foreground)
        cols = try c.decodeIfPresent(Int.self, forKey: .cols)
        rows = try c.decodeIfPresent(Int.self, forKey: .rows)
        title = try c.decodeIfPresent(String.self, forKey: .title)
    }
}

enum HcAddress {
    /// 원격 terminal은 `machine/t3` 꼴로 주소가 온다. local이면 nil.
    static func machine(of address: String) -> String? {
        guard let slash = address.firstIndex(of: "/") else { return nil }
        let machine = address[address.startIndex..<slash]
        return machine.isEmpty ? nil : String(machine)
    }
}

struct HcEvent: Sendable {
    let seq: UInt64
    let type: String
    let terminal: String?
    /// `data` 값의 JSON 원문. 없거나 null이면 `null`.
    let data: Data

    private struct Envelope: Decodable {
        struct Params: Decodable {
            let seq: UInt64
            let type: String
            let terminal: String?
        }
        let params: Params
    }

    static func decode(notification raw: Data) throws -> HcEvent {
        let env = try JSONDecoder().decode(Envelope.self, from: raw)
        var data = Data("null".utf8)
        if let root = try JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed]) as? [String: Any],
           let params = root["params"] as? [String: Any],
           let value = params["data"] {
            data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        }
        return HcEvent(seq: env.params.seq, type: env.params.type, terminal: env.params.terminal, data: data)
    }
}

enum HcTerminalChange: Sendable, Equatable {
    case upserted(HcTerminal)
    case removed(String)
    case status(String, HcStatus?)
    case foreground(String, HcForeground?)
    case lost(String, reason: String)
    case restarted(HcTerminal)
    case finished(String, exitCode: Int32?, reason: String)
}
