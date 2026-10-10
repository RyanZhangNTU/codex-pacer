import XCTest
import PacerCore
@testable import PacerIsland

final class QuotaDashboardLayoutTests: XCTestCase {
    private func snapshot(primary: [String: Any]?, secondary: [String: Any]? = nil,
                          extraBucket: [String: Any]? = nil) throws -> QuotaSnapshot {
        var codex: [String: Any] = [:]
        if let primary { codex["primary"] = primary }
        if let secondary { codex["secondary"] = secondary }
        var buckets: [String: Any] = ["codex": codex]
        if let extraBucket { buckets["other-service"] = extraBucket }
        let data = try JSONSerialization.data(withJSONObject: ["rateLimitsByLimitId": buckets])
        return try QuotaSnapshot.decode(data, capturedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testLegacyBarsApplyOnlyToCodexAloneWithReportedLimitsAndNoPrimaryFiveHourWindow() throws {
        let weekly = try snapshot(primary: ["windowDurationMins": 10080, "usedPercent": 40])
        XCTAssertTrue(QuotaDashboardLayout.usesLegacyCodexDisplay(providers: [.codex], snapshot: weekly))
        XCTAssertFalse(QuotaDashboardLayout.usesLegacyCodexDisplay(providers: [.codex, .claude], snapshot: weekly))
        XCTAssertFalse(QuotaDashboardLayout.usesLegacyCodexDisplay(providers: [.claude], snapshot: weekly))
        XCTAssertFalse(QuotaDashboardLayout.usesLegacyCodexDisplay(providers: [], snapshot: weekly))
        let bothPeriods = try snapshot(primary: ["windowDurationMins": 300, "usedPercent": 20],
            secondary: ["windowDurationMins": 10080, "usedPercent": 40])
        XCTAssertFalse(QuotaDashboardLayout.usesLegacyCodexDisplay(providers: [.codex], snapshot: bothPeriods))
        XCTAssertFalse(QuotaDashboardLayout.usesLegacyCodexDisplay(providers: [.codex], snapshot: nil))
        XCTAssertFalse(QuotaDashboardLayout.usesLegacyCodexDisplay(providers: [.codex], snapshot: try snapshot(primary: nil)))
        XCTAssertFalse(QuotaDashboardLayout.usesLegacyCodexDisplay(providers: [.codex], snapshot: try snapshot(primary: [:])))
    }

    func testLegacyPolicyRetainsNonstandardAndUnspecifiedLimitsWithoutBorrowingOtherBucketPeriods() throws {
        let limits = try snapshot(primary: ["windowDurationMins": 480], secondary: ["usedPercent": 15],
            extraBucket: ["primary": ["windowDurationMins": 300, "usedPercent": 30]])
        XCTAssertTrue(QuotaDashboardLayout.usesLegacyCodexDisplay(providers: [.codex], snapshot: limits))
        let unspecified = try snapshot(primary: ["usedPercent": 15])
        XCTAssertTrue(QuotaDashboardLayout.usesLegacyCodexDisplay(providers: [.codex], snapshot: unspecified))
    }

    func testBothProvidersSharePeriodWithoutDependingOnProviderSelectionOrder() {
        for period in QuotaDashboardPeriod.allCases {
            let slots = QuotaDashboardLayout.slots(providers: [.claude, .codex], selectedPeriod: period)
            XCTAssertEqual(slots.map(\.provider), [.codex, .claude])
            XCTAssertEqual(slots.map(\.period), [period, period])
            XCTAssertTrue(slots.allSatisfy(\.identifiesProvider))
            XCTAssertEqual(Set(slots.map(\.id)).count, 2)
        }
    }

    func testSingleProviderAlwaysShowsBothPeriodsWhenOtherModuleIsDisabled() {
        for provider in AgentProvider.allCases {
            for selected in QuotaDashboardPeriod.allCases {
                let slots = QuotaDashboardLayout.slots(providers: [provider], selectedPeriod: selected)
                XCTAssertEqual(slots.map(\.provider), [provider, provider])
                XCTAssertEqual(slots.map(\.period), [.fiveHour, .weekly])
                XCTAssertFalse(slots.contains(where: \.identifiesProvider))
                XCTAssertEqual(Set(slots.map(\.id)).count, 2)
            }
        }
    }

    func testNoEnabledModuleProducesNoQuotaSlotAndRepeatedIdentityCannotDuplicateRings() {
        XCTAssertTrue(QuotaDashboardLayout.slots(providers: [], selectedPeriod: .weekly).isEmpty)
        let slots = QuotaDashboardLayout.slots(providers: [.claude, .claude], selectedPeriod: .fiveHour)
        XCTAssertEqual(slots.map(\.provider), [.claude, .claude])
        XCTAssertEqual(slots.map(\.period), [.fiveHour, .weekly])
    }
}
