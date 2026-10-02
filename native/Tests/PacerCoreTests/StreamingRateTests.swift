import XCTest
@testable import PacerCore

final class StreamingRateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let thread = "019a0000-0000-7000-8000-000000000001"
    private func log(_ a: inout SessionActivity, _ kind: String, seconds: Double, fields: [String: Any] = [:], outer: String = "event_msg") {
        var p = fields; p["type"] = kind
        let value: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: start.addingTimeInterval(seconds)), "type": outer, "payload": p]
        a.consume(try! JSONSerialization.data(withJSONObject: value))
    }
    private func live(_ a: inout SessionActivity, _ method: String, seconds: Double, turn: String = "turn", fields: [String: Any] = [:]) {
        var e = fields; e["method"] = method; e["threadId"] = thread; e["turnId"] = turn; e["at"] = start.addingTimeInterval(seconds).timeIntervalSince1970
        a.consumeLive(e)
    }
    func testBlockingToolTimeIsRemovedAndDoesNotDisplayOldSpeed() {
        var a = SessionActivity(id: thread, phaseAwareRate: true)
        log(&a, "task_started", seconds: 0, fields: ["turn_id": "turn"])
        log(&a, "token_count", seconds: 0, fields: ["info": ["total_token_usage": ["output_tokens": 100]]])
        log(&a, "function_call", seconds: 5, fields: ["call_id": "tool", "name": "calculate"], outer: "response_item")
        XCTAssertEqual(a.outputEstimate(at: start.addingTimeInterval(10))?.value, 0)
        XCTAssertEqual(a.phase, .running)
        log(&a, "function_call_output", seconds: 20, fields: ["call_id": "tool"], outer: "response_item")
        log(&a, "token_count", seconds: 20, fields: ["info": ["total_token_usage": ["output_tokens": 400]]])
        XCTAssertEqual(a.outputEstimate(at: start.addingTimeInterval(20))?.value, 60)
    }
    func testOverlappingToolsSubtractUnionRatherThanBothDurations() {
        var a = SessionActivity(id: thread, phaseAwareRate: true)
        log(&a, "task_started", seconds: 0, fields: ["turn_id": "turn"])
        log(&a, "token_count", seconds: 0, fields: ["info": ["total_token_usage": ["output_tokens": 0]]])
        for (seconds, id) in [(5.0, "one"), (6.0, "two")] {
            log(&a, "function_call", seconds: seconds, fields: ["call_id": id], outer: "response_item")
        }
        log(&a, "function_call_output", seconds: 18, fields: ["call_id": "one"], outer: "response_item")
        XCTAssertEqual(a.outputEstimate(at: start.addingTimeInterval(19))?.value, 0)
        log(&a, "function_call_output", seconds: 20, fields: ["call_id": "two"], outer: "response_item")
        log(&a, "token_count", seconds: 20, fields: ["info": ["total_token_usage": ["output_tokens": 300]]])
        XCTAssertEqual(a.outputEstimate(at: start.addingTimeInterval(20))?.value, 60)
    }
    func testModelEvidenceWhileBackgroundToolRunsCountsGeneration() {
        var a = SessionActivity(id: thread, phaseAwareRate: true)
        log(&a, "task_started", seconds: 0, fields: ["turn_id": "turn"])
        log(&a, "token_count", seconds: 0, fields: ["info": ["total_token_usage": ["output_tokens": 0]]])
        log(&a, "function_call", seconds: 5, fields: ["call_id": "background"], outer: "response_item")
        log(&a, "reasoning", seconds: 10, outer: "response_item")
        log(&a, "function_call_output", seconds: 20, fields: ["call_id": "background"], outer: "response_item")
        log(&a, "token_count", seconds: 20, fields: ["info": ["total_token_usage": ["output_tokens": 300]]])
        XCTAssertEqual(a.outputEstimate(at: start.addingTimeInterval(20))?.value, 20)
    }
    func testMidRequestAttachSeedsCounterWithoutInventingFirstRate() {
        var a = SessionActivity(id: thread, phaseAwareRate: true)
        live(&a, "item/agentMessage/delta", seconds: 1)
        live(&a, "thread/tokenUsage/updated", seconds: 2, fields: ["outputTokens": 1000, "lastOutputTokens": 800])
        XCTAssertNil(a.outputEstimate(at: start.addingTimeInterval(2)))
        live(&a, "thread/tokenUsage/updated", seconds: 4, fields: ["outputTokens": 1060, "lastOutputTokens": 60])
        XCTAssertEqual(a.outputEstimate(at: start.addingTimeInterval(4))?.value, 30)
    }
    func testStreamStartUsageAndBlockingStateUseAuthoritativeCounts() {
        var a = SessionActivity(id: thread, phaseAwareRate: true)
        live(&a, "turn/started", seconds: 0)
        live(&a, "item/started", seconds: 5, fields: ["itemId": "tool", "itemType": "commandExecution"])
        XCTAssertEqual(a.outputEstimate(at: start.addingTimeInterval(12))?.value, 0)
        live(&a, "item/completed", seconds: 20, fields: ["itemId": "tool", "itemType": "commandExecution"])
        live(&a, "thread/tokenUsage/updated", seconds: 20, fields: ["outputTokens": 900, "lastOutputTokens": 300])
        XCTAssertEqual(a.outputEstimate(at: start.addingTimeInterval(20))?.value, 60)
        live(&a, "turn/completed", seconds: 21, fields: ["status": "completed"])
        live(&a, "thread/tokenUsage/updated", seconds: 22, fields: ["outputTokens": 910])
        XCTAssertEqual(a.phase, .completed)
        XCTAssertNil(a.outputEstimate(at: start.addingTimeInterval(22)))
    }
    func testIdleStatusAndOrphanTerminalDoNotDeclareTaskFinished() {
        var a = SessionActivity(id: thread, phaseAwareRate: true)
        live(&a, "turn/completed", seconds: 0, fields: ["status": "completed"])
        XCTAssertEqual(a.phase, .unknown)
        live(&a, "turn/started", seconds: 1)
        live(&a, "thread/status/changed", seconds: 2, fields: ["status": "idle"])
        XCTAssertEqual(a.phase, .running)
        live(&a, "turn/completed", seconds: 3, turn: "other", fields: ["status": "completed"])
        XCTAssertEqual(a.phase, .running)
    }
    func testUnrelatedThreadUnknownEventsAndReviewsCannotChangeUserState() {
        var a = SessionActivity(id: thread, phaseAwareRate: true)
        live(&a, "unknown/event", seconds: 0)
        XCTAssertEqual(a.phase, .unknown)
        a.consumeLive(["method": "turn/started", "threadId": UUID().uuidString.lowercased(), "turnId": "other", "at": start.timeIntervalSince1970])
        XCTAssertEqual(a.phase, .unknown)
        a.consumeLive(["method": "metadata", "threadId": thread, "source": "guardian_review", "at": start.timeIntervalSince1970])
        live(&a, "turn/started", seconds: 1)
        XCTAssertTrue(ActivitySourceMerger.merge(logged: [], streamed: [a]).isEmpty)
    }
    func testLiveAndLogCopiesDeduplicateAndNewerLoggedTurnWins() {
        var logged = SessionActivity(id: "rollout-" + thread + ".jsonl", phaseAwareRate: true)
        var streamed = SessionActivity(id: thread, phaseAwareRate: true)
        log(&logged, "task_started", seconds: 0, fields: ["turn_id": "turn"])
        live(&streamed, "turn/started", seconds: 1)
        XCTAssertEqual(ActivitySourceMerger.merge(logged: [logged], streamed: [streamed]).count, 1)
        log(&logged, "task_started", seconds: 10, fields: ["turn_id": "newer"])
        let merged = ActivitySourceMerger.merge(logged: [logged], streamed: [streamed])
        XCTAssertEqual(merged.first?.turnID, "newer")
        live(&streamed, "item/agentMessage/delta", seconds: 11, turn: "old-but-attached-late")
        XCTAssertEqual(ActivitySourceMerger.merge(logged: [logged], streamed: [streamed]).first?.turnID, "newer")
    }
    func testSameThreadIdOnDifferentHostsRemainsTwoTasks() {
        var local = SessionActivity(id: thread, phaseAwareRate: true)
        var remote = SessionActivity(id: thread, sourceHost: "gpu", sourceHostID: "remote-ssh-discovered:gpu", phaseAwareRate: true)
        log(&local, "task_started", seconds: 0, fields: ["turn_id": "local"])
        log(&remote, "task_started", seconds: 0, fields: ["turn_id": "ssh"])
        let combined = ActivitySourceMerger.merge(logged: [local], streamed: [remote])
        XCTAssertEqual(combined.count, 2)
        XCTAssertEqual(ActivityOverview(activities: combined, at: start).running.count, 2)
    }
    func testSocketWithoutItemEvidenceDoesNotMaskFallbackAndDisconnectKeepsLogs() {
        var state = RuntimeEventState(sourceID: nil, sourceName: nil)
        var logged = SessionActivity(id: thread)
        log(&logged, "task_started", seconds: 0, fields: ["turn_id": "logged"])
        state.replaceLocalFallback([logged])
        state.consume(["kind": "status", "connected": true])
        state.consume(["kind": "runtime", "event": ["method": "metadata", "threadId": thread, "at": start.timeIntervalSince1970, "name": "test"]])
        XCTAssertEqual(state.activities.first?.turnID, "logged")
        state.consume(["kind": "status", "connected": false])
        XCTAssertEqual(state.activities.first?.phase, .running)
    }
    func testTransportDisconnectDoesNotEraseVerifiedTurnCompletion() {
        var state = RuntimeEventState(sourceID: nil, sourceName: nil)
        state.consume(["kind": "status", "connected": true])
        for (method, seconds) in [("turn/started", 0.0), ("turn/completed", 1.0)] {
            state.consume(["kind": "runtime", "event": ["method": method, "threadId": thread, "turnId": "turn",
                "at": start.addingTimeInterval(seconds).timeIntervalSince1970, "status": "completed"]])
        }
        state.consume(["kind": "status", "connected": false])
        XCTAssertEqual(state.activities.first?.phase, .completed)
    }
    func testBlockedAndUnmeasuredGeneratingTasksDoNotDisplayFalseGlobalZero() {
        var blocked = SessionActivity(id: thread, phaseAwareRate: true)
        var unmeasured = SessionActivity(id: "other", phaseAwareRate: true)
        live(&blocked, "turn/started", seconds: 0)
        live(&blocked, "item/started", seconds: 1, fields: ["itemId": "tool", "itemType": "commandExecution"])
        log(&unmeasured, "task_started", seconds: 0, fields: ["turn_id": "other"])
        let overview = ActivityOverview(activities: [blocked, unmeasured], at: start.addingTimeInterval(2))
        XCTAssertEqual(overview.running.count, 2)
        XCTAssertNil(overview.displayedRate)
        XCTAssertEqual(ActivityOverview(activities: [blocked], at: start.addingTimeInterval(2)).displayedRate, 0)
    }
}
