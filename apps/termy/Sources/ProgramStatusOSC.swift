import Foundation

// OSC 7501 program status(herdr-core가 쓰는 규약). Claude Code는 시작할 때 `ESC ] 7501 ; ? BEL`로 묻고,
// 답한 터미널에만 상태를 보고한다. hc pane은 core가 답하고 events로 받는다. local pane은 TermyTerminalView가
// 이 parser로 직접 답하고 받는다.
// 보고는 `key=value`를 `:`로 이은 꼴이고 `msg`는 base64다(Claude Code 2.1.319에서 확인).

enum ProgramStatusOSC {
    static let code = 7501

    /// herdr-core가 질의에 주는 답과 같은 바이트. 종결자는 Claude의 질의처럼 BEL이다.
    static let probeReply = "\u{1b}]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\u{07}"

    enum Message: Equatable {
        /// `?`: 이 터미널이 보고를 받는지 묻는다.
        case probe
        /// root 레코드 보고. nil은 `state=clear`(프로그램이 보고를 그만뒀다).
        case status(HcStatus?)
        /// termy가 쓰지 않는 것: `id`가 붙은 레코드, `state`가 없는 보고, UTF-8이 아닌 바이트.
        case ignored
    }

    /// `payload`는 SwiftTerm이 OSC handler에 넘기는 값, 곧 `7501;` 뒤의 바이트다.
    static func parse(_ payload: ArraySlice<UInt8>) -> Message {
        guard let text = String(bytes: payload, encoding: .utf8) else { return .ignored }
        if text.hasPrefix("?") { return .probe }
        var fields: [String: String] = [:]
        for part in text.split(separator: ":") {
            guard let eq = part.firstIndex(of: "=") else { continue }
            fields[String(part[..<eq])] = String(part[part.index(after: eq)...])
        }
        if let id = fields["id"], !id.isEmpty { return .ignored }
        guard let state = fields["state"], !state.isEmpty else { return .ignored }
        if state == "clear" { return .status(nil) }
        let msg = fields["msg"]
            .flatMap { Data(base64Encoded: $0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        return .status(HcStatus(state: state, kind: fields["kind"], msg: msg, app: fields["app"]))
    }
}
