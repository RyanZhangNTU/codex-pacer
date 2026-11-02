import Foundation
import XCTest
@testable import PacerCore

final class NoticeScenarioTableTests: XCTestCase {
    private typealias F = PresentationScenarioFixtures
    private struct WarningRow: Decodable {
        let provider: String, remaining: Double, age: Double, expired: Bool, failed: Bool, delayed: [String], kinds: [String], solid: Bool
    }
    private struct Transition: Decodable {
        let balance: Double, spent: Double, stale: Bool, low: Bool, budget: Bool, balanceIDs: [String], spendIDs: [String]
    }
    private struct Table: Decodable { let warnings: [WarningRow], transitions: [Transition] }
    private func snapshot(_ provider: AgentProvider, remaining: Double, age: Double, expired: Bool) -> QuotaSnapshot {
        F.snapshot(provider, windows: [
            .init(id: "five", usedPercent: 100 - remaining, durationMinutes: 300, resetsAt: F.now.addingTimeInterval(expired ? -1 : 3600)),
            .init(id: "week", usedPercent: 50, durationMinutes: 10080, resetsAt: F.now.addingTimeInterval(expired ? -1 : 86400))], age: age)
    }
    func testBothProvidersAtEveryWarningBoundaryAndFailureState() throws {
        let table = try F.table("notices", as: Table.self)
        XCTAssertEqual(table.warnings.count, 24)
        let otherClaude = try F.demoQuota(.claude)
        for row in table.warnings {
            let provider = try XCTUnwrap(AgentProvider(rawValue: row.provider))
            let own = snapshot(provider, remaining: row.remaining, age: row.age, expired: row.expired)
            let snapshots: [AgentProvider: QuotaSnapshot] = [.codex: provider == .codex ? own : snapshot(.codex, remaining: 0, age: 0, expired: false),
                .claude: provider == .claude ? own : otherClaude]
            var failed: Set<AgentProvider> = provider == .claude ? [.codex] : []
            if row.failed { failed.insert(provider) }
            let values = CompactWarningPresentation.items(enabled: [.codex, .claude], warnings: [.fiveHour, .ssh, .quotaDelay],
                snapshots: snapshots, failed: failed, sshIssue: false, now: F.now)
            let label = "\(row.provider)/\(row.remaining)/\(row.age)/expired=\(row.expired)/failed=\(row.failed)"
            XCTAssertEqual(values.map(\.kind.rawValue), row.kinds, label)
            XCTAssertEqual(values.first { $0.kind == .quotaDelay }?.affectedProviders ?? [], row.delayed, label)
            let mark = values.first { $0.kind == .fiveHour && $0.provider == row.provider }
            if row.kinds.contains("fiveHour") {
                XCTAssertEqual(try XCTUnwrap(mark).solid, row.solid, label)
                XCTAssertEqual(mark?.label, "5h", label)
                let help = row.solid ? L10n.text("quota.five_hour_exhausted", provider.displayName)
                    : L10n.text("quota.five_hour_low", provider.displayName, "20%")
                XCTAssertEqual(mark?.help, help, label)
            } else { XCTAssertNil(mark, label) }
        }
    }
    func testAllNineNotificationTransitionsHaveFixedIDsMessagesCategoriesAndOrder() throws {
        let rows = try F.table("notices", as: Table.self).transitions
        XCTAssertEqual(rows.count, 9)
        var policy = DeepSeekNoticePolicy()
        for (index, row) in rows.enumerated() {
            let date = F.now.addingTimeInterval(Double(index))
            var ledger = DeepSeekSpendLedger()
            ledger.record(id: "synthetic", at: date.addingTimeInterval(-60), cost: row.spent)
            let wallet = DeepSeekWallet(balance: .init(total: row.balance, capturedAt: date.addingTimeInterval(row.stale ? -601 : 0), source: .web),
                connected: true, ledger: ledger, now: date, budgets: .init(daily: 10, weekly: 50), spikeLimit: 5, calendar: F.calendar)
            let balances = policy.balanceNotices(wallet, low: row.low)
            let expectedBalances = row.balanceIDs.map { kind in
                IslandNotice(id: "deepseek:balance:" + kind, kind: .lowQuota,
                    title: "DeepSeek · " + L10n.text("deepseek.notice." + kind),
                    detail: kind == "exhausted" ? L10n.text("deepseek.notice.exhausted_detail") : L10n.text("deepseek.notice.low_detail", row.balance == 9 ? "¥9.00" : "¥5.00"),
                    category: "deepseek.balance")
            }
            XCTAssertEqual(balances, expectedBalances, "transition \(index)")
            let snooze = index < 3 ? F.now.addingTimeInterval(3600) : Date.distantPast
            let spend = policy.spendNotices(wallet, spike: true, budget: row.budget, snoozedUntil: snooze, now: date)
            let expected = row.spendIDs.map { kind -> IslandNotice in
                if kind == "spike" {
                    return .init(id: "deepseek:spike", kind: .lowQuota, title: "DeepSeek · " + L10n.text("deepseek.notice.spike"),
                        detail: L10n.text("deepseek.notice.spike_detail", row.spent == 9 ? "¥9.00" : "¥6.00", "¥5.00"), category: "deepseek.spike")
                }
                let over = kind == "day:2"
                return .init(id: "deepseek:budget:day1799971200:" + (over ? "2" : "1"), kind: .lowQuota,
                    title: "DeepSeek · " + L10n.text(over ? "deepseek.notice.day_over" : "deepseek.notice.day_near"),
                    detail: L10n.text("deepseek.notice.budget_detail_day", over ? "¥10.10" : "¥9.00", "¥10.00"))
            }
            XCTAssertEqual(spend, expected, "transition \(index)")
        }
    }
}
