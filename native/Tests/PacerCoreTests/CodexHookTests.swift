import XCTest
@testable import PacerCore

final class CodexHookTests: XCTestCase {
    private let thread = "019a0000-0000-7000-8000-000000000001"

    private func line(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func row(_ extra: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = ["v": 1, "hook": 1, "at": 1_800_000_000.25, "event": "Stop", "thread": thread, "turn": "turn-1",
                                    "agent": NSNull(), "agentType": NSNull(), "transcript": "/home/a/.codex/sessions/2026/11/21/rollout.jsonl",
                                    "agentTranscript": NSNull(), "approval": NSNull(), "reason": NSNull()]
        for (key, item) in extra { value[key] = item }
        return value
    }

    func testSpoolRowsDecodeOnlyKnownEventsWithIdentifiersAndAbsolutePaths() throws {
        let decoded = try XCTUnwrap(CodexHookEvent.decode(line(row())))
        XCTAssertEqual(decoded.kind, .stop); XCTAssertEqual(decoded.thread, thread); XCTAssertEqual(decoded.turn, "turn-1")
        XCTAssertEqual(decoded.at.timeIntervalSince1970, 1_800_000_000.25)
        XCTAssertEqual(CodexHookEvent.decode(try line(row(["event": "PermissionRequest", "approval": "exec"])))?.approval, .exec)
        XCTAssertNil(CodexHookEvent.decode(try line(row(["v": 2]))), "A newer spool format is not guessed at")
        XCTAssertNil(CodexHookEvent.decode(try line(row(["event": "PreToolUse"]))))
        XCTAssertNil(CodexHookEvent.decode(try line(row(["thread": "../escape"]))))
        XCTAssertNil(CodexHookEvent.decode(try line(row(["turn": "has space"]))))
        XCTAssertNil(CodexHookEvent.decode(try line(row(["approval": "anything"]))))
        XCTAssertNil(CodexHookEvent.decode(try line(row(["transcript": 3]))))
        XCTAssertNil(CodexHookEvent.decode(Data("{\"v\":1".utf8)))
        XCTAssertNil(CodexHookEvent.decode(Data(repeating: 32, count: 9 * 1024)))
    }

    func testOnlyRolloutsInsideTheCodexHomeAreAccepted() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-codex-hook-paths", isDirectory: true)
        let home = root.appendingPathComponent(".codex", isDirectory: true)
        func path(_ relative: String, in base: URL? = nil) -> String { (base ?? home).appendingPathComponent(relative).path }
        XCTAssertNotNil(CodexHookSpool.transcript(path("sessions/2026/11/21/rollout-x.jsonl"), home: home))
        XCTAssertNotNil(CodexHookSpool.transcript(path("archived_sessions/rollout-x.jsonl"), home: home))
        XCTAssertNil(CodexHookSpool.transcript(home.path + "/sessions/../auth.jsonl", home: home))
        XCTAssertNil(CodexHookSpool.transcript(path("config.jsonl"), home: home))
        XCTAssertNil(CodexHookSpool.transcript(path("sessions/rollout.json"), home: home))
        XCTAssertNil(CodexHookSpool.transcript(path("sessions/rollout.jsonl", in: root.appendingPathComponent("other")), home: home))
        XCTAssertNil(CodexHookSpool.transcript("sessions/rollout.jsonl", home: home))
        XCTAssertNil(CodexHookSpool.transcript(nil, home: home))
    }

