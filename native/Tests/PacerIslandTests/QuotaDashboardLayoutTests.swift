import XCTest
import AppKit
import SwiftUI
import PacerCore
@testable import PacerIsland

final class QuotaDashboardLayoutTests: XCTestCase {
    @MainActor
    private func renderRing(_ view: QuotaDashboardRingView, name: String) async throws -> Data {
        let host = NSHostingView(rootView: view.frame(width: 180, height: 180).background(Color.black).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 180, height: 180),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Pacer synthetic ring check"; window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 180, height: 180); window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        if let path = ProcessInfo.processInfo.environment["PACER_UI_QA_OUTPUT"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent(name + ".png"))
        }
        return png
    }

    @MainActor
    func testUnknownTimeRingRendersDifferentlyFromMeasuredZeroWithoutChangingKnownQuota() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func render(_ time: Double?, name: String) async throws -> Data {
            let quota = QuotaDashboardQuota(provider: .codex, period: .weekly, window: nil, availability: .available,
                remainingQuotaPercent: 75, remainingTimePercent: time, capturedAt: now,
                freshnessText: "Synthetic", sourceText: nil, bucketName: nil)
            return try await renderRing(QuotaDashboardRingView(quota: quota, providerHelp: "Synthetic", now: now), name: name)
        }
        let unknown = try await render(nil, name: "unknown-time"), zero = try await render(0, name: "zero-time")
        let half = try await render(50, name: "half-time")
        XCTAssertNotEqual(unknown, zero, "Unknown time must have its own visual state, independent of the known quota value")
        XCTAssertNotEqual(half, zero)
        XCTAssertNotEqual(unknown, half)
    }

    @MainActor
    func testSplitRingsKeepEachPeriodsTimeAndUnknownQuotaIndependent() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func render(shortTime: Double? = 50, weeklyTime: Double? = 50,
                    shortQuota: Double? = 75, weeklyQuota: Double? = 40,
                    stale: Bool = false, name: String) async throws -> Data {
            func quota(_ period: QuotaDashboardPeriod, remaining: Double?, time: Double?) -> QuotaDashboardQuota {
                QuotaDashboardQuota(provider: .claude, period: period,
                    window: QuotaWindow(id: period.rawValue, usedPercent: remaining.map { 100 - $0 },
                        durationMinutes: period.durationMinutes,
                        resetsAt: now.addingTimeInterval(Double(period.durationMinutes) * 30)),
                    availability: stale ? .stale : .available, remainingQuotaPercent: remaining, remainingTimePercent: time,
                    capturedAt: now, freshnessText: "Synthetic", sourceText: nil, bucketName: nil)
            }
            let view = QuotaDashboardRingView(quota: quota(.weekly, remaining: weeklyQuota, time: weeklyTime),
                fiveHourQuota: quota(.fiveHour, remaining: shortQuota, time: shortTime), providerHelp: "Synthetic", now: now)
            return try await renderRing(view, name: name)
        }
        let standard = try await render(name: "split-standard")
        let shortUnknown = try await render(shortTime: nil, name: "split-unknown-5h-time")
        let shortZero = try await render(shortTime: 0, name: "split-zero-5h-time")
        let weekUnknown = try await render(weeklyTime: nil, name: "split-unknown-7d-time")
        let weekZero = try await render(weeklyTime: 0, name: "split-zero-7d-time")
        XCTAssertNotEqual(shortUnknown, shortZero); XCTAssertNotEqual(shortZero, standard)
        XCTAssertNotEqual(weekUnknown, weekZero); XCTAssertNotEqual(weekZero, standard)
        XCTAssertNotEqual(shortUnknown, weekUnknown, "Missing time only removes its own period's tick")
        let unknownShortQuota = try await render(shortQuota: nil, name: "split-unknown-5h-quota")
        let unknownWeekQuota = try await render(weeklyQuota: nil, name: "split-unknown-7d-quota")
        XCTAssertNotEqual(unknownShortQuota, unknownWeekQuota, "Each period retains its own unknown quota state")
        let low = try await render(shortQuota: 10, name: "split-low-5h")
        let stale = try await render(stale: true, name: "split-stale")
        XCTAssertNotEqual(low, standard); XCTAssertNotEqual(stale, standard)
    }

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

    func testEachProviderKeepsOneRingWithoutDependingOnSelectionOrderOrModuleCount() {
        let slots = QuotaDashboardLayout.slots(providers: [.claude, .codex])
        XCTAssertEqual(slots.map(\.provider), [.codex, .claude])
        XCTAssertEqual(Set(slots.map(\.id)).count, 2)
        for provider in AgentProvider.allCases {
            XCTAssertEqual(QuotaDashboardLayout.slots(providers: [provider]).map(\.provider), [provider])
        }
        XCTAssertTrue(QuotaDashboardLayout.slots(providers: []).isEmpty)
        XCTAssertEqual(QuotaDashboardLayout.slots(providers: [.claude, .claude]).map(\.provider), [.claude])
    }

    func testClassicLayoutRetainsTheOriginalPeriodsAndProviderLabels() {
        let both = ClassicQuotaDashboardLayout.slots(providers: [.claude, .codex])
        XCTAssertEqual(both.map(\.provider), [.codex, .claude])
        XCTAssertEqual(both.map(\.period), [.weekly, .weekly])
        XCTAssertTrue(both.allSatisfy(\.identifiesProvider))
        for provider in AgentProvider.allCases {
            let single = ClassicQuotaDashboardLayout.slots(providers: [provider])
            XCTAssertEqual(single.map(\.provider), [provider, provider])
            XCTAssertEqual(single.map(\.period), [.fiveHour, .weekly])
            XCTAssertFalse(single.contains(where: \.identifiesProvider))
            XCTAssertEqual(Set(single.map(\.id)).count, 2)
        }
        XCTAssertTrue(ClassicQuotaDashboardLayout.slots(providers: []).isEmpty)
        XCTAssertEqual(ClassicQuotaDashboardLayout.slots(providers: [.claude, .claude]).map(\.period), [.fiveHour, .weekly])
    }

    @MainActor
    func testSplitRequiresAnActualSameProviderFiveHourWindowEvenWhenUsageIsUnknownOrStale() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func quota(_ provider: AgentProvider, period: QuotaDashboardPeriod, reported: Bool,
                   availability: QuotaDashboardQuota.Availability = .available) -> QuotaDashboardQuota {
            QuotaDashboardQuota(provider: provider, period: period,
                window: reported ? QuotaWindow(id: provider.rawValue, usedPercent: nil,
                    durationMinutes: period.durationMinutes, resetsAt: nil) : nil,
                availability: availability, remainingQuotaPercent: nil, remainingTimePercent: nil,
                capturedAt: now, freshnessText: "Synthetic", sourceText: nil, bucketName: nil)
        }
        let weekly = quota(.codex, period: .weekly, reported: true)
        for availability in [QuotaDashboardQuota.Availability.available, .stale] {
            let short = quota(.codex, period: .fiveHour, reported: true, availability: availability)
            XCTAssertTrue(QuotaDashboardRingView(quota: weekly, fiveHourQuota: short, providerHelp: "", now: now).showsSplitRing)
        }
        for short in [quota(.codex, period: .fiveHour, reported: false, availability: .proOnly),
                      quota(.codex, period: .fiveHour, reported: false, availability: .unavailable),
                      quota(.claude, period: .fiveHour, reported: true),
                      quota(.codex, period: .weekly, reported: true)] {
            XCTAssertFalse(QuotaDashboardRingView(quota: weekly, fiveHourQuota: short, providerHelp: "", now: now).showsSplitRing)
        }
    }
}
