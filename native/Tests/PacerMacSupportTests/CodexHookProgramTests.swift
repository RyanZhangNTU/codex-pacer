import XCTest
import PacerCore
@testable import PacerMacSupport

/// Runs the real launcher and `codex_hook.py` as Codex would, in a temporary Codex home.
final class CodexHookProgramTests: XCTestCase {
    private var home: URL!
    private let thread = "019a0000-0000-7000-8000-000000000001"
    private let child = "019a0000-0000-7000-8000-000000000002"

    override func setUpWithError() throws {
        // A space and a quote in the home exercise the launcher's quoting.
        home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer codex-hook '\(UUID().uuidString)'/.codex", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try MacCodexHookLauncher().prepare(home: home)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    @discardableResult
    private func run(_ payload: [String: Any]) throws -> (status: Int32, output: Data) {
        try run(JSONSerialization.data(withJSONObject: payload))
    }

    @discardableResult
    private func run(_ input: Data) throws -> (status: Int32, output: Data) {
        // Codex starts the trusted command through a shell.
        let process = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", try XCTUnwrap(MacCodexHookLauncher().command(home: home))]
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        stdin.fileHandleForWriting.write(input); try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile() + stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    private func rows() throws -> [[String: Any]] {
        let data = (try? Data(contentsOf: CodexHookSpool.current(home: home))) ?? Data()
        return try data.split(separator: 10).map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
    }

    private func payload(_ event: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = ["hook_event_name": event, "session_id": thread, "turn_id": "turn-1", "cwd": "/private/project",
                                    "model": "synthetic", "permission_mode": "default",
                                    "transcript_path": home.appendingPathComponent("sessions/2026/11/21/rollout-\(thread).jsonl").path]
        for (key, item) in extra { value[key] = item }
        return value
    }

    func testEachEventLeavesOnlyIdentifiersAndNeverAnswers() throws {
        let secret = "PRIVATE synthetic text"
        let events: [(String, [String: Any])] = [
            ("UserPromptSubmit", ["prompt": secret]),
            ("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": secret]]),
            ("PermissionRequest", ["tool_name": "mcp__pacer_progress__report_progress", "tool_input": ["percent": 5]]),
            ("PermissionRequest", ["tool_name": "apply_patch", "tool_input": ["patch": secret]]),
            ("SubagentStart", ["agent_id": child, "agent_type": "explorer", "turn_id": "child-turn"]),
            ("SubagentStop", ["agent_id": child, "agent_type": "explorer", "last_assistant_message": secret,
                              "agent_transcript_path": home.appendingPathComponent("sessions/2026/11/21/rollout-\(child).jsonl").path]),
            ("Stop", ["last_assistant_message": secret, "stop_hook_active": false]),
            ("Interrupt", [:]),
            ("SessionEnd", ["reason": "other", "turn_id": NSNull()]),
            ("PreCompact", ["trigger": "auto"]),
            ("PostCompact", ["trigger": "manual"])
        ]
        for (event, extra) in events {
            let result = try run(payload(event, extra))
            XCTAssertEqual(result.status, 0, event)
            XCTAssertTrue(result.output.isEmpty, "\(event) must never write output that Codex could read as a decision")
        }
        let written = try rows()
        XCTAssertEqual(written.map { $0["event"] as? String }, events.map(\.0))
        XCTAssertEqual(written.compactMap { $0["approval"] as? String }, ["exec", "mcp", "file"])
        XCTAssertEqual(written[4]["agent"] as? String, child); XCTAssertEqual(written[4]["agentType"] as? String, "explorer")
        XCTAssertEqual(written[4]["thread"] as? String, thread, "A subagent row keeps the root thread")
        XCTAssertNotNil(written[5]["agentTranscript"] as? String)
        XCTAssertEqual(written[8]["reason"] as? String, "other"); XCTAssertTrue(written[8]["turn"] is NSNull)
        for row in written {
            XCTAssertEqual(row["v"] as? Int, 1); XCTAssertEqual(row["hook"] as? Int, 1)
            XCTAssertNotNil(CodexHookEvent.decode(try JSONSerialization.data(withJSONObject: row)), "Swift reads every row the hook writes")
        }
        let spool = try Data(contentsOf: CodexHookSpool.current(home: home))
        XCTAssertNil(spool.range(of: Data("PRIVATE".utf8)), "Prompts, tool input and messages never reach the spool")
        XCTAssertNil(spool.range(of: Data("/private/project".utf8)))
        let attributes = try FileManager.default.attributesOfItem(atPath: CodexHookSpool.current(home: home).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testUnknownMalformedAndOversizedInputExitsQuietlyWithoutARow() throws {
        for input in [Data("not json".utf8), Data("[]".utf8), Data(),
                      try JSONSerialization.data(withJSONObject: payload("PreToolUse")),
                      try JSONSerialization.data(withJSONObject: payload("Stop", ["session_id": "../escape"]))] {
            let result = try run(input)
            XCTAssertEqual(result.status, 0); XCTAssertTrue(result.output.isEmpty)
        }
        XCTAssertTrue(try rows().isEmpty)
        // Codex's camel-case event names are accepted too.
        try run(payload("stop"))
        XCTAssertEqual(try rows().first?["event"] as? String, "Stop")
    }

    func testTheSpoolRotatesUnderItsLockAtTwoMebibytes() throws {
        let current = CodexHookSpool.current(home: home)
        try Data(repeating: 120, count: CodexHookSpool.maximumBytes - 10).write(to: current)
        try run(payload("Stop"))
        XCTAssertEqual(try Data(contentsOf: CodexHookSpool.previous(home: home)).count, CodexHookSpool.maximumBytes - 10)
        XCTAssertEqual(try rows().count, 1)
    }

    func testRemovalLeavesNoProgramLauncherOrSpool() throws {
        try run(payload("Stop"))
        try MacCodexHookLauncher().remove(home: home)
        for path in [CodexHookProgram.launcher(home: home), CodexHookProgram.script(home: home), CodexHookSpool.folder(home: home)] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path.path), path.lastPathComponent)
        }
    }
}
