import XCTest
@testable import PacerCore

final class CodexProgressTests: XCTestCase {
    private let thread = "11111111-1111-4111-8111-111111111111"
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func activity() -> SessionActivity { SessionActivity(id: "local:" + thread) }
    private func log(_ value: inout SessionActivity, _ type: String, at seconds: Double, outer: String = "event_msg",
                     fields: [String: Any] = [:]) {
        value.consume(["type": outer, "timestamp": ISO8601DateFormatter().string(from: start.addingTimeInterval(seconds)),
                       "payload": fields.merging(["type": type]) { first, _ in first }])
    }
    private func runtime(_ value: inout SessionActivity, _ method: String, at seconds: Double, turn: String = "turn-1",
                         fields: [String: Any] = [:]) {
        value.applyRuntime(fields.merging(["method": method, "threadId": thread, "turnId": turn,
                                          "at": start.timeIntervalSince1970 + seconds]) { first, _ in first })
    }
    private func report(_ percent: Any, server: String = "pacer_progress", error: Bool = false) -> [String: Any] {
        ["type": "McpToolCall", "id": "call-1", "server": server, "tool": "report_progress", "arguments": ["percent": percent],
         "status": "completed", "result": ["isError": error, "content": [["type": "text", "text": "pacer-progress:accepted"]]]]
    }
    private func ring(_ value: SessionActivity, at seconds: Double, attention: Bool = false) -> TaskProgressRing? {
        TaskProgressRing.make(value, phase: value.phase, enabled: true, at: start.addingTimeInterval(seconds), hasAttention: attention)
    }

    func testReportsUseCompletedOwnedItemsAndNeverAdvanceLifecycle() {
        var value = activity()
        log(&value, "task_started", at: 0, fields: ["turn_id": "turn-1"])
        log(&value, "reasoning", at: 9, outer: "response_item")
        func item(_ percent: Any, at time: Double, turn: String = "turn-1", source: String = "pacer_progress", error: Bool = false) {
            log(&value, "item_completed", at: time, fields: ["thread_id": thread, "turn_id": turn, "item": report(percent, server: source, error: error)])
        }
        item(63, at: 2)
        XCTAssertEqual(value.currentProgress?.percent, 63)
        item(41, at: 4)
        item(99, at: 3)
        item(true, at: 5); item(12.5, at: 6); item("34", at: 6); item(101, at: 6)
        item(99, at: 7, turn: "old-turn"); item(99, at: 7, source: "another_server"); item(99, at: 8, error: true)
        XCTAssertEqual(value.currentProgress?.percent, 41)
        XCTAssertEqual(value.lastObserved, start.addingTimeInterval(9))
        XCTAssertEqual(value.phase, .running)
        XCTAssertEqual(ring(value, at: 10)?.fraction, 0.41)
        log(&value, "task_complete", at: 10, fields: ["turn_id": "turn-1", "error": ["message": "synthetic failure"]])
        XCTAssertEqual(ring(value, at: 10)?.mode, .failed)
        XCTAssertEqual(ring(value, at: 10)?.fraction, 0.41)
        log(&value, "task_started", at: 11, fields: ["turn_id": "turn-2"])
        item(95, at: 12)
        XCTAssertEqual(ring(value, at: 12)?.state, .pending)
    }

