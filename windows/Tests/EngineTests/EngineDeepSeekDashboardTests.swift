@testable import PacerEngineSupport
import Foundation
import XCTest
@testable import PacerCore

final class EngineDeepSeekDashboardTests: XCTestCase {
    func testBudgetConfigurationKeepsAmountsAndControlsBothDashboardAndCompactRing() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000), capture = SoloCapture()
        let runtime = EngineRuntime(demo: true, now: { now }, output: { capture.append($0) })
        func command(_ method: String, _ parameters: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": UUID().uuidString, "method": method, "params": parameters])
        }
        func group(mode: String = "budget", daily: Double? = 10, weekly: Double? = 50, period: String = "day", cost: Bool = false) -> [String: Any] {
            ["mode": mode, "daily": daily.map { $0 as Any } ?? NSNull(), "weekly": weekly.map { $0 as Any } ?? NSNull(),
             "ringPeriod": period, "speedSource": "local", "showsTurnCost": cost]
        }
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["deepseek"], "deepseekSettings": group()]))
        let shown = try XCTUnwrap(capture.last()), wallet = try XCTUnwrap(shown.wallet)
        XCTAssertEqual(wallet.solo?.budgets.map(\.kind), ["day", "week"])
        XCTAssertEqual(wallet.settings?.compactBudgetKind, "day")
        XCTAssertEqual(try XCTUnwrap(wallet.settings?.compactBudgetPercent), try XCTUnwrap(wallet.solo?.budgets.first?.fraction) * 100, accuracy: 1e-10)
        let suggestion = DeepSeekBudgets.suggested(averageDaily: wallet.averageDaily)
        XCTAssertEqual(wallet.settings?.suggestedDaily, suggestion.daily); XCTAssertEqual(wallet.settings?.suggestedWeekly, suggestion.weekly)
        XCTAssertTrue(shown.presentation.rows.filter { $0.provider == "deepseek" }.allSatisfy { $0.cost == nil })
        _ = await runtime.receive(try command("configure", ["deepseekSettings": group(period: "week", cost: true)]))
        XCTAssertEqual(capture.last()?.wallet?.settings?.compactBudgetKind, "week")
        XCTAssertTrue(capture.last()?.presentation.rows.contains { $0.provider == "deepseek" && $0.cost != nil } == true)
        _ = await runtime.receive(try command("configure", ["deepseekSettings": group(daily: -1), "hideProjects": true]))
        _ = await runtime.receive(try command("refresh", [:]))
        XCTAssertEqual(capture.last()?.wallet?.settings?.compactBudgetKind, "week", "An invalid group must reject the complete update")
        XCTAssertEqual(capture.last()?.presentation.rows.first?.title, shown.presentation.rows.first?.title)
        _ = await runtime.receive(try command("configure", ["deepseekSettings": group(mode: "balance")]))
        XCTAssertTrue(capture.last()?.wallet?.solo?.budgets.isEmpty == true); XCTAssertNil(capture.last()?.wallet?.settings?.compactBudgetKind)
        _ = await runtime.receive(try command("configure", ["deepseekSettings": group(daily: nil, weekly: 50)]))
        XCTAssertEqual(capture.last()?.wallet?.solo?.budgets.map(\.kind), ["week"])
        _ = await runtime.receive(try command("configure", ["hideProjects": true]))
        XCTAssertEqual(capture.last()?.wallet?.solo?.budgets.map(\.kind), ["week"], "Old protocol-1 updates that omit settings must retain them")
        _ = await runtime.receive(try command("configure", ["deepseekSettings": group(daily: nil, weekly: nil)]))
        XCTAssertTrue(capture.last()?.wallet?.solo?.budgets.isEmpty == true); XCTAssertNil(capture.last()?.wallet?.settings?.compactBudgetKind)
        await runtime.stop()
    }
    func testDisconnectedQuietWalletAdvancesOnMetadataClockAcrossMidnight() async throws {
        var calendar = Calendar.current
        calendar.timeZone = .current
        let midnight = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let clock = SoloClock(midnight.addingTimeInterval(-10)), capture = SoloCapture()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-solo-clock-" + UUID().uuidString)
        let runtime = EngineRuntime(demo: false, now: { clock.value() }, dismissalStore: nil, output: { capture.append($0) })
        func command(_ method: String, _ params: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": UUID().uuidString, "method": method, "params": params])
        }
        let path = home.withUnsafeFileSystemRepresentation { String(cString: $0!) }
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["deepseek"], "deepseekHome": path]))
        _ = await runtime.receive(try command("setExpanded", ["expanded": true]))
        let before = capture.last()
        XCTAssertGreaterThan(before?.wallet?.angle ?? 0, 359)
        XCTAssertEqual(before?.wallet?.state, "disconnected")
        clock.set(midnight.addingTimeInterval(120))
        let started = ProcessInfo.processInfo.systemUptime
        while capture.last()?.sequence == before?.sequence && ProcessInfo.processInfo.systemUptime - started < 3 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let after = capture.last()
        await runtime.stop()
        XCTAssertGreaterThan(after?.sequence ?? 0, before?.sequence ?? 0, "A disconnected, inactive wallet still needs clock ticks")
        XCTAssertEqual(try XCTUnwrap(after?.wallet?.angle), 0.5, accuracy: 1e-9)
        XCTAssertEqual(after?.wallet?.today, 0)
        XCTAssertNil(after?.wallet?.solo?.speed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path), "Metadata projection must not create or reopen a source")
    }
    func testSoloDashboardKeepsOriginalSpendAndRemovesHiddenNamesBeforeEncoding() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000), capture = SoloCapture()
        let runtime = EngineRuntime(demo: true, now: { now }, output: { capture.append($0) })
        func command(_ method: String, _ parameters: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": UUID().uuidString, "method": method, "params": parameters])
        }
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["deepseek"]]))
        let shown = try XCTUnwrap(capture.last()), solo = try XCTUnwrap(shown.wallet?.solo)
        XCTAssertEqual(shown.quotaDashboard?.split.kind, .deepseekSolo)
        XCTAssertNotNil(solo.week); XCTAssertNotNil(solo.speed); XCTAssertNotNil(solo.distribution)
        let titles = try XCTUnwrap(solo.distribution).parts.filter { !$0.elsewhere && $0.opacity >= 0.6 }.map(\.title)
        XCTAssertFalse(titles.isEmpty)
        _ = await runtime.receive(try command("configure", ["hideProjects": true]))
        let hidden = try XCTUnwrap(capture.last()), bytes = try JSONEncoder().encode(hidden), text = String(decoding: bytes, as: UTF8.self)
        for title in titles { XCTAssertFalse(text.contains(title), "Hidden spend titles must not remain in the wire snapshot") }
        XCTAssertEqual(hidden.wallet?.solo?.todayText, solo.todayText)
        let fractions = try XCTUnwrap(hidden.wallet?.solo?.distribution?.parts.map(\.fraction))
        let original = try XCTUnwrap(solo.distribution?.parts.map(\.fraction))
        XCTAssertEqual(fractions.count, original.count)
        for (value, before) in zip(fractions, original) { XCTAssertEqual(value, before, accuracy: 1e-12) }
        await runtime.stop()
    }
}
private final class SoloClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ value: Date) { date = value }
    func set(_ value: Date) { lock.lock(); defer { lock.unlock() }; date = value }
    func value() -> Date { lock.lock(); defer { lock.unlock() }; return date }
}
private final class SoloCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: EngineSnapshot?
    func append(_ data: Data) { guard let value = try? JSONDecoder().decode(EngineSnapshot.self, from: data) else { return }; lock.lock(); defer { lock.unlock() }; snapshot = value }
    func last() -> EngineSnapshot? { lock.lock(); defer { lock.unlock() }; return snapshot }
}
