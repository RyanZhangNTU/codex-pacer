import XCTest
@testable import PacerCore

/// Sessions that loaded no hooks, such as `claude -p --setting-sources project`
/// or an Agent SDK app: no Stop summary ever confirms the model's ending. The
/// transcript still shows the SDK prompt, the model's `end_turn` and, once the
/// process shuts down, a `cost-state` record.
final class ClaudeHooklessSessionTests: XCTestCase {
    private let parent = "fixture-parent", child = "fixturechild01", turn = "fixture-turn"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let ssh = "remote-ssh-discovered:fixture"

    private func raw(_ type: String, _ id: String, _ second: Double, _ previous: String?, _ extra: [String: Any] = [:], agent: Bool = false) -> [String: Any] {
        var record: [String: Any] = ["type": type, "uuid": id, "sessionId": parent, "timestamp": stamp(second)]
        if let previous { record["parentUuid"] = previous }
        if agent { record["agentId"] = child; record["isSidechain"] = true }
        return record.merging(extra) { _, new in new }
    }
    private func stamp(_ second: Double) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: now.addingTimeInterval(second))
    }
    private func lines(_ rows: [[String: Any]]) throws -> Data {
        try rows.reduce(into: Data()) { data, row in data += try JSONSerialization.data(withJSONObject: row); data.append(10) }
    }
    private func activity(_ state: ClaudeActivityState, _ thread: String) -> SessionActivity? { state.activities.first { $0.threadID == thread } }
    /// A sanitized record as either collector delivers it.
    private func send(_ kind: String, _ state: inout ClaudeActivityState, thread: String? = nil, prompt: String? = "fixture-turn", at second: Double,
                      _ extra: [String: Any] = [:], origin: String = "transcript", readAt: Double = 100) {
        var row: [String: Any] = ["kind": kind, "origin": origin, "sessionId": thread ?? parent, "at": now.timeIntervalSince1970 + second]
        if let prompt { row["promptId"] = prompt }
        if thread == child { row["parentId"] = parent }
        state.consume(ClaudeActivityRecord.encode(row.merging(extra) { _, new in new })!, now: now.addingTimeInterval(max(readAt, second)))
    }

    /// The reported case: six `claude -p` runs without hooks, five of them with
    /// a foreground agent, stayed running after they finished. The SDK prompt
    /// now opens the turn, so the agent's typed result ends its child; the
    /// process's `cost-state` ends the main turn the model had ended. The native
    /// reader and the SSH helper agree.
    func testHeadlessRunEndsItsAgentWithTheResultAndItsTurnWhenTheProcessExits() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-hookless-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent("projects/fixture"), subagents = project.appendingPathComponent(parent + "/subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let root = project.appendingPathComponent(parent + ".jsonl"), agent = subagents.appendingPathComponent("agent-" + child + ".jsonl")
        try Data().write(to: root); try Data().write(to: agent)
        let stages: [(root: Data, agent: Data)] = [
            (try lines([raw("user", "prompt", 0, nil, ["promptId": turn, "promptSource": "sdk", "turnOrigin": "sdk", "message": ["role": "user", "content": "PRIVATE prompt"]]),
                        raw("assistant", "agent-call", 1, "prompt", ["message": ["role": "assistant", "stop_reason": "tool_use",
                            "content": [["type": "tool_use", "id": "agent-tool", "name": "Agent", "input": ["prompt": "PRIVATE task"]]]]])]),
             try lines([raw("user", "child-prompt", 1.1, nil, ["promptId": turn, "message": ["role": "user", "content": "PRIVATE task"]], agent: true),
                        raw("assistant", "child-tool", 2, "child-prompt", ["message": ["role": "assistant", "stop_reason": "tool_use",
                            "content": [["type": "tool_use", "id": "child-bash", "name": "Bash", "input": ["command": "PRIVATE"]]]]], agent: true),
                        raw("user", "child-result", 3, "child-tool", ["promptId": turn, "message": ["role": "user",
                            "content": [["type": "tool_result", "tool_use_id": "child-bash", "content": "PRIVATE"]]]], agent: true),
                        raw("assistant", "child-answer", 4, "child-result", ["message": ["role": "assistant", "stop_reason": "end_turn",
                            "content": [["type": "text", "text": "PRIVATE report"]]]], agent: true)])),
            (try lines([raw("user", "agent-result", 5, "agent-call", ["promptId": turn, "message": ["role": "user",
                            "content": [["type": "tool_result", "tool_use_id": "agent-tool", "content": "PRIVATE report"]]],
                            "toolUseResult": ["status": "completed", "agentId": child, "content": "PRIVATE report"]]),
                        raw("assistant", "answer", 6, "agent-result", ["message": ["role": "assistant", "stop_reason": "end_turn",
                            "content": [["type": "text", "text": "PRIVATE answer"]]]])]), Data()),
            (try lines([["type": "cost-state", "sessionId": parent, "totalCostUSD": 0.01]]), Data())
        ]
        func append(_ data: Data, to file: URL) throws { let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }; handle.seekToEndOfFile(); handle.write(data) }

        let program = """
        __name__ = 'fixture'
        import base64, json, pathlib, sys
        exec(base64.b64decode(sys.argv[1]), globals())
        root, agent = map(pathlib.Path, sys.argv[2:4])
        reader = Tailer.__new__(Tailer)
        reader.cursors = {path: {'inode': 0, 'offset': 0, 'fragment': b'', 'session': session, 'parent': owner, 'owned': False, 'historicalEnd': None}
                          for path, session, owner in ((root, sys.argv[4], None), (agent, sys.argv[5], sys.argv[4]))}
        def drain():
            rows = []
            reader.dirty = set(reader.cursors)
            for _ in range(32):
                if not reader.dirty: break
                rows += reader.read()
            assert not reader.dirty
            return rows
        reads = [drain()]
        for stage in sys.argv[6:]:
            for path, data in zip((root, agent), json.loads(base64.b64decode(stage))):
                with path.open('ab') as handle: handle.write(base64.b64decode(data))
            reads.append(drain())
        print(json.dumps(reads))
        """
        let pythonHome = home.appendingPathComponent("python-copy")
        try FileManager.default.createDirectory(at: pythonHome, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: home.appendingPathComponent("projects"), to: pythonHome.appendingPathComponent("projects"))
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = PythonFixture.executable
        process.arguments = ["-c", program, Data(ClaudeActivityProbe.script.utf8).base64EncodedString(),
                             pythonHome.appendingPathComponent("projects/fixture/" + parent + ".jsonl").path,
                             pythonHome.appendingPathComponent("projects/fixture/" + parent + "/subagents/agent-" + child + ".jsonl").path, parent, child]
            + (try stages.map { try JSONSerialization.data(withJSONObject: [$0.root.base64EncodedString(), $0.agent.base64EncodedString()]).base64EncodedString() })
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = errors
        let pythonFixture = try PythonFixture.prepare(process); defer { pythonFixture.remove() }; try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("PRIVATE"))
        let helperReads = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [[[String: Any]]])
        XCTAssertEqual(helperReads.count, stages.count + 1)

        var reader = ClaudeActivityReader(), local = ClaudeActivityState(), remote = ClaudeActivityState(sourceID: ssh)
        func readLocal(at second: Double) throws {
            for _ in 0..<8 {
                let result = reader.read(home: home, discover: true, now: now.addingTimeInterval(second))
                for frame in result.records {
                    XCTAssertFalse(String(decoding: frame, as: UTF8.self).contains("PRIVATE"))
                    local.consume(frame, now: now.addingTimeInterval(second))
                }
                if result.caughtUp { local.finalizeHistoricalBaseline(now: now.addingTimeInterval(second)); return }
            }
            XCTFail("The native reader did not catch up")
        }
        func readRemote(_ rows: [[String: Any]], at second: Double) {
            remote.consume(ClaudeActivityRecord.encode(["kind": "claudeBatch", "records": rows])!, now: now.addingTimeInterval(second))
        }
        try readLocal(at: -1); readRemote(helperReads[0], at: -1)
        for (index, stage) in stages.enumerated() {
            try append(stage.root, to: root); try append(stage.agent, to: agent)
            try readLocal(at: 10 + Double(index)); readRemote(helperReads[index + 1], at: 10 + Double(index))
            for (name, state) in [("local", local), ("ssh", remote)] {
                let main = try XCTUnwrap(activity(state, parent), name), worker = try XCTUnwrap(activity(state, child), name)
                switch index {
                case 0:
                    XCTAssertEqual(main.phase, .running, name); XCTAssertEqual(main.turnID, turn, "The SDK prompt opens the turn, \(name)")
                    XCTAssertEqual(worker.phase, .running, "The child's own end_turn does not end it, \(name)")
                case 1:
                    XCTAssertEqual(worker.phase, .completed, "The agent's typed result ends its child, \(name)")
                    XCTAssertEqual(main.phase, .running, "A model ending alone may still be continued by a Stop hook, \(name)")
                default:
                    XCTAssertEqual(main.phase, .completed, name); XCTAssertFalse(main.turnFailed, name)
                    XCTAssertFalse(main.isHistoricalCompletion, "A live ending is announced, \(name)")
                    XCTAssertEqual(main.phaseChangedAt, now.addingTimeInterval(6), "It ends at the model's ending, \(name)")
                    XCTAssertEqual(worker.phase, .completed, name)
                    XCTAssertEqual(ActivityTaskGroup.make(state.activities).first { $0.primary.threadID == parent }?.runningSubagentCount, 0, name)
                }
            }
        }
        XCTAssertEqual(helperReads.last?.filter { $0["kind"] as? String == "sessionClosed" }.count, 1)
    }

    /// Only an SDK caller's prompt opens a turn; Claude Code's own turns keep
    /// their origins. A generated error reply marks its model ending, and the
    /// helper projects the same rows.
    func testSdkPromptAndRequestErrorProjectionAgreeWithTheHelper() throws {
        func user(_ id: String, _ extra: [String: Any]) -> [String: Any] {
            raw("user", id, 1, nil, ["promptId": id, "message": ["role": "user", "content": "PRIVATE prompt"]].merging(extra) { _, new in new })
        }
        let fixtures: [[String: Any]] = [
            user("sdk-prompt", ["promptSource": "sdk", "turnOrigin": "sdk"]),
            user("scheduled", ["promptSource": "sdk", "turnOrigin": "scheduled"]),
            user("system", ["promptSource": "system", "turnOrigin": "system"]),
            user("meta", ["promptSource": "sdk", "turnOrigin": "sdk", "isMeta": true]),
            user("notified", ["promptSource": "sdk", "turnOrigin": "sdk", "origin": ["kind": "task-notification", "producer": "session-task"]]),
            raw("assistant", "error-reply", 2, "sdk-prompt", ["isApiErrorMessage": true, "error": "authentication_failed",
                "message": ["role": "assistant", "model": "<synthetic>", "stop_reason": "stop_sequence", "content": [["type": "text", "text": "PRIVATE error"]]]]),
            raw("assistant", "reply", 3, "sdk-prompt", ["message": ["role": "assistant", "stop_reason": "end_turn", "content": [["type": "text", "text": "PRIVATE"]]]])
        ]
        let native = try fixtures.flatMap { ClaudeActivityRecord.transcript(ClaudeActivityRecord.encode($0)!, sessionID: parent) }
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        let script = "__name__='fixture'\nimport base64,json,sys\nexec(base64.b64decode(sys.argv[1]).decode(),globals())\nrows=[]\nfor value in json.loads(base64.b64decode(sys.argv[2])):\n rows.extend(transcript(json.dumps(value).encode(),sys.argv[3]))\nprint(json.dumps(rows,separators=(',',':')))\n"
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = PythonFixture.executable
        process.arguments = ["-c", script, Data(ClaudeActivityProbe.script.utf8).base64EncodedString(), try JSONSerialization.data(withJSONObject: fixtures).base64EncodedString(), parent]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = errors
        let pythonFixture = try PythonFixture.prepare(process); defer { pythonFixture.remove() }; try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("PRIVATE"))
        XCTAssertTrue(NSArray(array: try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [[String: Any]])).isEqual(to: native))
        XCTAssertEqual(native.filter { $0["kind"] as? String == "prompt" }.compactMap { $0["promptId"] as? String }, ["sdk-prompt"])
        let stops = native.filter { $0["kind"] as? String == "stopRequested" }
        XCTAssertEqual(stops.map { $0["apiError"] as? Bool }, [true, nil])

        // Only a main transcript's `cost-state` closes the session, dated by the latest record read.
        let closing = ClaudeTranscriptFields(ClaudeActivityRecord.encode(["type": "cost-state", "sessionId": parent])!)!
        XCTAssertTrue(ClaudeActivityRecord.sessionClosed(closing, sessionID: parent, parentID: nil, latestTimestamp: nil).isEmpty)
        XCTAssertTrue(ClaudeActivityRecord.sessionClosed(closing, sessionID: child, parentID: parent, latestTimestamp: stamp(3)).isEmpty)
        XCTAssertTrue(ClaudeActivityRecord.sessionClosed(closing, sessionID: "other-session", parentID: nil, latestTimestamp: stamp(3)).isEmpty)
        let closed = try XCTUnwrap(ClaudeActivityRecord.sessionClosed(closing, sessionID: parent, parentID: nil, latestTimestamp: stamp(3)).first)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: closed) as? [String: Any])
        XCTAssertEqual(value["kind"] as? String, "sessionClosed"); XCTAssertEqual(value["at"] as? Double, now.timeIntervalSince1970 + 3)
    }

    /// A closed session cannot continue. Without the model's ending its turn is
    /// unconfirmed, as after SessionEnd, and so is a background child begun
    /// before; a request error fails it. A resumed session starts again.
    func testClosedSessionWithoutAModelEndingIsUnconfirmedAndARequestErrorFails() throws {
        var state = ClaudeActivityState()
        send("prompt", &state, at: 0)
        send("toolStart", &state, at: 1, ["itemId": "long-tool"])
        send("prompt", &state, thread: child, prompt: "child-turn", at: 2)
        send("sessionClosed", &state, prompt: nil, at: 3)
        state.finalizeHistoricalBaseline(now: now.addingTimeInterval(100))
        XCTAssertEqual(activity(state, parent)?.phase, .unknown); XCTAssertEqual(activity(state, child)?.phase, .unknown)

        // A resume writes a new prompt; the earlier closure ends nothing begun after it.
        send("prompt", &state, prompt: "resumed-turn", at: 50)
        send("prompt", &state, thread: child, prompt: "resumed-child-turn", at: 51)
        state.finalizeHistoricalBaseline(now: now.addingTimeInterval(100))
        XCTAssertEqual(activity(state, parent)?.phase, .running); XCTAssertEqual(activity(state, child)?.phase, .running)
        send("response", &state, prompt: "resumed-turn", at: 52, ["itemId": "error-reply"])
        send("stopRequested", &state, prompt: "resumed-turn", at: 52, ["apiError": true])
        send("sessionClosed", &state, prompt: nil, at: 52)
        state.finalizeHistoricalBaseline(now: now.addingTimeInterval(100))
        XCTAssertEqual(activity(state, parent)?.phase, .interrupted); XCTAssertEqual(activity(state, parent)?.turnFailed, true)
        XCTAssertEqual(activity(state, child)?.phase, .unknown, "Its child had not ended either")
    }

    /// Hooks own the lifecycle of a session that loaded them: a transcript model
    /// ending, `cost-state` or quiet never end it; its Stop summary does.
    func testHookDrivenSessionIgnoresTranscriptClosureAndQuiet() {
        var state = ClaudeActivityState()
        send("prompt", &state, at: 0, origin: "hook")
        send("response", &state, at: 1, ["itemId": "reply"])
        send("stopRequested", &state, at: 1)
        send("sessionClosed", &state, prompt: nil, at: 1)
        state.finalizeHistoricalBaseline(now: now.addingTimeInterval(100))
        state.expireUnconfirmedBaseline(now: now.addingTimeInterval(3600))
        XCTAssertEqual(activity(state, parent)?.phase, .running, "A long Stop hook may still continue the turn")
        send("stopVerified", &state, at: 3700, readAt: 3700)
        XCTAssertEqual(activity(state, parent)?.phase, .completed)
    }

    /// Without hooks or a closure, a turn the model ended and that stays quiet
    /// for 15 minutes is unconfirmed, like a baseline tail; its new records bring
    /// it back. A long tool call or reply has no model ending and keeps running.
    func testQuietModelEndingIsUnconfirmedButALongToolCallKeepsRunning() {
        let idle = "fixture-idle"
        var state = ClaudeActivityState()
        send("prompt", &state, at: 0)
        send("toolStart", &state, at: 1, ["itemId": "long-build"])
        send("prompt", &state, thread: idle, prompt: "idle-turn", at: 0)
        send("response", &state, thread: idle, prompt: "idle-turn", at: 1, ["itemId": "reply"])
        send("stopRequested", &state, thread: idle, prompt: "idle-turn", at: 1)
        state.expireUnconfirmedBaseline(now: now.addingTimeInterval(1 + 14 * 60))
        XCTAssertEqual(activity(state, idle)?.phase, .running)
        state.expireUnconfirmedBaseline(now: now.addingTimeInterval(1 + 16 * 60))
        XCTAssertEqual(activity(state, idle)?.phase, .unknown)
        XCTAssertEqual(activity(state, parent)?.phase, .running, "A tool still running has no model ending")
        state.expireUnconfirmedBaseline(now: now.addingTimeInterval(3 * 3600))
        XCTAssertEqual(activity(state, parent)?.phase, .running)
        send("toolStart", &state, thread: idle, prompt: "idle-turn", at: 17 * 60, ["itemId": "late-tool"])
        XCTAssertEqual(activity(state, idle)?.phase, .running, "New records of the turn bring it back")
    }
}
