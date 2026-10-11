import XCTest
@testable import PacerCore

final class ResponsePerformanceTests: XCTestCase {
    private let thread = "019a0000-0000-7000-8000-000000000001"
    private let start = Date(timeIntervalSince1970: 1000)
    private func consume(_ meter: inout ResponsePerformanceMeter, output: Int = 600, id: String = "response-1", at seconds: Double = 10) {
        meter.observeRequest(id: id, turn: "turn", output: output, reasoning: 200, at: start.addingTimeInterval(seconds))
    }
    func testFirstRequestIsSettledWithoutTwoCountersAndDuplicatesCannotChangeIt() {
        var meter = ResponsePerformanceMeter()
        meter.start(turnID: "turn", at: start, observed: true)
        meter.modelOutput(at: start.addingTimeInterval(2), textDelta: true)
        meter.modelOutput(at: start.addingTimeInterval(10), textDelta: false)
        consume(&meter)
        XCTAssertEqual(meter.latest?.tokensPerSecond, 60)
        XCTAssertEqual(meter.latest?.reasoningTokens, 200)
        XCTAssertEqual(meter.firstTokenLatency, 2)
        consume(&meter, output: 900, at: 11)
        XCTAssertEqual(meter.latest?.outputTokens, 600)
    }
    func testToolWaitAndSparseReportsDoNotContaminateResponseDuration() {
        var meter = ResponsePerformanceMeter()
        meter.start(turnID: "turn", at: start, observed: true)
        meter.modelOutput(at: start.addingTimeInterval(5), textDelta: true)
        consume(&meter, at: 5)
        meter.setWaiting(true, at: start.addingTimeInterval(5))
        meter.setWaiting(false, at: start.addingTimeInterval(305))
        meter.modelOutput(at: start.addingTimeInterval(315), textDelta: true)
        consume(&meter, id: "response-2", at: 315)
        XCTAssertEqual(meter.latest?.duration, 10)
        XCTAssertEqual(meter.latest?.tokensPerSecond, 60)
        XCTAssertEqual(meter.firstTokenLatency, 5, "TTFT belongs to the turn's first observed output")
        var legacy = GenerationRate(); legacy.start()
        legacy.observe(total: 100, at: start)
        legacy.setWaiting(true, at: start.addingTimeInterval(1))
        legacy.setWaiting(false, at: start.addingTimeInterval(301))
        legacy.observe(total: 200, at: start.addingTimeInterval(310))
        XCTAssertEqual(legacy.estimate(at: start.addingTimeInterval(310))?.value, 10)
    }
    func testAttachmentMissingTimingAndWrongTurnNeverInventPerformance() {
        var meter = ResponsePerformanceMeter()
        meter.start(turnID: "turn", at: start, observed: false)
        meter.modelOutput(at: start.addingTimeInterval(2), textDelta: true)
        consume(&meter)
        XCTAssertNil(meter.latest); XCTAssertNil(meter.firstTokenLatency)
        meter.inputBoundary(at: start.addingTimeInterval(10))
        meter.modelOutput(at: start.addingTimeInterval(20), textDelta: true)
        meter.observeRequest(id: "wrong", turn: "older", output: 600, reasoning: 200, at: start.addingTimeInterval(20))
        XCTAssertNil(meter.latest)
        consume(&meter, at: 20)
        XCTAssertEqual(meter.latest?.tokensPerSecond, 60); XCTAssertNil(meter.firstTokenLatency)
    }
    func testMetadataCompletionAndCounterReplayKeepLifecycleIndependent() throws {
        var activity = SessionActivity(id: thread, phaseAwareRate: true)
        func log(_ type: String, _ seconds: Double, _ payload: [String: Any]) throws -> Data {
            let stamp = ISO8601DateFormatter().string(from: start.addingTimeInterval(seconds))
            return try JSONSerialization.data(withJSONObject: ["timestamp": stamp, "type": type, "payload": payload])
        }
        activity.consume(try log("event_msg", 0, ["type": "task_started", "turn_id": "turn"]))
        activity.consume(try log("response_item", 10, ["type": "message", "role": "assistant", "PRIVATE": "not stored"]))
        let record: [String: Any] = ["thread_id": thread, "turn_id": "turn", "response_id": "response",
            "usage": ["output_tokens": 600, "reasoning_output_tokens": 200]]
        activity.consume(try log("token_usage_record", 10, record))
        activity.consume(try log("event_msg", 11, ["type": "task_complete", "turn_id": "turn"]))
        let ending = activity.phaseChangedAt
        activity.consume(try log("token_usage_record", 12, record))
        XCTAssertEqual(activity.responsePerformance?.tokensPerSecond, 60)
        XCTAssertEqual(activity.phase, .completed); XCTAssertEqual(activity.phaseChangedAt, ending)
        XCTAssertNil(activity.firstTokenLatency, "Log item-completion timestamps are not first-token observations")
        var inbox = CompletionInbox(); inbox.observe([activity], at: start.addingTimeInterval(12), retention: 30)
        inbox.dismiss(activity)
        inbox.observe([activity], at: start.addingTimeInterval(13), retention: 30)
        XCTAssertTrue(inbox.activities.isEmpty)
    }
    func testRuntimeUsageRequiresGeneratedEvidenceAndCachedSnapshotsAreNotNewRequests() {
        var meter = ResponsePerformanceMeter(); meter.start(turnID: "turn", at: start, observed: true)
        meter.observeRuntime(total: 1000, last: 600, reasoning: nil, at: start, cached: true)
        XCTAssertNil(meter.latest)
        meter.modelOutput(at: start.addingTimeInterval(10), textDelta: true)
        meter.observeRuntime(total: 1600, last: 600, reasoning: nil, at: start.addingTimeInterval(10.1))
        XCTAssertEqual(meter.latest?.tokensPerSecond, 60)
        meter.observeRuntime(total: 1600, last: 600, reasoning: nil, at: start.addingTimeInterval(20))
        XCTAssertEqual(meter.latest?.completedAt, start.addingTimeInterval(10))
    }
    func testNativeFirstNonemptyOutputAndFinalUsageAreObservedBeforeCompletion() throws {
        var projection = DesktopWireProjection(threadID: thread)
        var activity = SessionActivity(id: thread, phaseAwareRate: true)
        func receive(_ value: [String: Any], _ seconds: Double) throws -> [[String: Any]] {
            let view = try JSONFieldView.document(JSONSerialization.data(withJSONObject: value))
            let events = try projection.consume(view, owner: "owner", at: start.addingTimeInterval(seconds))
            for event in events { activity.consumeLive(event) }
            return events
        }
        _ = try receive(["type": "snapshot", "revision": 0, "conversationState": ["turns": [], "latestTokenUsageInfo": ["total": ["outputTokens": 1000]]]], 0)
        _ = try receive(["type": "patches", "baseRevision": 0, "revision": 1, "patches": [["op": "add", "path": ["turns", 0],
            "value": ["turnId": "turn", "status": "inProgress", "items": [["id": "answer", "type": "agentMessage", "status": "inProgress", "text": ""]]]]]], 0)
        _ = try receive(["type": "patches", "baseRevision": 1, "revision": 2, "patches": [["op": "replace", "path": ["turns", 0, "items", 0, "text"], "value": ""]]], 1)
        XCTAssertNil(activity.firstTokenLatency); XCTAssertNil(activity.responsePerformance)
        let first = try receive(["type": "patches", "baseRevision": 2, "revision": 3, "patches": [["op": "replace", "path": ["turns", 0, "items", 0, "text"], "value": "PRIVATE TEXT"]]], 2)
        XCTAssertEqual(activity.firstTokenLatency, 2)
        XCTAssertTrue(first.contains { $0["firstTextDelta"] as? Bool == true })
        XCTAssertFalse(String(describing: first).contains("PRIVATE TEXT"))
        let final = try receive(["type": "patches", "baseRevision": 3, "revision": 4, "patches": [
            ["op": "replace", "path": ["turns", 0, "items", 0, "status"], "value": "completed"],
            ["op": "replace", "path": ["latestTokenUsageInfo"], "value": ["total": ["outputTokens": 1600], "last": ["outputTokens": 600, "reasoningOutputTokens": 200]]],
            ["op": "replace", "path": ["turns", 0, "status"], "value": "completed"]]], 10)
        XCTAssertEqual(activity.responsePerformance?.tokensPerSecond, 60)
        XCTAssertEqual(activity.responsePerformance?.reasoningTokens, 200)
        XCTAssertEqual(activity.phase, .completed)
        let count = try XCTUnwrap(final.firstIndex { $0["method"] as? String == "thread/tokenUsage/updated" })
        let end = try XCTUnwrap(final.firstIndex { $0["method"] as? String == "turn/completed" })
        XCTAssertLessThan(count, end)
        // Historical hydration can supply stage, never first-token latency.
        var attached = SessionActivity(id: thread, phaseAwareRate: true)
        attached.consumeLive(["method": "turn/attached", "threadId": thread, "turnId": "turn", "at": 1000.0])
        attached.consumeLive(["method": "item/agentMessage/delta", "threadId": thread, "turnId": "turn", "at": 1002.0, "hasText": true])
        XCTAssertNil(attached.firstTokenLatency)
    }
    func testExactAccountingAfterReleaseUpdatesOnlyMatchingRetainedTurn() throws {
        var stream = RuntimeEventState(sourceID: "remote-ssh-discovered:test", sourceName: "SSH")
        stream.consume(["kind": "status", "connected": true])
        func live(_ method: String, _ seconds: Double, _ fields: [String: Any] = [:]) {
            var event: [String: Any] = ["method": method, "threadId": thread, "turnId": "turn", "at": start.addingTimeInterval(seconds).timeIntervalSince1970]
            event.merge(fields) { _, new in new }; stream.consume(["kind": "runtime", "event": event])
        }
        live("turn/started", 0); live("item/agentMessage/delta", 2, ["hasText": true]); live("turn/completed", 11, ["status": "completed"])
        var inbox = CompletionInbox(); inbox.observe(stream.activities, at: start.addingTimeInterval(11), retention: 30)
        let before = try XCTUnwrap(inbox.activities.first)
        live("stream/released", 11); stream.releasePublishedState()
        func record(_ type: String, _ seconds: Double, _ payload: [String: Any]) -> [String: Any] {
            ["type": type, "timestamp": ISO8601DateFormatter().string(from: start.addingTimeInterval(seconds)), "payload": payload]
        }
        let records = [record("event_msg", 0, ["type": "task_started", "turn_id": "turn"]),
            record("response_item", 10, ["type": "message", "role": "assistant"]),
            record("event_msg", 11, ["type": "task_complete", "turn_id": "turn"]),
            record("token_usage_record", 12, ["thread_id": thread, "turn_id": "turn", "response_id": "r", "usage": ["output_tokens": 600]])]
        stream.consume(["kind": "performance", "sessions": [["threadId": thread, "reset": true, "records": records]]])
        XCTAssertTrue(stream.activities.isEmpty, "Accounting cannot recreate a released task")
        inbox.updatePerformance(stream.performanceUpdates)
        let updated = try XCTUnwrap(inbox.activities.first)
        XCTAssertEqual(updated.responsePerformance?.tokensPerSecond, 60)
        XCTAssertEqual(updated.firstTokenLatency, 2); XCTAssertEqual(updated.phaseChangedAt, before.phaseChangedAt)
        XCTAssertTrue(inbox.isUnread(updated))
        var local = SessionActivity(id: thread, phaseAwareRate: true)
        for var row in records {
            if row["type"] as? String == "token_usage_record", var payload = row["payload"] as? [String: Any] {
                payload["usage"] = ["output_tokens": 3000]; row["payload"] = payload
            }
            local.consume(try JSONSerialization.data(withJSONObject: row))
        }
        XCTAssertEqual(local.responsePerformance?.outputTokens, 3000)
        inbox.updatePerformance([try XCTUnwrap(SessionPerformanceUpdate(local))])
        XCTAssertEqual(inbox.activities.first?.responsePerformance?.tokensPerSecond, 60)
        inbox.dismiss(updated); inbox.updatePerformance(stream.performanceUpdates); XCTAssertTrue(inbox.activities.isEmpty)
        inbox.observe([before], at: start.addingTimeInterval(42), retention: 30); inbox.updatePerformance(stream.performanceUpdates)
        XCTAssertTrue(inbox.activities.isEmpty, "Accounting cannot extend expiry")
    }
    func testGlobalTPSAddsRequestRatesAndKeepsFreshnessAndParticipationBoundaries() {
        func task(_ id: String, tokens: Int, duration: Double) -> SessionActivity {
            var value = SessionActivity(id: id, phaseAwareRate: true)
            let began = start.addingTimeInterval(10-duration)
            for event in [["method": "turn/started", "at": began.timeIntervalSince1970],
                          ["method": "item/agentMessage/delta", "at": start.addingTimeInterval(10).timeIntervalSince1970, "hasText": true],
                          ["method": "thread/tokenUsage/updated", "at": start.addingTimeInterval(10).timeIntervalSince1970, "outputTokens": tokens, "lastOutputTokens": tokens]] as [[String: Any]] {
                var event = event; event["threadId"] = id; event["turnId"] = "turn"; value.consumeLive(event)
            }
            return value.canonicalized()
        }
        let tasks = [task(thread, tokens: 600, duration: 10), task("019a0000-0000-7000-8000-000000000002", tokens: 600, duration: 20)]
        let large = ActivityOverview(activities: [task(thread, tokens: Int.max, duration: 10),
            task("019a0000-0000-7000-8000-000000000002", tokens: Int.max, duration: 20)], at: start.addingTimeInterval(10))
        XCTAssertTrue(large.displayedRate?.isFinite == true, "Large numeric metadata cannot overflow the cross-task sum")
        let overview = ActivityOverview(activities: tasks, at: start.addingTimeInterval(10))
        XCTAssertEqual(overview.displayedRate, 90); XCTAssertEqual(overview.tokensPerSecond, 90); XCTAssertTrue(overview.rateIsFresh)
        let older = ActivityOverview(activities: tasks, at: start.addingTimeInterval(30))
        XCTAssertEqual(older.displayedRate, 90); XCTAssertFalse(older.rateIsFresh); XCTAssertNil(older.tokensPerSecond)

        func live(_ activity: inout SessionActivity, method: String, fields: [String: Any]) {
            var data: [String: Any] = ["method": method, "threadId": activity.threadID!, "turnId": "turn", "at": start.addingTimeInterval(11).timeIntervalSince1970]
            data.merge(fields) { _, new in new }; activity.consumeLive(data)
        }
        var blocked = tasks[1]
        live(&blocked, method: "item/started", fields: ["itemId": "tool", "itemType": "commandExecution"])
        XCTAssertEqual(blocked.responsePerformance?.tokensPerSecond, 30, "Task row retains its last request")
        XCTAssertEqual(ActivityOverview(activities: [tasks[0], blocked], at: start.addingTimeInterval(11)).displayedRate, 90, "Tool waits retain the last measured rate in the displayed total")
        for (method, fields) in [("thread/status/changed", ["status": "active", "flags": ["waitingOnUserInput"]]),
                                 ("turn/completed", ["status": "completed"]),
                                 ("metadata", ["source": "guardian_review"])] as [(String, [String: Any])] {
            var excluded = tasks[1]; live(&excluded, method: method, fields: fields)
            XCTAssertEqual(ActivityOverview(activities: [tasks[0], excluded], at: start.addingTimeInterval(11)).displayedRate, 60, method)
        }
        var unmeasured = SessionActivity(id: "019a0000-0000-7000-8000-000000000003", phaseAwareRate: true)
        live(&unmeasured, method: "turn/started", fields: [:])
        let partial = ActivityOverview(activities: [tasks[0], unmeasured], at: start.addingTimeInterval(11))
        XCTAssertEqual(partial.displayedRate, 60); XCTAssertTrue(partial.rateIsFresh)
        var legacy = SessionActivity(id: "019a0000-0000-7000-8000-000000000004", phaseAwareRate: true)
        for (method, seconds, fields) in [("turn/started", 0.0, [:]),
            ("thread/tokenUsage/updated", 0.0, ["outputTokens": 0]),
            ("thread/tokenUsage/updated", 2.0, ["outputTokens": 100])] as [(String, Double, [String: Any])] {
            var data: [String: Any] = ["method": method, "threadId": legacy.threadID!, "turnId": "turn", "at": start.addingTimeInterval(seconds).timeIntervalSince1970]
            data.merge(fields) { _, new in new }; legacy.consumeLive(data)
        }
        let mixed = ActivityOverview(activities: [tasks[0], legacy], at: start.addingTimeInterval(10))
        XCTAssertEqual(mixed.displayedRate, 110, "Legacy estimates also contribute alongside settled request rates")
        XCTAssertTrue(mixed.rateIsFresh)
    }
    func testRuntimeEstimateCanUpgradeToExactRecordAndInvalidWindowsAreRejected() {
        var meter = ResponsePerformanceMeter(); meter.start(turnID: "turn", at: start, observed: true)
        meter.modelOutput(at: start.addingTimeInterval(10), textDelta: true)
        meter.observeRuntime(total: 600, last: 600, reasoning: nil, at: start.addingTimeInterval(10))
        consume(&meter, at: 11)
        XCTAssertEqual(meter.latest?.source, .requestUsage); XCTAssertEqual(meter.latest?.responseID, "response-1")
        meter.modelOutput(at: start.addingTimeInterval(20), textDelta: true)
        meter.observeRuntime(total: 1200, last: 600, reasoning: nil, at: start.addingTimeInterval(20))
        XCTAssertEqual(meter.latest?.responseID, "response-1", "Modern request records take precedence over replayed cumulative counters")
        for duration in [-1.0, 0, .infinity, 3601] {
            XCTAssertNil(ResponsePerformance(responseID: "r", turnID: "turn", outputTokens: 600,
                startedAt: start, completedAt: start.addingTimeInterval(duration), source: .requestUsage))
        }
        XCTAssertNil(ResponsePerformance(responseID: "r", turnID: "turn", outputTokens: 600, reasoningTokens: 601,
            startedAt: start, completedAt: start.addingTimeInterval(10), source: .requestUsage))
    }

