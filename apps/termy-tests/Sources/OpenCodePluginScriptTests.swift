// OpenCodePluginScriptTests.swift
//
// Evaluates only the `termy-pure` region of the bundled opencode TUI plugin in
// JavaScriptCore, so phase/emission/view/payload rules are testable without
// opencode. This does not prove the opencode runtime names, event ordering, or
// spawn behaviour — spike S4 and the Task 4 Step 7 integration check cover
// those.
//
// protects=phase calculation, emission rules, and view/payload construction;
// fails_when=a reason differs from the spec §4.2 table, child sessions or
// pending work are missed, or the payload passes 480 bytes;
// no_claim=opencode's API names and event order (S4, Task 4 Step 7), and there
// is no opencode runtime inside JavaScriptCore.

import JavaScriptCore
import XCTest
@testable import termy

final class OpenCodePluginScriptTests: XCTestCase {
    private static let marker = "// termy-managed opencode plugin. termy rewrites this file; do not edit."

    private func template() throws -> String {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "tui", withExtension: "js", subdirectory: "opencode-plugin"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private var js: JSContext!

    override func setUpWithError() throws {
        let source = try template()
        let start = try XCTUnwrap(source.range(of: "// #region termy-pure"))
        let end = try XCTUnwrap(source.range(of: "// #endregion termy-pure"))
        js = try XCTUnwrap(JSContext())
        js.evaluateScript(String(source[start.upperBound..<end.lowerBound]))
        XCTAssertNil(js.exception, "pure region must evaluate in JavaScriptCore")
        js.evaluateScript("""
        function fakeCtx(o) {
          return {
            ui: { router: { current: () => o.route } },
            data: { session: {
              root: (id) => o.root ?? id,
              family: (id) => o.family ?? [id],
              status: (id) => (o.running ?? []).includes(id) ? "running" : "idle",
              pending: { list: (id) => (o.pending ?? {})[id] ?? [] },
              permission: { list: (id) => (o.permissions ?? {})[id] },
              form: { list: (id) => (o.forms ?? {})[id] },
              get: (id) => o.directory ? { location: { directory: o.directory } } : undefined,
            } },
          }
        }
        """)
    }

    private func eval(_ source: String) -> String? {
        let value = js.evaluateScript("String(\(source))")
        XCTAssertNil(js.exception, source)
        return value?.toString()
    }

    func testTemplate_firstLineIsTermyMarker() throws {
        XCTAssertEqual(try template().split(separator: "\n", maxSplits: 1).first.map(String.init), Self.marker)
    }

    func testTemplate_hasExactlyOnePlaceholder() throws {
        XCTAssertEqual(try template().components(separatedBy: "\"__TERMY_HOOK_PATH__\"").count, 2)
    }

    func testPhase_withoutSession_isIdle() {
        XCTAssertEqual(eval("termyPhase({ sessionID: null, permission: true, busy: true })"), "idle")
    }

    func testPhase_precedence_permissionQuestionRunningIdle() {
        XCTAssertEqual(eval("termyPhase({ sessionID: 'S', permission: true, question: true, busy: true })"), "permission")
        XCTAssertEqual(eval("termyPhase({ sessionID: 'S', question: true, busy: true })"), "question")
        XCTAssertEqual(eval("termyPhase({ sessionID: 'S', busy: true })"), "running")
        XCTAssertEqual(eval("termyPhase({ sessionID: 'S' })"), "idle")
    }

    // protects=the spec §4.2 emission table; fails_when=any row returns a different reason;
    // no_claim=that opencode fires events in this order (Task 1 S4)
    func testEmission_matchesSpecTable() {
        let rows: [(String, String)] = [
            ("termyEmission(null, { sessionID: 'S', phase: 'running' })", "running"),
            ("termyEmission(null, { sessionID: null, phase: 'idle' })", "idle"),
            ("termyEmission({ sessionID: 'S', phase: 'running' }, { sessionID: 'S', phase: 'permission' })", "permission"),
            ("termyEmission({ sessionID: 'S', phase: 'permission' }, { sessionID: 'S', phase: 'running' })", "running"),
            ("termyEmission({ sessionID: 'S', phase: 'running' }, { sessionID: 'S', phase: 'idle' }, 'succeeded')", "succeeded"),
            ("termyEmission({ sessionID: 'S', phase: 'question' }, { sessionID: 'S', phase: 'idle' }, 'succeeded')", "succeeded"),
            ("termyEmission({ sessionID: 'S', phase: 'running' }, { sessionID: 'S', phase: 'idle' }, 'failed')", "failed"),
            ("termyEmission({ sessionID: 'S', phase: 'running' }, { sessionID: 'S', phase: 'idle' }, 'interrupted')", "idle"),
            ("termyEmission({ sessionID: 'S', phase: 'running' }, { sessionID: 'S', phase: 'idle' })", "idle"),
            ("termyEmission({ sessionID: 'S', phase: 'idle' }, { sessionID: 'T', phase: 'running' })", "running"),
            ("termyEmission({ sessionID: 'S', phase: 'running' }, { sessionID: null, phase: 'idle' }, 'succeeded')", "idle"),
            ("termyEmission({ sessionID: 'S', phase: 'idle' }, { sessionID: 'S', phase: 'idle' })", "null"),
        ]
        for (source, expected) in rows {
            XCTAssertEqual(eval(source), expected, source)
        }
    }

    func testView_nonSessionRoute_hasNoSession() {
        XCTAssertEqual(eval("JSON.stringify(termyView(fakeCtx({ route: { type: 'home' } })))"), #"{"sessionID":null}"#)
        XCTAssertEqual(eval("JSON.stringify(termyView(fakeCtx({ route: { type: 'plugin', id: 'x', name: 'y' } })))"), #"{"sessionID":null}"#)
    }

    func testView_childSessionPermission_countsForRoot() {
        XCTAssertEqual(eval("""
        JSON.stringify(termyView(fakeCtx({
          route: { type: 'session', sessionID: 'ses_child' }, root: 'ses_root',
          family: ['ses_root', 'ses_child'], running: ['ses_root'],
          permissions: { ses_child: [{ id: 'per_1' }] } })))
        """), #"{"sessionID":"ses_root","permission":true,"question":false,"busy":true}"#)
    }

    func testView_pendingNonSyntheticIsBusy_syntheticIsNot() {
        XCTAssertEqual(eval("""
        termyView(fakeCtx({ route: { type: 'session', sessionID: 'S' }, pending: { S: [{ type: 'user' }] } })).busy
        """), "true")
        XCTAssertEqual(eval("""
        termyView(fakeCtx({ route: { type: 'session', sessionID: 'S' }, pending: { S: [{ type: 'synthetic' }] } })).busy
        """), "false")
    }

    func testView_cwdComesFromRootLocation() {
        XCTAssertEqual(eval("termyView(fakeCtx({ route: { type: 'session', sessionID: 'S' }, directory: '/w/proj' })).cwd"), "/w/proj")
    }

    func testPayload_includesSessionIdOnlyWhenPresent() {
        XCTAssertEqual(eval("termyPayload('idle', { sessionID: null }, '/fallback')"), #"{"reason":"idle","cwd":"/fallback"}"#)
        XCTAssertEqual(eval("termyPayload('running', { sessionID: 'ses_a', cwd: '/p' }, '/fallback')"),
                       #"{"reason":"running","session_id":"ses_a","cwd":"/p"}"#)
    }

    func testPayload_dropsCwdPast480Bytes() {
        let long = "/" + String(repeating: "a", count: 470)
        XCTAssertEqual(eval("termyPayload('running', { sessionID: 'ses_a', cwd: '\(long)' }, '/w')"),
                       #"{"reason":"running","session_id":"ses_a"}"#)
    }

    func testPayload_countsUtf8BytesNotUtf16Units() {
        // 150 Hangul syllables: 150 UTF-16 units but 450 UTF-8 bytes → over 480 with the JSON around it.
        let hangul = "/" + String(repeating: "가", count: 150)
        XCTAssertEqual(eval("termyPayload('running', { sessionID: 'ses_a', cwd: '\(hangul)' }, '/w')"),
                       #"{"reason":"running","session_id":"ses_a"}"#)
    }
}
