import Foundation

// mode 2048(in-band resize notifications). hc pane 전용.
//
// hc core(ghostty-vt)는 DECRQM `CSI ? 2048 $ p`에 "지원"이라고 답한다. 그래서 이 모드를 켠 프로그램
// (nvim 0.10+)은 SIGWINCH를 듣지 않고, 터미널이 입력으로 보내는 `CSI 48 ; rows ; cols ; height_px ; width_px t`를
// 기다린다. Ghostty에서 이 알림은 VT 라이브러리가 아니라 앱(client)이 보내므로 core는 보내지 않는다.
// termy가 보내지 않으면 창이나 글꼴 크기를 바꿔도 nvim이 예전 크기로 남는다.
//
// local pane은 SwiftTerm이 이 모드를 모른다고 답하므로 프로그램이 SIGWINCH를 쓰고, 여기와 상관없다.

/// 프로그램 출력에서 DECSET/DECRST 2048(`CSI ? … 2048 … h/l`)을 찾는다. 출력이 어디서 잘려 와도 이어서 읽는다.
struct InBandResizeModeScanner {
    private enum State { case ground, escape, csi, privateParams }

    private var state = State.ground
    private var params: [UInt8] = []

    /// `bytes` 안에서 마지막으로 바뀐 mode 2048 상태. 바뀐 것이 없으면 nil.
    mutating func scan(_ bytes: ArraySlice<UInt8>) -> Bool? {
        var result: Bool?
        for byte in bytes {
            switch state {
            case .ground:
                if byte == 0x1b { state = .escape }
            case .escape:
                state = byte == 0x5b ? .csi : (byte == 0x1b ? .escape : .ground)       // `[`
            case .csi:
                if byte == 0x3f {                                                      // `?`
                    params.removeAll(keepingCapacity: true)
                    state = .privateParams
                } else {
                    state = byte == 0x1b ? .escape : .ground
                }
            case .privateParams:
                if (0x30...0x39).contains(byte) || byte == 0x3b {                      // 숫자, `;`
                    if params.count < 64 { params.append(byte) } else { state = .ground }
                    continue
                }
                if byte == 0x68 || byte == 0x6c, Self.names2048(params) {              // `h`, `l`
                    result = byte == 0x68
                }
                state = byte == 0x1b ? .escape : .ground
            }
        }
        return result
    }

    private static func names2048(_ params: [UInt8]) -> Bool {
        params.split(separator: 0x3b).contains { Array($0) == Array("2048".utf8) }
    }

    /// 프로그램에 입력으로 보낼 크기 알림.
    static func report(cols: Int, rows: Int, widthPixels: Int, heightPixels: Int) -> [UInt8] {
        Array("\u{1b}[48;\(rows);\(cols);\(heightPixels);\(widthPixels)t".utf8)
    }
}
