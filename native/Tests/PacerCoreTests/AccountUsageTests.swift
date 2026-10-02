import XCTest
@testable import PacerCore

final class AccountUsageTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_000_000)
    private func snapshot(_ fields: String) throws -> QuotaSnapshot {
        try QuotaSnapshot.decode(Data(fields.utf8), capturedAt: date)
    }
    func testRemainingQuotaAndElapsedTimeUseIndependentDirections() {
        let window = QuotaWindow(id: "week", usedPercent: 40, durationMinutes: 10080, resetsAt: date.addingTimeInterval(604800))
        XCTAssertEqual(window.remainingPercent, 60)
        XCTAssertEqual(window.elapsedTimePercent(at: date), 0)
        XCTAssertEqual(window.elapsedTimePercent(at: date.addingTimeInterval(302400)), 50)
        XCTAssertEqual(window.remainingSeconds(at: date.addingTimeInterval(302400)), 302400)
        XCTAssertEqual(window.elapsedTimePercent(at: date.addingTimeInterval(-60)), 0)
        XCTAssertEqual(window.elapsedTimePercent(at: date.addingTimeInterval(604900)), 100)
        XCTAssertEqual(window.remainingSeconds(at: date.addingTimeInterval(604900)), 0)
        XCTAssertNil(QuotaWindow(id: "unknown", usedPercent: nil, durationMinutes: nil, resetsAt: nil).elapsedTimePercent(at: date))
    }
    func testBackendCountIsNotReplacedByCappedDetailLength() throws {
        let value = try snapshot(#"{"rateLimits":null,"rateLimitResetCredits":{"availableCount":4,"credits":[{"id":"one","grantedAt":999000,"expiresAt":1000100,"status":"available"}]}}"#)
        let summary = try XCTUnwrap(value.resetCredits)
        XCTAssertEqual(summary.remainingCount(at: date, capturedAt: date), 4)
        XCTAssertFalse(summary.hasCompleteDetails)
        XCTAssertEqual(summary.nextExpiry(at: date), date.addingTimeInterval(100))
        XCTAssertEqual(summary.remainingCount(at: date.addingTimeInterval(101), capturedAt: date), 3)
    }
    func testNextExpiryUsesAvailableStatusAndEarliestDeadline() throws {
        let value = try snapshot(#"{"rateLimits":null,"rateLimitResetCredits":{"availableCount":2,"credits":[{"id":"late","grantedAt":999500,"expiresAt":1000300,"status":"available"},{"id":"early","grantedAt":999100,"expiresAt":1000100,"status":"available"},{"id":"used","grantedAt":999900,"expiresAt":1000050,"status":"redeemed"}]}}"#)
        let summary = try XCTUnwrap(value.resetCredits)
        XCTAssertEqual(summary.nextExpiry(at: date), date.addingTimeInterval(100))
        XCTAssertTrue(summary.hasCompleteDetails)
        XCTAssertEqual(summary.nextExpiry(at: date.addingTimeInterval(101)), date.addingTimeInterval(300))
        XCTAssertEqual(summary.remainingCount(at: date.addingTimeInterval(301), capturedAt: date), 0)
        XCTAssertFalse(summary.hasNoExpiringCredits(at: date.addingTimeInterval(301)))
    }
    func testMissingDetailsIsUnknownAndExplicitNoExpiryIsDistinct() throws {
        let missing = try snapshot(#"{"rateLimits":null,"rateLimitResetCredits":{"availableCount":3,"credits":null}}"#)
        XCTAssertEqual(missing.resetCredits?.availableCount, 3)
        XCTAssertFalse(missing.resetCredits!.hasCompleteDetails)
        XCTAssertFalse(missing.resetCredits!.hasNoExpiringCredits(at: date))
        let endless = try snapshot(#"{"rateLimits":null,"rateLimitResetCredits":{"availableCount":1,"credits":[{"id":"forever","grantedAt":999500,"expiresAt":null,"status":"available"}]}}"#)
        XCTAssertTrue(endless.resetCredits!.hasNoExpiringCredits(at: date))
        XCTAssertNil(endless.resetCredits?.nextExpiry(at: date))
    }
    func testBalanceKeepsDecimalPrecisionAndDoesNotConvertToApiValue() throws {
        let value = try snapshot(#"{"rateLimits":{"credits":{"hasCredits":true,"unlimited":false,"balance":"62500.125"}}}"#)
        XCTAssertEqual(value.credits?.amount, Decimal(string: "62500.125"))
        let debt = try snapshot(#"{"rateLimits":{"credits":{"hasCredits":false,"unlimited":false,"balance":"-5.25"}}}"#)
        XCTAssertEqual(debt.credits?.amount, Decimal(string: "-5.25"))
        let bad = try snapshot(#"{"rateLimits":{"credits":{"hasCredits":true,"unlimited":false,"balance":"125 credits"}}}"#)
        XCTAssertNil(bad.credits?.amount)
        let absent = try snapshot(#"{"rateLimits":{"credits":{"hasCredits":false,"unlimited":false,"balance":null}}}"#)
        XCTAssertNil(absent.credits?.amount)
    }
    func testOptionalInvalidCreditMetadataDoesNotBreakQuota() throws {
        let value = try snapshot(#"{"rateLimits":{"primary":{"usedPercent":20},"credits":{"hasCredits":"bad","unlimited":false}},"rateLimitResetCredits":{"availableCount":-1}}"#)
        XCTAssertEqual(value.windows.first?.remainingPercent, 80)
        XCTAssertNil(value.credits)
        XCTAssertNil(value.resetCredits)
        let malformed = try snapshot(#"{"rateLimits":{"primary":{"usedPercent":20}},"rateLimitResetCredits":{"availableCount":"bad"}}"#)
        XCTAssertEqual(malformed.windows.first?.remainingPercent, 80)
        XCTAssertNil(malformed.resetCredits)
    }
    func testCreditBalanceUsesAuthoritativeCodexBucketInsteadOfLegacyMirror() throws {
        let value = try snapshot(#"{"rateLimits":{"credits":{"hasCredits":true,"unlimited":false,"balance":"999"}},"rateLimitsByLimitId":{"special":{"credits":{"hasCredits":true,"unlimited":false,"balance":"100"}},"codex":{"credits":{"hasCredits":true,"unlimited":false,"balance":"10"}}}}"#)
        XCTAssertEqual(value.credits?.amount, 10)
        let unavailable = try snapshot(#"{"rateLimits":{"credits":{"hasCredits":true,"unlimited":false,"balance":"999"}},"rateLimitsByLimitId":{"codex":{"credits":null}}}"#)
        XCTAssertNil(unavailable.credits)
    }
    func testSnapshotRetainsResetMetadataAcrossPrivateCacheRoundtrip() throws {
        let value = try snapshot(#"{"rateLimits":{"credits":{"hasCredits":true,"unlimited":true,"balance":null}},"rateLimitResetCredits":{"availableCount":1,"credits":[{"id":"one","grantedAt":999000,"expiresAt":1000100,"status":"available"}]}}"#)
        let restored = try JSONDecoder().decode(QuotaSnapshot.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(restored, value)
        XCTAssertEqual(restored.resetCredits?.nextExpiry(at: date), date.addingTimeInterval(100))
        XCTAssertTrue(restored.credits!.unlimited)
    }
    func testDuplicateExpiredRowsOnlyDecreaseCountOnce() throws {
        let value = try snapshot(#"{"rateLimits":null,"rateLimitResetCredits":{"availableCount":1,"credits":[{"id":"same","grantedAt":999000,"expiresAt":1000100,"status":"available"},{"id":"same","grantedAt":999000,"expiresAt":1000100,"status":"available"}]}}"#)
        XCTAssertEqual(value.resetCredits?.remainingCount(at: date.addingTimeInterval(101), capturedAt: date), 0)
    }
    func testLegacyCacheWithoutNewMetadataStillLoads() throws {
        let raw = #"{"buckets":[{"id":"codex","windows":[]}],"capturedAt":-977307200}"#
        let restored = try JSONDecoder().decode(QuotaSnapshot.self, from: Data(raw.utf8))
        XCTAssertNil(restored.credits)
        XCTAssertNil(restored.resetCredits)
    }
}