    func testThePluginDefinesSevenFixedHooksAndOnlySessionEndWaits() throws {
        let files = try CodexHookPlugin.files(command: "'/home/a/.codex/pacer/bin/codex-hook'", commandWindows: nil)
        XCTAssertEqual(files.map(\.relativePath), [".agents/plugins/marketplace.json", "plugins/pacer-hooks/.codex-plugin/plugin.json",
                                                   "plugins/pacer-hooks/hooks/hooks.json"])
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: files[1].data) as? [String: Any])
        XCTAssertEqual(manifest["version"] as? String, "1.0.0", "A new version makes Codex ask the user to review every hook again")
        XCTAssertEqual(manifest["hooks"] as? String, "./hooks/hooks.json")
        let hooks = try XCTUnwrap((JSONSerialization.jsonObject(with: files[2].data) as? [String: Any])?["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(Set(hooks.keys), Set(CodexHookEvent.Kind.allCases.map(\.rawValue)))
        for (event, groups) in hooks {
            XCTAssertEqual(groups.count, 1, event)
            let handlers = try XCTUnwrap(groups[0]["hooks"] as? [[String: Any]])
            XCTAssertEqual(handlers.count, 1, event)
            let handler = handlers[0]
            XCTAssertEqual(handler["command"] as? String, "'/home/a/.codex/pacer/bin/codex-hook'")
            XCTAssertNil(handler["commandWindows"])
            XCTAssertEqual(handler["async"] as? Bool, event == "SessionEnd" ? nil : true, event)
            XCTAssertLessThanOrEqual(handler["timeout"] as? Int ?? 99, ["SessionEnd", "Interrupt"].contains(event) ? 3 : 10, event)
            XCTAssertEqual(groups[0]["matcher"] as? String, event == "PermissionRequest" ? "*" : nil, event)
        }
        let windows = try CodexHookPlugin.files(command: nil, commandWindows: "& \"C:\\Users\\a\\.codex\\pacer\\bin\\codex-hook.cmd\"")
        let stop = try XCTUnwrap(((JSONSerialization.jsonObject(with: windows[2].data) as? [String: Any])?["hooks"] as? [String: [[String: Any]]])?["Stop"])
        XCTAssertNil((stop[0]["hooks"] as? [[String: Any]])?[0]["command"])
        XCTAssertNotNil((stop[0]["hooks"] as? [[String: Any]])?[0]["commandWindows"])
        XCTAssertThrowsError(try CodexHookPlugin.files(command: nil, commandWindows: nil))
        XCTAssertEqual(try CodexHookPlugin.files(command: "c", commandWindows: nil).map(\.data),
                       try CodexHookPlugin.files(command: "c", commandWindows: nil).map(\.data), "The definitions are byte-stable")
    }

    func testThePOSIXLauncherQuotesItsPathsAndNeverAnswersAHook() {
        let home = URL(fileURLWithPath: "/Users/a b/it's/.codex")
        XCTAssertEqual(CodexHookProgram.posixCommand(home: home), "'/Users/a b/it'\\''s/.codex/pacer/bin/codex-hook'")
        let launcher = String(decoding: CodexHookProgram.posixLauncher(home: home), as: UTF8.self)
        XCTAssertTrue(launcher.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(launcher.contains("exec python3 -S -B '/Users/a b/it'\\''s/.codex/pacer/codex_hook.py' hook '/Users/a b/it'\\''s/.codex' >/dev/null 2>&1"))
        XCTAssertNotNil(CodexHookProgram.source)
    }

    func testStatusNeedsEveryHookTrustedAndNoticesASilentHook() {
        let now = Date(), all = Array(repeating: "trusted", count: 7)
        func status(enabled: Bool = true, supports: Bool? = true, installed: Bool? = true, trust: [String]? = all,
                    hook: Date? = nil, turn: Date? = nil) -> CodexHookStatus {
            CodexHookStatus.evaluate(enabled: enabled, supportsHooks: supports, installed: installed, trust: trust,
                                     lastHookEvent: hook, lastCodexTurn: turn, now: now)
        }
        XCTAssertEqual(status(enabled: false), .off)
        XCTAssertEqual(status(supports: false), .needsCodexUpdate)
        XCTAssertEqual(status(installed: nil), .installFailed)
        XCTAssertEqual(status(installed: false), .notInstalled)
        XCTAssertEqual(status(trust: ["trusted", "untrusted", "modified", "trusted", "trusted", "trusted", "trusted"]), .needsApproval(count: 2))
        XCTAssertEqual(status(trust: ["trusted"]), .installFailed, "Missing definitions mean the plugin did not load as written")
        XCTAssertEqual(status(), .running)
        XCTAssertEqual(status(turn: now.addingTimeInterval(-30)), .notRunning, "Codex ran a turn and no hook wrote a row")
        XCTAssertEqual(status(hook: now.addingTimeInterval(-40), turn: now.addingTimeInterval(-30)), .running)
        XCTAssertEqual(status(turn: now.addingTimeInterval(-3600)), .running, "Old Codex activity proves nothing")
    }

    func testCodexClientRefusesMethodsThatCouldStartOrSteerATurn() {
        for method in ["turn/start", "thread/start", "thread/resume", "turn/interrupt", "thread/archive", "command/exec"] {
            XCTAssertFalse(CodexClient.allowedMethods.contains(method), method)
        }
        XCTAssertTrue(CodexClient.allowedMethods.isSuperset(of: ["hooks/list", "thread/read", "thread/list", "thread/goal/get"]))
    }
}
