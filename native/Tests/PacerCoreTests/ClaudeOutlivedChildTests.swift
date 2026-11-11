import XCTest
@testable import PacerCore

/// A child run cannot outlive the end of its main conversation, even when its
/// own ending cannot match. Claude Code's main-thread Stop lists every in-flight
/// background task of the session, agents that subagents launched included, so
/// a Stop that lists no agent ends every child run begun before it. An
/// interrupted or failed main-thread turn ends every such run except a
/// background agent with a known launch, which Claude Code keeps running.
final class ClaudeOutlivedChildTests: XCTestCase {
    private let parent = "fixture-parent", turn = "fixture-turn", child = "fixture-child"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let ssh = "remote-ssh-discovered:fixture"

    private func row(_ kind: String, _ offset: Double, thread: String? = nil, _ extra: [String: Any] = [:]) -> [String: Any] {
        var row: [String: Any] = ["kind": kind, "origin": "hook", "sessionId": thread ?? parent, "promptId": turn, "at": now.timeIntervalSince1970 + offset]
        if let thread, thread != parent { row["parentId"] = parent }
        return row.merging(extra) { _, new in new }
    }
    /// One read: an SSH helper batch, or the native reader's frames and the end of its read.
    private func read(_ rows: [[String: Any]], into state: inout ClaudeActivityState, batch: Bool) {
        if batch { state.consume(ClaudeActivityRecord.encode(["kind": "claudeBatch", "records": rows])!, now: now.addingTimeInterval(100)); return }
        for value in rows { state.consume(ClaudeActivityRecord.encode(value)!, now: now.addingTimeInterval(100)) }
        state.finalizeHistoricalBaseline(now: now.addingTimeInterval(100))
    }
    private func activity(_ state: ClaudeActivityState, _ thread: String) -> SessionActivity? { state.activities.first { $0.threadID == thread } }

    func testAgentFreeStopEndsAChildWhoseEndingCannotMatch() throws {
        for host in [String?.none, ssh] { for batch in [false, true] {
            let label = "\(host ?? "local"), batch \(batch)"
            var state = ClaudeActivityState(sourceID: host)
            // The launch was lost, as to a rotated spool after a restart.
            read([row("prompt", 0), row("subagentStart", 2, thread: child), row("toolStart", 3, thread: child, ["itemId": "child-tool", "attention": "none"]),
                  row("toolEnd", 4, thread: child, ["itemId": "child-tool"])], into: &state, batch: batch)
            // Its ending names a launch Pacer never read, and a child's own Stop ends nothing.
            read([row("agentNotification", 5, ["origin": "transcript", "itemId": "agent-tool", "agentId": child, "agentStatus": "completed"]),
                  row("stopRequested", 5.5, thread: child, ["agents": 0])], into: &state, batch: batch)
            XCTAssertEqual(activity(state, child)?.phase, .running, label)
            // Agents still in flight, no count, or a count not from the main thread's Stop hook prove nothing.
            for extra: [String: Any] in [["agents": 1], [:], ["origin": "transcript", "agents": 0], ["agents": "0"]] {
                read([row("stopRequested", 6, extra)], into: &state, batch: batch)
                XCTAssertEqual(activity(state, child)?.phase, .running, "\(extra), \(label)")
            }
            read([row("stopRequested", 7, ["agents": 0])], into: &state, batch: batch)
            let ended = try XCTUnwrap(activity(state, child), label)
            XCTAssertEqual(ended.phase, .completed, label)
            XCTAssertEqual(ended.phaseChangedAt, now.addingTimeInterval(4), "The run ends at its latest evidence, \(label)")
            XCTAssertEqual(ActivityTaskGroup.make(state.activities).first?.runningSubagentCount, 0, label)
            // Its later records and its ending neither reopen it nor move its end.
            read([row("toolStart", 8, thread: child, ["itemId": "late-tool", "attention": "none"]),
                  row("agentNotification", 9, ["origin": "transcript", "itemId": "agent-tool", "agentId": child, "agentStatus": "completed"])], into: &state, batch: batch)
            XCTAssertEqual(activity(state, child)?.phase, .completed, label)
            XCTAssertEqual(activity(state, child)?.phaseChangedAt, now.addingTimeInterval(4), label)
            // A run begun after an agent-free Stop keeps going, even past such a Stop read late.
            read([row("subagentStart", 10, thread: "later-child"), row("stopRequested", 9.5, ["agents": 0])], into: &state, batch: batch)
            XCTAssertEqual(activity(state, "later-child")?.phase, .running, label)
            // A revival of the ended child is a new run; the next agent-free Stop ends both.
            read([row("subagentStart", 11, thread: child)], into: &state, batch: batch)
            XCTAssertEqual(activity(state, child)?.phase, .running, label)
            read([row("stopRequested", 12, ["agents": 0])], into: &state, batch: batch)
            XCTAssertEqual(activity(state, child)?.phase, .completed, label)
            XCTAssertEqual(activity(state, "later-child")?.phase, .completed, label)
            XCTAssertEqual(ActivityTaskGroup.make(state.activities).first?.runningSubagentCount, 0, label)
        } }
    }

