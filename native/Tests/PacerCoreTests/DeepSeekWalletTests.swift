import XCTest
@testable import PacerCore

final class DeepSeekWalletTests: XCTestCase {
    private var beijing: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = DeepSeekPricing.beijing
        return calendar
    }
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        beijing.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testBalanceRepliesReduceToYuanAndConnectionErrorsAskToReconnect() throws {
        let now = date(27, 10, 41)
        let api = try DeepSeekBalance.api(Data(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"3.00"},{"currency":"CNY","total_balance":"86.40","granted_balance":"6.40","topped_up_balance":"80.00"}]}"#.utf8), at: now)
        XCTAssertEqual(api.total, 86.4, accuracy: 0.001)
        XCTAssertEqual(api.granted ?? 0, 6.4, accuracy: 0.001)
        XCTAssertEqual(api.source, .apiKey)
        XCTAssertNil(api.alertBound, "Only the platform page reports an alert line")
        XCTAssertFalse(try DeepSeekBalance.api(Data(#"{"is_available":false,"balance_infos":[{"currency":"CNY","total_balance":"1.20"}]}"#.utf8)).available)
        XCTAssertThrowsError(try DeepSeekBalance.api(Data(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"3.00"}]}"#.utf8))) {
            XCTAssertEqual($0 as? DeepSeekBalanceError, .unsupportedCurrency)
        }
        for invalid in [#"{}"#, #"{"balance_infos":[{"currency":"CNY","total_balance":"-1"}]}"#, "broken"] {
            XCTAssertThrowsError(try DeepSeekBalance.api(Data(invalid.utf8))) { XCTAssertEqual($0 as? DeepSeekBalanceError, .invalidReply) }
        }

        let web = try DeepSeekBalance.web(["state": "ok", "normal": ["80.00"], "bonus": [6.4], "estimation": 21_600_000,
            "alertEnabled": true, "alertBound": "20"], at: now)
        XCTAssertEqual(web.total, 86.4, accuracy: 0.001)
        XCTAssertEqual(web.granted ?? 0, 6.4, accuracy: 0.001)
        XCTAssertEqual(web.tokenEstimation, 21_600_000)
        XCTAssertEqual(web.alertBound, 20)
        XCTAssertNil(try DeepSeekBalance.web(["state": "ok", "normal": ["5"], "alertEnabled": false, "alertBound": "20"]).alertBound,
            "A disabled platform alert does not replace Pacer's own line")
        for (state, error) in [("signedOut", DeepSeekBalanceError.signedOut), ("challenge", .challenge), ("mystery", .invalidReply)] {
            XCTAssertThrowsError(try DeepSeekBalance.web(["state": state])) { XCTAssertEqual($0 as? DeepSeekBalanceError, error) }
        }
        XCTAssertThrowsError(try DeepSeekBalance.web(["state": "ok", "otherCurrency": true])) {
            XCTAssertEqual($0 as? DeepSeekBalanceError, .unsupportedCurrency)
        }
        XCTAssertTrue(DeepSeekBalanceError.signedOut.needsConnection)
        XCTAssertTrue(DeepSeekBalanceError.invalidKey.needsConnection)
        XCTAssertFalse(DeepSeekBalanceError.connectionFailed.needsConnection, "A network failure retries instead of asking to sign in")

        XCTAssertEqual(DeepSeekAPIKeyStore.validated("  sk-0123456789abcdef0123 \n"), "sk-0123456789abcdef0123")
        XCTAssertNil(DeepSeekAPIKeyStore.validated("sk-short"))
        XCTAssertNil(DeepSeekAPIKeyStore.validated("sk-0123456789 abcdef0123"))
        XCTAssertNil(DeepSeekAPIKeyStore.validated("sk-0123456789abcdef0123\"};"))
    }

    func testWalletFollowsTheDayItsAlertLineAndItsRunway() {
        let calendar = beijing, now = date(27, 10, 41) // A Tuesday, inside the morning peak.
        var ledger = DeepSeekSpendLedger()
        for day in 1...7 {
            let start = calendar.date(byAdding: .day, value: -day, to: calendar.startOfDay(for: now))!
            ledger.record(id: "morning-\(day)", at: start.addingTimeInterval(9 * 3600 + 41 * 60), cost: 1)
            ledger.record(id: "evening-\(day)", at: start.addingTimeInterval(20 * 3600), cost: 2)
        }
        ledger.record(id: "night", at: date(27, 1), cost: 0.5)
        ledger.record(id: "peak", at: date(27, 10), cost: 3)
        ledger.record(id: "peak", at: date(27, 10), cost: 3)
        let wallet = DeepSeekWallet(balance: DeepSeekBalance(total: 86.4, capturedAt: now, source: .web), connected: true,
            ledger: ledger, now: now, calendar: calendar)
        XCTAssertEqual(wallet.today, 3.5, accuracy: 0.001, "A response read twice is counted once")
        XCTAssertEqual(wallet.todayPeak, 3, accuracy: 0.001)
        XCTAssertEqual(wallet.hourly[1], 0.5, accuracy: 0.001)
        XCTAssertEqual(wallet.hourly[10], 3, accuracy: 0.001)
        XCTAssertEqual(wallet.typicalByNow ?? 0, 1, accuracy: 0.001, "Only spend before this time of day counts as usual")
        XCTAssertTrue(wallet.spendingFast)
        XCTAssertEqual(wallet.days.count, 7)
        XCTAssertEqual(wallet.days.last?.total ?? 0, 3.5, accuracy: 0.001)
        XCTAssertEqual(wallet.days.first?.peak ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(wallet.averageDaily ?? 0, 24.5 / (7 + 1.0 / 24), accuracy: 0.01)
        XCTAssertEqual(wallet.state, .normal)
        XCTAssertEqual(wallet.runwayDays ?? 0, 86.4 / (24.5 / (7 + 1.0 / 24)), accuracy: 0.1)
        XCTAssertTrue(wallet.peakNow)
        XCTAssertEqual(wallet.nextPriceChange, date(27, 12))
        XCTAssertEqual(wallet.peakToday, [DateInterval(start: date(27, 9), end: date(27, 12)), DateInterval(start: date(27, 14), end: date(27, 18))])

        func state(_ balance: DeepSeekBalance?, connected: Bool = true, threshold: Double = 10) -> DeepSeekWallet.State {
            DeepSeekWallet(balance: balance, connected: connected, ledger: DeepSeekSpendLedger(), now: now, lowThreshold: threshold, calendar: calendar).state
        }
        XCTAssertEqual(state(DeepSeekBalance(total: 8.4, capturedAt: now, source: .apiKey)), .low)
        XCTAssertEqual(state(DeepSeekBalance(total: 20, alertBound: 5, capturedAt: now, source: .web), threshold: 30), .normal,
            "The platform's own alert line replaces Pacer's")
        XCTAssertEqual(state(DeepSeekBalance(total: 4, alertBound: 5, capturedAt: now, source: .web)), .low)
        XCTAssertEqual(state(DeepSeekBalance(total: 0, capturedAt: now, source: .web)), .exhausted)
        XCTAssertEqual(state(DeepSeekBalance(total: 50, available: false, capturedAt: now, source: .apiKey)), .exhausted)
        XCTAssertEqual(state(DeepSeekBalance(total: 50, capturedAt: now.addingTimeInterval(-660), source: .web)), .stale)
        XCTAssertEqual(state(nil), .stale)
        XCTAssertEqual(state(nil, connected: false), .disconnected)
        let shortRunway = DeepSeekWallet(balance: DeepSeekBalance(total: 9, capturedAt: now, source: .web), connected: true,
            ledger: ledger, now: now, lowThreshold: 5, calendar: calendar)
        XCTAssertEqual(shortRunway.state, .low, "Under three days at the recent average is low even above the line")

        let saturday = DeepSeekWallet(balance: nil, connected: true, ledger: DeepSeekSpendLedger(), now: date(31, 10), calendar: calendar)
        XCTAssertFalse(saturday.peakNow)
        XCTAssertTrue(saturday.peakToday.isEmpty)
        XCTAssertEqual(saturday.nextPriceChange, beijing.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9)))
        XCTAssertNil(saturday.typicalByNow, "No earlier days means no comparison")
        XCTAssertFalse(saturday.spendingFast)
    }

    func testAmountsKeepTheirColumnWidths() {
        XCTAssertEqual(DeepSeekWallet.compactAmount(8.4), "¥8.40")
        XCTAssertEqual(DeepSeekWallet.compactAmount(86.4), "¥86")
        XCTAssertEqual(DeepSeekWallet.compactAmount(1234), "¥1.2k")
        XCTAssertEqual(DeepSeekWallet.compactAmount(.nan), "¥–")
        XCTAssertEqual(DeepSeekWallet.compactAmount(14.99), "¥14", "A balance never shows more than is left")
        XCTAssertEqual(DeepSeekWallet.compactSpend(14.99), "¥15", "Spend matches the two-decimal details")
        XCTAssertEqual(DeepSeekWallet.compactSpend(9.996), "¥10")
        XCTAssertEqual(DeepSeekWallet.compactSpend(3.124), "¥3.12")
        XCTAssertEqual(DeepSeekWallet.turnAmount(0.004), "<¥0.01", "An upper bound needs no approximation mark")
        XCTAssertEqual(DeepSeekWallet.turnAmount(0.42), "≈¥0.42")
        XCTAssertEqual(DeepSeekWallet.turnAmount(12.34), "≈¥12.3")
        XCTAssertEqual(DeepSeekWallet.turnAmount(-1), "")
    }

    func testBalanceHasNoWindowForTheGaugeOrTimeRemaining() {
        for component in [CompactIslandLayout.Component.quotaGauge, .quotaLabel, .timeRemaining] {
            XCTAssertFalse(component.isAvailable(for: [.deepseek]))
            XCTAssertTrue(component.isAvailable(for: [.deepseek, .claude]))
        }
        XCTAssertTrue(CompactIslandLayout.Component.quota.isAvailable(for: [.deepseek]), "The balance takes the value's place")
        XCTAssertEqual(ModelDisplay.name("deepseek-v4-pro"), "V4 Pro")
        XCTAssertEqual(ModelDisplay.name("deepseek-flash"), "Flash")
        XCTAssertNil(ModelDisplay.effortLabel("off"), "A model asked not to reason shows no effort")
    }
}
