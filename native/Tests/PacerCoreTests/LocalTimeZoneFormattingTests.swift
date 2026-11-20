import Foundation
import XCTest
@testable import PacerCore

/// Date text follows the calendar's zone. On Windows a `Date.FormatStyle`'s own
/// zone stays GMT after the engine sets the host's, so Core formats through
/// `L10n.format`. Singapore keeps UTC+8 all year, so its text at a moment is
/// UTC's text eight hours later.
final class LocalTimeZoneFormattingTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00 UTC, 16:00 in Singapore
    private let shift: TimeInterval = 8 * 3600
    private func calendar(_ zone: TimeZone) -> Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = zone; return value }
    private var singapore: Calendar { calendar(TimeZone(identifier: "Asia/Singapore")!) }
    private var utc: Calendar { calendar(TimeZone(secondsFromGMT: 0)!) }

    func testDateTextUsesTheCalendarsZone() {
        let clock = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        let british = Locale(identifier: "en_GB")
        XCTAssertEqual(L10n.format(instant, clock, calendar: singapore, locale: british), "16:00")
        XCTAssertEqual(L10n.format(instant, clock, calendar: utc, locale: british), "08:00")
        for (date, time) in [(Date.FormatStyle.DateStyle.abbreviated, Date.FormatStyle.TimeStyle.shortened), (.complete, .omitted), (.abbreviated, .standard)] {
            XCTAssertEqual(L10n.date(instant, date: date, time: time, calendar: singapore),
                           L10n.date(instant.addingTimeInterval(shift), date: date, time: time, calendar: utc))
        }
        XCTAssertNotEqual(L10n.date(instant, date: .omitted, time: .shortened, calendar: singapore),
                          L10n.date(instant, date: .omitted, time: .shortened, calendar: utc))
        XCTAssertEqual(L10n.moment(instant.addingTimeInterval(3600), relativeTo: instant, calendar: singapore),
                       L10n.moment(instant.addingTimeInterval(3600 + shift), relativeTo: instant.addingTimeInterval(shift), calendar: utc))
    }

    func testWithoutAHostZoneTextMatchesADefaultStyle() {
        // The Mac sets no default zone, so its text is what a plain style gave before.
        XCTAssertEqual(L10n.timeZone.identifier, TimeZone.current.identifier)
        XCTAssertEqual(L10n.date(instant), instant.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)))
        XCTAssertEqual(L10n.date(instant, date: .complete, time: .omitted),
                       instant.formatted(Date.FormatStyle(date: .complete, time: .omitted).locale(L10n.locale)))
        XCTAssertEqual(L10n.format(instant, Date.FormatStyle().weekday(.narrow)), instant.formatted(Date.FormatStyle().weekday(.narrow).locale(L10n.locale)))
    }

    func testChartLabelsUseTheCalendarsZone() {
        // 2027-01-14 20:00 UTC is already 15 January in Singapore.
        func data(_ start: Date) -> QuotaChartData {
            let cycle = QuotaCycle(id: "window", bucketName: "bucket", startedAt: start, resetsAt: start.addingTimeInterval(604800),
                points: (0..<40).map { .init(timestamp: start.addingTimeInterval(Double($0) * 5400), remaining: 100 - Double($0)) })
            let credits = (0..<3).map { QuotaResetCredit(id: "credit-\($0)", status: "available",
                expiresAt: start.addingTimeInterval(Double($0) * 90000 + 3600), grantedAt: start) }
            return .init(cycle: cycle, resetCredits: .init(availableCount: 3, credits: credits), now: start)
        }
        let start = instant.addingTimeInterval(-12 * 3600)
        for language in AppLanguage.allCases {
            let local = QuotaCycleChartPresentation(data: data(start), language: language, calendar: singapore)
            let shifted = QuotaCycleChartPresentation(data: data(start.addingTimeInterval(shift)), language: language, calendar: utc)
            let gmt = QuotaCycleChartPresentation(data: data(start), language: language, calendar: utc)
            XCTAssertEqual(local.startText, shifted.startText); XCTAssertEqual(local.endText, shifted.endText)
            XCTAssertNotEqual(local.startText, gmt.startText)
            XCTAssertEqual(local.points.map(\.dateText), shifted.points.map(\.dateText))
            XCTAssertEqual(local.points.map(\.accessibilityLabel), shifted.points.map(\.accessibilityLabel))
            XCTAssertEqual(local.expiries.count, 3)
            XCTAssertEqual(local.expiries.map(\.dateText), shifted.expiries.map(\.dateText))
            XCTAssertEqual(local.expiries.map(\.accessibilityLabel), shifted.expiries.map(\.accessibilityLabel))
            XCTAssertNotEqual(local.expiries.map(\.dateText), gmt.expiries.map(\.dateText))
        }
    }

    func testWeekLabelsNameTheLocalDays() throws {
        // Local midnights in Singapore are 16:00 UTC the day before, which a GMT
        // label would name.
        func week(_ calendar: Calendar, at now: Date) throws -> DeepSeekSoloPresentation.Week {
            let today = calendar.startOfDay(for: now)
            let daily = [-5, -3, -1, 0].map { HarnessDailyAmount(day: calendar.date(byAdding: .day, value: $0, to: today)!, amount: 10) }
            return try XCTUnwrap(HarnessWeekPresentation.week(provider: .workbuddy, daily: daily, now: now, calendar: calendar))
        }
        let local = try week(singapore, at: instant), shifted = try week(utc, at: instant.addingTimeInterval(shift))
        XCTAssertEqual(local.days.map(\.label), shifted.days.map(\.label)); XCTAssertEqual(local.days.map(\.help), shifted.days.map(\.help))
        let gmtHelp = local.days.map { L10n.format(Date(timeIntervalSince1970: $0.timestamp),
            Date.FormatStyle().weekday(.abbreviated).month(.defaultDigits).day(), calendar: utc) }
        XCTAssertTrue(zip(local.days.map(\.help), gmtHelp).allSatisfy { !$0.hasPrefix($1) }, "Each bar names its own local day")

        func deepSeek(_ calendar: Calendar, at now: Date) throws -> DeepSeekSoloPresentation.Week {
            var ledger = DeepSeekSpendLedger()
            for days in [1, 3, 5] { ledger.record(id: "day-\(days)", at: now.addingTimeInterval(-Double(days) * 86400), cost: Double(days)) }
            ledger.record(id: "today", at: now.addingTimeInterval(-60), cost: 2)
            let wallet = DeepSeekWallet(balance: nil, connected: false, ledger: ledger, now: now, calendar: calendar)
            return try XCTUnwrap(DeepSeekSoloPresentation.week(wallet, calendar: calendar))
        }
        let spend = try deepSeek(singapore, at: instant), shiftedSpend = try deepSeek(utc, at: instant.addingTimeInterval(shift))
        XCTAssertEqual(spend.days.map(\.label), shiftedSpend.days.map(\.label)); XCTAssertEqual(spend.days.map(\.help), shiftedSpend.days.map(\.help))
        XCTAssertEqual(spend.days.map(\.timestamp), local.days.map(\.timestamp))
    }

    func testHistoryNamesTheCalendarsZone() throws {
        let snapshot = try QuotaSnapshot.decode(JSONSerialization.data(withJSONObject: [
            "rateLimitsByLimitId": ["codex": ["limitName": "Account",
                "secondary": ["usedPercent": 60, "windowDurationMins": 10080, "resetsAt": instant.timeIntervalSince1970 + 86400]]],
            "rateLimitResetCredits": ["availableCount": 1, "credits": [
                ["id": "credit", "grantedAt": instant.timeIntervalSince1970 - 100, "expiresAt": instant.timeIntervalSince1970 + 600, "status": "available"]]]]),
            capturedAt: instant)
        let value = QuotaAccountPresentation(snapshot: snapshot, context: "opaque", now: instant)
        XCTAssertEqual(value.expiries.count, 1)
        XCTAssertEqual(value.timeZoneText, L10n.text("account.expiry_timezone", Calendar.current.timeZone.identifier))
    }

    /// `Date.FormatStyle`'s own zone, and `TimeZone.current`, are GMT on Windows
    /// even after the engine sets the host's zone.
    func testCoreFormatsDatesOnlyThroughTheZonedHelper() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true).appendingPathComponent("PacerCore", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50, root.path)
        var found: [String] = []
        for file in files {
            for (index, line) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") else { continue }
                for pattern in [".formatted(", "TimeZone.current", "TimeZone.autoupdatingCurrent", "TimeZone = .current", "timeZone = .current", "timeZone: .current"]
                where code.contains(pattern) { found.append("\(file.lastPathComponent):\(index + 1) \(pattern)") }
            }
        }
        let helper = found.filter { $0.hasPrefix("Localization.swift:") && $0.hasSuffix(" .formatted(") }
        XCTAssertEqual(helper.count, 1, "L10n.format is the one place Core formats a date")
        XCTAssertEqual(found.filter { !helper.contains($0) }, [], "Format dates with L10n.format or L10n.date, and use L10n.timeZone for the user's zone")
    }
}
