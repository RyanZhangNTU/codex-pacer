import XCTest
@testable import PacerCore

final class ClaudeSubagentLifecycleTests: XCTestCase {
    private let parent = "fixture-parent", turn = "fixture-turn", child = "fixture-child"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func send(_ kind: String, to state: inout ClaudeActivityState, thread: String? = nil, at offset: Double, extra: [String: Any] = [:], attaching: Bool = false) {
        var row: [String: Any] = ["kind": kind, "origin": "hook", "sessionId": thread ?? parent, "promptId": turn, "at": now.timeIntervalSince1970 + offset]
        if let thread, thread != parent { row["parentId"] = parent }
        state.consume(ClaudeActivityRecord.encode(row.merging(extra) { _, new in new })!, now: now.addingTimeInterval(100), attaching: attaching)
    }
    func testForegroundAgentResultCompletesOnlyExactChildWhileBackgroundAndBlockedStopRemainRunning() throws {
        for host in [String?.none, "remote-ssh-discovered:fixture"] {
            var state = ClaudeActivityState(sourceID: host)
            send("prompt", to: &state, at: 0)
            send("toolStart", to: &state, at: 1, extra: ["itemId": "agent-tool", "agentTool": true])
            send("subagentStart", to: &state, thread: child, at: 2)
            send("subagentStart", to: &state, thread: "background-child", at: 2)
            send("stopRequested", to: &state, thread: child, at: 3)
            send("stopVerified", to: &state, at: 4)
            XCTAssertEqual(state.activities.first { $0.threadID == child }?.phase, .running)
            XCTAssertEqual(state.activities.first { $0.threadID == "background-child" }?.phase, .running)
            for invalid: [String: Any] in [["agentStatus": "async_launched"], ["itemId": "unobserved-tool"], ["agentId": "agent-" + child], ["promptId": "older-turn"]] {
                send("agentResult", to: &state, at: 5, extra: ["itemId": "agent-tool", "agentId": child, "agentStatus": "completed"].merging(invalid) { _, new in new })
                XCTAssertEqual(state.activities.first { $0.threadID == child }?.phase, .running)
            }
            send("agentResult", to: &state, at: 6, extra: ["itemId": "agent-tool", "agentId": child, "agentStatus": "completed"])
            XCTAssertEqual(state.activities.first { $0.threadID == child }?.phase, .completed)
            XCTAssertEqual(state.activities.first { $0.threadID == "background-child" }?.phase, .running)
            XCTAssertEqual(state.activities.first { $0.threadID == parent }?.phase, .completed)
            XCTAssertEqual(state.activities.count, 3)
        }
    }
    func testInternalHookWithoutSpawnNeverAppearsAndLaterRealSpawnKeepsParent() {
        var state = ClaudeActivityState()
        send("prompt", to: &state, at: 0); send("stopVerified", to: &state, at: 1)
        for (index, kind) in ["metadata", "toolStart", "toolEnd", "stopRequested", "approval"].enumerated() {
            send(kind, to: &state, thread: "internal-child", at: Double(index + 2), extra: ["itemId": "internal-tool"])
        }
        XCTAssertEqual(state.activities.count, 1); XCTAssertTrue(state.attention.isEmpty)
        XCTAssertEqual(state.activities.first?.phase, .completed)
        // Removing/acknowledging the parent cannot expose an internal orphan.
        XCTAssertTrue(state.activities.filter { $0.threadID != parent }.isEmpty)
        send("subagentStart", to: &state, thread: "internal-child", at: 10, extra: ["project": "fixture-project"])
        let spawned = state.activities.first { $0.threadID == "internal-child" }
        XCTAssertEqual(spawned?.phase, .running); XCTAssertEqual(spawned?.parentThreadID, parent)
        XCTAssertEqual(spawned?.project, "fixture-project")
    }
    func testResultBeforeChildSourceDoesNotCreateOrphanAndLateUsageOnlyEnrichesEndedTurn() throws {
        var state = ClaudeActivityState()
        send("prompt", to: &state, at: 0)
        send("toolStart", to: &state, at: 1, extra: ["itemId": "agent-tool", "agentTool": true])
        send("agentResult", to: &state, at: 6, extra: ["itemId": "agent-tool", "agentId": child, "agentStatus": "completed"])
        XCTAssertEqual(state.activities.count, 1)
        send("subagentStart", to: &state, thread: child, at: 2)
        let end = try XCTUnwrap(state.activities.first { $0.threadID == child }?.phaseChangedAt)
        XCTAssertEqual(state.activities.first { $0.threadID == child }?.phase, .completed)
        send("modelBlock", to: &state, thread: child, at: 5, extra: ["origin": "transcript", "requestId": "child-request", "messageId": "child-message", "outputTokens": 90, "toolIds": [String]()])
        let measured = try XCTUnwrap(state.activities.first { $0.threadID == child })
        XCTAssertEqual(measured.phaseChangedAt, end); XCTAssertEqual(measured.phase, .completed)
        XCTAssertEqual(measured.responsePerformance?.tokensPerSecond, 30); XCTAssertNil(measured.firstTokenLatency)
        send("subagentStart", to: &state, thread: child, at: 10, extra: ["promptId": "new-child-turn"])
        XCTAssertEqual(state.activities.first { $0.threadID == child }?.phase, .running)
        send("agentResult", to: &state, at: 11, extra: ["itemId": "agent-tool", "agentId": child, "agentStatus": "completed"])
        XCTAssertEqual(state.activities.first { $0.threadID == child }?.phase, .running)
    }
    func testOrdinaryToolAndUnownedOrMalformedResultsCannotEndChild() {
        var state = ClaudeActivityState()
        send("prompt", to: &state, at: 0)
        send("toolStart", to: &state, at: 1, extra: ["itemId": "ordinary-tool"])
        send("subagentStart", to: &state, thread: child, at: 2)
        send("agentResult", to: &state, at: 3, extra: ["itemId": "ordinary-tool", "agentId": child, "agentStatus": "completed"])
        XCTAssertEqual(state.activities.first { $0.threadID == child }?.phase, .running)
        send("toolStart", to: &state, at: 4, extra: ["itemId": "agent-tool", "agentTool": true])
        send("agentResult", to: &state, at: 5, extra: ["promptId": NSNull(), "itemId": "agent-tool", "agentId": child, "agentStatus": "completed"])
        XCTAssertEqual(state.activities.first { $0.threadID == child }?.phase, .running)
    }
    private func notification(status: String = "completed", task: String? = nil, item: String = "agent-tool") -> String {
        "<task-notification>\n<task-id>" + (task ?? child) + "</task-id>\n<tool-use-id>" + item + "</tool-use-id>\n<output-file>/PRIVATE/output</output-file>\n<status>" + status + "</status>\n<summary>PRIVATE &lt;summary&gt;</summary>\nPRIVATE escaped &lt;report&gt;\n</task-notification>"
    }
    private func notificationFixture(_ text: String, origin: Any = ["kind": "task-notification", "producer": "session-task", "runId": "engine-run"], at: String = "2027-01-15T08:00:10Z") -> [String: Any] {
        ["type": "user", "sessionId": parent, "promptId": "engine-wake-prompt", "uuid": "engine-wake", "timestamp": at,
         "origin": origin, "isMeta": false, "isSynthetic": false, "message": ["role": "user", "content": [["type": "text", "text": text]]]]
    }
    func testBackgroundOwnedNotificationEndsOnlyStoredChildTurnAfterParentNewPrompt() throws {
        for status in ["completed", "failed", "killed"] {
            for host in [String?.none, "remote-ssh-discovered:fixture"] {
                var state = ClaudeActivityState(sourceID: host)
                send("prompt", to: &state, at: 0)
                send("toolStart", to: &state, at: 1, extra: ["itemId": "agent-tool", "agentTool": true])
                send("subagentStart", to: &state, thread: child, at: 2, extra: ["promptId": "child-owned-turn"])
                send("agentResult", to: &state, at: 3, extra: ["itemId": "agent-tool", "agentId": child, "agentStatus": "async_launched"])
                send("stopVerified", to: &state, at: 4)
                send("prompt", to: &state, at: 5, extra: ["promptId": "parent-new-turn"])
                for rejected: [String: Any] in [["itemId": "other-tool"], ["agentId": "other-child"], ["sessionId": "other-parent"], ["at": now.timeIntervalSince1970 + 1]] {
                    send("agentNotification", to: &state, at: 10, extra: ["origin": "transcript", "promptId": "engine-wake-prompt", "itemId": "agent-tool", "agentId": child, "agentStatus": status].merging(rejected) { _, new in new })
                    XCTAssertEqual(state.activities.first { $0.threadID == child }?.phase, .running)
                }
                send("agentNotification", to: &state, at: 10, extra: ["origin": "transcript", "promptId": "engine-wake-prompt", "itemId": "agent-tool", "agentId": child, "agentStatus": status])
                let ended = try XCTUnwrap(state.activities.first { $0.threadID == child })
                XCTAssertEqual(ended.phase, status == "completed" ? .completed : .interrupted)
                XCTAssertEqual(ended.turnID, "child-owned-turn"); XCTAssertEqual(ended.turnFailed, status == "failed")
                XCTAssertEqual(state.activities.first { $0.threadID == parent }?.turnID, "parent-new-turn")
                XCTAssertEqual(state.activities.first { $0.threadID == parent }?.phase, .running)
                send("subagentStart", to: &state, thread: child, at: 11, extra: ["promptId": "resumed-child-turn"])
                send("agentNotification", to: &state, at: 12, extra: ["origin": "transcript", "itemId": "agent-tool", "agentId": child, "agentStatus": status])
                XCTAssertEqual(state.activities.first { $0.threadID == child }?.phase, .running)
            }
        }
    }
    func testHooksDisabledParentBeforeChildBindsRealChildPromptAndHistoricalReplayStaysQuiet() throws {
        for status in ["completed", "async_launched"] {
            var state = ClaudeActivityState(), inbox = CompletionInbox(), policy = AttentionPolicy()
            send("prompt", to: &state, at: 0, extra: ["origin": "transcript"], attaching: true)
            send("toolStart", to: &state, at: 1, extra: ["origin": "transcript", "itemId": "agent-tool", "agentTool": true], attaching: true)
            send("agentResult", to: &state, at: 6, extra: ["origin": "transcript", "itemId": "agent-tool", "agentId": child, "agentStatus": status], attaching: true)
            if status == "async_launched" {
                send("agentNotification", to: &state, at: 8, extra: ["origin": "transcript", "itemId": "agent-tool", "agentId": child, "agentStatus": "completed"], attaching: true)
            }
            XCTAssertEqual(state.activities.count, 1)
            send("prompt", to: &state, thread: child, at: 2, extra: ["origin": "transcript", "promptId": "child-file-turn"], attaching: true)
            let ended = try XCTUnwrap(state.activities.first { $0.threadID == child })
            XCTAssertEqual(ended.phase, .completed); XCTAssertEqual(ended.turnID, "child-file-turn")
            XCTAssertTrue(ended.isHistoricalCompletion); XCTAssertNil(ended.responsePerformance)
            inbox.observe(state.activities, at: now.addingTimeInterval(10), retention: 60)
            XCTAssertTrue(inbox.unreadActivities.isEmpty); XCTAssertTrue(policy.activityNotices(state.activities, at: now.addingTimeInterval(10)).isEmpty)
        }
    }
    func testStrictEngineHeaderRejectsHumanUnknownOriginNestedOrMalformedHeadersAndKeepsHumanPrompts() throws {
        let valid = notification()
        let invalidTexts = [valid.replacingOccurrences(of: "<task-id>" + child + "</task-id>", with: "<task-id>" + child + "</task-id>\n<task-id>" + child + "</task-id>"),
                            valid.replacingOccurrences(of: "<task-id>" + child + "</task-id>", with: "<task-id><task-id>" + child + "</task-id></task-id>"),
                            valid.replacingOccurrences(of: child, with: child + "\n"), notification(status: "running"),
                            valid.replacingOccurrences(of: "<status>completed</status>", with: "<status>&completed;</status>"),
                            "<!DOCTYPE example>" + valid, valid + "extra", valid.replacingOccurrences(of: "<task-id>", with: "<task-id attr='x'>")]
        var fixtures = [notificationFixture(valid)] + invalidTexts.map { notificationFixture($0) }
        var stringContent = notificationFixture(valid.replacingOccurrences(of: "PRIVATE escaped &lt;report&gt;", with: "<usage><total_tokens>90</total_tokens></usage>\n<status>failed</status>"))
        stringContent["promptSource"] = "sdk"
        stringContent["message"] = ["role": "user", "content": valid.replacingOccurrences(of: "PRIVATE escaped &lt;report&gt;", with: "<usage><total_tokens>90</total_tokens></usage>\n<status>failed</status>")]
        fixtures.append(stringContent)
        for origin: Any in [["kind": "human"], ["kind": "task-notification", "producer": "other"], ["kind": "task-notification", "producer": "session-task", "runId": "run\n"], ["kind": "other"], ["PRIVATE malformed"]] {
            fixtures.append(notificationFixture(valid, origin: origin))
        }
        var secondText = notificationFixture(valid)
        secondText["message"] = ["role": "user", "content": [["type": "text", "text": valid], ["type": "text", "text": "PRIVATE extra"]]]
        fixtures.append(secondText)
        let native = try fixtures.flatMap { ClaudeActivityRecord.transcript(ClaudeActivityRecord.encode($0)!, sessionID: parent, promptID: turn) }.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        XCTAssertTrue(NSArray(array: try pythonRows(fixtures, owner: parent, parentID: nil)).isEqual(to: native))
        XCTAssertEqual(native.filter { $0["kind"] as? String == "agentNotification" }.count, 2)
        XCTAssertTrue(native.filter { $0["kind"] as? String == "agentNotification" }.allSatisfy { $0["agentStatus"] as? String == "completed" })
        XCTAssertEqual(native.filter { $0["kind"] as? String == "prompt" }.count, 1) // genuine human literal remains a human turn
        for source in ["hook", "transcript"] {
            var state = ClaudeActivityState()
            send("prompt", to: &state, at: 0, extra: ["origin": source])
            for fixture in [notificationFixture(valid), notificationFixture(valid, origin: ["kind": "other"])] {
                for row in ClaudeActivityRecord.transcript(ClaudeActivityRecord.encode(fixture)!, sessionID: parent, promptID: turn) { state.consume(row, now: now.addingTimeInterval(100)) }
            }
            XCTAssertEqual(state.activities.count, 1); XCTAssertEqual(state.activities.first?.turnID, turn)
            let human = notificationFixture("PRIVATE genuine prompt", origin: ["kind": "human"])
            let projectedHuman = ClaudeActivityRecord.transcript(ClaudeActivityRecord.encode(human)!, sessionID: parent, promptID: turn)
            XCTAssertTrue(projectedHuman.contains { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["kind"] as? String == "prompt" })
            for row in projectedHuman { state.consume(row, now: now.addingTimeInterval(100)) }
            XCTAssertEqual(state.activities.first?.turnID, source == "hook" ? turn : "engine-wake-prompt")
            if source == "hook" {
                send("prompt", to: &state, at: 11, extra: ["promptId": "engine-wake-prompt"])
                XCTAssertEqual(state.activities.first?.turnID, "engine-wake-prompt")
            }
        }
    }
    private func pythonRows(_ fixtures: [[String: Any]], owner: String, parentID: String?) throws -> [[String: Any]] {
        let script = "__name__='fixture'\nimport base64,json,sys\nexec(base64.b64decode(sys.argv[1]).decode(),globals())\nrows=[]\nfor value in json.loads(base64.b64decode(sys.argv[2])):\n rows.extend(transcript(json.dumps(value).encode(),sys.argv[3],sys.argv[4] or None,sys.argv[5]))\nprint(json.dumps(rows,separators=(',',':')))\n"
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, Data(ClaudeActivityProbe.script.utf8).base64EncodedString(), try JSONSerialization.data(withJSONObject: fixtures).base64EncodedString(), owner, parentID ?? "", turn]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = errors
        try process.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0); XCTAssertTrue(errors.fileHandleForReading.readDataToEndOfFile().isEmpty)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("PRIVATE"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [[String: Any]])
    }
    func testNativeSshTypedResultAndFileAliasProjectionAgreeWithoutPrivateOutputs() throws {
        let result: [String: Any] = ["type": "user", "sessionId": parent, "promptId": turn, "timestamp": "2027-01-15T08:00:05Z", "message": ["content": [["type": "tool_result", "tool_use_id": "agent-tool", "content": "PRIVATE result"]]], "toolUseResult": ["status": "completed", "agentId": child, "content": "PRIVATE result", "prompt": "PRIVATE prompt"]]
        let start: [String: Any] = ["type": "assistant", "sessionId": parent, "promptId": turn, "timestamp": "2027-01-15T08:00:01Z", "message": ["content": [["type": "tool_use", "id": "agent-tool", "name": "Agent", "input": ["prompt": "PRIVATE prompt"]]]]]
        var fixtures = [start, result]
        for response: Any in [["status": "async_launched", "agentId": child], ["status": "completed", "agentId": "child\n"], ["status": "PRIVATE status", "agentId": child], ["status": "completed", "agentId": 5], ["PRIVATE response"]] {
            var fixture = result; fixture["toolUseResult"] = response; fixtures.append(fixture)
        }
        let native = try fixtures.flatMap { ClaudeActivityRecord.transcript(ClaudeActivityRecord.encode($0)!, sessionID: parent, promptID: turn) }.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        let remote = try pythonRows(fixtures, owner: parent, parentID: nil)
        XCTAssertTrue(NSArray(array: remote).isEqual(to: native))
        XCTAssertEqual(native.filter { $0["kind"] as? String == "agentResult" }.count, 2)
        XCTAssertEqual(native.first { $0["kind"] as? String == "toolStart" }?["agentTool"] as? Bool, true)
        let aliases: [[String: Any]] = [child, "agent-" + child, "other-child", "agent-other-child"].map { header in
            ["type": "user", "sessionId": parent, "agentId": header, "promptId": turn, "timestamp": "2027-01-15T08:00:02Z", "message": ["content": "PRIVATE prompt"]]
        }
        let projected = try aliases.flatMap { ClaudeActivityRecord.transcript(ClaudeActivityRecord.encode($0)!, sessionID: child, parentID: parent, promptID: turn) }.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        XCTAssertTrue(NSArray(array: try pythonRows(aliases, owner: child, parentID: parent)).isEqual(to: projected))
        XCTAssertEqual(projected.count, 4)
        XCTAssertTrue(projected.allSatisfy { $0["sessionId"] as? String == child && $0["parentId"] as? String == parent })
    }
    func testSshColdReplayEstablishesHookEngineTurnBeforeExactStopAndNextHumanAppend() throws {
        let home = URL(fileURLWithPath: "/private/tmp/pacer-child-cold-replay-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("root.jsonl"), spool = home.appendingPathComponent("hooks.jsonl")
        func raw(_ type: String, id: String, parentID: String? = nil, second: Int, extra: [String: Any] = [:]) -> [String: Any] {
            var row: [String: Any] = ["type": type, "uuid": id, "sessionId": parent, "timestamp": String(format: "2027-01-15T08:00:%02dZ", second)]
            if let parentID { row["parentUuid"] = parentID }
            return row.merging(extra) { _, new in new }
        }
        func hook(_ kind: String, second: Double, prompt: String, extra: [String: Any] = [:]) -> [String: Any] {
            ["kind": kind, "origin": "hook", "sessionId": parent, "promptId": prompt, "at": now.timeIntervalSince1970 + second].merging(extra) { _, new in new }
        }
        let transcript: [[String: Any]] = [
            raw("user", id: "human-1", second: 0, extra: ["promptId": turn, "origin": ["kind": "human"], "message": ["role": "user", "content": "PRIVATE prompt"]]),
            raw("assistant", id: "tool-1", parentID: "human-1", second: 1, extra: ["message": ["content": [["type": "tool_use", "id": "agent-tool", "name": "Agent", "input": ["prompt": "PRIVATE child prompt"]]]]]),
            raw("user", id: "result-1", parentID: "tool-1", second: 3, extra: ["message": ["content": [["type": "tool_result", "tool_use_id": "agent-tool", "content": "PRIVATE result"]]], "toolUseResult": ["status": "async_launched", "agentId": child]]),
            raw("assistant", id: "answer-1", parentID: "result-1", second: 4, extra: ["message": ["content": [["type": "text", "text": "PRIVATE response"]]]]),
            raw("system", id: "stop-1", parentID: "answer-1", second: 5, extra: ["subtype": "stop_hook_summary", "preventedContinuation": false, "hookErrors": [String](), "hookAdditionalContext": [String]()]),
            raw("user", id: "engine-1", parentID: "stop-1", second: 8, extra: ["promptId": "engine-turn", "origin": ["kind": "automation"], "isMeta": true, "message": ["content": "PRIVATE engine input"]]),
            raw("assistant", id: "engine-answer", parentID: "engine-1", second: 10, extra: ["message": ["content": [["type": "text", "text": "PRIVATE engine response"]]]]),
            raw("system", id: "engine-stop", parentID: "engine-answer", second: 12, extra: ["subtype": "stop_hook_summary", "preventedContinuation": false, "hookErrors": [String](), "hookAdditionalContext": [String]()]),
            notificationFixture(notification(), at: "2027-01-15T08:00:13Z")]
        let hooks: [[String: Any]] = [hook("prompt", second: 0.04, prompt: turn), hook("toolStart", second: 1.04, prompt: turn, extra: ["itemId": "agent-tool", "agentTool": true]),
            hook("subagentStart", second: 2, prompt: "child-owned-turn", extra: ["sessionId": child, "parentId": parent]),
            hook("agentResult", second: 3.04, prompt: turn, extra: ["itemId": "agent-tool", "agentId": child, "agentStatus": "async_launched"]),
            hook("stopRequested", second: 4.99, prompt: turn), hook("prompt", second: 8.04, prompt: "engine-turn"), hook("stopRequested", second: 11.99, prompt: "engine-turn")]
        func lines(_ values: [[String: Any]]) throws -> Data { try values.reduce(into: Data()) { data, row in data += try JSONSerialization.data(withJSONObject: row); data.append(10) } }
        let nextRaw = raw("user", id: "next-human", parentID: "engine-stop", second: 20, extra: ["promptId": "next-human-turn", "origin": ["kind": "human"], "message": ["content": "PRIVATE next prompt"]])
        let program = """
        __name__='fixture'
        import base64,json,pathlib,sys
        exec(base64.b64decode(sys.argv[1]).decode(),globals())
        class OrderedDirty:
         def __init__(self,paths):self.paths=list(paths)
         def __iter__(self):return iter(self.paths)
         def discard(self,path):self.paths=[p for p in self.paths if p!=path]
         def add(self,path):
          if path not in self.paths:self.paths.append(path)
        root=pathlib.Path(sys.argv[2]);spool=pathlib.Path(sys.argv[3]);owner=sys.argv[4]
        order=[root,spool] if sys.argv[5]=='root-first' else [spool,root]
        tailer=Tailer.__new__(Tailer);tailer.cursors={};tailer.dirty=OrderedDirty(order)
        for path,owned in ((root,False),(spool,True)):
         tailer.cursors[path]={'inode':0,'offset':0,'fragment':b'','session':owner,'parent':None,'owned':owned,'historicalEnd':None}
        def drain():
         batches=[];deferred=0
         for _ in range(8):
          if not list(tailer.dirty):break
          before=tailer.cursors[root]['offset'];rows=tailer.read();batches.append(rows)
          assert sum(row.get('origin')=='hook' for row in rows)<=512
          cursor=tailer.cursors[spool]
          if cursor['offset']<spool.stat().st_size or b'\\n' in cursor['fragment']:
           assert tailer.cursors[root]['offset']==before;deferred+=1
         assert not list(tailer.dirty)
         return batches,deferred
        cold,cold_deferred=drain()
        for path,argument in ((root,sys.argv[6]),(spool,sys.argv[7])):
         with path.open('ab') as handle:handle.write(base64.b64decode(argument))
        tailer.dirty=OrderedDirty(order);appended,append_deferred=drain()
        with spool.open('ab') as handle:handle.write(b'{"unfinished":')
        with root.open('ab') as handle:handle.write(base64.b64decode(sys.argv[8]))
        tailer.dirty=OrderedDirty(order);partial=tailer.read()
        print(json.dumps({'cold':cold,'appended':appended,'coldDeferred':cold_deferred,'appendDeferred':append_deferred,
         'partialReadRoot':tailer.cursors[root]['offset']==root.stat().st_size,'partialLeftDirty':bool(list(tailer.dirty))},separators=(',',':')))
        """
        for backlog in [0, 520] { for order in ["root-first", "hooks-first"] {
            let filler = Array(repeating: hook("metadata", second: 7, prompt: turn), count: backlog)
            let coldHooks = Array(hooks.prefix(5)) + filler + Array(hooks.suffix(2))
            try lines(transcript).write(to: root); try lines(coldHooks).write(to: spool)
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", program, Data(ClaudeActivityProbe.script.utf8).base64EncodedString(), root.path, spool.path, parent, order,
                try lines([nextRaw]).base64EncodedString(), try lines(filler + [hook("prompt", second: 20.04, prompt: "next-human-turn")]).base64EncodedString(),
                try lines([raw("assistant", id: "metadata-1", second: 21, extra: ["message": ["model": "fixture-model", "content": [Any]()]])]).base64EncodedString()]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = errors
            try process.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0); XCTAssertTrue(errors.fileHandleForReading.readDataToEndOfFile().isEmpty)
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("PRIVATE"))
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let cold = try XCTUnwrap(result["cold"] as? [[[String: Any]]]), appended = try XCTUnwrap(result["appended"] as? [[[String: Any]]])
            XCTAssertEqual(cold.count, backlog == 0 ? 1 : 2); XCTAssertEqual(appended.count, backlog == 0 ? 1 : 2)
            XCTAssertEqual(result["coldDeferred"] as? Int, backlog == 0 ? 0 : 1)
            XCTAssertEqual(result["appendDeferred"] as? Int, backlog == 0 ? 0 : 1)
            XCTAssertEqual(result["partialReadRoot"] as? Bool, true); XCTAssertEqual(result["partialLeftDirty"] as? Bool, false)
            var state = ClaudeActivityState(sourceID: "remote-ssh-discovered:fixture"), inbox = CompletionInbox(), policy = AttentionPolicy()
            for batch in cold { state.consume(ClaudeActivityRecord.encode(["kind": "claudeBatch", "records": batch])!, now: now.addingTimeInterval(30)) }
            XCTAssertEqual(state.activities.first { $0.threadID == parent }?.turnID, "engine-turn", order)
            XCTAssertEqual(state.activities.first { $0.threadID == parent }?.phase, .completed, order)
            XCTAssertEqual(state.activities.first { $0.threadID == child }?.phase, .completed, order)
            inbox.observe(state.activities, at: now.addingTimeInterval(30), retention: 60)
            XCTAssertTrue(inbox.unreadActivities.isEmpty); XCTAssertTrue(policy.activityNotices(state.activities, at: now.addingTimeInterval(30)).isEmpty)
            for batch in appended { state.consume(ClaudeActivityRecord.encode(["kind": "claudeBatch", "records": batch])!, now: now.addingTimeInterval(30)) }
            XCTAssertEqual(state.activities.first { $0.threadID == parent }?.turnID, "next-human-turn", order)
            XCTAssertEqual(state.activities.first { $0.threadID == parent }?.phase, .running, order)
        } }
    }
}
