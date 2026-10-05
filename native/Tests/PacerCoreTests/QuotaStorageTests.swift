import XCTest
@testable import PacerCore

final class QuotaStorageTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    private func snapshot(_ seconds: Double, remaining: Double = 80, scope: String = "test-account",
                          reset: Double = 604800) throws -> QuotaSnapshot {
        let object: [String: Any] = ["rateLimits": ["secondary": ["usedPercent": 100 - remaining,
            "windowDurationMins": 10080, "resetsAt": epoch.timeIntervalSince1970 + reset]]]
        var value = try QuotaSnapshot.decode(JSONSerialization.data(withJSONObject: object), capturedAt: epoch.addingTimeInterval(seconds))
        value.accountScope = scope
        return value
    }
    func testFrequentReadingsKeepEndpointsAndOnlyCoarseHistory() throws {
        var history = QuotaCycleHistory()
        for seconds in stride(from: 0, through: 604_770, by: 30) {
            history.record(try snapshot(Double(seconds), remaining: 80 - Double(seconds) / 10000))
        }
        let cycle = try XCTUnwrap(history.cycles.first)
        XCTAssertLessThanOrEqual(cycle.points.count, QuotaCycleHistory.maximumPoints)
        XCTAssertEqual(cycle.points.first?.timestamp, epoch)
        XCTAssertEqual(cycle.points.last?.timestamp, epoch.addingTimeInterval(604770))
        XCTAssertEqual(try XCTUnwrap(cycle.points.last?.remaining), 80 - 604770.0 / 10000, accuracy: 1e-9)
        XCTAssertEqual(cycle.points.count, 2017)
    }
    func testCurrentReadingRemainsVisibleInsideSamplingInterval() throws {
        var history = QuotaCycleHistory()
        history.record(try snapshot(0))
        history.record(try snapshot(30, remaining: 79))
        history.record(try snapshot(60, remaining: 78))
        XCTAssertEqual(history.cycles[0].points.count, 2)
        XCTAssertEqual(history.cycles[0].points.first?.remaining, 80)
        XCTAssertEqual(history.cycles[0].points.last?.remaining, 78)
        history.record(try snapshot(299, remaining: 77.5))
        XCTAssertEqual(history.cycles[0].points.count, 2)
        XCTAssertEqual(history.cycles[0].points.last?.timestamp, epoch.addingTimeInterval(299))
        history.record(try snapshot(300, remaining: 77))
        XCTAssertEqual(history.cycles[0].points.count, 3)
    }
    func testDeferredWritesFlushLatestReadingOnShutdownOrDeadline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = URL(fileURLWithPath: "/synthetic-home")
        let store = QuotaHistoryStore(directory: directory)
        let cache = QuotaCycleCache(directory: directory)
        var history = QuotaCycleHistory()
        let first = try snapshot(0); history.record(first)
        let initialSaved = await store.save(home: home, snapshot: first, history: history, now: epoch)
        XCTAssertTrue(initialSaved)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let initial = try Data(contentsOf: file)
        for seconds in stride(from: 30, through: 1770, by: 30) {
            let reading = try snapshot(Double(seconds), remaining: 79)
            history.record(reading)
            let scheduled = await store.save(home: home, snapshot: reading, history: history,
                                             now: epoch.addingTimeInterval(Double(seconds)))
            XCTAssertTrue(scheduled)
        }
        XCTAssertEqual(try Data(contentsOf: file), initial)
        let flushed = await store.flush(at: epoch.addingTimeInterval(1780))
        XCTAssertTrue(flushed)
        XCTAssertEqual(cache.load(home: home, accountScope: "test-account", now: epoch.addingTimeInterval(1780))?.0.capturedAt,
                       epoch.addingTimeInterval(1770))
        let flushedBytes = try Data(contentsOf: file)
        let beforeDeadline = try snapshot(3579); history.record(beforeDeadline)
        let queued = await store.save(home: home, snapshot: beforeDeadline, history: history,
                                      now: beforeDeadline.capturedAt)
        XCTAssertTrue(queued)
        XCTAssertEqual(try Data(contentsOf: file), flushedBytes)
        let later = try snapshot(3580); history.record(later)
        let savedAtDeadline = await store.save(home: home, snapshot: later, history: history,
                                               now: epoch.addingTimeInterval(3580))
        XCTAssertTrue(savedAtDeadline)
        XCTAssertEqual(cache.load(home: home, accountScope: "test-account", now: epoch.addingTimeInterval(3580))?.0.capturedAt,
                       later.capturedAt)
    }
    func testAccountAndResetChangesCommitImmediatelyWithoutMixingHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = URL(fileURLWithPath: "/synthetic-home")
        let store = QuotaHistoryStore(directory: directory), cache = QuotaCycleCache(directory: directory)
        var history = QuotaCycleHistory()
        for reading in [try snapshot(0), try snapshot(30, remaining: 79),
                        try snapshot(60, remaining: 100, reset: 604860),
                        try snapshot(90, remaining: 70, scope: "other-account", reset: 604860)] {
            history.record(reading)
            let saved = await store.save(home: home, snapshot: reading, history: history, now: reading.capturedAt)
            XCTAssertTrue(saved)
        }
        XCTAssertNil(cache.load(home: home, accountScope: "test-account", now: epoch.addingTimeInterval(90)))
        let restored = try XCTUnwrap(cache.load(home: home, accountScope: "other-account", now: epoch.addingTimeInterval(90)))
        XCTAssertEqual(restored.1.cycles[0].points.count, 1)
        XCTAssertEqual(restored.1.cycles[0].points[0].remaining, 70)
    }
    func testLegacyFineHistoryLoadsAsBoundedCoarseCurveWithoutWriting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = URL(fileURLWithPath: "/synthetic-home"), cache = QuotaCycleCache(directory: directory)
        let reading = try snapshot(3000)
        var history = QuotaCycleHistory(); history.record(reading)
        try cache.save(home: home, snapshot: reading, history: history)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var stored = try XCTUnwrap(envelope["history"] as? [String: Any])
        var cycles = try XCTUnwrap(stored["cycles"] as? [[String: Any]])
        cycles[0]["points"] = (0...3000).map { ["timestamp": epoch.addingTimeInterval(Double($0)).timeIntervalSinceReferenceDate,
                                             "remaining": 80.0 - Double($0) / 1000] }
        stored["cycles"] = cycles; envelope["history"] = stored
        let bytes = try JSONSerialization.data(withJSONObject: envelope); try bytes.write(to: file)
        let restored = try XCTUnwrap(cache.load(home: home, accountScope: "test-account", now: reading.capturedAt))
        XCTAssertEqual(restored.1.cycles[0].points.count, 12)
        XCTAssertEqual(restored.1.cycles[0].points.first?.timestamp, epoch)
        XCTAssertEqual(restored.1.cycles[0].points.last?.timestamp, reading.capturedAt)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
}
