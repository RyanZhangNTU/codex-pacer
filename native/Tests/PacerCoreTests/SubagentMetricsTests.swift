import XCTest
@testable import PacerCore

final class SubagentMetricsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func id(_ n: Int) -> String { String(format: "019a0000-0000-7000-8000-%012d", n) }
    private func live(_ activity: inout SessionActivity, _ method: String, _ second: Double, _ fields: [String: Any] = [:], turn: String = "turn") {
        var e: [String: Any] = ["method": method, "threadId": activity.threadID!, "turnId": turn, "at": start.addingTimeInterval(second).timeIntervalSince1970]
        e.merge(fields) { _, new in new }; activity.consumeLive(e)
    }
    private func measured(_ n: Int, parent: Int? = nil, host: String? = nil, tokens: Int = 600) -> SessionActivity {
        var a = SessionActivity(id: (host ?? "local") + ":" + id(n), sourceHostID: host, phaseAwareRate: true)
        if let parent { live(&a, "metadata", 0, ["parentThreadId": id(parent)]) }
        live(&a, "turn/started", 0)
        live(&a, "item/agentMessage/delta", 10, ["hasText": true])
        live(&a, "thread/tokenUsage/updated", 10, ["outputTokens": tokens, "lastOutputTokens": tokens])
        return a
    }
    func testNestedAgentsGroupOnceAndToolWaitRetainsTheirSum() throws {
        var parent = measured(1), child = measured(2, parent: 1, tokens: 300)
        let grandchild = measured(3, parent: 2, tokens: 200)
        live(&parent, "item/started", 11, ["itemId": "wait", "itemType": "collabToolCall"])
        let all = [parent, child, grandchild, child]
        let groups = ActivityTaskGroup.make(all)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.runningSubagentCount, 2)
        XCTAssertEqual(groups.first?.displayedRate(at: start.addingTimeInterval(11))?.value, 110)
        XCTAssertTrue(try XCTUnwrap(groups.first).rateIsEstimated(at: start.addingTimeInterval(11)))
        let overview = ActivityOverview(activities: all, at: start.addingTimeInterval(11))
        XCTAssertEqual(overview.running.count, 1)
        XCTAssertEqual(overview.displayedRate, 110)
        live(&child, "turn/completed", 12, ["status": "completed"])
        let after = try XCTUnwrap(ActivityTaskGroup.make([parent, child, grandchild]).first)
        XCTAssertEqual(after.runningSubagentCount, 1)
        XCTAssertEqual(after.displayedRate(at: start.addingTimeInterval(12))?.value, 80)
    }
    func testNewTurnRetainsOnlyDisplayAndDoesNotReuseOldAccounting() {
        var a = measured(1)
        live(&a, "turn/completed", 11, ["status": "completed"])
        live(&a, "turn/started", 12, turn: "new")
        XCTAssertNil(a.responsePerformance)
        XCTAssertNil(a.firstTokenLatency)
        XCTAssertNil(a.outputEstimate(at: start.addingTimeInterval(12)))
        XCTAssertEqual(a.displayedOutputEstimate(at: start.addingTimeInterval(12))?.value, 60)
        XCTAssertTrue(a.displayedRateIsEstimated(at: start.addingTimeInterval(12)))
        live(&a, "item/agentMessage/delta", 14, ["hasText": true], turn: "new")
        live(&a, "thread/tokenUsage/updated", 16, ["outputTokens": 800, "lastOutputTokens": 200], turn: "new")
        XCTAssertEqual(a.responsePerformance?.tokensPerSecond, 100)
        XCTAssertEqual(a.firstTokenLatency, 2)
        XCTAssertEqual(a.displayedOutputEstimate(at: start.addingTimeInterval(16))?.value, 100)
        XCTAssertFalse(a.displayedRateIsEstimated(at: start.addingTimeInterval(16)))
    }
    func testMissingChildMeasurementKeepsPartialSumAndHostScopesRemainSeparate() {
        let parent = measured(1)
        var child = SessionActivity(id: id(2), phaseAwareRate: true)
        live(&child, "metadata", 11, ["parentThreadId": id(1)])
        live(&child, "turn/started", 11)
        let partial = ActivityTaskGroup.make([parent, child]).first!
        XCTAssertEqual(partial.displayedRate(at: start.addingTimeInterval(11))?.value, 60)
        XCTAssertTrue(partial.rateIsEstimated(at: start.addingTimeInterval(11)))
        let remote = measured(2, parent: 1, host: "remote-ssh-discovered:fixture")
        let groups = ActivityTaskGroup.make([parent, remote])
        XCTAssertEqual(groups.count, 2, "A remote child cannot join an identically named local parent")
        XCTAssertEqual(ActivityOverview(activities: [parent, remote], at: start.addingTimeInterval(11)).displayedRate, 120)
    }
    func testParentRunningEvidenceMustBeNewerThanTheChildEnding() throws {
        let formatter = ISO8601DateFormatter()
        for ending in ["task_complete", "turn_aborted"] {
            var child = SessionActivity(id: id(2), phaseAwareRate: true)
            for (second, payload) in [(0.0, ["type": "task_started", "turn_id": "child"]),
                                      (20.0, ["type": ending, "turn_id": "child"])] {
                child.consume(try JSONSerialization.data(withJSONObject: ["type": "event_msg",
                    "timestamp": formatter.string(from: start.addingTimeInterval(second)), "payload": payload]))
            }
            // Later bookkeeping must not change the actual ending boundary.
            child.consume(try JSONSerialization.data(withJSONObject: ["type": "event_msg",
                "timestamp": formatter.string(from: start.addingTimeInterval(40)),
                "payload": ["type": "thread_settings_applied", "thread_id": id(2)]]))
            for second in [10.0, 20.0, 21.0] {
                var parent = measured(1)
                live(&parent, "subagents/updated", second, ["states": [id(2): "running"]])
                let group = try XCTUnwrap(ActivityTaskGroup.make([parent, child]).first)
                let projected = try XCTUnwrap(group.members.first { $0.threadID == id(2) })
                XCTAssertEqual(projected.phase, second > 20 ? .running : ending == "task_complete" ? .completed : .interrupted,
                    "An old or equal-time parent hint cannot undo \(ending); a newer activation remains supported")
                XCTAssertEqual(group.runningSubagentCount, second > 20 ? 1 : 0)
                if second <= 20 { XCTAssertEqual(projected.phaseChangedAt, start.addingTimeInterval(20)) }
            }
        }
    }
    func testParentProjectionDoesNotPersistInAnUnchangedLogCursor() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-child-overlay-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let day = DateFormatter(); day.dateFormat = "yyyy/MM/dd"
        let directory = home.appendingPathComponent("sessions/" + day.string(from: start))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-" + id(2) + ".jsonl")
        let formatter = ISO8601DateFormatter()
        var data = Data()
        func append(_ second: Double, _ payload: [String: Any]) throws {
            data.append(try JSONSerialization.data(withJSONObject: ["type": "event_msg",
                "timestamp": formatter.string(from: start.addingTimeInterval(second)), "payload": payload])); data.append(10)
            try data.write(to: file)
        }
        try append(0, ["type": "task_started", "turn_id": "first"])
        try append(20, ["type": "task_complete", "turn_id": "first"])
        var parent = measured(1)
        live(&parent, "subagents/updated", 30, ["states": [id(2): "running"]])
        let reader = LocalActivityReader()
        let projected = await reader.read(home: home, now: start.addingTimeInterval(31), phaseAwareRate: true,
                                          subagentStates: parent.subagentStates)
        XCTAssertEqual(projected.activities.first?.phase, .running, "A new parent activation still shows immediately")
        let restored = await reader.read(home: home, now: start.addingTimeInterval(32), phaseAwareRate: true,
                                         metricsOnly: true, subagentStates: [:])
        XCTAssertEqual(restored.activities.first?.phase, .completed, "Removing a hint must reveal the unchanged log ending")
        XCTAssertEqual(restored.activities.first?.phaseChangedAt, start.addingTimeInterval(20))
        try append(40, ["type": "task_started", "turn_id": "second"])
        let running = await reader.read(home: home, now: start.addingTimeInterval(41), phaseAwareRate: true)
        XCTAssertEqual(running.activities.first?.turnID, "second")
        XCTAssertEqual(running.activities.first?.phase, .running)
        try append(50, ["type": "task_complete", "turn_id": "second"])
        let finished = await reader.read(home: home, now: start.addingTimeInterval(51), phaseAwareRate: true,
                                         subagentStates: parent.subagentStates)
        XCTAssertEqual(finished.activities.first?.phase, .completed, "The earlier hint cannot revive the next ending either")
        XCTAssertEqual(finished.activities.first?.turnID, "second")
    }
    func testExplicitlyClearedChildStatesCannotReturnThroughMetadataMerge() throws {
        var parent = measured(1)
        live(&parent, "subagents/updated", 11, ["states": [id(2): "running"]])
        let earlier = parent
        live(&parent, "subagents/updated", 12, ["states": [String: String]()])
        parent.mergeDisplayMetadata(from: earlier)
        XCTAssertTrue(parent.subagentStates.isEmpty, "An explicit empty map is not missing metadata")
        live(&parent, "subagents/updated", 11, ["states": [id(2): "running"]])
        XCTAssertTrue(parent.subagentStates.isEmpty, "An older map cannot undo a newer clear")
        XCTAssertEqual(ActivityTaskGroup.make([parent]).first?.runningSubagentCount, 0)

        var logged = SessionActivity(id: id(1), phaseAwareRate: true)
        logged.consume(try JSONSerialization.data(withJSONObject: ["type": "event_msg",
            "timestamp": ISO8601DateFormatter().string(from: start), "payload": ["type": "task_started", "turn_id": "turn"]]))
        logged.mergeDisplayMetadata(from: earlier)
        XCTAssertEqual(logged.subagentStates.count, 1, "A log with no parent map can retain known metadata for the same turn")
        var clearedFallback = SessionActivity(id: id(1), phaseAwareRate: true)
        live(&clearedFallback, "turn/started", 0)
        clearedFallback.mergeDisplayMetadata(from: parent)
        clearedFallback.mergeDisplayMetadata(from: earlier)
        XCTAssertTrue(clearedFallback.subagentStates.isEmpty, "The explicit-clear marker must survive source replacement")
    }
    func testParentCompletionSurvivesHintRemovalAndDoesNotHideANewChildTurn() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-child-completion-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let day = DateFormatter(); day.dateFormat = "yyyy/MM/dd"
        let directory = home.appendingPathComponent("sessions/" + day.string(from: start))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-" + id(2) + ".jsonl")
        let formatter = ISO8601DateFormatter()
        var data = Data()
        func append(_ second: Double, turn: String) throws {
            data.append(try JSONSerialization.data(withJSONObject: ["type": "event_msg",
                "timestamp": formatter.string(from: start.addingTimeInterval(second)),
                "payload": ["type": "task_started", "turn_id": turn]])); data.append(10)
            try data.write(to: file)
        }
        try append(0, turn: "first")
        var parent = measured(1)
        live(&parent, "subagents/updated", 20, ["states": [id(2): "completed"]])
        let reader = LocalActivityReader()
        let ended = await reader.read(home: home, now: start.addingTimeInterval(21), phaseAwareRate: true,
                                      subagentStates: parent.subagentStates)
        XCTAssertEqual(ended.activities.first?.phase, .completed)
        let retained = await reader.read(home: home, now: start.addingTimeInterval(22), phaseAwareRate: true,
                                         metricsOnly: true, subagentStates: [:])
        XCTAssertEqual(retained.activities.first?.phase, .completed, "Releasing the parent cannot discard confirmed terminal evidence")
        XCTAssertEqual(retained.activities.first?.phaseChangedAt, start.addingTimeInterval(20))
        try append(30, turn: "second")
        let resumed = await reader.read(home: home, now: start.addingTimeInterval(31), phaseAwareRate: true,
                                        subagentStates: parent.subagentStates)
        XCTAssertEqual(resumed.activities.first?.phase, .running)
        XCTAssertEqual(resumed.activities.first?.turnID, "second")
        XCTAssertEqual(resumed.activities.first?.turnStartedAt, start.addingTimeInterval(30))
    }
    func testLogParentMetadataIsNumericOnlyAndSurvivesSourceMerge() throws {
        var log = measured(2)
        let bytes = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": id(2), "source": ["subagent": ["thread_spawn": ["parent_thread_id": id(1), "agent_path": "PRIVATE", "agent_nickname": "PRIVATE"]]]]])
        log.consume(bytes)
        XCTAssertEqual(log.parentThreadID, id(1))
        var stream = SessionActivity(id: id(2), phaseAwareRate: true)
        live(&stream, "turn/started", 12, turn: "new")
        let merged = try XCTUnwrap(ActivitySourceMerger.merge(logged: [log], streamed: [stream]).first)
        XCTAssertEqual(merged.parentThreadID, id(1))
        XCTAssertEqual(merged.displayedOutputEstimate(at: start.addingTimeInterval(12))?.value, 60)
        XCTAssertTrue(merged.displayedRateIsEstimated(at: start.addingTimeInterval(12)))
        XCTAssertNil(merged.responsePerformance)
    }
    func testMalformedParentsAndCyclesCannotDoubleCountOrCrossHost() {
        var a = measured(1), b = measured(2)
        a.updateParent(id(1)); XCTAssertNil(a.parentThreadID)
        a.updateParent("PRIVATE"); XCTAssertNil(a.parentThreadID)
        a.updateParent(id(2)); b.updateParent(id(1))
        XCTAssertEqual(ActivityTaskGroup.make([a, b]).count, 1)
        XCTAssertEqual(ActivityOverview(activities: [a, b], at: start.addingTimeInterval(11)).displayedRate, 120)
    }
    func testForkedHistoryCannotOverwriteChildIdentityOrSeedItsRate() throws {
        var child = SessionActivity(id: id(2), phaseAwareRate: true)
        let formatter = ISO8601DateFormatter()
        func log(_ type: String, _ second: Double, _ payload: [String: Any]) throws {
            child.consume(try JSONSerialization.data(withJSONObject: ["type": type,
                "timestamp": formatter.string(from: start.addingTimeInterval(second)), "payload": payload]))
        }
        try log("session_meta", 0, ["id": id(2), "parent_thread_id": id(1)])
        try log("session_meta", 0, ["id": id(1), "title": "Ancestor title"])
        try log("event_msg", 0, ["type": "task_started", "turn_id": "ancestor"])
        try log("event_msg", 0, ["type": "token_count", "info": ["total_token_usage": ["output_tokens": 700_000]]])
        try log("response_item", 1, ["type": "message", "role": "assistant", "phase": "commentary"])
        try log("event_msg", 1, ["type": "token_count", "info": ["total_token_usage": ["output_tokens": 704_000]]])
        XCTAssertEqual(child.threadID, id(2))
        XCTAssertEqual(child.parentThreadID, id(1))
        XCTAssertNil(child.title)
        XCTAssertNil(child.turnID)
        XCTAssertNil(child.displayedOutputEstimate(at: start.addingTimeInterval(2)))
        try log("event_msg", 2, ["type": "thread_settings_applied", "thread_id": id(2)])
        try log("event_msg", 2, ["type": "task_started", "turn_id": "child"])
        try log("response_item", 7, ["type": "custom_tool_call", "call_id": "read", "name": "exec"])
        try log("token_usage_record", 7, ["thread_id": id(2), "turn_id": "child", "response_id": "response", "usage": ["output_tokens": 100]])
        XCTAssertEqual(child.responsePerformance?.outputTokens, 100)
        XCTAssertEqual(child.displayedOutputEstimate(at: start.addingTimeInterval(8))?.value, 20)
        XCTAssertTrue(child.displayedRateIsEstimated(at: start.addingTimeInterval(8)))
        let grouped = ActivityTaskGroup.make([measured(1), child])
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped.first?.runningSubagentCount, 1)
        XCTAssertEqual(grouped.first?.displayedRate(at: start.addingTimeInterval(11))?.value, 80)
    }
    func testNativeCollaborationDiscoversChildrenAndDropsPromptAndAgentMessages() throws {
        var messages: [[String: Any]] = []
        var session = try NativeDesktopSession(hosts: ["local"]) { messages.append($0) }
        try session.discover([.init(host: "local", thread: id(1))])
        func receive(_ value: [String: Any]) throws { try session.receive(JSONSerialization.data(withJSONObject: value), at: start) }
        try receive(["type": "response", "method": "initialize", "resultType": "success", "result": ["clientId": id(9)]])
        try receive(["type": "broadcast", "method": "thread-stream-state-changed", "version": 11, "sourceClientId": id(8), "params": ["hostId": "local", "conversationId": id(1), "change": ["type": "snapshot", "revision": 0, "conversationState": ["turns": [["turnId": "turn", "status": "inProgress", "items": [["id": "spawn", "type": "collabAgentToolCall", "status": "inProgress", "receiverThreadIds": [id(2), id(3), id(2)], "prompt": "PRIVATE", "agentsStates": [id(2): ["status": "running", "message": "PRIVATE"]]]]]]]]]])
        let follows = messages.filter { $0["method"] as? String == "thread-stream-following-changed" }.compactMap { ($0["params"] as? [String: Any])?["conversationId"] as? String }
        XCTAssertEqual(Set(follows), Set([id(1), id(2), id(3)]))
        try session.publishEvents()
        XCTAssertFalse(String(describing: session.takeFrames().map { String(decoding: $0, as: UTF8.self) }).contains("PRIVATE"))
    }
    func testDesktopSubAgentActivityCompletesAndReactivatesWithoutChildSnapshots() throws {
        var projection = DesktopWireProjection(threadID: id(1))
        var state = RuntimeEventState(sourceID: nil, sourceName: nil)
        state.consume(["kind": "status", "connected": true])
        func consume(_ value: [String: Any], at second: Double) throws {
            let view = try JSONFieldView.document(JSONSerialization.data(withJSONObject: value))
            let events = try projection.consume(view, owner: "owner", at: start.addingTimeInterval(second))
            XCTAssertFalse(String(describing: events).contains("PRIVATE"))
            state.consume(["kind": "runtimeBatch", "events": events])
        }
        func crumb(_ kind: String, _ n: Int, _ item: String) -> [String: Any] {
            ["type": "subAgentActivity", "id": item, "kind": kind, "agentThreadId": id(n), "agentPath": "PRIVATE", "message": "PRIVATE"]
        }
        try consume(["type": "snapshot", "revision": 0, "conversationState": ["turns": [["turnId": "turn", "status": "inProgress", "items": [crumb("started", 2, "a"), crumb("started", 3, "b")]]]]], at: 11)
        XCTAssertEqual(Set(projection.collaborationThreadIDs), Set([id(2), id(3)]))
        var child = SessionActivity(id: id(2), phaseAwareRate: true)
        child.updateParent(id(1))
        let formatter = ISO8601DateFormatter()
        for (type, second, payload) in [
            ("event_msg", 0.0, ["type": "task_started", "turn_id": "turn"]),
            ("response_item", 10.0, ["type": "message", "role": "assistant"]),
            ("token_usage_record", 10.0, ["thread_id": id(2), "turn_id": "turn", "response_id": "child", "usage": ["output_tokens": 300]])
        ] as [(String, Double, [String: Any])] {
            child.consume(try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": formatter.string(from: start.addingTimeInterval(second)), "payload": payload]))
        }
        XCTAssertFalse(child.hasLiveEvidence)
        func group(_ second: Double) throws -> ActivityTaskGroup {
            let combined = ActivitySourceMerger.merge(logged: [measured(1), child], streamed: state.activities)
            return try XCTUnwrap(ActivityTaskGroup.make(combined).first)
        }
        XCTAssertEqual(try group(11).runningSubagentCount, 2)
        XCTAssertEqual(try group(11).displayedRate(at: start.addingTimeInterval(11))?.value, 90)
        try consume(["type": "patches", "baseRevision": 0, "revision": 1, "patches": [["op": "add", "path": ["turns", 0, "items", 2], "value": crumb("completed", 2, "c")]]], at: 12)
        XCTAssertEqual(try group(12).runningSubagentCount, 1)
        XCTAssertEqual(try group(12).displayedRate(at: start.addingTimeInterval(12))?.value, 60)
        try consume(["type": "patches", "baseRevision": 1, "revision": 2, "patches": [["op": "add", "path": ["turns", 0, "items", 3], "value": crumb("interacted", 2, "d")]]], at: 13)
        XCTAssertEqual(try group(13).runningSubagentCount, 2)
        XCTAssertEqual(try group(13).displayedRate(at: start.addingTimeInterval(13))?.value, 90)
        XCTAssertTrue(try group(13).rateIsEstimated(at: start.addingTimeInterval(13)))
        try consume(["type": "patches", "baseRevision": 2, "revision": 3, "patches": [["op": "replace", "path": ["turns", 0, "items", 1, "kind"], "value": "completed"]]], at: 14)
        XCTAssertEqual(try group(14).runningSubagentCount, 1)
    }
    func testReplayedDesktopCrumbsCannotReviveEndedChildrenAndClearWithTheParentTurn() throws {
        // Desktop keeps a "started" crumb after the child ends. Pacer then
        // reattaches (wake, relaunch or stream reconnect) during the parent turn.
        var projection = DesktopWireProjection(threadID: id(1))
        var state = RuntimeEventState(sourceID: nil, sourceName: nil)
        state.consume(["kind": "status", "connected": true])
        func consume(_ value: [String: Any], at second: Double) throws {
            let view = try JSONFieldView.document(JSONSerialization.data(withJSONObject: value))
            state.consume(["kind": "runtimeBatch", "events": try projection.consume(view, owner: "owner", at: start.addingTimeInterval(second))])
        }
        func crumb(_ kind: String, _ n: Int, _ item: String) -> [String: Any] {
            ["type": "subAgentActivity", "id": item, "kind": kind, "agentThreadId": id(n)]
        }
        var ended = SessionActivity(id: id(2), phaseAwareRate: true)
        ended.updateParent(id(1))
        let formatter = ISO8601DateFormatter()
        for (second, kind) in [(1.0, "task_started"), (20.0, "task_complete")] {
            ended.consume(try JSONSerialization.data(withJSONObject: ["type": "event_msg",
                "timestamp": formatter.string(from: start.addingTimeInterval(second)), "payload": ["type": kind, "turn_id": "child"]]))
        }
        func group() throws -> ActivityTaskGroup {
            let combined = ActivitySourceMerger.merge(logged: [ended], streamed: state.activities)
            return try XCTUnwrap(ActivityTaskGroup.make(combined).first { $0.primary.threadID == id(1) })
        }
        func parentStates() -> [String: SessionActivity.SubagentEvidence]? { state.activities.first { $0.threadID == id(1) }?.subagentStates }
        try consume(["type": "snapshot", "revision": 0, "conversationState": ["turns": [["turnId": "turn", "status": "inProgress",
            "turnStartedAtMs": start.timeIntervalSince1970 * 1000, "items": [crumb("started", 2, "a"), crumb("started", 3, "b")]]]]], at: 30)
        XCTAssertEqual(parentStates()?[id(2)]?.observedAt, start, "Replayed running crumbs are dated no later than the turn start")
        XCTAssertEqual(try group().runningSubagentCount, 1, "The replay cannot revive the logged ending; an unlogged child still runs")
        XCTAssertEqual(try group().members.first { $0.threadID == id(2) }?.phase, .completed)
        // A transition observed live after the ending is a genuine reactivation.
        try consume(["type": "patches", "baseRevision": 0, "revision": 1, "patches": [["op": "replace", "path": ["turns", 0, "items", 0, "kind"], "value": "completed"]]], at: 31)
        try consume(["type": "patches", "baseRevision": 1, "revision": 2, "patches": [["op": "add", "path": ["turns", 0, "items", 2], "value": crumb("interacted", 2, "c")]]], at: 32)
        XCTAssertEqual(try group().runningSubagentCount, 2)
        // The terminal patch alone ends the turn's crumbs; no later patch is required.
        try consume(["type": "patches", "baseRevision": 2, "revision": 3, "patches": [["op": "replace", "path": ["turns", 0, "status"], "value": "completed"]]], at: 40)
        XCTAssertEqual(state.activities.first { $0.threadID == id(1) }?.phase, .completed)
        XCTAssertEqual(parentStates()?.isEmpty, true)
        XCTAssertFalse(try group().isRunning, "A finished parent cannot keep its task row running through stale crumbs")
    }
    func testHelperPreservesParentAndDiscoversReceiverWithoutForwardingCollaborationText() throws {
        let script = RealtimeProbe.library + "\n" + #"""
        class WS:
            def __init__(self):self.sent=[]
            def send(self,value):self.sent.append(value)
        parent='019a0000-0000-7000-8000-000000000001';child='019a0000-0000-7000-8000-000000000002'
        header=sanitize({'type':'session_meta','payload':{'id':child,'source':{'subagent':{'thread_spawn':{'parent_thread_id':parent,'agent_path':'PRIVATE','agent_nickname':'PRIVATE'}}}}})
        assert header['payload']['parent_thread_id']==parent and 'PRIVATE' not in repr(header)
        boundary=sanitize({'type':'event_msg','payload':{'type':'thread_settings_applied','thread_id':child,'thread_settings':{'prompt':'PRIVATE'}}})
        assert boundary['payload']=={'type':'thread_settings_applied','thread_id':child} and 'PRIVATE' not in repr(boundary)
        ws=WS();s=Session(ws);s.pending={};s.ready=True;s.known[parent]={'type':'active'};s.attached.add(parent)
        packets=[];emit=lambda value:packets.append(value)
        s.receive({'method':'item/started','params':{'threadId':parent,'turnId':'turn','item':{'id':'spawn','type':'collabAgentToolCall','receiverThreadIds':[child],'prompt':'PRIVATE','agentsStates':{child:{'status':'running','message':'PRIVATE'}}}}})
        request=next(v for v in ws.sent if v.get('method')=='thread/read')
        assert request['params']=={'threadId':child,'includeTurns':False}
        s.receive({'id':request['id'],'result':{'thread':{'id':child,'status':{'type':'active'},'parentThreadId':parent,'source':{'subAgent':{'thread_spawn':{'parent_thread_id':parent,'agent_nickname':'PRIVATE'}}}}}})
        flush_events(s)
        assert any(e.get('parentThreadId')==parent for p in packets for e in p.get('events',[]))
        assert 'PRIVATE' not in repr(packets) and 'PRIVATE' not in repr(ws.sent)
        print('parent and receiver sanitized')
        """#
        let child = Process(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", script, Data("/private/tmp/unused-subagent-fixture".utf8).base64EncodedString()]
        child.standardOutput = stdout; child.standardError = stderr
        try child.run(); let output = stdout.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0, String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("parent and receiver sanitized"))
    }
}
