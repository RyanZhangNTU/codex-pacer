import Foundation
import XCTest
@testable import PacerCore

final class DeepSeekNoticePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func wallet(spent: Double = 0, balance: Double? = nil, at date: Date? = nil, stale: Bool = false) -> DeepSeekWallet {
        let date = date ?? now
        var ledger = DeepSeekSpendLedger()
        ledger.record(id: "synthetic-response", at: date.addingTimeInterval(-60), cost: spent)
        let reading = balance.map { DeepSeekBalance(total: $0, capturedAt: date.addingTimeInterval(stale ? -601 : 0), source: .web) }
        return DeepSeekWallet(balance: reading, connected: reading != nil, ledger: ledger, now: date, budgets: .init(daily: 10), spikeLimit: 5)
    }
    func testBalancesNotifyOnceAndExhaustionDoesNotNeedTheLowBalanceSwitch() {
        var policy = DeepSeekNoticePolicy()
        XCTAssertEqual(policy.balanceNotices(wallet(balance: 9)).map(\.category), [DeepSeekNoticePolicy.balanceCategory])
        XCTAssertTrue(policy.balanceNotices(wallet(balance: 8)).isEmpty)
        XCTAssertEqual(policy.balanceNotices(wallet(balance: 0), low: false).count, 1)
        XCTAssertTrue(policy.balanceNotices(wallet(balance: 5)).isEmpty)
        XCTAssertTrue(policy.balanceNotices(wallet(balance: 5, stale: true)).isEmpty)
        XCTAssertTrue(policy.balanceNotices(wallet(balance: 20)).isEmpty)
        XCTAssertEqual(policy.balanceNotices(wallet(balance: 5)).count, 1)
    }
    func testStartupSpendIsQuietThenBudgetCrossingsNotifyEvenWithoutAnAccount() {
        var policy = DeepSeekNoticePolicy()
        func spend(_ value: Double, _ date: Date) -> [IslandNotice] {
            policy.spendNotices(wallet(spent: value, at: date), spike: false, budget: true, snoozedUntil: .distantPast, now: date)
        }
        XCTAssertTrue(spend(9, now).isEmpty, "A relaunch already over the near line must establish its baseline")
        XCTAssertTrue(spend(9.5, now).isEmpty)
        let crossed = spend(10.1, now)
        XCTAssertEqual(crossed.count, 1); XCTAssertTrue(crossed[0].id.hasPrefix("deepseek:budget:day"))
        XCTAssertNil(crossed[0].category)
        XCTAssertTrue(spend(11, now).isEmpty)
        let tomorrow = now.addingTimeInterval(86400)
        XCTAssertTrue(spend(2, tomorrow).isEmpty)
        XCTAssertEqual(spend(8.1, tomorrow).count, 1, "A new period gets its own near threshold")
    }
    func testSnoozeAndDisabledKindsStillAdvanceTheirBaselines() {
        var policy = DeepSeekNoticePolicy()
        func spend(_ value: Double, _ date: Date, spike: Bool = true, budget: Bool = false, until: Date = .distantPast) -> [IslandNotice] {
            policy.spendNotices(wallet(spent: value, at: date), spike: spike, budget: budget, snoozedUntil: until, now: date)
        }
        XCTAssertTrue(spend(2, now).isEmpty)
        XCTAssertTrue(spend(6, now, until: now.addingTimeInterval(3600)).isEmpty)
        XCTAssertTrue(spend(6, now.addingTimeInterval(3601)).isEmpty, "The end of a snooze does not replay an ongoing spike")
        XCTAssertTrue(spend(2, now.addingTimeInterval(3602)).isEmpty)
        XCTAssertEqual(spend(6, now.addingTimeInterval(3603)).first?.category, DeepSeekNoticePolicy.spikeCategory)
        XCTAssertTrue(spend(9, now.addingTimeInterval(3604), spike: false, budget: false).isEmpty)
        XCTAssertTrue(spend(9, now.addingTimeInterval(3605), spike: false, budget: true).isEmpty, "Enabling a kind must not replay a crossing observed while off")
    }
}
