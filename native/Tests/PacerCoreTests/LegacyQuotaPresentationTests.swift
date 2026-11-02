import XCTest
@testable import PacerCore

final class LegacyQuotaPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func snapshot(age: Double = 0, expired: Bool = false) -> QuotaSnapshot {
        QuotaSnapshot(buckets: [
            QuotaBucket(id: "codex", name: nil, plan: nil, windows: [
                QuotaWindow(id: "week", usedPercent: 20, durationMinutes: 10080, resetsAt: expired ? now : now.addingTimeInterval(302400))], credits: nil),
            QuotaBucket(id: "scoped", name: "Synthetic model", plan: nil, windows: [
                QuotaWindow(id: "eight", usedPercent: 70, durationMinutes: 480, resetsAt: now.addingTimeInterval(14400)),
                QuotaWindow(id: "unknown", usedPercent: nil, durationMinutes: nil, resetsAt: nil)], credits: nil)
        ], capturedAt: now.addingTimeInterval(-age), accountScope: "synthetic-private-account", resetCredits: nil)
    }
    func testLegacyKeepsEveryBucketAndNonstandardWindowWithoutAccountIdentity() throws {
        let reading = QuotaDashboardPresentation.Legacy(snapshot: snapshot(), now: now)
        XCTAssertTrue(reading.fresh)
        XCTAssertEqual(reading.buckets.map(\.id), ["codex", "scoped"])
        XCTAssertEqual(reading.buckets[1].title, "Synthetic model")
        XCTAssertEqual(reading.buckets.flatMap(\.windows).map(\.id), ["week", "eight", "unknown"])
        XCTAssertEqual(reading.buckets[0].windows[0].remainingPercent, 80)
        XCTAssertEqual(reading.buckets[1].windows[0].pacePercent, 60)
        XCTAssertNil(reading.buckets[1].windows[1].remainingPercent)
        XCTAssertEqual(reading.buckets[1].windows[1].valueText, "—")
        let bytes = try JSONEncoder().encode(reading)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("synthetic-private-account"))
    }
    func testFailedAgedAndExpiredLegacyReadingsKeepValuesAndRemoveLiveReferences() {
        let fresh = snapshot()
        for reading in [QuotaDashboardPresentation.Legacy(snapshot: fresh, failed: true, now: now),
            .init(snapshot: snapshot(age: 301), now: now), .init(snapshot: snapshot(expired: true), now: now)] {
            XCTAssertFalse(reading.fresh)
            XCTAssertEqual(reading.buckets[0].windows[0].remainingPercent, 80)
            XCTAssertTrue(reading.buckets.flatMap(\.windows).allSatisfy { $0.pacePercent == nil && $0.remainingTimePercent == nil })
        }
        let weeklyFallback = QuotaDashboardPresentation.Legacy(snapshot: fresh, selectedWindowID: "5h", now: now)
        XCTAssertTrue(weeklyFallback.fresh, "A missing saved 5h window must follow the original weekly fallback")
    }
}