    /// The main conversation was interrupted (or failed) while its agents ran.
    /// The foreground agent it aborted and an agent whose launch was lost end
    /// with it, so the task reads as interrupted and one click clears it. A
    /// background agent with a known launch keeps running, as Claude Code keeps
    /// it, until its own notification.
    func testInterruptedMainTurnEndsEveryChildButAKnownBackgroundAgent() throws {
        for host in [String?.none, ssh] { for batch in [false, true] { for ending in ["interrupt", "failure"] {
            let label = "\(host ?? "local"), batch \(batch), \(ending)"
            var state = ClaudeActivityState(sourceID: host)
            read([row("prompt", 0), row("toolStart", 1, ["itemId": "agent-tool", "agentTool": true, "attention": "none"]),
                  row("subagentStart", 2, thread: "background-child"),
                  row("agentResult", 2.5, ["itemId": "agent-tool", "agentId": "background-child", "agentStatus": "async_launched"]),
                  row("subagentStart", 3, thread: child),
                  row("toolStart", 4, ["itemId": "foreground-tool", "agentTool": true, "attention": "none"]),
                  row("subagentStart", 5, thread: "foreground-child"),
                  row("toolStart", 6, thread: child, ["itemId": "child-tool", "attention": "none"]),
                  row("toolStart", 6.5, thread: "foreground-child", ["itemId": "foreground-child-tool", "attention": "none"])], into: &state, batch: batch)
            XCTAssertEqual(ActivityTaskGroup.make(state.activities).first?.runningSubagentCount, 3, label)
            read([row(ending, 7, ["origin": "transcript"])], into: &state, batch: batch)
            XCTAssertEqual(activity(state, parent)?.phase, .interrupted, label)
            for (thread, last) in [(child, 6.0), ("foreground-child", 6.5)] {
                let ended = try XCTUnwrap(activity(state, thread), label)
                XCTAssertEqual(ended.phase, .interrupted, "\(thread), \(label)")
                XCTAssertEqual(ended.phaseChangedAt, now.addingTimeInterval(last), "\(thread) ends at its latest evidence, \(label)")
            }
            XCTAssertEqual(activity(state, "background-child")?.phase, .running, label)
            XCTAssertEqual(ActivityTaskGroup.make(state.activities).first?.isRunning, true, "Real background work still shows, \(label)")
            // Its notification ends it; then nothing holds the interrupted task.
            read([row("agentNotification", 20, ["origin": "transcript", "itemId": "agent-tool", "agentId": "background-child", "agentStatus": "completed"])],
                 into: &state, batch: batch)
            XCTAssertEqual(activity(state, "background-child")?.phase, .completed, label)
            let group = try XCTUnwrap(ActivityTaskGroup.make(state.activities).first, label)
            XCTAssertFalse(group.isRunning, label); XCTAssertEqual(group.runningSubagentCount, 0, label)
            // A run begun after the interrupt is not touched.
            read([row("prompt", 21, ["promptId": "next-turn"]), row("subagentStart", 22, thread: "next-child", ["promptId": "next-turn"])], into: &state, batch: batch)
            XCTAssertEqual(activity(state, "next-child")?.phase, .running, label)
        } } }
    }

    func testHelperWaitsForBackgroundLaunchEvidenceInTheFinalBatch() {
        for arrives in [true, false] {
            var state = ClaudeActivityState(sourceID: ssh)
            func batch(_ rows: [[String: Any]], drained: Bool) {
                state.consume(ClaudeActivityRecord.encode(["kind": "claudeBatch", "baselineFinal": drained, "records": rows])!,
                    now: now.addingTimeInterval(10))
            }
            batch([row("prompt", 0), row("toolStart", 1, ["itemId": "agent-tool", "agentTool": true, "attention": "none"]),
                   row("subagentStart", 2, thread: child)], drained: true)
            batch([row("failure", 5, ["origin": "transcript"])], drained: false)
            XCTAssertEqual(activity(state, child)?.phase, .running)
            let launch = row("agentResult", 3, ["origin": "transcript", "itemId": "agent-tool", "agentId": child, "agentStatus": "async_launched"])
            batch(arrives ? [launch] : [], drained: true)
            XCTAssertEqual(activity(state, child)?.phase, arrives ? .running : .interrupted)
        }
    }