    func testLegacyReportRequiresTheMatchingSuccessfulResult() {
        var value = activity()
        log(&value, "task_started", at: 0, fields: ["turn_id": "turn-1"])
        log(&value, "function_call", at: 1, outer: "response_item",
            fields: ["name": "report_progress", "namespace": "mcp__pacer_progress", "call_id": "call-1", "arguments": #"{"percent":0}"#])
        XCTAssertNil(value.currentProgress)
        XCTAssertNil(value.toolWaitStartedAt)
        let output = [["type": "input_text", "text": "Wall time: 0.1 seconds\nOutput:"],
                      ["type": "input_text", "text": "pacer-progress:accepted"]]
        log(&value, "function_call_output", at: 2, outer: "response_item", fields: ["call_id": "other", "output": output])
        XCTAssertNil(value.currentProgress)
        log(&value, "function_call_output", at: 3, outer: "response_item", fields: ["call_id": "call-1", "output": output])
        XCTAssertEqual(value.currentProgress?.percent, 0)
        XCTAssertEqual(value.lastObserved, start)
        log(&value, "task_complete", at: 4, fields: ["turn_id": "turn-1"])
        XCTAssertEqual(ring(value, at: 4)?.mode, .done)
        XCTAssertEqual(ring(value, at: 4)?.fraction, 1)
    }

    func testAttentionAndSleepDoNotEraseExecutionOrToolTiming() {
        var value = activity()
        runtime(&value, "turn/started", at: 0, fields: ["rootTurnId": "turn-1"])
        runtime(&value, "progress/reported", at: 1, fields: ["percent": 63])
        runtime(&value, "item/started", at: 2, fields: ["itemType": "sleep", "itemId": "sleep"])
        XCTAssertEqual(ring(value, at: 3)?.mode, .waiting)
        runtime(&value, "item/started", at: 3, fields: ["itemType": "commandExecution", "itemId": "old-tool"])
        runtime(&value, "item/started", at: 30, fields: ["itemType": "commandExecution", "itemId": "new-tool"])
        XCTAssertEqual(ring(value, at: 34)?.mode, .longStep)
        XCTAssertEqual(ring(value, at: 34, attention: true)?.mode, .attention)
        XCTAssertEqual(value.phase, .running)
        runtime(&value, "item/completed", at: 34, fields: ["itemType": "commandExecution", "itemId": "old-tool"])
        XCTAssertEqual(ring(value, at: 34)?.mode, .working)
        runtime(&value, "thread/status/changed", at: 35, fields: ["status": "active", "flags": ["waitingOnApproval", "waitingOnUserInput"]])
        runtime(&value, "item/agentMessage/delta", at: 36, fields: ["itemId": "answer", "hasText": true])
        XCTAssertEqual(value.phase, .waitingForInput)
        runtime(&value, "thread/status/changed", at: 37, fields: ["status": "active", "flags": ["waitingOnUserInput"]])
        XCTAssertEqual(value.phase, .waitingForInput)
        XCTAssertFalse(value.waitingForApproval)
        runtime(&value, "thread/status/changed", at: 38, fields: ["status": "active", "flags": [String]()])
        XCTAssertEqual(value.phase, .running)
        runtime(&value, "turn/started", at: 39, turn: "turn-2", fields: ["rootTurnId": "turn-1"])
        XCTAssertEqual(value.currentProgress?.percent, 63)
        XCTAssertEqual(value.currentProgress?.reportedAt, start.addingTimeInterval(1))
        runtime(&value, "progress/reported", at: 40, fields: ["percent": 90])
        XCTAssertEqual(value.currentProgress?.percent, 63)
        runtime(&value, "turn/started", at: 41, turn: "turn-3", fields: ["rootTurnId": "turn-3"])
        XCTAssertEqual(ring(value, at: 41)?.state, .pending)
    }

    func testKnownActiveMetadataGetsADashedRingAndMatchingLogEnrichesLive() {
        var live = activity(), logged = activity()
        runtime(&live, "thread/observed", at: 0, fields: ["status": "active"])
        XCTAssertNil(live.turnID)
        XCTAssertEqual(ring(live, at: 0)?.state, .pending)
        runtime(&live, "turn/attached", at: 4, fields: ["startedAt": start.timeIntervalSince1970])
        log(&logged, "task_started", at: 0, fields: ["turn_id": "turn-1"])
        log(&logged, "item_completed", at: 2, fields: ["thread_id": thread, "turn_id": "turn-1", "item": report(45)])
        let merged = ActivitySourceMerger.merge(logged: [logged], streamed: [live]).first
        XCTAssertEqual(merged?.currentProgress?.percent, 45)
        XCTAssertEqual(merged?.lastObserved, start.addingTimeInterval(4))
    }

    func testGoalPauseAndContinuationDoNotCompleteTheRequestEarly() {
        var value = activity()
        let created = start.timeIntervalSince1970
        func goal(_ status: String, at seconds: Double, turn: String = "turn-1") {
            runtime(&value, "thread/goal/updated", at: seconds, turn: turn, fields: [
                "goalStatus": status, "goalCreatedAt": created, "goalUpdatedAt": created + seconds])
        }
        runtime(&value, "turn/started", at: 0, fields: ["rootTurnId": "turn-1"])
        runtime(&value, "progress/reported", at: 1, fields: ["percent": 41])
        goal("active", at: 2)
        runtime(&value, "turn/completed", at: 3, fields: ["status": "failed"])
        XCTAssertEqual(ring(value, at: 3)?.mode, .waiting)
        XCTAssertEqual(ring(value, at: 3)?.percent, 41)
        goal("budgetLimited", at: 4)
        XCTAssertEqual(ring(value, at: 4)?.mode, .paused)
        XCTAssertFalse(ActivityTaskGroup.make([value])[0].isRunning)
        XCTAssertFalse(value.turnFailed)
        goal("active", at: 5)
        runtime(&value, "turn/started", at: 6, turn: "turn-2", fields: ["rootTurnId": "turn-1"])
        XCTAssertEqual(value.currentProgress?.percent, 41)
        goal("complete", at: 7, turn: "turn-2")
        XCTAssertEqual(value.phase, .running)
        runtime(&value, "turn/completed", at: 8, turn: "turn-2", fields: ["status": "completed"])
        XCTAssertEqual(ring(value, at: 8)?.mode, .done)
    }

    func testDesktopProgressCanArriveInSeparateStatusAndResultPatches() throws {
        var value = activity()
        var wire = DesktopWireProjection(threadID: thread)
        func send(_ change: [String: Any], at seconds: Double) throws {
            let document = try JSONFieldView.document(JSONSerialization.data(withJSONObject: change))
            for event in try wire.consume(document, owner: "test-owner", at: start.addingTimeInterval(seconds)) {
                value.applyRuntime(event)
                XCTAssertNil(event["arguments"])
                XCTAssertNil(event["result"])
            }
        }
        let item: [String: Any] = ["id": "report-1", "type": "mcpToolCall", "server": "pacer_progress",
            "tool": "report_progress", "status": "inProgress", "arguments": ["percent": 41]]
        try send(["type": "snapshot", "revision": 1, "conversationState": [
            "turns": [["turnId": "turn-1", "status": "inProgress", "turnStartedAtMs": start.timeIntervalSince1970 * 1000, "items": [item]]]
        ]], at: 0)
        XCTAssertNil(value.currentProgress)
        XCTAssertNil(value.toolWaitStartedAt)
        try send(["type": "patches", "baseRevision": 1, "revision": 2,
                  "patches": [["op": "replace", "path": ["turns", 0, "items", 0, "status"], "value": "completed"]]], at: 1)
        XCTAssertNil(value.currentProgress)
        try send(["type": "patches", "baseRevision": 2, "revision": 3,
                  "patches": [["op": "add", "path": ["turns", 0, "items", 0, "result"],
                               "value": ["content": [["type": "text", "text": "pacer-progress:accepted"]]]]]], at: 2)
        XCTAssertEqual(value.currentProgress?.percent, 41)
        XCTAssertEqual(value.phase, .running)
    }

    func testLiveAttemptEndingDoesNotFillRingWhenLogAlreadyBoundAGoal() {
        var logged = activity(), live = activity()
        let created = start.timeIntervalSince1970
        log(&logged, "task_started", at: 0, fields: ["turn_id": "turn-1"])
        log(&logged, "thread_goal_updated", at: 1, fields: ["threadId": thread, "turnId": "turn-1",
            "goal": ["status": "active", "createdAt": created, "updatedAt": created + 1]])
        log(&logged, "item_completed", at: 2, fields: ["thread_id": thread, "turn_id": "turn-1", "item": report(41)])
        runtime(&live, "turn/started", at: 0)
        runtime(&live, "turn/completed", at: 3, fields: ["status": "completed"])
        let merged = ActivitySourceMerger.merge(logged: [logged], streamed: [live]).first
        XCTAssertEqual(merged?.phase, .running)
        XCTAssertEqual(merged.flatMap { ring($0, at: 4) }?.mode, .waiting)
        XCTAssertEqual(merged?.currentProgress?.percent, 41)
    }

    func testOwnedTerminalEventWithoutKnownStatusStillEndsTheTurn() {
        for fields in [[:], ["status": "future-terminal-status"]] {
            var value = activity()
            runtime(&value, "turn/started", at: 0)
            runtime(&value, "turn/completed", at: 1, turn: "unrelated", fields: fields)
            XCTAssertEqual(value.phase, .running)
            runtime(&value, "turn/completed", at: 2, fields: fields)
            XCTAssertEqual(value.phase, .completed)
            XCTAssertFalse(value.turnFailed)
            XCTAssertEqual(ring(value, at: 2)?.mode, .done)
        }
    }

    func testHeldGoalLeavesTheListAtItsDeadlineAndLateContinuationStartsFresh() {
        for status in ["active", "paused"] {
            var value = activity()
            runtime(&value, "turn/started", at: 0, fields: ["rootTurnId": "turn-1"])
            runtime(&value, "progress/reported", at: 1, fields: ["percent": 41])
            let goal: [String: Any] = ["goalStatus": status, "goalCreatedAt": start.timeIntervalSince1970,
                                       "goalUpdatedAt": start.timeIntervalSince1970 + 2]
            runtime(&value, "thread/goal/updated", at: 2, fields: goal)
            runtime(&value, "turn/completed", at: 3)
            runtime(&value, "thread/goal/updated", at: 900, fields: goal)
            let before = start.addingTimeInterval(902), deadline = start.addingTimeInterval(903)
            var application = ActivityApplicationState(inbox: .init(dismissalStore: nil))
            application.remoteActivities = [value]
            application.reconcile(at: before, retention: 1800, visibility: .init())
            XCTAssertEqual(application.presentation(at: before).rows.count, 1)
            XCTAssertEqual(application.taskGroups().first?.isRunning, status == "active")
            XCTAssertEqual(application.nextDisplayDeadline(at: before, retention: 1800), deadline)
            application.prune(at: deadline, retention: 1800)
            XCTAssertTrue(application.presentation(at: deadline).rows.isEmpty)
            let replay = application.reconcile(at: deadline, retention: 1800, visibility: .init())
            XCTAssertTrue(replay.activities.isEmpty)
            XCTAssertTrue(replay.notices.isEmpty)
            XCTAssertTrue(application.inbox.activities.isEmpty)
            runtime(&value, "turn/started", at: 904, turn: "turn-2", fields: ["rootTurnId": "turn-1"])
            XCTAssertNil(value.currentProgress)
            XCTAssertNil(value.codexGoalDeadline)
        }
    }

    func testCachedMCPConnectionStopsReportingWhenDisabled() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let flag = CodexProgressSetup.flag(home)
        try FileManager.default.createDirectory(at: flag.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try CodexProgressSetup.on.write(to: flag)
        var reporter = CodexProgressReporter(home: home)
        func report(_ percent: String) throws -> [String: Any] {
            let request = """
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"report_progress","arguments":{"percent":\(percent)}}}
            """
            let frame = try XCTUnwrap(reporter.receive(Data((request + "\n").utf8)).first)
            let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: frame) as? [String: Any])
            return try XCTUnwrap(reply["result"] as? [String: Any])
        }
        XCTAssertEqual(try report("41")["isError"] as? Bool, false)
        XCTAssertEqual(try report("true")["isError"] as? Bool, true)
        XCTAssertEqual(try report("101")["isError"] as? Bool, true)
        try FileManager.default.removeItem(at: flag)
        XCTAssertEqual(try report("63")["isError"] as? Bool, true)
    }
}
