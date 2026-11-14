#if canImport(PacerMacSupport)
import PacerMacSupport
#else
@testable import PacerEngineSupport
#endif
import XCTest
@testable import PacerCore

final class QuotaTests: XCTestCase {
    func testMultipleBucketsTakePrecedenceOverLegacyView() throws {
        let snapshot = try decode("""
        {"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{
        "special":{"limitName":"Special","primary":{"usedPercent":40,"windowDurationMins":60}},
        "codex":{"planType":"pro","primary":{"usedPercent":25,"windowDurationMins":300},"secondary":{"usedPercent":80,"windowDurationMins":10080}}
        }}
        """)
        XCTAssertEqual(snapshot.buckets.map(\.id), ["codex", "special"])
        XCTAssertEqual(snapshot.windows.count, 3)
        XCTAssertEqual(snapshot.limitingWindow?.remainingPercent, 20)
        XCTAssertEqual(snapshot.windows.first?.label, L10n.text("quota.hours", 5))
        XCTAssertEqual(snapshot.windows[1].label, L10n.text("quota.days", 7))
    }
    func testNullUsageIsUnavailableRatherThanFullQuota() throws {
        let snapshot = try decode("{\"rateLimits\":{\"primary\":{\"usedPercent\":null},\"secondary\":null}}")
        XCTAssertNil(snapshot.windows.first?.remainingPercent)
        XCTAssertNil(snapshot.limitingWindow)
    }
    func testUnknownDurationDoesNotPretendToBeFiveHours() throws {
        let snapshot = try decode("{\"rateLimits\":{\"primary\":{\"usedPercent\":0}}}")
        XCTAssertEqual(snapshot.windows.first?.label, L10n.text("quota.generic_window"))
        XCTAssertEqual(snapshot.windows.first?.remainingPercent, 100)
    }
    func testAuthoritativeEmptyResultReplacesPreviousWindows() throws {
        let snapshot = try decode("{\"rateLimits\":null,\"rateLimitsByLimitId\":{}}")
        XCTAssertTrue(snapshot.windows.isEmpty)
    }
    func testOutOfRangeUsageIsClampedAndResetUsesSeconds() throws {
        let snapshot = try decode("{\"rateLimits\":{\"primary\":{\"usedPercent\":120,\"resetsAt\":1780000000},\"secondary\":{\"usedPercent\":-5}}}")
        XCTAssertEqual(snapshot.windows.map(\.remainingPercent), [0, 100])
        XCTAssertEqual(snapshot.windows.first?.resetsAt?.timeIntervalSince1970, 1780000000)
    }
    func testOldSnapshotBecomesStaleWithoutInventingAReset() throws {
        let snapshot = try QuotaSnapshot.decode(Data("{\"rateLimits\":{\"primary\":{\"usedPercent\":90}}}".utf8), capturedAt: Date(timeIntervalSince1970: 100))
        XCTAssertFalse(snapshot.isStale(at: Date(timeIntervalSince1970: 700)), "Ten minutes old is still current")
        XCTAssertTrue(snapshot.isStale(at: Date(timeIntervalSince1970: 701)))
        XCTAssertEqual(snapshot.windows.first?.remainingPercent, 10)
    }
    private func decode(_ text: String) throws -> QuotaSnapshot { try QuotaSnapshot.decode(Data(text.utf8)) }
}