    /// Only an interrupt that ends the live main turn counts: one for a turn
    /// that already ended, such as a dismissed next-step box, ends no child.
    func testInterruptOfAnEndedMainTurnEndsNoChild() throws {
        for host in [String?.none, ssh] { for batch in [false, true] {
            let label = "\(host ?? "local"), batch \(batch)"
            var state = ClaudeActivityState(sourceID: host)
            read([row("prompt", 0), row("subagentStart", 2, thread: child), row("stopVerified", 4, ["origin": "transcript"])], into: &state, batch: batch)
            XCTAssertEqual(activity(state, parent)?.phase, .completed, label)
            read([row("interrupt", 5, ["origin": "transcript"])], into: &state, batch: batch)
            XCTAssertEqual(activity(state, child)?.phase, .running, label)
        } }
    }

    /// A read takes the hooks first, so a child's tail is often read after the
    /// root ending that it preceded. Whatever the order, the run ends once, at
    /// its latest evidence, and only after the whole read applied.
    func testEveryOrderOfAReadEndsTheChildAtItsLatestEvidence() throws {
        func orders(_ values: [[String: Any]]) -> [[[String: Any]]] {
            values.count <= 1 ? [values] : values.indices.flatMap { index -> [[[String: Any]]] in
                var rest = values; let first = rest.remove(at: index)
                return orders(rest).map { [first] + $0 }
            }
        }
        let endings: [(String, [String: Any]?, ActivityPhase)] = [("agent-free Stop", row("stopRequested", 9, ["agents": 0]), .completed),
            ("interrupt", row("interrupt", 9, ["origin": "transcript"]), .interrupted), ("none", nil, .running)]
        for host in [String?.none, ssh] {
            for (name, ending, phase) in endings {
                let records = [row("subagentStart", 2, thread: child),
                               row("toolStart", 3, thread: child, ["origin": "transcript", "itemId": "child-tool", "attention": "none"]),
                               row("response", 5, thread: child, ["origin": "transcript", "itemId": "child-reply"])] + (ending.map { [$0] } ?? [])
                for order in orders(records) { for baseline in [true, false] {
                    let label = "\(host ?? "local"), \(order.map { $0["kind"] as? String ?? "" }), \(name), baseline \(baseline)"
                    var state = ClaudeActivityState(sourceID: host)
                    let rows = [row("prompt", 0)] + order
                    if baseline {
                        state.consume(ClaudeActivityRecord.encode(["kind": "claudeBatch", "attaching": true, "records": rows])!, now: now.addingTimeInterval(100))
                        XCTAssertEqual(activity(state, child)?.phase, .running, "A baseline keeps the tail open until it is read whole, \(label)")
                        state.finalizeHistoricalBaseline(now: now.addingTimeInterval(100))
                    } else { read(rows, into: &state, batch: host != nil) }
                    let value = try XCTUnwrap(activity(state, child), label)
                    XCTAssertEqual(value.phase, phase, label)
                    if ending != nil { XCTAssertEqual(value.phaseChangedAt, now.addingTimeInterval(5), label) }
                } }
            }
        }
    }

