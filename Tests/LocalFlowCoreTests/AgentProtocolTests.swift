import XCTest
@testable import LocalFlowCore

/// C6: Claude Code events, answers and the settings.json merge.
final class AgentProtocolTests: XCTestCase {
    func message(_ kind: String, _ payload: [String: Any], env: [String: String] = ["TERM_PROGRAM": "iTerm.app"]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["kind": kind, "payload": payload, "env": env])
    }

    let bash: [String: Any] = [
        "hook_event_name": "PermissionRequest", "session_id": "s1", "cwd": "/Users/me/Projects/saywell",
        "tool_name": "Bash", "tool_input": ["command": "rm -rf build\nmake", "description": "Clean"],
        "permission_suggestions": [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "make:*"]],
                                    "behavior": "allow", "destination": "localSettings"]],
    ]

    func testParsesAPermissionRequest() throws {
        let e = try XCTUnwrap(AgentProtocol.parse(message("permission", bash)))
        XCTAssertEqual(e.kind, .permission)
        XCTAssertEqual(e.project, "saywell")
        XCTAssertEqual(e.summary, "rm -rf build make")
        XCTAssertEqual(e.host, "iTerm.app")
        XCTAssertEqual(AgentProtocol.step(for: e), "Needs your OK")
        XCTAssertNil(AgentProtocol.parse(Data("not json".utf8)))
    }

    func testPermissionOutputs() throws {
        let e = try XCTUnwrap(AgentProtocol.parse(message("permission", bash)))
        XCTAssertEqual(AgentProtocol.permissionOutput(.allow, event: e),
                       #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)
        let always = try XCTUnwrap(AgentProtocol.permissionOutput(.always, event: e))
        XCTAssertTrue(always.contains(#""updatedPermissions":[{"behavior":"allow""#), always)
        XCTAssertTrue(try XCTUnwrap(AgentProtocol.permissionOutput(.deny, event: e)).contains(#""behavior":"deny""#))
        XCTAssertNil(AgentProtocol.permissionOutput(.terminal, event: e), "no output → Claude Code asks in the terminal")
    }

    func testAskUserQuestionAnswers() throws {
        let payload: [String: Any] = [
            "hook_event_name": "PreToolUse", "session_id": "s1", "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [
                ["question": "Which database?", "header": "Database choice here", "multiSelect": false,
                 "options": [["label": "Postgres", "description": "x"], ["label": "SQLite", "description": "y"]]],
                ["question": "Which extras?", "header": "Extras", "multiSelect": true,
                 "options": [["label": "Cache"], ["label": "Search"], ["label": "Auth"]]],
            ]],
        ]
        let e = try XCTUnwrap(AgentProtocol.parse(message("ask", payload)))
        let qs = AgentProtocol.questions(e)
        XCTAssertEqual(qs.map(\.options.count), [2, 3])
        XCTAssertEqual(qs.first?.header, "Database cho", "headers cut to 12")
        XCTAssertTrue(qs[1].multiSelect)
        let out = try XCTUnwrap(AgentProtocol.answerOutput(event: e, answers: ["Which database?": ["SQLite"],
                                                                               "Which extras?": ["Cache", "Auth"]]))
        XCTAssertTrue(out.contains(#""permissionDecision":"allow""#))
        XCTAssertTrue(out.contains(#""Which extras?":"Cache, Auth""#), out)
        XCTAssertTrue(out.contains(#""questions":["#), "the questions are passed back unchanged")
        XCTAssertNil(AgentProtocol.answerOutput(event: e, answers: [:]))
    }

    func testStepSummaries() {
        XCTAssertEqual(AgentProtocol.summary(tool: "Edit", input: ["file_path": "/a/b/Store.swift"]), "Store.swift")
        XCTAssertEqual(AgentProtocol.summary(tool: "Bash", input: ["command": String(repeating: "x", count: 300)]).count, 158)
        let e = AgentProtocol.Event(kind: .event, hookEvent: "PreToolUse", sessionID: "s", cwd: nil, toolName: "Read",
                                    summary: "Notes.swift", message: nil, host: nil, toolInput: [:], suggestions: nil)
        XCTAssertEqual(AgentProtocol.step(for: e), "Reads Notes.swift")
        XCTAssertEqual(e.project, "Claude Code")
    }

    func testInstallKeepsOtherHooksAndIsIdempotent() throws {
        let mine: [String: Any] = [
            "model": "opus",
            "hooks": ["PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "~/bin/guard.sh"]]]]],
        ]
        let once = try AgentProtocol.installingHooks(into: mine, helper: "/x/saywell-hook")
        let twice = try AgentProtocol.installingHooks(into: once, helper: "/x/saywell-hook")
        XCTAssertEqual(AgentProtocol.prettyJSON(once), AgentProtocol.prettyJSON(twice), "installing twice changes nothing")
        XCTAssertTrue(AgentProtocol.isInstalled(once))
        let pre = (once["hooks"] as? [String: Any])?["PreToolUse"] as? [Any]
        XCTAssertEqual(pre?.count, 3, "user's Bash guard + ours + the AskUserQuestion matcher")
        XCTAssertEqual(once["model"] as? String, "opus")

        let removed = try AgentProtocol.removingHooks(from: once)
        XCTAssertEqual(AgentProtocol.prettyJSON(removed), AgentProtocol.prettyJSON(mine), "uninstall restores the original")
        XCTAssertFalse(AgentProtocol.isInstalled(removed))
        XCTAssertEqual(AgentProtocol.prettyJSON(try AgentProtocol.removingHooks(from: [:])), AgentProtocol.prettyJSON([:]))
    }

    func testMixedGroupKeepsTheUsersEntry() throws {
        let mixed: [String: Any] = ["hooks": ["Stop": [["hooks": [
            ["type": "command", "command": "\"/x/saywell-hook\""], ["type": "command", "command": "say done"],
        ]]]]]
        let out = try AgentProtocol.removingHooks(from: mixed)
        let entries = (((out["hooks"] as? [String: Any])?["Stop"] as? [Any])?.first as? [String: Any])?["hooks"] as? [Any]
        XCTAssertEqual(entries?.count, 1)
    }

    func testRefusesSettingsItDoesNotUnderstand() {
        XCTAssertThrowsError(try AgentProtocol.installingHooks(into: ["hooks": "oops"], helper: "/x/saywell-hook"))
        XCTAssertThrowsError(try AgentProtocol.removingHooks(from: ["hooks": ["Stop": "oops"]]))
    }
}
