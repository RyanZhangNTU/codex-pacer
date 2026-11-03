import XCTest
@testable import PacerCore

final class QuotaConnectionPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var snapshot: QuotaSnapshot {
        QuotaSnapshot(buckets: [QuotaBucket(id: "codex", name: nil, plan: nil,
            windows: [QuotaWindow(id: "week", usedPercent: 60, durationMinutes: 10080, resetsAt: now.addingTimeInterval(302400))], credits: nil)],
            capturedAt: now, accountScope: "synthetic-private-account", resetCredits: nil)
    }
    func testAReportedWindowHidesRecoveryWithoutRequiringASelectedPeriod() {
        for refreshing in [false, true] {
            let view = QuotaConnectionPresentation(provider: .codex, snapshot: snapshot, error: nil, refreshing: refreshing)
            XCTAssertEqual(view.state, .hidden); XCTAssertNil(view.message); XCTAssertTrue(view.actions.isEmpty)
        }
    }
    func testUnreadAndEmptyQuotaExposeSettingsAndPreserveLoadingState() {
        let empty = QuotaSnapshot(buckets: [], capturedAt: now, accountScope: nil, resetCredits: nil)
        for snapshot in [nil, empty] as [QuotaSnapshot?] {
            for refreshing in [false, true] {
                let view = QuotaConnectionPresentation(provider: .claude, snapshot: snapshot, error: nil, refreshing: refreshing)
                XCTAssertEqual(view.state, refreshing ? .loading : .unavailable)
                XCTAssertEqual(view.actions.map(\.kind), [.settings]); XCTAssertEqual(view.actions.first?.enabled, true)
                XCTAssertNotNil(view.message)
            }
        }
    }
    func testFailureTakesPrecedenceAndRefreshingOnlyDisablesRetry() throws {
        for snapshot in [nil, snapshot] as [QuotaSnapshot?] {
            for refreshing in [false, true] {
                let view = QuotaConnectionPresentation(provider: .codex, snapshot: snapshot, error: "Synthetic failure", refreshing: refreshing)
                XCTAssertEqual(view.state, .error); XCTAssertEqual(view.message, "Synthetic failure")
                XCTAssertEqual(view.actions.map(\.kind), [.retry, .settings])
                XCTAssertEqual(view.actions.map(\.enabled), [!refreshing, true])
                XCTAssertFalse(String(decoding: try JSONEncoder().encode(view), as: UTF8.self).contains("synthetic-private-account"))
            }
        }
    }
}
