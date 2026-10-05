import XCTest
@testable import PacerCore

final class NativeDesktopTests: XCTestCase {
    private let thread = "019a0000-0000-7000-8000-000000000001"
    private let epoch = Date(timeIntervalSince1970: 1000)
    private func view(_ value: [String: Any]) throws -> JSONFieldView {
        try JSONFieldView.document(JSONSerialization.data(withJSONObject: value))
    }
    func testNextTurnWithCachedUsageSeedsInsteadOfDividingHistoryByArrivalDelay() throws {
        var projection = DesktopWireProjection(threadID: thread)
        var runtime = RuntimeEventState(sourceID: nil, sourceName: nil)
        runtime.consume(["kind": "status", "connected": true])
        func consume(_ value: [String: Any], seconds: Double) throws {
            let events = try projection.consume(view(value), owner: "owner", at: epoch.addingTimeInterval(seconds))
            runtime.consume(["kind": "runtimeBatch", "events": events])
        }
        try consume(["type": "snapshot", "revision": 0, "conversationState": [
            "latestTokenUsageInfo": ["total": ["outputTokens": 10_000], "last": ["outputTokens": 8_000]],
            "turns": [["turnId": "old", "status": "completed", "items": []]]]], seconds: 0)
        try consume(["type": "patches", "baseRevision": 0, "revision": 1, "patches": [[
            "op": "add", "path": ["turns", 1], "value": ["turnId": "new", "status": "inProgress",
                "turnStartedAtMs": epoch.addingTimeInterval(0.5).timeIntervalSince1970 * 1000,
                "items": [["id": "reasoning", "type": "reasoning"]]]]]], seconds: 1)
        XCTAssertEqual(runtime.activities.first?.turnID, "new")
        XCTAssertNil(runtime.activities.first?.outputEstimate(at: epoch.addingTimeInterval(1)))
        try consume(["type": "patches", "baseRevision": 1, "revision": 2, "patches": [[
            "op": "replace", "path": ["latestTokenUsageInfo"], "value": [
                "total": ["outputTokens": 10_040], "last": ["outputTokens": 40]]]]], seconds: 3)
        XCTAssertEqual(runtime.activities.first?.tokensPerSecond(at: epoch.addingTimeInterval(3)), 20)
        XCTAssertNil(ActivityOverview(activities: runtime.activities, at: epoch.addingTimeInterval(18)).displayedRate)
    }
    func testRouteDiscoveryBoundsBootstrapWithoutLosingLaterTasks() throws {
        let home = URL(fileURLWithPath: "/private/tmp/pacer-route-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let host = "remote-ssh-discovered:synthetic", file = home.appendingPathComponent(".codex-global-state.json")
        var routes = Dictionary(uniqueKeysWithValues: (1...100).map { (String(format: "019a0000-0000-7000-8000-%012d", $0), host) })
        func save() throws { try JSONSerialization.data(withJSONObject: ["thread-project-membership-host-ids": routes, "unrelated": "PRIVATE"]).write(to: file, options: .atomic) }
        try save()
        var reader = DesktopRouteHints()
        XCTAssertEqual(reader.changed(home: home, hosts: [host]).count, 8)
        XCTAssertTrue(reader.changed(home: home, hosts: [host]).isEmpty)
        routes[thread] = host
        let new = "019b0000-0000-7000-8000-000000000001"
        routes[new] = host; routes[UUID().uuidString] = "disabled-host"
        try save()
        XCTAssertEqual(reader.changed(home: home, hosts: [host]), [.init(host: host, thread: new)])
        XCTAssertFalse(String(describing: reader).contains("PRIVATE"))
    }
    private func state(turns: Int = 1, items: Int = 2) -> [String: Any] {
        var entities: [String: Any] = [:]
        for i in 0..<turns {
            entities["key\(i)"] = ["turnId": "turn\(i)", "status": i == turns - 1 ? "inProgress" : "completed",
                "turnStartedAtMs": 900000 + i, "items": (0..<items).map { j in
                    ["id": "item\(j)", "type": j == 0 ? "reasoning" : "commandExecution",
                     "status": j == 0 ? "completed" : "inProgress", "text": "PRIVATE", "arguments": "PRIVATE"]
                }]
        }
        return ["title": "Synthetic", "cwd": "/synthetic", "latestModel": "model", "requests": [],
            "threadRuntimeStatus": ["type": "active", "activeFlags": []],
            "latestTokenUsageInfo": ["total": ["outputTokens": 10]],
            "turnHistory": ["kind": "canonical", "history": ["entitiesByKey": entities]]]
    }
    func testHistoricalItemsAreNotRetainedAndTokenPatchesPreserveCurrentItems() throws {
        var projection = DesktopWireProjection(threadID: thread)
        let initial = try projection.consume(view(["type": "snapshot", "revision": 0, "conversationState": state(turns: 100, items: 32)]), owner: "owner", at: epoch)
        XCTAssertEqual(projection.retainedItemCount, 32)
        XCTAssertTrue(initial.contains { $0["method"] as? String == "turn/attached" })
        let events = try projection.consume(view(["type": "patches", "baseRevision": 0, "revision": 1,
            "patches": [["op": "replace", "path": ["latestTokenUsageInfo", "total", "outputTokens"], "value": 20]]]), owner: "owner", at: epoch)
        XCTAssertEqual(projection.retainedItemCount, 32)
        XCTAssertEqual(events.first { $0["method"] as? String == "thread/tokenUsage/updated" }?["outputTokens"] as? Int, 20)
        XCTAssertFalse(String(describing: projection).contains("PRIVATE"))
    }
    func testTextPatchesAdvanceRevisionAndMalformedBatchesRollbackAtomically() throws {
        var projection = DesktopWireProjection(threadID: thread)
        _ = try projection.consume(view(["type": "snapshot", "revision": 0, "conversationState": state()]), owner: "owner", at: epoch)
        let text = try projection.consume(view(["type": "patches", "baseRevision": 0, "revision": 1,
            "patches": [["op": "replace", "path": ["turnHistory", "history", "entitiesByKey", "key0", "items", 0, "text"], "value": "PRIVATE"]]]), owner: "owner", at: epoch)
        XCTAssertTrue(text.contains { $0["method"] as? String == "item/reasoning/textDelta" })
        XCTAssertThrowsError(try projection.consume(view(["type": "patches", "baseRevision": 1, "revision": 2,
            "patches": [["op": "replace", "path": ["turnHistory", "history", "entitiesByKey", "key0", "status"], "value": "completed"],
                        ["op": "replace", "path": ["turnHistory", "history", "entitiesByKey", "key0", "items", 100, "status"], "value": "completed"]]]), owner: "owner", at: epoch))
        XCTAssertEqual(projection.revision, 1)
        XCTAssertTrue(projection.isActive)
        XCTAssertThrowsError(try projection.consume(view(["type": "patches", "baseRevision": 1, "revision": 2, "patches": []]), owner: "other", at: epoch))
    }
    func testAsyncRequestsAreIndependentOfRunningStatusAndContainNoQuestionText() throws {
        var projection = DesktopWireProjection(threadID: thread, attentionOnly: true)
        var raw = state(turns: 30, items: 32)
        raw["requests"] = [["id": 123, "request": ["method": "item/tool/requestUserInput",
            "params": ["isBlocking": false, "questions": [["question": "PRIVATE", "options": ["PRIVATE"]]]]]]]
        let events = try projection.consume(view(["type": "snapshot", "revision": 0, "conversationState": raw]), owner: "owner", at: epoch)
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(projection.isActive)
        XCTAssertEqual(projection.requests.count, 1)
        XCTAssertEqual(projection.requests.first?.kind, .input)
        XCTAssertEqual(projection.retainedItemCount, 0)
        XCTAssertFalse(String(describing: projection).contains("PRIVATE"))
        _ = try projection.consume(view(["type": "patches", "baseRevision": 0, "revision": 1,
            "patches": [["op": "replace", "path": ["requests"], "value": []]]]), owner: "owner", at: epoch)
        XCTAssertTrue(projection.requests.isEmpty)
        XCTAssertTrue(projection.isActive)
    }
    func testCurrentItemRemovalAndCompletionDoNotKeepHistoricalItemStorage() throws {
        var projection = DesktopWireProjection(threadID: thread)
        _ = try projection.consume(view(["type": "snapshot", "revision": 0, "conversationState": state()]), owner: "owner", at: epoch)
        _ = try projection.consume(view(["type": "patches", "baseRevision": 0, "revision": 1,
            "patches": [["op": "remove", "path": ["turnHistory", "history", "entitiesByKey", "key0", "items", 0]]]]), owner: "owner", at: epoch)
        XCTAssertEqual(projection.retainedItemCount, 1)
        let events = try projection.consume(view(["type": "patches", "baseRevision": 1, "revision": 2,
            "patches": [["op": "replace", "path": ["turnHistory", "history", "entitiesByKey", "key0", "status"], "value": "completed"]]]), owner: "owner", at: epoch)
        XCTAssertEqual(events.filter { $0["method"] as? String == "turn/completed" }.count, 1)
        XCTAssertEqual(projection.retainedItemCount, 0)
    }
    func testRequestPolicyAlertsOnceWhileTaskContinuesAndResolvesIndependently() {
        let request = PendingAttentionRequest(id: "pending", threadID: thread, sourceHostID: "remote-ssh-discovered:test",
            sourceName: "Synthetic", kind: .input, detectedAt: epoch)
        var policy = AttentionPolicy()
        XCTAssertEqual(policy.requestNotices([request]).first?.kind, .waitingForInput)
        XCTAssertTrue(policy.requestNotices([request]).isEmpty)
        XCTAssertTrue(policy.requestNotices([]).isEmpty)
        XCTAssertEqual(policy.requestNotices([request]).count, 1)
        XCTAssertEqual(request.activity.threadID, thread)
        XCTAssertEqual(URLComponents(url: request.activity.threadURL!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value,
                       "remote-ssh-discovered:test")
    }
    func testDesktopAsyncQuestionMetadataPersistsUntilReplyOrTurnEnds() throws {
        for (attentionOnly, replyType) in [(false, "userMessage"), (true, "userMessage"), (false, "steeringUserMessage"), (true, "steeringUserMessage")] {
            var projection = DesktopWireProjection(threadID: thread, attentionOnly: attentionOnly)
            var raw = state()
            var history = raw["turnHistory"] as! [String: Any]
            var canonical = history["history"] as! [String: Any]
            canonical["entitiesByKey"] = ["key0": ["turnId": "turn0", "status": "inProgress", "turnStartedAtMs": 900000,
                "items": [["id": "user0", "type": "userMessage", "content": "PRIVATE"],
                          ["id": "question0", "type": "agentMessage", "text": "PRIVATE", "questions": [["title": "PRIVATE", "options": ["PRIVATE"]]]]]]]
            history["history"] = canonical; raw["turnHistory"] = history
            _ = try projection.consume(view(["type": "snapshot", "revision": 0, "conversationState": raw]), owner: "owner", at: epoch)
            XCTAssertEqual(projection.requests.map(\.kind), [.input])
            XCTAssertTrue(projection.isActive)
            XCTAssertFalse(String(describing: projection).contains("PRIVATE"))
            func patch(_ base: Int, _ path: [Any], _ value: Any, op: String = "add") throws -> JSONFieldView {
                try view(["type": "patches", "baseRevision": base, "revision": base + 1,
                    "patches": [["op": op, "path": path, "value": value]]])
            }
            let items: [Any] = ["turnHistory", "history", "entitiesByKey", "key0", "items"]
            _ = try projection.consume(patch(0, items + [2], ["id": "running", "type": "commandExecution", "status": "inProgress"]), owner: "owner", at: epoch)
            XCTAssertEqual(projection.requests.count, 1)
            _ = try projection.consume(patch(1, items + [3], ["id": "reply", "type": replyType, "content": "PRIVATE"]), owner: "owner", at: epoch)
            XCTAssertTrue(projection.requests.isEmpty)
            _ = try projection.consume(patch(2, items + [4], ["id": "question1", "type": "agentMessage", "questions": []]), owner: "owner", at: epoch)
            _ = try projection.consume(patch(3, items + [4, "questions", 0], ["title": "PRIVATE"]), owner: "owner", at: epoch)
            XCTAssertEqual(projection.requests.count, 1)
            _ = try projection.consume(patch(4, items + [4, "questions", 0], NSNull(), op: "remove"), owner: "owner", at: epoch)
            XCTAssertTrue(projection.requests.isEmpty)
            _ = try projection.consume(patch(5, items + [4, "questions"], [["title": "PRIVATE"]], op: "replace"), owner: "owner", at: epoch)
            XCTAssertEqual(projection.requests.count, 1)
            _ = try projection.consume(patch(6, ["turnHistory", "history", "entitiesByKey", "key0", "status"], "completed", op: "replace"), owner: "owner", at: epoch)
            XCTAssertTrue(projection.requests.isEmpty)
            XCTAssertEqual(projection.retainedItemCount, 0)
        }
    }
    func testSnapshotAndWholeItemReplacementRestoreModelStageWithoutTextDelta() throws {
        var projection = DesktopWireProjection(threadID: thread)
        var runtime = RuntimeEventState(sourceID: nil, sourceName: nil)
        runtime.consume(["kind": "status", "connected": true])
        let background: [String: Any] = ["id": "background", "type": "commandExecution", "status": "inProgress"]
        let thinking: [String: Any] = ["id": "thinking", "type": "reasoning", "text": "PRIVATE"]
        let turn: [String: Any] = ["turnId": "turn", "status": "inProgress", "turnStartedAtMs": 900000, "items": [background, thinking]]
        let initial = try projection.consume(view(["type": "snapshot", "revision": 0, "conversationState": ["turns": [turn]]]), owner: "owner", at: epoch)
        runtime.consume(["kind": "runtimeBatch", "events": initial])
        XCTAssertEqual(runtime.activities.first?.stage, .thinking, "An older background tool must not mask the latest model item")
        let answering: [String: Any] = ["id": "answer", "type": "agentMessage", "text": "PRIVATE"]
        let replacement = try projection.consume(view(["type": "patches", "baseRevision": 0, "revision": 1,
            "patches": [["op": "replace", "path": ["turns", 0, "items"], "value": [background, thinking, answering]]]]), owner: "owner", at: epoch.addingTimeInterval(1))
        runtime.consume(["kind": "runtimeBatch", "events": replacement])
        XCTAssertEqual(runtime.activities.first?.stage, .responding)
        XCTAssertFalse(String(describing: initial + replacement).contains("PRIVATE"))
        let tool: [String: Any] = ["id": "latest-tool", "type": "commandExecution", "status": "inProgress"]
        let executing = try projection.consume(view(["type": "patches", "baseRevision": 1, "revision": 2,
            "patches": [["op": "replace", "path": ["turns", 0, "items"], "value": [background, thinking, answering, tool]]]]), owner: "owner", at: epoch.addingTimeInterval(2))
        runtime.consume(["kind": "runtimeBatch", "events": executing])
        XCTAssertEqual(runtime.activities.first?.stage, .tool, "An old model item must not override the latest tool")
    }
    func testTerminalWatchKeepsNextTurnVisibleAndFreesActiveCapacity() throws {
        final class Sent { var values: [[String: Any]] = [] }
        let sent = Sent(), client = "019a0000-0000-7000-8000-000000000010", owner = "019a0000-0000-7000-8000-000000000020"
        var session = try NativeDesktopSession(hosts: ["local"]) { sent.values.append($0) }
        func send(_ value: [String: Any]) throws { try session.receive(JSONSerialization.data(withJSONObject: value), at: epoch) }
        func follow(_ id: String) throws { try send(["type": "broadcast", "method": "thread-stream-following-changed", "version": 1, "params": ["hostId": "local", "conversationId": id, "following": true]]) }
        func change(_ id: String, _ value: [String: Any]) throws { try send(["type": "broadcast", "method": "thread-stream-state-changed", "version": 11, "sourceClientId": owner, "targetClientIds": [client], "params": ["hostId": "local", "conversationId": id, "change": value]]) }
        try send(["type": "response", "method": "initialize", "resultType": "success", "result": ["clientId": client]])
        try follow(thread)
        try change(thread, ["type": "snapshot", "revision": 0, "conversationState": ["turns": [["turnId": "old", "status": "inProgress", "turnStartedAtMs": 800000, "items": [["id": "answer", "type": "agentMessage"]]]]]])
        try session.publishEvents()
        _ = session.takeFrames()
        try change(thread, ["type": "patches", "baseRevision": 0, "revision": 1, "patches": [["op": "replace", "path": ["turns", 0, "status"], "value": "completed"]]])
        // Real owners send token/status bookkeeping after the terminal patch,
        // often before the 250ms batch has delivered that ending to the UI.
        try change(thread, ["type": "patches", "baseRevision": 1, "revision": 2, "patches": [["op": "replace", "path": ["threadRuntimeStatus"], "value": ["type": "idle", "activeFlags": []]]]])
        try session.publishEvents()
        let ended = try session.takeFrames().map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
        XCTAssertFalse(ended.contains { $0["kind"] as? String == "streamInvalidated" })
        XCTAssertEqual(ended.compactMap { $0["events"] as? [[String: Any]] }.flatMap { $0 }.filter {
            $0["method"] as? String == "turn/completed"
        }.count, 1, "A trailing patch must not discard the queued completion")
        XCTAssertEqual(session.dormantSubscriptionCount, 1)
        XCTAssertEqual(session.retainedItemCount, 0)
        XCTAssertFalse(sent.values.contains { ($0["params"] as? [String: Any])?["following"] as? Bool == false })
        // No new following announcement: the already-open owner only sends
        // its next patch to clients which retained their interest.
        try change(thread, ["type": "patches", "baseRevision": 2, "revision": 3, "patches": [["op": "add", "path": ["turns", 1], "value": ["turnId": "next", "status": "inProgress", "turnStartedAtMs": 900000, "items": [["id": "reasoning", "type": "reasoning"]]]]]])
        try session.publishEvents()
        let frames = try session.takeFrames().map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
        let events = frames.compactMap { $0["events"] as? [[String: Any]] }.flatMap { $0 }
        XCTAssertTrue(events.contains { $0["method"] as? String == "turn/started" && $0["turnId"] as? String == "next" })
        XCTAssertEqual(session.dormantSubscriptionCount, 0)
        // More than 32 ended conversations do not consume the 32 initial /
        // active subscription slots; dormant interests remain bounded at 64.
        for i in 1...80 {
            let id = String(format: "019a0000-0000-7000-8000-%012d", i + 100)
            try follow(id)
            try change(id, ["type": "snapshot", "revision": 0, "conversationState": ["turns": [["turnId": "ended", "status": "completed", "items": []]]]])
            try session.publishEvents(); _ = session.takeFrames()
        }
        XCTAssertEqual(session.dormantSubscriptionCount, 64)
        XCTAssertEqual(session.retainedItemCount, 1, "Only the active next turn retains item metadata")
        let newID = "019a0000-0000-7000-8000-000000000999"
        try follow(newID)
        XCTAssertEqual((sent.values.last?["params"] as? [String: Any])?["conversationId"] as? String, newID)
        session.close()
        XCTAssertEqual(session.dormantSubscriptionCount, 0)
    }
    func testRemoteRuntimeAndRequestsAreRoutedSeparatelyFromLocalTasks() throws {
        final class Sent { var values: [[String: Any]] = [] }
        let sent = Sent(), host = "remote-ssh-discovered:test"
        var session = try NativeDesktopSession(hosts: ["local", host]) { sent.values.append($0) }
        let client = "019a0000-0000-7000-8000-000000000010", owner = "019a0000-0000-7000-8000-000000000020"
        func send(_ value: [String: Any]) throws { try session.receive(JSONSerialization.data(withJSONObject: value), at: epoch) }
        try send(["type": "response", "method": "initialize", "resultType": "success", "result": ["clientId": client]])
        // The broker only forwards targeted messages to their recipients.
        // Discovery must work from the owner's real following announcement.
        try send(["type": "broadcast", "method": "thread-stream-following-status-requested", "version": 1,
            "sourceClientId": owner, "params": ["hostId": host, "conversationId": thread]])
        XCTAssertEqual((sent.values.last?["params"] as? [String: Any])?["hostId"] as? String, host)
        var raw = state(); raw["requests"] = [["id": "async", "method": "item/tool/requestUserInput", "params": ["isBlocking": false, "questions": ["PRIVATE"]]]]
        try send(["type": "broadcast", "method": "thread-stream-state-changed", "version": 11, "sourceClientId": owner,
            "params": ["hostId": host, "conversationId": thread, "change": ["type": "snapshot", "revision": 0, "conversationState": raw]]])
        try send(["type": "broadcast", "method": "thread-stream-following-status-requested", "version": 1,
            "sourceClientId": owner, "params": ["hostId": "local", "conversationId": thread]])
        try send(["type": "broadcast", "method": "thread-stream-state-changed", "version": 11, "sourceClientId": owner,
            "params": ["hostId": "local", "conversationId": thread, "change": ["type": "snapshot", "revision": 0, "conversationState": state()]]])
        try session.publishEvents()
        let frames = try session.takeFrames().map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
        XCTAssertEqual(frames.filter { $0["kind"] as? String == "attention" && $0["hostId"] as? String == host }.count, 1)
        var local = RuntimeEventState(sourceID: nil, sourceName: nil)
        let batch = try XCTUnwrap(frames.first { $0["kind"] as? String == "runtimeBatch" && $0["hostId"] as? String == "local" })
        local.consume(["kind": "status", "connected": true]); local.consume(batch)
        XCTAssertEqual(local.activities.first?.id, "local:" + thread)
        XCTAssertFalse(frames.contains { $0["kind"] as? String == "runtimeBatch" && $0["hostId"] as? String == host }, "A cached Desktop view cannot be runtime authority for an SSH task")
        XCTAssertEqual(frames.first { $0["kind"] as? String == "discovery" && $0["hostId"] as? String == host }?["threadIds"] as? [String], [thread])
        let sentCount = sent.values.count
        try send(["type": "broadcast", "method": "thread-stream-following-status-requested", "version": 1,
            "sourceClientId": owner, "params": ["hostId": host, "conversationId": thread]])
        XCTAssertEqual(sent.values.count, sentCount + 1, "An already-followed owner must receive a fresh acknowledgement")
        XCTAssertEqual((sent.values.last?["params"] as? [String: Any])?["following"] as? Bool, true)
        XCTAssertFalse(String(describing: frames).contains("PRIVATE"))
    }
}
