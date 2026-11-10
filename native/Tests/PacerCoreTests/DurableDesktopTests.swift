import XCTest
@testable import PacerCore

final class DurableDesktopTests: XCTestCase {
    private let thread = "019a0000-0000-7000-8000-000000000001"
    private let other = "019a0000-0000-7000-8000-000000000002"

    func testCatalogFiltersTheExecutorAndDetectsBusyWork() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let payload: [String: Any] = ["data": [
            ["id": thread, "threadSource": "aeon_child", "updatedAt": 970, "status": ["type": "idle"],
             "environments": [["environmentId": "this-mac"]]],
            ["id": other, "threadSource": "aeon_child", "updatedAt": 999, "status": ["type": "active"],
             "environments": [["environmentId": "other-mac"]], "cwd": "/Users/synthetic"],
            ["id": UUID().uuidString, "threadSource": "aeon_child", "updatedAt": 999, "status": ["type": "active"],
             "environments": [], "cwd": "/Users/synthetic"],
            ["id": UUID().uuidString, "threadSource": "work", "updatedAt": 990, "status": ["type": "active"],
             "environments": [["environmentId": "this-mac"]]]
        ], "nextCursor": NSNull()]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let page = try DurableActivityCatalog.page(JSONFieldView.document(data), environmentID: "this-mac", now: now)
        XCTAssertEqual(page.threadIDs, [thread])
        XCTAssertFalse(page.executorIdle)
        let later = try DurableActivityCatalog.page(JSONFieldView.document(data), environmentID: "this-mac",
                                                    retaining: [thread], now: now.addingTimeInterval(900))
        XCTAssertEqual(later.threadIDs, [thread])
    }

    func testClosedTaskWaitsForItsOwnerAndReportsTwoAcceptedPercentages() throws {
        let start = Date(), host = DurableActivityCatalog.hostID
        let owner = "019a0000-0000-7000-8000-000000000020"
        var sent: [[String: Any]] = []
        var session = try NativeDesktopSession(hosts: ["local", host]) { sent.append($0) }
        var runtime = RuntimeEventState(sourceID: host, sourceName: nil)
        runtime.consume(["kind": "status", "connected": true])
        func receive(_ frame: [String: Any], seconds: TimeInterval) throws {
            try session.receive(JSONSerialization.data(withJSONObject: frame), at: start.addingTimeInterval(seconds))
        }
        func update(_ change: [String: Any], for id: String, seconds: TimeInterval) throws {
            try receive(["type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
                         "sourceClientId": owner, "params": ["hostId": host, "conversationId": id, "change": change]], seconds: seconds)
            try session.publishEvents()
            for data in session.takeFrames() {
                let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                if frame["kind"] as? String == "runtimeBatch" { runtime.consume(frame) }
            }
        }
        try receive(["type": "response", "method": "initialize", "resultType": "success",
                     "result": ["clientId": "019a0000-0000-7000-8000-000000000010"]], seconds: 0)
        try session.discover([.init(host: host, thread: thread), .init(host: host, thread: other)])
        XCTAssertFalse(sent.contains { $0["method"] as? String == "thread-stream-following-changed" })
        try session.setDurableCatalog(.init(scope: "test-account", threadIDs: [thread]), at: start)
        for _ in 0..<8 {
            guard let time = session.nextServiceDate, time < start.addingTimeInterval(33) else { break }
            try session.service(at: time)
        }
        XCTAssertEqual((sent.last?["params"] as? [String: Any])?["following"] as? Bool, true)
        let snapshot: [String: Any] = ["type": "snapshot", "revision": 0, "conversationState": [
            "turns": [["turnId": "turn-1", "status": "inProgress", "turnStartedAtMs": start.timeIntervalSince1970 * 1000, "items": []]]
        ]]
        try update(snapshot, for: other, seconds: 33)
        XCTAssertTrue(runtime.activities.isEmpty)
        try update(snapshot, for: thread, seconds: 33)
        XCTAssertEqual(runtime.activities.first?.phase, .running)
        for (index, percent) in [25, 60].enumerated() {
            let active: [String: Any] = [
                "id": "call-\(index)", "type": "mcpToolCall", "server": "pacer_progress", "tool": "report_progress",
                "status": "inProgress", "arguments": ["percent": percent]
            ]
            let path: [Any] = ["turns", 0, "items", index], revision = index * 2
            let at = Double(50 + index * 40)
            try update(["type": "patches", "baseRevision": revision, "revision": revision + 1,
                        "patches": [["op": "add", "path": path, "value": active]]], for: thread, seconds: at)
            XCTAssertEqual(runtime.activities.first?.currentProgress?.percent, index == 0 ? nil : 25)
            try update(["type": "patches", "baseRevision": revision + 1, "revision": revision + 2,
                        "patches": [
                            ["op": "replace", "path": path + ["status"], "value": "completed"],
                            ["op": "add", "path": path + ["result"], "value": [
                                "content": [["type": "text", "text": "pacer-progress:accepted"]]
                            ]]
                        ]], for: thread, seconds: at + 1)
            XCTAssertEqual(runtime.activities.first?.currentProgress?.percent, percent)
        }
        try update(["type": "patches", "baseRevision": 4, "revision": 5,
                    "patches": [["op": "replace", "path": ["turns", 0, "status"], "value": "completed"]]],
                   for: thread, seconds: 100)
        XCTAssertEqual(runtime.activities.first?.phase, .completed)
        XCTAssertEqual(runtime.activities.first?.threadURL?.query, "hostId=durable")
        try session.setDurableCatalog(nil, at: start.addingTimeInterval(101))
        XCTAssertEqual((sent.last?["params"] as? [String: Any])?["following"] as? Bool, false)
    }

    func testClosedTaskReceivesDurableHistoryWhenDesktopNeverSendsASnapshot() throws {
        let host = DurableActivityCatalog.hostID, scope = "account"
        let start = Date(timeIntervalSince1970: 10_000)
        var session = try NativeDesktopSession(hosts: [host]) { _ in }
        var runtime = RuntimeEventState(sourceID: host, sourceName: nil)
        try initialize(&session, at: start)
        try session.setDurableCatalog(.init(scope: scope, threadIDs: [thread]), at: start)
        func consume() throws {
            try session.publishEvents()
            for data in session.takeFrames() {
                let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                if frame["kind"] as? String == "runtimeBatch" { runtime.consume(["kind": "status", "connected": true]) }
                runtime.consume(frame)
            }
        }
        func observe(_ history: DurableTurnHistory, scope: String = "account", seconds: TimeInterval) throws {
            try session.observeDurableHistory([history], scope: scope, at: start.addingTimeInterval(seconds))
            try consume()
        }
        try observe(history(thread: other, start: start, percent: 95), seconds: 10)
        try observe(history(thread: thread, start: start, percent: 95), scope: "another-account", seconds: 10)
        XCTAssertTrue(runtime.activities.isEmpty)
        try observe(history(thread: thread, start: start, percent: 0, includeStartedAt: false), seconds: 12)
        XCTAssertEqual(runtime.activities.first?.phase, .running)
        XCTAssertEqual(runtime.activities.first?.currentProgress?.percent, 0)

        // Follow retries may expire with no IPC owner. That does not invalidate
        // the verified Durable turn or produce a second unknown activity.
        for _ in 0..<8 {
            if let date = session.nextServiceDate { try session.service(at: date) }
        }
        try session.status(loopIterations: 1)
        try consume()
        XCTAssertEqual(runtime.activities.count, 1)
        XCTAssertEqual(runtime.activities.first?.phase, .running)
        try observe(history(thread: thread, start: start, percent: 20), seconds: 65)
        try observe(history(thread: thread, start: start, percent: 75), seconds: 80)
        XCTAssertEqual(runtime.activities.first?.currentProgress?.percent, 75)
        try observe(history(thread: thread, start: start, percent: 100), seconds: 110)
        XCTAssertEqual(runtime.activities.first?.currentProgress?.percent, 100)
        XCTAssertEqual(runtime.activities.first?.phase, .running)
        let finished = try history(thread: thread, start: start, percent: 100, status: .completed)
        try observe(finished, seconds: 115)
        XCTAssertEqual(runtime.activities.first?.phase, .completed)
        XCTAssertEqual(runtime.activities.first?.title, "Closed task")
        XCTAssertEqual(runtime.activities.first?.threadURL?.query, "hostId=durable")
        runtime.releasePublishedState()
        try observe(finished, seconds: 130)
        XCTAssertTrue(runtime.activities.isEmpty, "Repeated history must not recreate a published completion")
    }

    func testDesktopSnapshotDoesNotOverwriteMoreRecentHistoryAndStillEndsTheTurn() throws {
        let host = DurableActivityCatalog.hostID, scope = "account"
        let start = Date(timeIntervalSince1970: 20_000)
        var session = try NativeDesktopSession(hosts: [host]) { _ in }
        var runtime = RuntimeEventState(sourceID: host, sourceName: nil)
        runtime.consume(["kind": "status", "connected": true])
        try initialize(&session, at: start)
        try session.setDurableCatalog(.init(scope: scope, threadIDs: [thread]), at: start)
        func consume() throws {
            try session.publishEvents()
            for data in session.takeFrames() {
                let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                if frame["kind"] as? String == "runtimeBatch" { runtime.consume(frame) }
            }
        }
        func ipc(_ change: [String: Any], seconds: TimeInterval) throws {
            let wire: [String: Any] = ["type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
                "sourceClientId": "019a0000-0000-7000-8000-000000000020",
                "params": ["hostId": host, "conversationId": thread, "change": change]]
            try session.receive(JSONSerialization.data(withJSONObject: wire), at: start.addingTimeInterval(seconds))
            try consume()
        }
        try session.observeDurableHistory([history(thread: thread, start: start, percent: 20)], scope: scope,
                                          at: start.addingTimeInterval(30))
        try consume()
        try ipc(["type": "snapshot", "revision": 0, "conversationState": ["threadRuntimeStatus": ["type": "notLoaded"], "turns": [[
            "turnId": "turn-1", "status": "inProgress", "turnStartedAtMs": start.timeIntervalSince1970 * 1000,
            "items": [receipt(percent: 0)]
        ]]]], seconds: 31)
        XCTAssertEqual(runtime.activities.first?.currentProgress?.percent, 20)
        try ipc(["type": "patches", "baseRevision": 0, "revision": 1, "patches": [
            ["op": "replace", "path": ["turns", 0, "status"], "value": "completed"]
        ]], seconds: 40)
        XCTAssertEqual(runtime.activities.first?.phase, .completed)
        runtime.releasePublishedState()
        try session.observeDurableHistory([history(thread: thread, start: start, percent: 20, status: .completed)], scope: scope,
                                          at: start.addingTimeInterval(120))
        try consume()
        XCTAssertTrue(runtime.activities.isEmpty)
    }

    private func initialize(_ session: inout NativeDesktopSession, at start: Date) throws {
        let response: [String: Any] = ["type": "response", "method": "initialize", "resultType": "success",
                                       "result": ["clientId": "019a0000-0000-7000-8000-000000000010"]]
        try session.receive(JSONSerialization.data(withJSONObject: response), at: start)
    }

    private func receipt(percent: Int, acknowledgment: String = "pacer-progress:accepted") -> [String: Any] {
        ["id": "call-\(percent)", "type": "mcpToolCall", "server": "pacer_progress", "tool": "report_progress",
         "status": "completed", "arguments": ["percent": percent], "result": ["content": [["type": "text", "text": acknowledgment]]]]
    }

    private func history(thread: String, start: Date, percent: Int,
                         status: DurableTurnHistory.Status = .inProgress, includeStartedAt: Bool = true) throws -> DurableTurnHistory {
        let entry = DurableActivityCatalog.Entry(id: thread, name: "Closed task", updatedAt: start, active: status == .inProgress)
        var turn: [String: Any] = ["id": "turn-1", "status": status.rawValue]
        if includeStartedAt { turn["startedAt"] = start.timeIntervalSince1970 }
        if status != .inProgress { turn["completedAt"] = start.addingTimeInterval(110).timeIntervalSince1970 }
        let turns = try JSONSerialization.data(withJSONObject: ["data": [turn]])
        let now = start.addingTimeInterval(120)
        var history = try XCTUnwrap(DurableTurnHistory.latest(JSONFieldView.document(turns), thread: entry, now: now))
        let items: [[String: Any]] = [
            ["turnId": "turn-2", "item": receipt(percent: 99)],
            ["turnId": "turn-1", "item": receipt(percent: 98, acknowledgment: "rejected")],
            ["turnId": "turn-1", "completedAtMs": start.addingTimeInterval(Double(percent) + 1).timeIntervalSince1970 * 1000,
             "item": receipt(percent: percent)]
        ]
        let bytes = try JSONSerialization.data(withJSONObject: ["data": items])
        history.report = try history.receiptPage(JSONFieldView.document(bytes), now: now).report
        return history
    }
}
