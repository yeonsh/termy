import Foundation

// herdr-core(hc) 연결이 frame 모드에서 쓰는 wire 포맷.
// 헤더는 [channel u32 LE][kind u8][len u32 LE] 9바이트이고 payload는 최대 16 MiB다.
// 순수 값 계층으로 두어 I/O(HcConnection)와 따로 테스트한다.

enum HcFrameKind: UInt8, Sendable {
    case data = 0, credit = 1, close = 2, resize = 3, focus = 4, facts = 5
}

enum HcFrameError: Error, Equatable {
    case payloadTooLarge(UInt32)
    case unknownKind(UInt8)
}

struct HcFrame: Equatable, Sendable {
    static let headerSize = 9
    static let maxPayload: UInt32 = 16_777_216

    var channel: UInt32
    var kind: HcFrameKind
    var payload: Data

    func encoded() -> Data {
        var out = Data(capacity: Self.headerSize + payload.count)
        Self.appendLE(&out, channel)
        out.append(kind.rawValue)
        Self.appendLE(&out, UInt32(payload.count))
        out.append(payload)
        return out
    }

    static func credit(channel: UInt32, bytes: UInt32) -> HcFrame {
        var p = Data(); appendLE(&p, bytes)
        return HcFrame(channel: channel, kind: .credit, payload: p)
    }

    static func resize(channel: UInt32, cols: UInt16, rows: UInt16) -> HcFrame {
        var p = Data()
        appendLE(&p, cols)
        appendLE(&p, rows)
        return HcFrame(channel: channel, kind: .resize, payload: p)
    }

    static func focus(channel: UInt32, _ focused: Bool) -> HcFrame {
        HcFrame(channel: channel, kind: .focus, payload: Data([focused ? 1 : 0]))
    }

    static func close(channel: UInt32) -> HcFrame {
        HcFrame(channel: channel, kind: .close, payload: Data())
    }

    private static func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}

struct HcFrameDecoder: Sendable {
    private var buffer = Data()

    /// 받은 바이트를 쌓고 완성된 frame을 모두 꺼낸다. 오류가 나면 decoder는 더 쓰지 않는다.
    mutating func append(_ data: Data) throws -> [HcFrame] {
        buffer.append(data)
        var frames: [HcFrame] = []
        var pos = 0   // buffer 안의 0 기준 offset
        defer { buffer = Data(buffer.dropFirst(pos)) }
        while buffer.count - pos >= HcFrame.headerSize {
            let base = buffer.startIndex + pos
            let channel = Self.readLE(buffer, base, as: UInt32.self)
            let rawKind = buffer[base + 4]
            let len = Self.readLE(buffer, base + 5, as: UInt32.self)
            guard len <= HcFrame.maxPayload else { throw HcFrameError.payloadTooLarge(len) }
            guard let kind = HcFrameKind(rawValue: rawKind) else { throw HcFrameError.unknownKind(rawKind) }
            let end = pos + HcFrame.headerSize + Int(len)
            guard buffer.count >= end else { break }
            let start = buffer.startIndex + pos + HcFrame.headerSize
            frames.append(HcFrame(channel: channel, kind: kind, payload: Data(buffer[start..<(buffer.startIndex + end)])))
            pos = end
        }
        return frames
    }

    private static func readLE<T: FixedWidthInteger>(_ d: Data, _ at: Int, as: T.Type) -> T {
        var v: T = 0
        for i in 0..<MemoryLayout<T>.size { v |= T(d[at + i]) << (8 * i) }
        return v
    }
}
