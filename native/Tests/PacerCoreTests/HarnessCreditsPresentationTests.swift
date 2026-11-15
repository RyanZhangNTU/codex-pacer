import XCTest
@testable import PacerCore

final class HarnessCreditsPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "UTC")!; return value }
    private func days(_ count: Double) -> Double { now.addingTimeInterval(count * 86_400 + 3_600).timeIntervalSince1970 }

    /// A standard plan partway through the month, rewards about to lapse and a top-up.
    private func standard(rewardDays: Double = 2, groups: [HarnessAccountCredits.Group]? = nil) -> HarnessAccountCredits {
        HarnessAccountCredits(state: .ready, remaining: 4_620, total: 5_500, reserved: 0, plan: "Standard",
            cycle: .init(total: 2_000, remaining: 1_320, used: 680, reset: days(14)), expiration: .init(credits: 300, at: days(rewardDays)),
            groups: groups ?? [.init(kind: .planBase, remaining: 1_320, total: 2_000, refresh: days(14)),
                               .init(kind: .planBonus, remaining: 2_000, total: 2_000, refresh: days(14)),
                               .init(kind: .reward, remaining: 300, expiries: [.init(credits: 300, at: days(rewardDays))]),
                               .init(kind: .topUp, remaining: 1_000, expiries: [.init(credits: 1_000, at: days(29))])])
    }
    private func present(_ credits: HarnessAccountCredits, _ settings: HarnessCreditsSettings = .default) throws -> HarnessCreditsPresentation {
        try XCTUnwrap(HarnessCreditsPresentation(credits: credits, settings: settings, now: now, language: .english, calendar: calendar))
    }

    func testMonthlyCreditsRefreshAndExtraCreditsLapse() throws {
        let reading = try XCTUnwrap(standard().reading(at: now))
        XCTAssertEqual(reading.monthly?.remaining, 3_320, "Plan base and plan bonus refresh together")
        XCTAssertEqual(reading.monthly?.total, 4_000)
        XCTAssertEqual(reading.percent ?? 0, 83, accuracy: 0.01, "A share means something only for credits that refresh")
        XCTAssertEqual(reading.extra?.remaining, 1_300, "Rewards and top-ups never refresh")
        XCTAssertEqual(reading.extra?.batches.map(\.credits), [300, 1_000], "Batches run from the earliest lapse")
        XCTAssertEqual(reading.expiringSoon(within: 3, at: now)?.credits, 300)
        XCTAssertNil(reading.expiringSoon(within: 1, at: now), "The user's window decides what counts as soon")
    }

    func testDialShowsDaysLeftTheMonthAndExtraCreditsAsAnAmount() throws {
        let soon = try present(standard())
        XCTAssertEqual(soon.dial.center, "83%", "The center shows the month's share by default")
        XCTAssertEqual(soon.dial.top, "300 expire in 2 days", "Credits about to lapse take the top line")
        XCTAssertTrue(soon.dial.topWarns)
        XCTAssertEqual(soon.dial.badge, "+1,300", "Extra credits are an amount, never a share")
        XCTAssertEqual(soon.dial.badgeTone, .warning)
        XCTAssertNil(soon.dial.gapLabel, "With extra credits the gap holds them, not the month's label")
        XCTAssertEqual(soon.dial.fraction ?? 0, 0.83, accuracy: 0.001, "The ring is the month's credits")

        let calm = try present(standard(rewardDays: 9))
        XCTAssertEqual(calm.dial.top, "Refreshes in 14 days", "Otherwise the top line counts down to the refresh")
        XCTAssertFalse(calm.dial.topWarns)
        XCTAssertEqual(calm.dial.badgeTone, .normal)
    }

    func testWithoutExtraCreditsTheGapSaysThisMonth() throws {
        let plain = try present(standard(groups: [.init(kind: .planBase, remaining: 62, total: 100, refresh: days(16))]))
        XCTAssertNil(plain.dial.badge)
        XCTAssertEqual(plain.dial.gapLabel, "This month")
        XCTAssertEqual(plain.dial.top, "Refreshes in 16 days")
        XCTAssertEqual(plain.sections.map(\.rows.count), [1], "Only groups the account has appear")
    }

    func testSpentMonthLeavesExtraCreditsSolid() throws {
        let spent = try present(HarnessAccountCredits(state: .ready, remaining: 30, total: 130, reserved: 0, plan: nil, cycle: nil, expiration: nil,
            groups: [.init(kind: .planBase, remaining: 0, total: 100, refresh: days(14)),
                     .init(kind: .reward, remaining: 30, expiries: [.init(credits: 30, at: days(20))])]))
        XCTAssertEqual(spent.dial.center, "0%")
        XCTAssertEqual(spent.dial.badge, "+30")
        XCTAssertEqual(spent.dial.badgeTone, .solid, "Once the month is spent, the extra credits are all that is left")
    }

    func testFiguresFollowTheUsersChoices() throws {
        let credits = standard()
        XCTAssertEqual(try present(credits, .init(center: .monthlyRemaining)).dial.center, "3,320")
        XCTAssertEqual(try present(credits, .init(center: .available)).dial.center, "4,620")
        XCTAssertEqual(try present(credits).barText, "4.6k", "The collapsed bar shows everything available by default")
        XCTAssertEqual(try present(credits, .init(bar: .monthlyPercent)).barText, "83%")
        XCTAssertEqual(try present(credits, .init(bar: .monthlyRemaining)).barText, "3.3k")
        XCTAssertEqual(HarnessCreditsPresentation.grouped(420.5), "420.5", "Credits can be fractional")
        XCTAssertEqual(HarnessCreditsPresentation.grouped(3_320), "3,320")
    }

    func testLinesAndBreakdown() throws {
        let presentation = try present(standard())
        XCTAssertEqual(presentation.lines.map(\.label), ["Monthly", "Extra", "Total"])
        XCTAssertEqual(presentation.lines[0].value, "3,320 / 4,000")
        XCTAssertEqual(presentation.lines[1].value, "1,300 credits")
        XCTAssertTrue(presentation.lines[1].warns)
        XCTAssertEqual(presentation.lines[2].value, "4,620 credits available")
        XCTAssertEqual(presentation.sections.map(\.rows.count), [2, 2])
        let reward = try XCTUnwrap(presentation.sections.last?.rows.first)
        XCTAssertEqual(reward.amount, "300", "A reward shows what is left, not a share of its grant")
        XCTAssertEqual(reward.chip, "Expires within 3 days")
        XCTAssertNil(presentation.sections.first?.rows.first?.chip, "Refreshing credits never lapse early")
    }

    func testEarlierHostsWithoutGroupsStillSplitTheMonth() throws {
        let legacy = HarnessAccountCredits(state: .ready, remaining: 520.5, total: 600, reserved: 0, plan: nil,
            cycle: .init(total: 500, remaining: 420.5, used: nil, reset: days(17)), expiration: .init(credits: 100, at: days(10)))
        let reading = try XCTUnwrap(legacy.reading(at: now))
        XCTAssertEqual(reading.monthly?.remaining, 420.5)
        XCTAssertEqual(reading.extra?.remaining, 100)
        XCTAssertEqual(try present(legacy).dial.badge, "+100")
    }

    func testNoticesUseTheUsersLineAndAnnounceEachLapseOnce() throws {
        var policy = HarnessCreditsNoticePolicy()
        let credits: [AgentProvider: HarnessAccountCredits] = [.workbuddy: standard()]
        let first = policy.notices(credits, settings: [.workbuddy: .init(lowCredits: 5_000)], low: true, now: now)
        XCTAssertEqual(Set(first.map(\.id)).count, 2, "A low line above the balance and a lapse within the window both notify")
        XCTAssertTrue(first.contains { $0.id.hasPrefix("workbuddy:credits:expiring:") })
        XCTAssertTrue(first.contains { $0.id == "workbuddy:credits:low" })
        XCTAssertTrue(policy.notices(credits, settings: [.workbuddy: .init(lowCredits: 5_000)], low: true, now: now).isEmpty, "Each notice fires once")
        var quiet = HarnessCreditsNoticePolicy()
        XCTAssertTrue(quiet.notices(credits, settings: [.workbuddy: .init(expiryReminder: false)], low: true, now: now).isEmpty,
                      "The default line is a tenth of the month's credits, and the expiry reminder can be off")
        XCTAssertEqual(HarnessCreditsNoticePolicy.level(try XCTUnwrap(standard().reading(at: now)), settings: .init(lowCredits: 4_620)), .low)
    }

    func testSettingsFallBackOneByOne() throws {
        let decoded = try JSONDecoder().decode(HarnessCreditsSettings.self,
            from: Data(#"{"center":"bogus","bar":"monthlyPercent","lowCredits":-4,"expiryDays":99}"#.utf8))
        XCTAssertEqual(decoded, HarnessCreditsSettings(center: .monthlyPercent, bar: .monthlyPercent, lowCredits: nil, expiryReminder: true, expiryDays: 30))
    }

    func testBothWorkBuddyBuildsAreSeparateModules() {
        XCTAssertEqual(WorkBuddyHarness.china.home, ".workbuddy")
        XCTAssertEqual(WorkBuddyHarness.international.home, ".workbuddy-ai")
        XCTAssertEqual(WorkBuddyHarness.china.conversationScheme, "workbuddy")
        XCTAssertEqual(WorkBuddyHarness.china.macBundleIdentifiers, ["com.tencent.workbuddy.mac"])
        XCTAssertEqual(WorkBuddyHarness.international.macBundleIdentifiers, ["com.workbuddy.workbuddy"], "WorkBuddy's own Mac updater names both IDs")
        XCTAssertEqual(WorkBuddyHarness.international.macTeamIdentifier, WorkBuddyHarness.china.macTeamIdentifier)
        XCTAssertEqual(WorkBuddyHarness.international.conversationScheme, "workbuddy-ai")
        XCTAssertEqual(WorkBuddyHarness.accountCredits(.china).sites.map(\.url.host), ["www.workbuddy.cn"])
        XCTAssertEqual(WorkBuddyHarness.accountCredits(.international).sites.map(\.url.host), ["www.workbuddy.ai"])
        XCTAssertEqual(HarnessRegistry.ids(where: \.reportsAccountCredits), [.workbuddy, .workbuddyAI])
    }
}
