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
    private func event(_ kind: String, turn: String, second: Int) -> Data {
        Data("{\"timestamp\":\"2026-10-01T00:00:0\(second)Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"\(kind)\",\"turn_id\":\"\(turn)\"}}".utf8)
    }
}
