import XCTest
import AppKit
import SwiftUI
import PacerCore
@testable import PacerIsland

final class QuotaDashboardLayoutTests: XCTestCase {
    @MainActor
    func testUnknownTimeRingRendersDifferentlyFromMeasuredZeroWithoutChangingKnownQuota() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func render(_ time: Double?, name: String) async throws -> Data {
            let quota = QuotaDashboardQuota(provider: .codex, period: .fiveHour, window: nil, availability: .available,
                remainingQuotaPercent: 75, remainingTimePercent: time, capturedAt: now,
                freshnessText: "Synthetic", sourceText: nil, bucketName: nil)
            let view = QuotaDashboardRingView(quota: quota, title: "Codex", identifiesProvider: true, providerHelp: "Synthetic", now: now)
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
        let unknown = try await render(nil, name: "unknown-time"), zero = try await render(0, name: "zero-time")
        let half = try await render(50, name: "half-time")
        XCTAssertNotEqual(unknown, zero, "Unknown time must have its own visual state, independent of the known quota value")
        XCTAssertNotEqual(half, zero)
        XCTAssertNotEqual(unknown, half)
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