final class ActivityTests: XCTestCase {
    func testLateCompletionDoesNotEndNewTurn() {
        var activity = SessionActivity(id: "test")
        activity.consume(event("task_started", turn: "old", second: 1))
        activity.consume(event("task_started", turn: "new", second: 2))
        activity.consume(event("task_complete", turn: "old", second: 3))
        XCTAssertEqual(activity.phase, .running)
        XCTAssertEqual(activity.turnID, "new")
        activity.consume(event("task_complete", turn: "new", second: 4))
        XCTAssertEqual(activity.phase, .completed)
    }
    func testHeartbeatAloneDoesNotProveTaskIsRunning() {
        var activity = SessionActivity(id: "test")
        activity.consume(event("token_count", turn: "new", second: 1))
        XCTAssertEqual(activity.phase, .unknown)
    }
    func testLongSilentToolDoesNotEndObservedTurn() {
        var activity = SessionActivity(id: "test")
        activity.consume(event("task_started", turn: "new", second: 1))
        XCTAssertEqual(activity.observedPhase(at: activity.lastObserved!.addingTimeInterval(181)), .running)
        XCTAssertEqual(activity.phase, .running)
    }
    func testOutOfOrderStartIsIgnored() {
        var activity = SessionActivity(id: "test")
        activity.consume(event("task_started", turn: "new", second: 3))
        activity.consume(event("task_started", turn: "old", second: 1))
        XCTAssertEqual(activity.turnID, "new")
    }
    func testIncrementalReaderWaitsForCompleteLineAndHandlesTruncation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"
        let day = directory.appendingPathComponent("sessions/\(formatter.string(from: Date()))")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent("test.jsonl")
        var line = event("task_started", turn: "new", second: 1)
        try line.prefix(line.count - 2).write(to: file)
        let reader = LocalActivityReader(fileMetadata: { TestFileSystem().metadata($0) })
        let partial = await reader.read(home: directory)
        XCTAssertEqual(partial.activities.first?.phase, .unknown)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: line.suffix(2) + Data([10]))
        try handle.close()
        let complete = await reader.read(home: directory)
        XCTAssertEqual(complete.activities.first?.phase, .running)
        line = event("task_complete", turn: "other", second: 2)
        try (line + Data([10])).write(to: file, options: .atomic)
        let replaced = await reader.read(home: directory)
        XCTAssertEqual(replaced.activities.first?.phase, .unknown)
    }
    func testLongRolloutRecoversExplicitEndingWithoutAnUnreadNotification() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-ending-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let now = try XCTUnwrap(SessionActivity.parseDate("2026-10-01T00:00:05Z"))
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"
        let day = home.appendingPathComponent("sessions/" + formatter.string(from: now))
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let session = UUID().uuidString.lowercased(), turn = "historical-turn"
        let file = day.appendingPathComponent("rollout-\(session).jsonl")
        let header = try JSONSerialization.data(withJSONObject: ["timestamp": "2026-10-01T00:00:00Z", "type": "session_meta",
            "payload": ["id": session, "originator": "codex_cli_rs"]])
        var log = header + Data([10]) + event("task_started", turn: turn, second: 1) + Data([10])
        log += Data(repeating: 32, count: 8 * 1024 * 1024) + Data([10])
        log += event("token_count", turn: turn, second: 2) + Data([10])
        log += event("task_complete", turn: turn, second: 3) + Data([10])
        try log.write(to: file)

        let reader = LocalActivityReader(fileMetadata: { TestFileSystem().metadata($0) })
        let attached = await reader.read(home: home, now: now)
        let ended = try XCTUnwrap(attached.activities.first)
        XCTAssertEqual(ended.phase, .completed)
        XCTAssertEqual(ended.turnID, turn)
        XCTAssertNil(ended.turnStartedAt, "The missing start time must not be invented")
        XCTAssertTrue(ended.isHistoricalCompletion)
        var inbox = CompletionInbox()
        inbox.observe(attached.activities, at: now, retention: 900)
        XCTAssertFalse(inbox.isUnread(ended))

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: event("task_started", turn: "new-turn", second: 4) + Data([10]) +
            event("task_complete", turn: turn, second: 5) + Data([10]))
        try handle.close()
        let resumed = await reader.read(home: home, now: now, metricsOnly: true)
        XCTAssertEqual(resumed.activities.first?.phase, .running)
        XCTAssertEqual(resumed.activities.first?.turnID, "new-turn")
    }

    func testLiveRolloutRecoversEndingWhenAnAppendExceedsTheReadWindow() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-live-ending-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let now = try XCTUnwrap(SessionActivity.parseDate("2026-10-01T00:00:05Z"))
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"
        let day = home.appendingPathComponent("sessions/" + formatter.string(from: now))
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let session = UUID().uuidString.lowercased(), turn = "observed-turn"
        let file = day.appendingPathComponent("rollout-\(session).jsonl")
        let header = try JSONSerialization.data(withJSONObject: ["timestamp": "2026-10-01T00:00:00Z", "type": "session_meta",
            "payload": ["id": session, "originator": "codex_cli_rs"]])
        try (header + Data([10]) + event("task_started", turn: turn, second: 1) + Data([10])).write(to: file)

        let reader = LocalActivityReader(fileMetadata: { TestFileSystem().metadata($0) })
        let started = await reader.read(home: home, now: now)
        XCTAssertEqual(started.activities.first?.phase, .running)
        var inbox = CompletionInbox()
        inbox.observe(started.activities, at: now, retention: 900)

        // Large tool outputs can push the already observed start beyond the
        // recovery scan before the next file event reaches the reader.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"timestamp":"2026-10-01T00:00:02Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"large-tool","output":""#.utf8))
        try handle.write(contentsOf: Data(repeating: 120, count: 8 * 1024 * 1024))
        try handle.write(contentsOf: Data(#""}}"#.utf8) + Data([10]))
        let terminal = event("task_complete", turn: turn, second: 3)
        try handle.write(contentsOf: terminal.prefix(terminal.count - 2))
        try handle.close()

        let incomplete = await reader.read(home: home, now: now, metricsOnly: true)
        XCTAssertEqual(incomplete.activities.first?.phase, .unknown)
        let tail = try FileHandle(forWritingTo: file)
        try tail.seekToEnd()
        try tail.write(contentsOf: terminal.suffix(2) + Data([10]))
        try tail.close()

        let read = await reader.read(home: home, now: now, metricsOnly: true)
        let ended = try XCTUnwrap(read.activities.first)
        XCTAssertEqual(ended.phase, .completed)
        XCTAssertEqual(ended.turnID, turn)
        XCTAssertEqual(ended.turnStartedAt, started.activities.first?.turnStartedAt)
        XCTAssertFalse(ended.isHistoricalCompletion)
        inbox.observe(read.activities, at: now, retention: 900)
        XCTAssertTrue(inbox.isUnread(ended))
    }

    private func event(_ kind: String, turn: String, second: Int) -> Data {
        Data("{\"timestamp\":\"2026-10-01T00:00:0\(second)Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"\(kind)\",\"turn_id\":\"\(turn)\"}}".utf8)
    }
}