    func testSameTurnReconnectRetainsKnownMetricsWithoutInventingNewTiming() {
        var value = SessionActivity(id: thread, phaseAwareRate: true)
        func event(_ method: String, _ seconds: Double, turn: String = "turn", _ fields: [String: Any] = [:]) {
            var data: [String: Any] = ["threadId": thread, "turnId": turn, "method": method, "at": start.addingTimeInterval(seconds).timeIntervalSince1970]
            data.merge(fields) { _, new in new }; value.consumeLive(data)
        }
        event("turn/started", 0); event("item/agentMessage/delta", 2, ["hasText": true])
        event("item/completed", 10, ["itemId": "answer", "itemType": "agentMessage"])
        event("thread/tokenUsage/updated", 10, ["outputTokens": 600, "lastOutputTokens": 600])
        event("turn/attached", 12)
        XCTAssertEqual(value.firstTokenLatency, 2); XCTAssertEqual(value.turnStartedAt, start)
        XCTAssertEqual(value.responsePerformance?.tokensPerSecond, 60)
        event("item/agentMessage/delta", 14, ["hasText": true])
        event("thread/tokenUsage/updated", 15, ["outputTokens": 1200, "lastOutputTokens": 600])
        XCTAssertEqual(value.responsePerformance?.completedAt, start.addingTimeInterval(10), "Reconnection cannot measure a partial request")
        event("turn/started", 20, turn: "next")
        XCTAssertNil(value.firstTokenLatency); XCTAssertNil(value.responsePerformance)
    }

}
