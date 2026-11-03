import Foundation
import XCTest
@testable import PacerCore

final class QuotaHistoryPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func snapshot() throws -> QuotaSnapshot {
        var value = try QuotaSnapshot.decode(JSONSerialization.data(withJSONObject: [
            "rateLimitsByLimitId": [
                "codex": ["limitName": "Account", "primary": ["usedPercent": 30, "windowDurationMins": 300, "resetsAt": now.timeIntervalSince1970 - 1],
                    "secondary": ["usedPercent": 60, "windowDurationMins": 10080, "resetsAt": now.timeIntervalSince1970 + 86400],
                    "credits": ["hasCredits": true, "unlimited": false, "balance": "62500.125"]], "empty": ["limitName": "Unreported"]],
            "rateLimitResetCredits": ["availableCount": 5, "credits": [
                ["id": "private-credit-a", "grantedAt": now.timeIntervalSince1970 - 100, "expiresAt": now.timeIntervalSince1970 + 60, "status": "available"],
                ["id": "private-credit-b", "grantedAt": now.timeIntervalSince1970 - 100, "expiresAt": now.timeIntervalSince1970 + 60, "status": "available"],
                ["id": "private-credit-c", "grantedAt": now.timeIntervalSince1970 - 100, "expiresAt": now.timeIntervalSince1970 + 900000, "status": "available"],
                ["id": "private-credit-d", "grantedAt": now.timeIntervalSince1970 - 100, "status": "available"]]]]), capturedAt: now)
        value.accountScope = "private-account-scope"; return value
    }
    func testHistoryKeepsAllBucketsAndSuppressesPacePerWindowAndOnFailure() throws {
        let snapshot = try snapshot(), weekly = QuotaDashboardPresentation.Reading(provider: .codex, period: .weekly, snapshot: snapshot, now: now)
        let value = QuotaHistoryPresentation(provider: .codex, snapshot: snapshot, weekly: weekly, chart: nil, error: nil, warning: "cache warning", refreshing: false, accountContext: "opaque", now: now)
        XCTAssertEqual(value.buckets.count, 2); XCTAssertTrue(value.buckets.contains { $0.windows.isEmpty })
        let windows = try XCTUnwrap(value.buckets.first { $0.id == "codex" }).windows
        XCTAssertNil(windows.first { $0.id.contains("primary") }?.pacePercent)
        XCTAssertNotNil(windows.first { $0.id == weekly.windowID }?.pacePercent)
        XCTAssertFalse(value.notUpdated); XCTAssertEqual(value.placeholder, L10n.text("quota.waiting_sample"))
        XCTAssertEqual(value.warning, "cache warning")
        let failed = QuotaHistoryPresentation(provider: .codex, snapshot: snapshot, weekly: weekly, chart: nil, error: "failure", warning: nil, refreshing: true, accountContext: "opaque", now: now)
        XCTAssertTrue(failed.notUpdated); XCTAssertEqual(failed.errorText, "failure"); XCTAssertEqual(failed.refreshTitle, L10n.text("common.retrying"))
        XCTAssertTrue(failed.buckets.flatMap(\.windows).allSatisfy { $0.pacePercent == nil && $0.remainingTimePercent == nil })
    }
    func testAccountDetailsKeepUnknownAndOutsideCycleDeadlinesWithoutIdentifiers() throws {
        let snapshot = try snapshot(), value = QuotaAccountPresentation(snapshot: snapshot, context: "opaque", now: now)
        XCTAssertEqual(value.expiries.count, 2); XCTAssertNotNil(value.nonExpiringText); XCTAssertNotNil(value.unknownText)
        XCTAssertTrue(value.expirySoon); XCTAssertNotNil(value.timeZoneText)
        XCTAssertEqual(value.expiryDescription, L10n.text("account.known_expiry", L10n.date(now.addingTimeInterval(60), date: .complete)))
        let formatter = NumberFormatter(); formatter.locale = L10n.locale; formatter.numberStyle = .decimal; formatter.maximumFractionDigits = 2
        XCTAssertEqual(value.balanceText, formatter.string(from: NSDecimalNumber(string: "62500.125")))
        let after = QuotaAccountPresentation(snapshot: snapshot, context: "opaque", now: now.addingTimeInterval(60))
        XCTAssertEqual(after.resetText, L10n.text("account.reset_count", 3)); XCTAssertEqual(after.expiries.count, 1)
        let data = try JSONEncoder().encode(value), text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("private-")); XCTAssertFalse(text.contains("accountScope")); XCTAssertFalse(text.contains("grantedAt"))
        XCTAssertEqual(try JSONDecoder().decode(QuotaAccountPresentation.self, from: data), value)
    }
    func testMissingMetadataAndZeroAvailabilityStayDistinctFromUnlimitedAndNoExpiry() throws {
        let raw = try QuotaSnapshot.decode(Data(#"{"rateLimits":null}"#.utf8), capturedAt: now)
        let unknown = QuotaAccountPresentation(snapshot: raw, context: "none", now: now)
        XCTAssertEqual(unknown.balanceText, "—"); XCTAssertEqual(unknown.resetText, L10n.text("account.resets_unknown"))
        XCTAssertEqual(unknown.detailMessage, L10n.text("account.expiry_unknown")); XCTAssertNil(unknown.unknownText)
        let unlimited = try QuotaSnapshot.decode(Data(#"{"rateLimits":{"credits":{"hasCredits":true,"unlimited":true}},"rateLimitResetCredits":{"availableCount":0}}"#.utf8), capturedAt: now)
        let zero = QuotaAccountPresentation(snapshot: unlimited, context: "zero", now: now)
        XCTAssertEqual(zero.balanceText, L10n.text("common.unlimited")); XCTAssertEqual(zero.detailMessage, L10n.text("account.no_resets"))
        XCTAssertNil(zero.unknownText); XCTAssertTrue(zero.expiries.isEmpty)
        let reading = QuotaDashboardPresentation.Reading(provider: .codex, period: .weekly, snapshot: nil, refreshing: true, now: now)
        let loading = QuotaHistoryPresentation(provider: .codex, snapshot: nil, weekly: reading, chart: nil, error: nil, warning: nil, refreshing: true, accountContext: "opaque", now: now)
        XCTAssertEqual(loading.placeholder, L10n.text("quota.loading")); XCTAssertNil(loading.account); XCTAssertTrue(loading.buckets.isEmpty)
    }
}
