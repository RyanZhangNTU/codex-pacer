import Foundation
import XCTest
@testable import PacerCore

final class QuotaHistoryScenarioTableTests: XCTestCase {
    private typealias F = PresentationScenarioFixtures
    private struct Point: Decodable { let fraction: Double, remaining: Double }
    private struct Row: Decodable {
        let provider: AgentProvider, kind: String, failed: Bool, refreshing: Bool, attachChart: Bool
        let buckets: [String], points: [Double]?, account: Bool, paces: [Double?], notUpdated: Bool
        let freshness: F.Text, placeholder: String?
    }
    private struct Table: Decodable { let trace: [Point], cases: [Row] }
    func testEveryHistoryInputErrorRefreshAndChartCombinationHasFixedProjection() throws {
        let table = try F.table("quota-history", as: Table.self)
        XCTAssertEqual(table.cases.count, 48)
        for row in table.cases {
            let snapshot: QuotaSnapshot?
            var history = QuotaCycleHistory()
            switch row.kind {
            case "unread": snapshot = nil
            case "demo":
                let start = F.now.addingTimeInterval(-417600)
                for point in table.trace {
                    let remaining = row.provider == .codex ? point.remaining : min(100, point.remaining + 21)
                    history.record(try F.demoQuota(row.provider, weeklyRemaining: remaining,
                        capturedAt: start.addingTimeInterval(417600 * point.fraction)))
                }
                snapshot = try F.demoQuota(row.provider)
            case "unusual":
                snapshot = F.snapshot(row.provider, windows: [
                    .init(id: "expired-five", usedPercent: 20, durationMinutes: 300, resetsAt: F.now),
                    .init(id: "active-week", usedPercent: 40, durationMinutes: 10080, resetsAt: F.now.addingTimeInterval(86400))], emptyBucket: true)
                history.record(try XCTUnwrap(snapshot))
            default: XCTFail("Unknown table input"); continue
            }
            let weekly = QuotaDashboardPresentation.Reading(provider: row.provider, period: .weekly, snapshot: snapshot,
                failed: row.failed, refreshing: row.refreshing,
                sourceText: row.provider == .codex && snapshot != nil ? L10n.text("quota.source_codex") : nil, now: F.now)
            let cycle = history.currentCycle(for: weekly.window, at: F.now)
            let chart = row.attachChart ? cycle.map { QuotaCycleChartPresentation(data: .init(cycle: $0, resetCredits: snapshot?.resetCredits, now: F.now)) } : nil
            let value = QuotaHistoryPresentation(provider: row.provider, snapshot: snapshot, weekly: weekly, chart: chart,
                error: row.failed ? "Synthetic failure" : nil, warning: nil, refreshing: row.refreshing, accountContext: "opaque", now: F.now)
            let label = "\(row.provider)/\(row.kind)/failed=\(row.failed)/refresh=\(row.refreshing)/chart=\(row.attachChart)"
            XCTAssertEqual(value.title, L10n.text("settings.quota_history", row.provider.displayName), label)
            XCTAssertEqual(value.sourceText, row.provider == .codex && snapshot != nil ? L10n.text("quota.source_codex") : nil, label)
            XCTAssertEqual(value.freshnessText, row.freshness.render(), label)
            XCTAssertEqual(value.notUpdated, row.notUpdated, label)
            XCTAssertEqual(value.errorText, row.failed ? "Synthetic failure" : nil, label)
            XCTAssertEqual(value.refreshing, row.refreshing, label)
            XCTAssertEqual(value.refreshTitle, L10n.text(row.refreshing ? "common.retrying" : "common.refresh"), label)
            XCTAssertEqual(value.buckets.map(\.id), row.buckets, label)
            XCTAssertEqual(value.chart?.points.map(\.remaining), row.points, label)
            XCTAssertEqual(value.account != nil, row.account, label)
            XCTAssertEqual(value.placeholder, row.placeholder.map { $0 == "quota.not_connected" ? L10n.text($0, row.provider.displayName) : L10n.text($0) }, label)
            let windows = value.buckets.flatMap(\.windows)
            XCTAssertEqual(windows.count, row.paces.count, label)
            for (actual, expected) in zip(windows, row.paces) { F.equal(actual.pacePercent, expected, label) }
            if row.kind == "unusual" {
                XCTAssertTrue(try XCTUnwrap(value.buckets.last).windows.isEmpty, label)
                XCTAssertNil(windows.first?.pacePercent, label)
            }
            if row.kind == "demo", row.provider == .codex {
                XCTAssertEqual(value.account?.expiries.count, 2, label)
                if row.attachChart { XCTAssertEqual(value.chart?.expiries.map(\.count), [1, 1], label) }
            }
        }
    }
}
