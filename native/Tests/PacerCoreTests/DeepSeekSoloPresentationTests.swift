import Foundation
import XCTest
@testable import PacerCore

final class DeepSeekSoloPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value }
    func testQuietDayDoesNotInventSpeedDistributionOrHistory() {
        let wallet = DeepSeekWallet(balance: nil, connected: false, ledger: DeepSeekSpendLedger(), now: now, calendar: calendar)
        let value = DeepSeekSoloPresentation(wallet: wallet, at: now)
        XCTAssertNil(value.speed); XCTAssertNil(value.distribution); XCTAssertNil(value.week); XCTAssertTrue(value.budgets.isEmpty)
        XCTAssertEqual(value.todayText, "¥0.00")
    }
    func testDistributionKeepsTwoTasksRestAndAccountDifferenceButNeverEncodesTaskIDs() throws {
        var ledger = DeepSeekSpendLedger()
        for (index, cost) in [6.0, 3, 1, 2].enumerated() {
            ledger.record(id: "response-\(index)", at: now.addingTimeInterval(-Double(index + 1) * 60), cost: cost,
                task: index < 3 ? "private-session-\(index)" : nil)
        }
        var history = DeepSeekBalanceHistory()
        let start = calendar.startOfDay(for: now).addingTimeInterval(1)
        // The history splits spending by day; it must use the wallet's calendar, not the machine's.
        history.record(total: 94.1, at: start, source: "web", calendar: calendar)
        history.record(total: 80, at: now, source: "web", calendar: calendar)
        let wallet = DeepSeekWallet(balance: .init(total: 80, capturedAt: now, source: .web), connected: true, ledger: ledger, now: now, history: history, calendar: calendar)
        let names = ["private-session-0": "Confidential launch plan", "private-session-1": "Internal review"]
        let shown = DeepSeekSoloPresentation(wallet: wallet, at: now, taskTitle: { names[$0] ?? "Other private task" })
        let parts = try XCTUnwrap(shown.distribution?.parts)
        XCTAssertEqual(parts.count, 4); XCTAssertEqual(parts[0].title, "Confidential launch plan"); XCTAssertEqual(parts[2].amountText, "¥3.00")
        XCTAssertTrue(parts[3].elsewhere); XCTAssertEqual(parts.reduce(0) { $0 + $1.fraction }, 1, accuracy: 1e-9)
        let encoded = String(decoding: try JSONEncoder().encode(shown), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private-session")); XCTAssertNotNil(shown.speed)
        XCTAssertEqual(shown.speed?.fractions.count, 12)
        var lookedUp = false
        let hidden = DeepSeekSoloPresentation(wallet: wallet, at: now, hideProjects: true, taskTitle: { _ in lookedUp = true; return "Confidential launch plan" })
        XCTAssertFalse(lookedUp)
        let hiddenText = String(decoding: try JSONEncoder().encode(hidden), as: UTF8.self)
        XCTAssertFalse(hiddenText.contains("Confidential")); XCTAssertFalse(hiddenText.contains("Internal review")); XCTAssertFalse(hiddenText.contains("private-session"))
        XCTAssertEqual(try JSONDecoder().decode(DeepSeekSoloPresentation.self, from: JSONEncoder().encode(hidden)), hidden)
    }
    func testWeekRequiresTwoEarlierSpentDaysAndSeparatesBudgetExcess() throws {
        var ledger = DeepSeekSpendLedger()
        ledger.record(id: "old-one", at: now.addingTimeInterval(-86400), cost: 10)
        let one = DeepSeekWallet(balance: nil, connected: false, ledger: ledger, now: now, calendar: calendar)
        XCTAssertNil(DeepSeekSoloPresentation(wallet: one, at: now).week)
        ledger.record(id: "old-two", at: now.addingTimeInterval(-172800), cost: 3)
        ledger.record(id: "today", at: now.addingTimeInterval(-60), cost: 6)
        let wallet = DeepSeekWallet(balance: nil, connected: false, ledger: ledger, now: now, budgets: .init(daily: 5, weekly: 10), calendar: calendar)
        let value = DeepSeekSoloPresentation(wallet: wallet, at: now), week = try XCTUnwrap(value.week)
        XCTAssertEqual(week.days.count, 7); XCTAssertTrue(week.days.last!.today)
        XCTAssertGreaterThan(week.days.last!.overFraction, 0); XCTAssertTrue(week.days.contains { !$0.today && $0.overFraction > 0 })
        XCTAssertNotNil(week.lineText); XCTAssertNotNil(week.lineFraction)
        XCTAssertEqual(value.budgets.map(\.kind), ["day", "week"])
        let daily = value.budgets[0]
        XCTAssertTrue(daily.exceeded); XCTAssertEqual(daily.whole, "−¥1"); XCTAssertEqual(daily.cents, ".00")
        XCTAssertEqual(daily.fraction, 0); XCTAssertNil(daily.verdict); XCTAssertTrue(daily.projectionWarns)
    }
}
