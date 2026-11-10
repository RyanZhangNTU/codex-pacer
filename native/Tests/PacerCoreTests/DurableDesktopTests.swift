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
}
