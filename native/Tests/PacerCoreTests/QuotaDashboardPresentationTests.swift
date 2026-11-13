import XCTest
@testable import PacerCore

final class QuotaDashboardPresentationTests: XCTestCase {
    func testTypedReadingsKeepUnknownTimeSeparateFromMeasuredZero() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func reading(_ time: Double?) -> QuotaDashboardPresentation.Reading {
            .init(provider: .codex, period: .weekly, window: nil, availability: .available,
                remainingQuotaPercent: 75, remainingTimePercent: time, capturedAt: now,
                freshnessText: "Synthetic", sourceText: nil, bucketName: nil, now: now)
        }
        let unknown = reading(nil).at(now), zero = reading(0).at(now)
        XCTAssertEqual(unknown.fraction, 0.75); XCTAssertEqual(zero.fraction, 0.75)
        XCTAssertNil(unknown.timeFraction); XCTAssertEqual(zero.timeFraction, 0)
        XCTAssertNotEqual(unknown.accessibilityLabel, zero.accessibilityLabel)
    }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func window(_ id: String, minutes: Int?, used: Double? = 20, reset: Date? = nil) -> QuotaWindow {
        QuotaWindow(id: id, usedPercent: used, durationMinutes: minutes,
            resetsAt: reset ?? minutes.map { now.addingTimeInterval(Double($0) * 30) })
    }
    private func snapshot(_ buckets: [(String, [QuotaWindow])], age: Double = 0) -> QuotaSnapshot {
        QuotaSnapshot(buckets: buckets.map { QuotaBucket(id: $0.0, name: $0.0, plan: nil, windows: $0.1, credits: nil) },
            capturedAt: now.addingTimeInterval(-age), accountScope: "synthetic-only", resetCredits: nil)
    }
    func testProviderBucketIsolationAndPlanRestrictionsNeedPositiveEvidence() {
        typealias P = QuotaDashboardPresentation
        let week = window("week", minutes: 10080)
        let own = snapshot([("codex", [week]), ("scoped", [window("foreign-five", minutes: 300)])])
        let reading = P.Reading(provider: .codex, period: .fiveHour, snapshot: own, now: now)
        XCTAssertEqual(reading.availability, .proOnly); XCTAssertNil(reading.windowID)
        for sample in [snapshot([("scoped", [week])]), snapshot([("codex", [week, window("untyped", minutes: nil)])]),
                       snapshot([("codex", [window("unknown", minutes: 10080, used: nil)])]),
                       snapshot([("codex", [QuotaWindow(id: "no-reset", usedPercent: 20, durationMinutes: 10080, resetsAt: nil)])])] {
            XCTAssertNotEqual(P.Reading(provider: .codex, period: .fiveHour, snapshot: sample, now: now).availability, .proOnly)
        }
        XCTAssertEqual(P.Reading(provider: .codex, period: .weekly, snapshot: own, now: now).windowID, "week")
    }
    func testExpiredOrFailedReadingsRetainValuesButCannotClaimLivePace() {
        typealias P = QuotaDashboardPresentation
        let fresh = snapshot([("codex", [window("five", minutes: 300)])])
        let available = P.Reading(provider: .codex, period: .fiveHour, snapshot: fresh, now: now)
        XCTAssertEqual(available.remainingPercent, 80); XCTAssertEqual(available.remainingTimePercent, 50)
        XCTAssertEqual(available.pacePercent, 160); XCTAssertEqual(available.verdict, .spare)
        XCTAssertEqual(available.paceText, "160%")
        let late = P.Reading(provider: .codex, period: .fiveHour, snapshot: snapshot([("codex", [window("five", minutes: 300)])], age: 599), now: now)
        XCTAssertEqual(late.availability, .available, "Missed polls inside ten minutes leave the reading unchanged")
        for sample in [snapshot([("codex", [window("expired", minutes: 300, reset: now)])]),
                       snapshot([("codex", [window("five", minutes: 300)])], age: 601)] {
            let stale = P.Reading(provider: .codex, period: .fiveHour, snapshot: sample, now: now)
            XCTAssertEqual(stale.availability, .stale); XCTAssertEqual(stale.remainingPercent, 80)
            XCTAssertNil(stale.pacePercent); XCTAssertNil(stale.verdict); XCTAssertNil(stale.projectionText); XCTAssertFalse(stale.pressing)
            XCTAssertEqual(stale.paceText, "—")
        }
        let failed = P.Reading(provider: .codex, period: .fiveHour, snapshot: fresh, failed: true, now: now)
        XCTAssertEqual(failed.availability, .stale); XCTAssertNil(failed.verdict)
        XCTAssertEqual(failed.remainingPercent, 80, "The expanded ring keeps its cached value on failure")
        XCTAssertEqual(failed.freshnessText, L10n.text("quota.age", 1), "A failed refresh uses the existing cached-age wording")
    }
    func testLayoutsPreserveSinglePeriodsAndLegacyCodexExceptions() throws {
        typealias P = QuotaDashboardPresentation
        let classic = P.slots(providers: [.claude], style: .classic)
        XCTAssertEqual(classic.map(\.period), [.fiveHour, .weekly]); XCTAssertTrue(classic.allSatisfy { !$0.identifiesProvider })
        XCTAssertEqual(P.slots(providers: [.claude, .codex, .claude], style: .classic).map(\.provider), [.codex, .claude])
        let weekly = snapshot([("codex", [window("week", minutes: 10080)])])
        XCTAssertEqual(P.layout(providers: [.codex], snapshots: [.codex: weekly], style: .classic, now: now).kind, .legacyCodex)
        XCTAssertEqual(P.layout(providers: [.codex], snapshots: [.codex: weekly], style: .split, now: now).kind, .splitSingle)
        XCTAssertEqual(P.layout(providers: [.deepseek], snapshots: [:], style: .classic, now: now).kind, .deepseekSolo)
        let bytes = try JSONEncoder().encode(P.slots(providers: [.claude], style: .classic))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [[String: Any]])
        XCTAssertEqual(json.first?["id"] as? String, "claude:5h"); XCTAssertEqual(json.first?["title"] as? String, "5h")
    }
    func testUnknownAndClampedValuesStayIndependentAndSerializeNoAccountScope() throws {
        typealias P = QuotaDashboardPresentation
        let unknown = snapshot([("claude", [QuotaWindow(id: "five", usedPercent: .nan, durationMinutes: 300, resetsAt: nil)])])
        let reading = P.Reading(provider: .claude, period: .fiveHour, snapshot: unknown, now: now)
        XCTAssertEqual(reading.availability, .available); XCTAssertEqual(reading.valueText, "—"); XCTAssertEqual(reading.countdown, "—")
        XCTAssertNil(reading.remainingPercent); XCTAssertNil(reading.remainingTimePercent)
        for (used, value) in [(-10.0, "100"), (150.0, "0")] {
            let sample = snapshot([("claude", [window("five", minutes: 300, used: used)])])
            XCTAssertEqual(P.Reading(provider: .claude, period: .fiveHour, snapshot: sample, now: now).valueText, value)
        }
        let encoded = String(decoding: try JSONEncoder().encode(reading), as: UTF8.self)
        XCTAssertFalse(encoded.contains("synthetic-only")); XCTAssertFalse(encoded.contains("accountScope"))
    }
}
