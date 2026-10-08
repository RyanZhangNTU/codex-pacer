import XCTest
@testable import PacerCore
@testable import PacerIsland

@MainActor
final class RateDisplayTests: XCTestCase {
    private func activity(at report: Date) throws -> SessionActivity {
        let id = "019a0000-0000-7000-8000-000000000001"
        var runtime = RuntimeEventState(sourceID: nil, sourceName: nil)
        runtime.consume(["kind": "status", "connected": true])
        for (method, offset, total) in [("turn/started", -2.0, 100), ("thread/tokenUsage/updated", -2.0, 100),
                                       ("thread/tokenUsage/updated", 0.0, 120)] {
            runtime.consume(["kind": "runtime", "event": ["method": method, "threadId": id, "turnId": "turn",
                "at": report.addingTimeInterval(offset).timeIntervalSince1970, "outputTokens": total]])
        }
        return try XCTUnwrap(runtime.activities.first)
    }
    func testCollapsedRateBecomesStaleWithoutAnotherSourceEventOrPeriodicClock() async throws {
        let model = IslandModel()
        let now = Date()
        model.now = now
        model.activities = [try activity(at: now.addingTimeInterval(-14.5))]
        XCTAssertFalse(model.expanded)
        XCTAssertEqual(model.rate, 10)
        XCTAssertTrue(model.rateIsFresh)
        let stale = expectation(description: "retained rate becomes stale without polling")
        model.onStatusChange = { if !model.rateIsFresh { stale.fulfill() } }
        // Deliberately never call start(): no quota, file, SSH or periodic-clock work.
        await fulfillment(of: [stale], timeout: 2)
        XCTAssertEqual(model.rate, 10, "Freshness expiry must retain the last measured speed")
        XCTAssertFalse(model.rateIsFresh)
        XCTAssertEqual(model.running.count, 1, "Freshness expiry must not change task lifecycle")
        model.onStatusChange = nil
        await model.shutdown()
    }
    func testNewReportReplacesThePendingExpiryAndCompletionRemovesRateFromActiveTotal() async throws {
        let model = IslandModel()
        let now = Date()
        model.now = now
        model.activities = [try activity(at: now.addingTimeInterval(-14.5))]
        let noOldExpiry = expectation(description: "old estimate deadline is cancelled")
        noOldExpiry.isInverted = true
        model.onStatusChange = { noOldExpiry.fulfill() }
        // Production stamps UI time after decoding epoch timestamps. Keep the
        // fixture behind that clock too, avoiding sub-microsecond Date rounding.
        model.activities = [try activity(at: now.addingTimeInterval(-1))]
        await fulfillment(of: [noOldExpiry], timeout: 0.8)
        XCTAssertEqual(model.rate, 10)
        XCTAssertTrue(model.rateIsFresh)
        var ended = try activity(at: now.addingTimeInterval(-1))
        ended.consumeLive(["method": "turn/completed", "threadId": ended.threadID!, "turnId": "turn",
            "at": now.timeIntervalSince1970])
        model.activities = [ended]
        XCTAssertNil(model.rate, "Ended tasks must not contribute to the active total")
        XCTAssertEqual(ended.displayedOutputEstimate(at: model.now)?.value, 10, "The completion card retains its measured rate")
        model.activities = []
        XCTAssertNil(model.rate)
        model.onStatusChange = nil
        await model.shutdown()
    }
}
