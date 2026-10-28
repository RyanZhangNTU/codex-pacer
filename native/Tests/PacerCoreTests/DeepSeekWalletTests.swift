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

    func testWalletFollowsTheDayAndItsAlertLine() {
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

        func state(_ balance: DeepSeekBalance?, connected: Bool = true, line: Double? = nil) -> DeepSeekWallet.State {
            DeepSeekWallet(balance: balance, connected: connected, ledger: DeepSeekSpendLedger(), now: now, lowLine: line, calendar: calendar).state
        }
        XCTAssertEqual(state(DeepSeekBalance(total: 8.4, capturedAt: now, source: .apiKey)), .low, "Without a platform line ¥10 applies")
        XCTAssertEqual(state(DeepSeekBalance(total: 8, alertBound: 5, capturedAt: now, source: .web)), .normal,
            "The platform's own alert line replaces ¥10")
        XCTAssertEqual(state(DeepSeekBalance(total: 20, alertBound: 5, capturedAt: now, source: .web), line: 30), .low,
            "A line set in Pacer replaces the platform's")
        XCTAssertEqual(state(DeepSeekBalance(total: 4, alertBound: 5, capturedAt: now, source: .web)), .low)
        XCTAssertEqual(state(DeepSeekBalance(total: 0, capturedAt: now, source: .web)), .exhausted)
        XCTAssertEqual(state(DeepSeekBalance(total: 50, available: false, capturedAt: now, source: .apiKey)), .exhausted)
        XCTAssertEqual(state(DeepSeekBalance(total: 50, capturedAt: now.addingTimeInterval(-660), source: .web)), .stale)
        XCTAssertEqual(state(nil), .stale)
        XCTAssertEqual(state(nil, connected: false), .disconnected)
        let shortRunway = DeepSeekWallet(balance: DeepSeekBalance(total: 9, capturedAt: now, source: .web), connected: true,
            ledger: ledger, now: now, lowLine: 5, calendar: calendar)
        XCTAssertEqual(shortRunway.state, .normal, "Only the line decides low, not the days the balance lasts")

        let saturday = DeepSeekWallet(balance: nil, connected: true, ledger: DeepSeekSpendLedger(), now: date(31, 10), calendar: calendar)
        XCTAssertFalse(saturday.peakNow)
        XCTAssertTrue(saturday.peakToday.isEmpty)
        XCTAssertEqual(saturday.nextPriceChange, beijing.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9)))
        XCTAssertNil(saturday.typicalByNow, "No earlier days means no comparison")
        XCTAssertFalse(saturday.spendingFast)
    }

    func testAccountChargesBeyondThisMacBudgetsAndTheMostUrgentAlert() throws {
        let calendar = beijing, now = date(28, 15) // A Wednesday afternoon.
        var ledger = DeepSeekSpendLedger()
        ledger.record(id: "a", at: date(28, 9, 30), cost: 4, task: "task-a")
        ledger.record(id: "b", at: date(28, 12, 30), cost: 2, task: "task-b")
        ledger.record(id: "c", at: date(28, 14, 55), cost: 1, task: "task-a")
        ledger.record(id: "monday", at: date(26, 11), cost: 30, task: "task-c")
        ledger.record(id: "last-week", at: date(25, 11), cost: 50, task: "task-c")
        var history = DeepSeekBalanceHistory()
        history.record(total: 100, at: date(28, 9), calendar: calendar)
        history.record(total: 95, at: date(28, 12), calendar: calendar)
        history.record(total: 120, at: date(28, 13), calendar: calendar)
        history.record(total: 110, at: date(28, 14, 58), calendar: calendar)
        XCTAssertEqual(history.charged(onDayStarting: calendar.startOfDay(for: now)), 15, accuracy: 1e-9, "A top-up is not spend")
        func wallet(_ budgets: DeepSeekBudgets, balance: Double = 110) -> DeepSeekWallet {
            DeepSeekWallet(balance: DeepSeekBalance(total: balance, capturedAt: date(28, 14, 58), source: .web), connected: true,
                ledger: ledger, now: now, history: history, budgets: budgets, spikeLimit: 5, calendar: calendar)
        }
        let spent = wallet(DeepSeekBudgets(daily: 15, weekly: 40))
        XCTAssertEqual(spent.today, 7, accuracy: 1e-9)
        XCTAssertEqual(spent.elsewhereToday, 8, accuracy: 1e-9, "Charges beyond this Mac's estimate over the same span")
        XCTAssertEqual(spent.todayTotal, 15, accuracy: 1e-9)
        XCTAssertEqual(spent.dayTotals.last ?? 0, 15, accuracy: 1e-9)
        XCTAssertEqual(spent.tasks.map(\.task), ["task-a", "task-b"])
        XCTAssertEqual(spent.tasks.first?.total ?? 0, 5, accuracy: 1e-9)
        XCTAssertEqual(spent.daily?.spent ?? 0, 15, accuracy: 1e-9)
        XCTAssertEqual(spent.weekly?.spent ?? 0, 45, accuracy: 1e-9, "The week starts on Monday; Sunday's spend is last week")
        XCTAssertEqual(spent.weekly?.interval.start, calendar.date(from: DateComponents(year: 2026, month: 10, day: 26)))
        XCTAssertEqual(spent.alert(lowBalance: true, spike: true, budget: true), .overBudget(.day))
        XCTAssertNil(spent.alert(lowBalance: true, spike: true, budget: false))
        XCTAssertEqual(spent.ringBudget(prefer: .week)?.kind, .week)
        XCTAssertEqual(spent.daily?.window.remainingPercent ?? -1, 0, accuracy: 1e-9)

        let nearing = wallet(DeepSeekBudgets(daily: 18))
        XCTAssertEqual(nearing.alert(lowBalance: true, spike: true, budget: true), .nearingBudget(.day))
        XCTAssertEqual(nearing.ringBudget(prefer: .week)?.kind, .day, "The ring falls back to the budget that is set")
        XCTAssertNil(nearing.weekly)
        XCTAssertEqual(wallet(DeepSeekBudgets(daily: 18), balance: 5).alert(lowBalance: true, spike: true, budget: true), .lowBalance,
            "A low balance outranks a budget nearing its line")
        XCTAssertEqual(wallet(DeepSeekBudgets(daily: 10), balance: 0).alert(lowBalance: false, spike: false, budget: false), .exhausted,
            "An empty wallet always shows")
        XCTAssertNil(wallet(DeepSeekBudgets()).alert(lowBalance: true, spike: true, budget: true))
        XCTAssertTrue(DeepSeekBudgets(daily: 0, weekly: -3).isEmpty)
        XCTAssertEqual(DeepSeekBudgets.suggested(averageDaily: 14), DeepSeekBudgets(daily: 20, weekly: 120),
            "A fifth above the daily average, rounded up to ¥5 a day and ¥10 a week")
        XCTAssertEqual(DeepSeekBudgets.suggested(averageDaily: 12.5), DeepSeekBudgets(daily: 15, weekly: 110), "An exact step is not raised")
        XCTAssertEqual(DeepSeekBudgets.suggested(averageDaily: 0.3), DeepSeekBudgets(daily: 5, weekly: 10))
        XCTAssertEqual(DeepSeekBudgets.suggested(averageDaily: nil), DeepSeekBudgets(daily: 10, weekly: 50), "Without spend: ¥10 and ¥50")

        var burst = DeepSeekBalanceHistory()
        for minute in 0...6 { burst.record(total: 50 - Double(minute), at: date(28, 15, minute), calendar: calendar) }
        let spans = burst.spent(12, of: 600, endingAt: date(28, 15, 6))
        XCTAssertEqual(spans.count, 12)
        XCTAssertEqual(spans.last ?? 0, 6, accuracy: 1e-9); XCTAssertEqual(spans.dropLast().reduce(0, +), 0, accuracy: 1e-9)
        XCTAssertEqual(DeepSeekBalanceHistory().spent(12, of: 600, endingAt: now), Array(repeating: 0, count: 12))
        var gap = DeepSeekBalanceHistory()
        gap.record(total: 20, at: date(28, 14, 50), calendar: calendar)
        gap.record(total: 18, at: date(28, 15, 6), calendar: calendar)
        gap.record(total: 30, at: date(28, 15, 7), calendar: calendar)
        let shared = gap.spent(2, of: 600, endingAt: date(28, 15, 6))
        XCTAssertEqual(shared[0], 0.75, accuracy: 1e-9, "A drop over a gap is shared by time across the spans")
        XCTAssertEqual(shared[1], 1.25, accuracy: 1e-9, "A top-up is not spend")
        func burstWallet(_ source: DeepSeekSpeedSource) -> DeepSeekWallet {
            DeepSeekWallet(balance: DeepSeekBalance(total: 44, capturedAt: date(28, 15, 6), source: .web), connected: true,
                ledger: DeepSeekSpendLedger(), now: date(28, 15, 6), history: burst, spikeLimit: 5, speedSource: source, calendar: calendar)
        }
        let spiking = burstWallet(.account)
        XCTAssertTrue(spiking.spiking, "Counted by the account, charges not on this Mac count")
        XCTAssertEqual(spiking.alert(lowBalance: true, spike: true, budget: true), .spike)
        XCTAssertEqual(spiking.ratePerMinute, 0.6, accuracy: 1e-9)
        XCTAssertFalse(burstWallet(.local).spiking, "Counted on this Mac, they do not")
        XCTAssertEqual(burstWallet(.local).speed, Array(repeating: 0, count: 12))

        var night = DeepSeekBalanceHistory()
        night.record(total: 10, at: date(27, 23), calendar: calendar)
        night.record(total: 6, at: date(28, 1), calendar: calendar)
        XCTAssertEqual(night.charged(onDayStarting: calendar.startOfDay(for: date(27, 12))), 2, accuracy: 1e-9)
        XCTAssertEqual(night.charged(onDayStarting: calendar.startOfDay(for: now)), 2, accuracy: 1e-9, "A gap over midnight is shared by time")
        night.record(total: 50, at: date(28, 2), source: "web", calendar: calendar)
        XCTAssertEqual(night.charged(onDayStarting: calendar.startOfDay(for: now)), 0, "Another source may be another account")
        XCTAssertEqual(night.since, date(28, 2))
        let restored = try JSONDecoder().decode(DeepSeekBalanceHistory.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(restored, history)
    }

    func testSpikeLineFollowsTheSevenDaysBeforeToday() {
        let calendar = beijing, now = date(28, 15)
        var ledger = DeepSeekSpendLedger()
        XCTAssertEqual(ledger.automaticSpikeLimit(before: calendar.startOfDay(for: now)), 5, "Without history the line is ¥5")
        for index in 0..<10 { ledger.record(id: "span-\(index)", at: date(27, 9 + index), cost: Double(index + 1)) }
        ledger.record(id: "today", at: date(28, 10), cost: 100)
        ledger.record(id: "too-old", at: date(20, 10), cost: 1000)
        func wallet(_ limit: Double?) -> DeepSeekWallet {
            DeepSeekWallet(balance: nil, connected: true, ledger: ledger, now: now, spikeLimit: limit, calendar: calendar)
        }
        XCTAssertEqual(wallet(nil).spikeLimit, 27, accuracy: 1e-9,
            "Three times the 90th percentile of last week's spans with spend; today and older days are left out")
        XCTAssertEqual(wallet(8).spikeLimit, 8, "A line set in Pacer replaces the automatic one")

        var light = DeepSeekSpendLedger()
        for index in 0..<10 { light.record(id: "light-\(index)", at: date(26, 9 + index), cost: 0.2) }
        XCTAssertEqual(light.automaticSpikeLimit(before: calendar.startOfDay(for: now)), 5, "Light use keeps the ¥5 floor")
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
        XCTAssertEqual(DeepSeekWallet.compactRemaining(4.1), "¥4.1")
        XCTAssertEqual(DeepSeekWallet.compactRemaining(64.2), "¥64")
        XCTAssertEqual(DeepSeekWallet.compactRemaining(-3.2), "−¥3.2", "An exceeded budget shows how far over")
    }

    func testBalanceHasNoWindowForTheLabelOrTimeRemaining() {
        for component in [CompactIslandLayout.Component.quotaLabel, .timeRemaining] {
            XCTAssertFalse(component.isAvailable(for: [.deepseek]))
            XCTAssertTrue(component.isAvailable(for: [.deepseek, .claude]))
        }
        XCTAssertTrue(CompactIslandLayout.Component.quota.isAvailable(for: [.deepseek]), "The balance takes the value's place")
        XCTAssertTrue(CompactIslandLayout.Component.quotaGauge.isAvailable(for: [.deepseek]), "A budget can join the rings")
        XCTAssertTrue(CompactIslandLayout.Component.priceClock.isAvailable(for: [.deepseek]))
        XCTAssertFalse(CompactIslandLayout.Component.priceClock.isAvailable(for: [.codex, .claude]))
        XCTAssertEqual(ModelDisplay.name("deepseek-v4-pro"), "V4 Pro")
        XCTAssertEqual(ModelDisplay.name("deepseek-flash"), "Flash")
        XCTAssertNil(ModelDisplay.effortLabel("off"), "A model asked not to reason shows no effort")
    }
}
