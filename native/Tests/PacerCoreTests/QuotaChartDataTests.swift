import XCTest
@testable import PacerCore

final class QuotaChartDataTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private var cycle: QuotaCycle {
        QuotaCycle(id: "weekly", bucketName: nil, startedAt: start,
            resetsAt: start.addingTimeInterval(604800), points: [
                QuotaPoint(timestamp: start, remaining: 100),
                QuotaPoint(timestamp: start.addingTimeInterval(30), remaining: 90)
            ])
    }
    private func credit(_ id: String, at seconds: Double, status: String = "available") -> QuotaResetCredit {
        QuotaResetCredit(id: id, status: status, expiresAt: start.addingTimeInterval(seconds), grantedAt: start)
    }

    func testClockChangesDoNotInvalidateChartUntilAnExpiryBoundary() {
        let credits = QuotaResetSummary(availableCount: 1, credits: [credit("reset", at: 60)])
        let initial = QuotaChartData(cycle: cycle, resetCredits: credits, now: start)
        XCTAssertEqual(initial, QuotaChartData(cycle: cycle, resetCredits: credits, now: start.addingTimeInterval(59.999)))
        let expired = QuotaChartData(cycle: cycle, resetCredits: credits, now: start.addingTimeInterval(60))
        XCTAssertNotEqual(initial, expired)
        XCTAssertTrue(expired.expiries.isEmpty)
        XCTAssertEqual(initial.points, expired.points)
    }

    func testExpiryMarkersKeepCountsDatesAndCurrentCycleBoundaries() {
        let credits = QuotaResetSummary(availableCount: 6, credits: [
            credit("first", at: 60), credit("first", at: 60), credit("second", at: 60),
            credit("end", at: 604800), credit("next-cycle", at: 604801),
            credit("used", at: 70, status: "used"), credit("past", at: -1)
        ])
        let data = QuotaChartData(cycle: cycle, resetCredits: credits, now: start)
        XCTAssertEqual(data.expiries.map(\.date), [start.addingTimeInterval(60), cycle.resetsAt])
        XCTAssertEqual(data.expiries.map(\.count), [2, 1])
    }

    func testNewPointsCycleAndExpiryDetailChangesInvalidateChart() {
        let credits = QuotaResetSummary(availableCount: 1, credits: [credit("reset", at: 60)])
        let original = QuotaChartData(cycle: cycle, resetCredits: credits, now: start)
        var updated = cycle
        updated.points.append(QuotaPoint(timestamp: start.addingTimeInterval(31), remaining: 89))
        XCTAssertNotEqual(original, QuotaChartData(cycle: updated, resetCredits: credits, now: start))
        let nextCycle = QuotaCycle(id: "weekly", bucketName: nil, startedAt: start.addingTimeInterval(30),
            resetsAt: cycle.resetsAt.addingTimeInterval(30), points: cycle.points)
        XCTAssertNotEqual(original, QuotaChartData(cycle: nextCycle, resetCredits: credits, now: start))
        let incomplete = QuotaResetSummary(availableCount: 2, credits: credits.credits)
        let partial = QuotaChartData(cycle: cycle, resetCredits: incomplete, now: start)
        XCTAssertNotEqual(original, partial)
        XCTAssertTrue(partial.hasPartialExpiryDetails)
        let used = QuotaResetSummary(availableCount: 0, credits: [credit("reset", at: 60, status: "used")])
        XCTAssertTrue(QuotaChartData(cycle: cycle, resetCredits: used, now: start).expiries.isEmpty)
    }
}
