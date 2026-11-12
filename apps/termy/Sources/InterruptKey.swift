// InterruptKey.swift
//
// Recognizes a standalone Esc or Ctrl-C key press in one chunk of user input
// headed for the PTY. Used to notice that the user interrupted a running agent
// turn when the agent itself gives no hook for it.
//
// Byte shapes (SwiftTerm): without kitty flags Esc / Ctrl-C are the single
// bytes 0x1b / 0x03. With the kitty disambiguate flag they are CSI-u:
// `ESC [ 27 u` and `ESC [ 99 ; 5 u`, i.e. `<key>(:<alt>)*(;<mods>(:<event>)?)? u`.

enum InterruptKey {
    private static let lockBits = 64 | 128   // caps lock, num lock

    static func isStandaloneInterrupt(_ data: ArraySlice<UInt8>) -> Bool {
        let bytes = Array(data)
        if bytes == [0x1b] || bytes == [0x03] { return true }
        guard bytes.count >= 4,
              bytes[0] == 0x1b, bytes[1] == UInt8(ascii: "["),
              bytes[bytes.count - 1] == UInt8(ascii: "u")
        else { return false }

        let body = bytes[2..<(bytes.count - 1)]
        let fields = body.split(separator: UInt8(ascii: ";"), maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 1 || fields.count == 2 else { return false }

        // Field 1: key code, optionally followed by `:alternate` codes.
        let keyParts = fields[0].split(separator: UInt8(ascii: ":"), omittingEmptySubsequences: false)
        guard let keyPart = keyParts.first, let key = number(keyPart),
              keyParts.dropFirst().allSatisfy({ number($0) != nil })
        else { return false }

        // Field 2: modifiers (1 + bits), optionally `:event`. Omitted means 1.
        var mods = 1
        if fields.count == 2 {
            let modParts = fields[1].split(separator: UInt8(ascii: ":"), omittingEmptySubsequences: false)
            guard modParts.count <= 2, let m = number(modParts[0]) else { return false }
            if modParts.count == 2 {
                guard let event = number(modParts[1]), event == 1 else { return false }
            }
            mods = m
        }
        guard mods >= 1 else { return false }
        let bits = (mods - 1) & ~lockBits

        switch key {
        case 27: return bits == 0
        case 99: return bits == 4   // ctrl only
        default: return false
        }
    }

    private static func number(_ s: ArraySlice<UInt8>) -> Int? {
        guard !s.isEmpty, s.count <= 6, s.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return s.reduce(0) { $0 * 10 + Int($1 - 0x30) }
    }
}
