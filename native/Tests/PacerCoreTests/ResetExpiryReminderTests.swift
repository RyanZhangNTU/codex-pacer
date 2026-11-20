import Foundation
import XCTest
@testable import PacerCore

final class ResetExpiryReminderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func snapshot(available: Int = 4, scope: String = "scope-a") throws -> QuotaSnapshot {
        func credit(_ id: String, _ offset: TimeInterval?) -> [String: Any] {
            var value: [String: Any] = ["id": id, "grantedAt": now.timeIntervalSince1970 - 100, "status": "available"]
            if let offset { value["expiresAt"] = now.timeIntervalSince1970 + offset }
            return value
        }
        var value = try QuotaSnapshot.decode(JSONSerialization.data(withJSONObject: [
            "rateLimits": NSNull(),
            "rateLimitResetCredits": ["availableCount": available, "credits": [
                credit("private-a", 7_200), credit("private-b", 7_200), credit("private-c", 30 * 3_600), credit("private-d", 10 * 86_400)]]]),
            capturedAt: now)
        value.accountScope = scope; return value
    }

    func testDeadlinesInsideTheLeadTimeMakeOneCodexWarning() throws {
        let snapshot = try snapshot()
        XCTAssertEqual(ResetExpiryReminder.due(snapshot, leadDays: 1, now: now).map(\.count), [2], "Two resets share the nearest deadline")
        XCTAssertEqual(ResetExpiryReminder.due(snapshot, leadDays: 2, now: now).map(\.count), [2, 1])
        for value in [0, 31, nil] { XCTAssertEqual(ResetExpiryReminder.leadDays(value), ResetExpiryReminder.defaultLeadDays) }
        XCTAssertEqual(ResetExpiryReminder.leadDays(30), 30)
        let item = try XCTUnwrap(ResetExpiryReminder.warning(snapshot, leadDays: 1, now: now))
        XCTAssertEqual(item.kind, .resetExpiry); XCTAssertEqual(item.provider, "codex")
        XCTAssertEqual(item.symbol, ResetExpiryReminder.symbol); XCTAssertNil(item.label)
        XCTAssertTrue(item.solid, "The last three hours need the user")
        XCTAssertEqual(item.help, L10n.text("warning.reset_expiry_help", 2, CompactDuration.text(7_200), L10n.date(now.addingTimeInterval(7_200), time: .standard)))
        XCTAssertEqual(ResetExpiryReminder.warning(snapshot, leadDays: 2, now: now)?.help,
            L10n.text("warning.reset_expiry_help", 3, CompactDuration.text(7_200), L10n.date(now.addingTimeInterval(7_200), time: .standard)))
        let calm = try XCTUnwrap(ResetExpiryReminder.warning(snapshot, leadDays: 2, now: now.addingTimeInterval(7_300)))
        XCTAssertFalse(calm.solid, "A deadline a day away is noticed, not urgent")
        XCTAssertNil(ResetExpiryReminder.warning(try self.snapshot(available: 0), leadDays: 30, now: now), "Nothing is available to lose")
        XCTAssertFalse(String(describing: item).contains("private-"))

        let items = CompactWarningPresentation.items(enabled: [.codex], warnings: [.resetExpiry], snapshots: [.codex: snapshot], now: now)
        XCTAssertEqual(items.map(\.kind), [.resetExpiry])
        XCTAssertTrue(CompactWarningPresentation.items(enabled: [.codex], warnings: [], snapshots: [.codex: snapshot], now: now).isEmpty)
        XCTAssertTrue(CompactWarningPresentation.items(enabled: [.claude], warnings: [.resetExpiry], snapshots: [.codex: snapshot], now: now).isEmpty,
            "Codex must be on")
        XCTAssertTrue(CompactWarningPresentation.items(enabled: [.codex], warnings: [.resetExpiry], snapshots: [.codex: snapshot],
            resetLeadDays: 1, now: now.addingTimeInterval(7_300)).isEmpty, "The next deadline is outside a one-day lead time")
    }

    func testEachDeadlineNotifiesOnceAndAnAccountChangeStartsOver() throws {
        var policy = ResetExpiryNoticePolicy(), snapshot = try snapshot()
        let first = policy.notices(snapshot, leadDays: 1, now: now)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.id, "codex:reset-expiry:\(Int((now.timeIntervalSince1970 + 7_200) / 60))")
        XCTAssertEqual(first.first?.kind, .lowQuota, "Delivered like the quota notices")
        XCTAssertEqual(first.first?.title, L10n.text("notice.reset_expiry"))
        XCTAssertTrue(policy.notices(snapshot, leadDays: 1, now: now.addingTimeInterval(60)).isEmpty, "Each deadline notifies once")
        let widened = policy.notices(snapshot, leadDays: 2, now: now.addingTimeInterval(120))
        XCTAssertEqual(widened.first?.detail, L10n.text("warning.reset_expiry_help", 1, CompactDuration.text(30 * 3_600 - 120),
            L10n.date(now.addingTimeInterval(30 * 3_600), time: .standard)), "Only the deadline that entered now is announced")
        XCTAssertTrue(policy.notices(snapshot, leadDays: 2, now: now.addingTimeInterval(8_000)).isEmpty, "A passed deadline adds nothing")
        snapshot.accountScope = "scope-b"
        XCTAssertEqual(policy.notices(snapshot, leadDays: 2, now: now.addingTimeInterval(8_000)).count, 1, "Another account's deadlines are new")
        var fresh = ResetExpiryNoticePolicy()
        XCTAssertTrue(fresh.notices(nil, leadDays: 1, now: now).isEmpty)
    }
}
