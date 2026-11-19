@testable import PacerEngineSupport
import Foundation
import XCTest
@testable import PacerCore

/// The engine sets the host's zone as `NSTimeZone.default` at launch. Foundation
/// on Windows still reports GMT for `TimeZone.current` and a default
/// `Date.FormatStyle`, so every date text must take the zone from the calendar.
/// Singapore keeps UTC+8 all year: its text at a moment is UTC's eight hours later.
final class EngineLocalTimeZoneTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00 UTC, 16:00 in Singapore
    private let shift: TimeInterval = 8 * 3600
    private var utc: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value }

    /// As `PacerEngine` applies the arguments `EngineTimeZone.Arguments` passes.
    private func inHostZone(_ body: () throws -> Void) throws {
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        NSTimeZone.default = try XCTUnwrap(EngineStartupTimeZone.parse(["--time-zone", "Asia/Singapore", "--time-zone-offset", "28800"]))
        try body()
    }

    func testDateTextUsesTheHostZone() throws {
        try inHostZone {
            XCTAssertEqual(Calendar.current.timeZone.identifier, "Asia/Singapore")
            XCTAssertEqual(L10n.timeZone.identifier, "Asia/Singapore")
            let clock = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
            XCTAssertEqual(L10n.format(instant, clock, locale: Locale(identifier: "en_GB")), "16:00")
            XCTAssertEqual(L10n.date(instant), L10n.date(instant.addingTimeInterval(shift), calendar: utc))
            XCTAssertEqual(L10n.date(instant, date: .complete, time: .omitted),
                           L10n.date(instant.addingTimeInterval(shift), date: .complete, time: .omitted, calendar: utc))
            XCTAssertEqual(L10n.date(instant, time: .standard), L10n.date(instant.addingTimeInterval(shift), time: .standard, calendar: utc))
            XCTAssertNotEqual(L10n.date(instant, date: .omitted, time: .shortened), L10n.date(instant, date: .omitted, time: .shortened, calendar: utc))
        }
    }

    func testChartAndWeekLabelsUseTheHostZone() throws {
        func data(_ start: Date) -> QuotaChartData {
            let cycle = QuotaCycle(id: "window", bucketName: "bucket", startedAt: start, resetsAt: start.addingTimeInterval(604800),
                points: (0..<40).map { .init(timestamp: start.addingTimeInterval(Double($0) * 5400), remaining: 100 - Double($0)) })
            let credits = (0..<3).map { QuotaResetCredit(id: "credit-\($0)", status: "available",
                expiresAt: start.addingTimeInterval(Double($0) * 90000 + 3600), grantedAt: start) }
            return .init(cycle: cycle, resetCredits: .init(availableCount: 3, credits: credits), now: start)
        }
        // 20:00 UTC on 14 January is already 15 January in Singapore.
        let start = instant.addingTimeInterval(-12 * 3600)
        try inHostZone {
            let chart = QuotaCycleChartPresentation(data: data(start))
            let shifted = QuotaCycleChartPresentation(data: data(start.addingTimeInterval(shift)), calendar: utc)
            XCTAssertEqual(chart.startText, shifted.startText); XCTAssertEqual(chart.endText, shifted.endText)
            XCTAssertNotEqual(chart.startText, QuotaCycleChartPresentation(data: data(start), calendar: utc).startText)
            XCTAssertEqual(chart.points.map(\.dateText), shifted.points.map(\.dateText))
            XCTAssertEqual(chart.expiries.map(\.dateText), shifted.expiries.map(\.dateText))
            XCTAssertEqual(chart.expiries.map(\.accessibilityLabel), shifted.expiries.map(\.accessibilityLabel))

            // Local midnights are 16:00 UTC the day before; a GMT label named that day.
            let calendar = Calendar.current, today = calendar.startOfDay(for: instant)
            let daily = [-5, -3, -1, 0].map { HarnessDailyAmount(day: calendar.date(byAdding: .day, value: $0, to: today)!, amount: 10) }
            let week = try XCTUnwrap(HarnessWeekPresentation.week(provider: .workbuddy, daily: daily, now: instant))
            let shiftedWeek = try XCTUnwrap(HarnessWeekPresentation.week(provider: .workbuddy,
                daily: daily.map { .init(day: $0.day.addingTimeInterval(shift), amount: $0.amount) }, now: instant.addingTimeInterval(shift), calendar: utc))
            XCTAssertEqual(week.days.map(\.label), shiftedWeek.days.map(\.label)); XCTAssertEqual(week.days.map(\.help), shiftedWeek.days.map(\.help))

            func spend(_ now: Date, _ calendar: Calendar) -> DeepSeekWallet {
                var ledger = DeepSeekSpendLedger()
                for days in [1, 3, 5] { ledger.record(id: "day-\(days)", at: now.addingTimeInterval(-Double(days) * 86400), cost: Double(days)) }
                ledger.record(id: "today", at: now.addingTimeInterval(-60), cost: 2)
                return DeepSeekWallet(balance: nil, connected: false, ledger: ledger, now: now, calendar: calendar)
            }
            let deepSeek = try XCTUnwrap(DeepSeekSoloPresentation(wallet: spend(instant, .current), at: instant).week)
            let shiftedSpend = try XCTUnwrap(DeepSeekSoloPresentation.week(spend(instant.addingTimeInterval(shift), utc), calendar: utc))
            XCTAssertEqual(deepSeek.days.map(\.label), shiftedSpend.days.map(\.label)); XCTAssertEqual(deepSeek.days.map(\.help), shiftedSpend.days.map(\.help))
            XCTAssertEqual(deepSeek.days.map(\.timestamp), week.days.map(\.timestamp))
        }
    }

    func testHistoryNamesTheHostZoneAndReformatsItsChartWhenTheZoneChanges() throws {
        let snapshot = try QuotaSnapshot.decode(JSONSerialization.data(withJSONObject: [
            "rateLimitsByLimitId": ["codex": ["limitName": "Account",
                "secondary": ["usedPercent": 60, "windowDurationMins": 10080, "resetsAt": instant.timeIntervalSince1970 + 86400]]],
            "rateLimitResetCredits": ["availableCount": 1, "credits": [
                ["id": "credit", "grantedAt": instant.timeIntervalSince1970 - 100, "expiresAt": instant.timeIntervalSince1970 + 600, "status": "available"]]]]),
            capturedAt: instant)
        try inHostZone {
            let account = QuotaAccountPresentation(snapshot: snapshot, context: "opaque", now: instant)
            XCTAssertEqual(account.timeZoneText, L10n.text("account.expiry_timezone", "Asia/Singapore"))
            XCTAssertEqual(account.expiries.map(\.dateText), [L10n.date(instant.addingTimeInterval(600 + shift), time: .standard, calendar: utc)])
        }

        var history = QuotaCycleHistory(), state = EngineQuotaHistory()
        let samples = DemoScenario.quota(at: instant), demo = try XCTUnwrap(samples.last)
        for sample in samples { history.record(sample) }
        state.bind(home: URL(fileURLWithPath: "/synthetic/a"), customPath: "cli-a")
        state.receive(snapshot: demo, history: history, warning: nil)
        func present() -> QuotaHistoryPresentation {
            state.presentation(provider: .codex, snapshot: demo, weekly: .init(provider: .codex, period: .weekly, snapshot: demo, now: instant),
                error: nil, refreshing: false, now: instant)
        }
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        NSTimeZone.default = utc.timeZone
        let before = try XCTUnwrap(present().chart), revision = state.chartRevision
        try inHostZone {
            let after = try XCTUnwrap(present().chart)
            XCTAssertEqual(state.chartRevision, revision + 1, "A new zone reformats the cached chart")
            XCTAssertEqual(after.points.map(\.timestamp), before.points.map(\.timestamp))
            XCTAssertEqual(after.points.first?.dateText, L10n.format(Date(timeIntervalSince1970: before.points[0].timestamp + shift),
                .dateTime.month(.twoDigits).day(.twoDigits).hour().minute(), calendar: utc, locale: L10n.language.locale))
        }
    }
}
