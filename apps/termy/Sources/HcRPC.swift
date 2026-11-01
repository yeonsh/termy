import Foundation

// hc 채널 0의 JSON-RPC 2.0 메시지. frame 모드에서는 DATA frame 하나가 메시지 하나이고
// 끝에 개행이 없다(plain 모드의 hello 줄만 호출부가 개행을 붙인다).
// parse는 id/method/error만 먼저 읽고 원본 Data를 그대로 넘겨, 본문 decode는 호출부가 타입에 맞춰 한다.

struct HcRPCErrorPayload: Decodable, Sendable, Equatable {
    let code: Int
    let message: String
    let kind: String?
    let hint: String?

    private enum CodingKeys: String, CodingKey { case code, message, data }
    private struct DataBody: Decodable { let kind: String?; let hint: String? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(Int.self, forKey: .code)
        message = try c.decode(String.self, forKey: .message)
        let body = try c.decodeIfPresent(DataBody.self, forKey: .data)
        kind = body?.kind
        hint = body?.hint
    }
}

enum HcRPCIncoming: Sendable {
    case response(id: Int, raw: Data)
    case error(id: Int, HcRPCErrorPayload)
    case notification(method: String, raw: Data)
}

enum HcRPCError: Error, Equatable {
    case malformed
}

enum HcRPC {
    private struct Envelope: Decodable {
        let id: Int?
        let method: String?
        let error: HcRPCErrorPayload?
    }

    private struct Req<P: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let id: Int
        let method: String
        let params: P
    }
    private struct ResultBox<T: Decodable>: Decodable { let result: T }
    private struct ParamsBox<T: Decodable>: Decodable { let params: T }

    static func parse(_ line: Data) throws -> HcRPCIncoming {
        let env = try JSONDecoder().decode(Envelope.self, from: line)
        if let id = env.id {
            if let err = env.error { return .error(id: id, err) }
            return .response(id: id, raw: line)
        }
        if let method = env.method { return .notification(method: method, raw: line) }
        throw HcRPCError.malformed
    }

    static func request(id: Int, method: String, params: some Encodable) throws -> Data {
        return try JSONEncoder().encode(Req(id: id, method: method, params: params))
    }

    static func decodeResult<R: Decodable>(_ type: R.Type, from raw: Data) throws -> R {
        return try JSONDecoder().decode(ResultBox<R>.self, from: raw).result
    }

    static func decodeParams<P: Decodable>(_ type: P.Type, from raw: Data) throws -> P {
        return try JSONDecoder().decode(ParamsBox<P>.self, from: raw).params
    }
}
