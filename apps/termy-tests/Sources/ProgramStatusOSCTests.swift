import XCTest
@testable import termy

final class ProgramStatusOSCTests: XCTestCase {
    private func parse(_ s: String) -> ProgramStatusOSC.Message {
        ProgramStatusOSC.parse(ArraySlice(Array(s.utf8)))
    }

    func testProbe() {
        XCTAssertEqual(parse("?"), .probe)
    }

    func testProbeReplyMatchesHerdrCore() {
        XCTAssertEqual(ProgramStatusOSC.probeReply,
                       "\u{1b}]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\u{07}")
    }

    func testWorking() {
        XCTAssertEqual(parse("state=working:app=claude-code"),
                       .status(HcStatus(state: "working", kind: nil, msg: nil, app: "claude-code")))
    }

    func testBlockedDecodesBase64Msg() {
        let payload = "state=blocked:app=claude-code:kind=permission:msg=YXBwcm92ZSBCYXNoOiB0b3VjaCAvdG1wL3Rlcm15LTc1MDEtcHJvYmUveC50eHQ="
        XCTAssertEqual(parse(payload),
                       .status(HcStatus(state: "blocked", kind: "permission",
                                        msg: "approve Bash: touch /tmp/termy-7501-probe/x.txt", app: "claude-code")))
    }

    func testUndecodableMsgIsDropped() {
        XCTAssertEqual(parse("state=working:msg=not*base64"),
                       .status(HcStatus(state: "working", kind: nil, msg: nil, app: nil)))
    }

    func testClearEndsReporting() {
        XCTAssertEqual(parse("state=clear"), .status(nil))
    }

    func testRecordWithIdIsIgnored() {
        XCTAssertEqual(parse("id=build:state=working"), .ignored)
    }

    func testMissingStateIsIgnored() {
        XCTAssertEqual(parse("app=claude-code"), .ignored)
        XCTAssertEqual(parse(""), .ignored)
    }

    func testInvalidUTF8IsIgnored() {
        XCTAssertEqual(ProgramStatusOSC.parse(ArraySlice([0xff, 0xfe])), .ignored)
    }
}
