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
    func testCountdownsFollowFixedDeadlinesAndThePanelCapsuleNeedsAKnownCount() throws {
        let snapshot = try snapshot(), value = QuotaAccountPresentation(snapshot: snapshot, context: "opaque", now: now)
        XCTAssertEqual(value.nextExpiryText, L10n.text("account.known_next_expires_in", CompactDuration.text(60)),
            "Partial details name the next known deadline")
        XCTAssertEqual(value.expiries.map(\.remainingText), [60, 900_000].map { L10n.text("account.expiry_remaining", CompactDuration.text($0)) })
        XCTAssertEqual(value.expiries.map(\.soon), [true, false], "Three days is the attention line, as for the summary")
        XCTAssertTrue(value.expiries[0].accessibilityLabel.hasSuffix(value.expiries[0].remainingText))
        XCTAssertEqual(value.panelText, L10n.text("account.panel_resets_expiring", 5, CompactDuration.text(60)))
        XCTAssertFalse(try XCTUnwrap(value.panelText).contains("\n"), "The capsule is one short line; History holds the list")
        XCTAssertEqual(value.panelCountText, L10n.text("account.panel_resets", 5))
        XCTAssertEqual(value.panelTimeText, CompactDuration.text(60), "A shared row alternates the count with the time alone")
        let later = QuotaAccountPresentation(snapshot: snapshot, context: "opaque", now: now.addingTimeInterval(3_600))
        XCTAssertEqual(later.expiries.map(\.remainingText), [L10n.text("account.expiry_remaining", CompactDuration.text(900_000 - 3_600))],
            "The countdown moves with the clock and drops a passed deadline without a new read")
        let raw = try QuotaSnapshot.decode(Data(#"{"rateLimits":null}"#.utf8), capturedAt: now)
        let unknown = QuotaAccountPresentation(snapshot: raw, context: "none", now: now)
        XCTAssertNil(unknown.panelText); XCTAssertNil(unknown.nextExpiryText)
        let none = try QuotaSnapshot.decode(Data(#"{"rateLimits":null,"rateLimitResetCredits":{"availableCount":0}}"#.utf8), capturedAt: now)
        let zero = QuotaAccountPresentation(snapshot: none, context: "zero", now: now)
        XCTAssertNil(zero.panelText, "No capsule without an available reset"); XCTAssertNil(zero.nextExpiryText)
        XCTAssertNil(zero.panelCountText); XCTAssertNil(zero.panelTimeText)
        let open = try QuotaSnapshot.decode(Data(#"{"rateLimits":null,"rateLimitResetCredits":{"availableCount":2}}"#.utf8), capturedAt: now)
        let undated = QuotaAccountPresentation(snapshot: open, context: "open", now: now)
        XCTAssertEqual(undated.panelText, L10n.text("account.panel_resets", 2), "A count without deadlines still shows the capsule")
        XCTAssertNil(undated.nextExpiryText)
        XCTAssertEqual(undated.panelCountText, L10n.text("account.panel_resets", 2)); XCTAssertNil(undated.panelTimeText, "Without a deadline the count stays")
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
