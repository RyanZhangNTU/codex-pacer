import Foundation
import XCTest
@testable import PacerCore

final class HarnessWeekPresentationTests: XCTestCase {
    func testChargeTimesComeFromVersionSevenRequestIDs() throws {
        // 0x01a1d3e485d1 milliseconds after 1970.
        let time = try XCTUnwrap(WorkBuddyHarness.chargeTime("01a1d3e485d17bf382e2b327bf3bc2b7"))
        XCTAssertEqual(time.timeIntervalSince1970, Double(0x01a1d3e485d1) / 1000, accuracy: 0.0005)
        XCTAssertEqual(WorkBuddyHarness.chargeTime("01a1d3e4-85d1-7bf3-82e2-b327bf3bc2b7"), time, "Hyphens are optional")
        XCTAssertNil(WorkBuddyHarness.chargeTime("01a1d3e485d14bf382e2b327bf3bc2b7"), "Only version 7 carries a time")
        XCTAssertNil(WorkBuddyHarness.chargeTime("r1"))
        XCTAssertNil(WorkBuddyHarness.chargeTime(String(repeating: "z", count: 32)))
    }

    func testWeekShowsSevenDaysOnceTwoFinishedDaysHaveCredits() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
        XCTAssertNil(HarnessWeekPresentation.week(provider: .workbuddy, daily: [.init(day: today, amount: 40)], now: now, calendar: calendar),
                     "Today alone says nothing about a week")
        XCTAssertNil(HarnessWeekPresentation.week(provider: .workbuddy, daily: [.init(day: day(-1), amount: 10), .init(day: today, amount: 40)],
                                                  now: now, calendar: calendar))
        let daily: [HarnessDailyAmount] = [.init(day: day(-8), amount: 999), .init(day: day(-5), amount: 20),
                                           .init(day: day(-1), amount: 10), .init(day: today, amount: 30)]
        let week = try XCTUnwrap(HarnessWeekPresentation.week(provider: .workbuddy, daily: daily, now: now, calendar: calendar))
        XCTAssertEqual(week.days.count, 7)
        XCTAssertEqual(week.days.last?.today, true)
        XCTAssertEqual(week.days.map(\.timestamp).first, day(-6).timeIntervalSince1970, "Days older than the week stay out")
        XCTAssertEqual(week.days.max { $0.withinFraction < $1.withinFraction }?.timestamp, today.timeIntervalSince1970)
        XCTAssertTrue(week.days.allSatisfy { $0.overFraction == 0 && $0.withinFraction <= 1 })
        XCTAssertNotNil(week.lineFraction, "The line marks the average of the days with credits")
        XCTAssertEqual(week.lineText, L10n.text("harness.daily_average", "20"))
    }
}