    /// The reported case: Pacer restarted while a background agent ran. A cold
    /// read reaches neither the launch at the head of a long main transcript nor
    /// the SubagentStart rotated into `events.previous.jsonl`, so the agent's
    /// ending cannot match. The main thread's next agent-free Stop ends it, through
    /// the native reader and the SSH helper alike.
    func testRestartThatLostTheLaunchEndsTheAgentAtTheNextAgentFreeStop() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-lost-launch-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent("projects/fixture"), subagents = project.appendingPathComponent(parent + "/subagents")
        let pacer = home.appendingPathComponent("pacer")
        for directory in [subagents, pacer] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let root = project.appendingPathComponent(parent + ".jsonl"), agent = subagents.appendingPathComponent("agent-" + child + ".jsonl")
        let spool = pacer.appendingPathComponent("events.jsonl")
        func raw(_ type: String, _ id: String, _ second: Int, _ previous: String?, _ extra: [String: Any], agentID: String? = nil) -> [String: Any] {
            var record: [String: Any] = ["type": type, "uuid": id, "sessionId": parent, "promptId": turn, "timestamp": String(format: "2027-01-15T08:00:%02dZ", second)]
            if let previous { record["parentUuid"] = previous }
            if let agentID { record["agentId"] = agentID; record["isSidechain"] = true }
            return record.merging(extra) { _, new in new }
        }
        func hook(_ kind: String, _ second: Double, _ extra: [String: Any] = [:]) -> [String: Any] {
            ["kind": kind, "origin": "hook", "sessionId": parent, "promptId": turn, "at": now.timeIntervalSince1970 + second].merging(extra) { _, new in new }
        }
        func lines(_ rows: [[String: Any]]) throws -> Data { try rows.reduce(into: Data()) { data, row in data += try JSONSerialization.data(withJSONObject: row); data.append(10) } }
        // The launch, then more main-thread work than a cold read takes.
        var main = [raw("user", "human", 0, nil, ["origin": ["kind": "human"], "message": ["role": "user", "content": "PRIVATE prompt"]]),
                    raw("assistant", "agent-call", 1, "human", ["message": ["content": [["type": "tool_use", "id": "agent-tool", "name": "Agent"]]]]),
                    raw("user", "agent-result", 3, "agent-call", ["message": ["content": [["type": "tool_result", "tool_use_id": "agent-tool", "content": "PRIVATE"]]],
                        "toolUseResult": ["status": "async_launched", "agentId": child]])]
        let padding = String(repeating: "PRIVATE work ", count: 80)
        for index in 0..<640 {
            main.append(raw("assistant", "work-\(index)", 4 + index * 15 / 640, index == 0 ? "agent-result" : "work-\(index - 1)", ["message": ["content": [["type": "text", "text": padding]]]]))
        }
        XCTAssertGreaterThan(try lines(main).count - (try lines(Array(main.prefix(3))).count), ClaudeActivityReader.initialReadBudget)
        try lines(main).write(to: root)
        try lines([raw("assistant", "child-work", 20, nil, ["message": ["content": [["type": "tool_use", "id": "child-tool", "name": "Bash"]]]], agentID: child),
                   raw("user", "child-result", 21, "child-work", ["message": ["content": [["type": "tool_result", "tool_use_id": "child-tool", "content": "PRIVATE"]]]], agentID: child)])
            .write(to: agent)
        // The launch's hooks were rotated away; a cold read never opens that file.
        try lines([hook("prompt", 0.01), hook("toolStart", 1.01, ["itemId": "agent-tool", "agentTool": true]),
                   hook("subagentStart", 2, ["sessionId": child, "parentId": parent]),
                   hook("agentResult", 3.01, ["itemId": "agent-tool", "agentId": child, "agentStatus": "async_launched"])])
            .write(to: pacer.appendingPathComponent("events.previous.jsonl"))
        try lines([hook("toolStart", 18.01, ["itemId": "main-tool", "attention": "none"]), hook("toolEnd", 18.5, ["itemId": "main-tool"]),
                   hook("stopRequested", 19.5, ["agents": 1])]).write(to: spool)
        // Appended after the restart: the agent's last work and its ending, then the main thread's agent-free Stop.
        let notice = "<task-notification>\n<task-id>" + child + "</task-id>\n<tool-use-id>agent-tool</tool-use-id>\n<status>completed</status>\n<summary>PRIVATE</summary>\n</task-notification>"
        let ending = try lines([raw("attachment", "ending", 30, "work-639", ["attachment": ["type": "queued_command", "commandMode": "task-notification",
            "origin": ["kind": "task-notification", "producer": "session-task"], "prompt": notice]])])
        let lastWork = try lines([raw("assistant", "child-final", 29, "child-result", ["message": ["content": [["type": "text", "text": "PRIVATE report"]]]], agentID: child)])
        let idle = try lines([hook("stopRequested", 31, ["agents": 0])])
        func append(_ data: Data, to file: URL) throws { let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }; handle.seekToEndOfFile(); handle.write(data) }

        // The SSH helper reads the same files before and after each append.
        let program = """
        __name__ = 'fixture'
        import base64, json, pathlib, sys
        exec(base64.b64decode(sys.argv[1]), globals())
        root, agent, spool = map(pathlib.Path, sys.argv[2:5])
        reader = Tailer(root.parents[2])
        for path, session, owner, owned in ((root, sys.argv[5], None, False), (agent, sys.argv[6], sys.argv[5], False), (spool, 'hooks', None, True)):
            reader.attach(path, session, owner, owned)
        def drain():
            rows = []
            reader.dirty = set(reader.cursors)
            for _ in range(32):
                if not reader.dirty: break
                rows += reader.read()
            assert not reader.dirty
            return rows
        reads = [drain()]
        for stage in sys.argv[7:]:
            for path, data in zip((root, agent, spool), json.loads(base64.b64decode(stage))):
                with path.open('ab') as handle: handle.write(base64.b64decode(data))
            reads.append(drain())
        reader.close(); print(json.dumps(reads))
        """
        // Stage one appends the last work and the ending; stage two the agent-free Stop.
        func stage(_ main: Data, _ agent: Data, _ spool: Data) throws -> String {
            try JSONSerialization.data(withJSONObject: [main, agent, spool].map { $0.base64EncodedString() }).base64EncodedString()
        }
        let pythonHome = home.appendingPathComponent("python-copy")
        // Foundation on macOS copies only into an existing folder.
        try FileManager.default.createDirectory(at: pythonHome, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: home.appendingPathComponent("projects"), to: pythonHome.appendingPathComponent("projects"))
        try FileManager.default.copyItem(at: pacer, to: pythonHome.appendingPathComponent("pacer"))
        let pythonRoot = pythonHome.appendingPathComponent("projects/fixture/" + parent + ".jsonl")
        let pythonAgent = pythonHome.appendingPathComponent("projects/fixture/" + parent + "/subagents/agent-" + child + ".jsonl")
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = PythonFixture.executable
        process.arguments = ["-c", program, Data(ClaudeActivityProbe.script.utf8).base64EncodedString(), pythonRoot.path, pythonAgent.path,
                             pythonHome.appendingPathComponent("pacer/events.jsonl").path, parent, child,
                             try stage(ending, lastWork, Data()), try stage(Data(), Data(), idle)]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = errors
        let pythonFixture = try PythonFixture.prepare(process); defer { pythonFixture.remove() }; try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("PRIVATE"))
        let helperReads = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [[[String: Any]]])
        XCTAssertEqual(helperReads.count, 3)
        XCTAssertFalse(helperReads[0].contains { $0["kind"] as? String == "agentResult" || $0["kind"] as? String == "subagentStart" }, "The cold read misses the launch")

        var reader = ClaudeActivityReader(), local = ClaudeActivityState(), remote = ClaudeActivityState(sourceID: ssh)
        func readLocal(at second: Double) {
            for _ in 0..<8 {
                let result = reader.read(home: home, discover: true, now: now.addingTimeInterval(second))
                for frame in result.records { local.consume(frame, now: now.addingTimeInterval(second)) }
                if result.caughtUp { local.finalizeHistoricalBaseline(now: now.addingTimeInterval(second)); return }
            }
            XCTFail("The native reader did not catch up")
        }
        func readRemote(_ rows: [[String: Any]], at second: Double, cold: Bool) {
            let chunks = stride(from: 0, to: max(rows.count, 1), by: 512).map { Array(rows[$0..<min($0 + 512, rows.count)]) }
            for (index, chunk) in chunks.enumerated() {
                var frame: [String: Any] = ["kind": "claudeBatch", "records": chunk]
                if cold { frame["attaching"] = true; frame["baselineFinal"] = index == chunks.count - 1 }
                remote.consume(ClaudeActivityRecord.encode(frame)!, now: now.addingTimeInterval(second))
            }
        }
        readLocal(at: 25); readRemote(helperReads[0], at: 25, cold: true)
        for (name, state) in [("local", local), ("ssh", remote)] {
            XCTAssertEqual(activity(state, child)?.phase, .running, "The rebuilt agent runs without its launch, \(name)")
        }
        try append(ending, to: root); try append(lastWork, to: agent)
        readLocal(at: 32); readRemote(helperReads[1], at: 32, cold: false)
        for (name, state) in [("local", local), ("ssh", remote)] {
            XCTAssertEqual(activity(state, child)?.phase, .running, "Its ending cannot match the lost launch, \(name)")
        }
        try append(idle, to: spool)
        readLocal(at: 35); readRemote(helperReads[2], at: 35, cold: false)
        for (name, state) in [("local", local), ("ssh", remote)] {
            let ended = try XCTUnwrap(activity(state, child), name)
            XCTAssertEqual(ended.phase, .completed, name)
            XCTAssertEqual(ended.phaseChangedAt, now.addingTimeInterval(29), "It ends at its last work, \(name)")
            XCTAssertEqual(ActivityTaskGroup.make(state.activities).first { $0.primary.threadID == parent }?.runningSubagentCount, 0, name)
        }
    }
}
