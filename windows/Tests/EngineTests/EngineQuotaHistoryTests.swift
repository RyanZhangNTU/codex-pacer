import Foundation
import XCTest
@testable import PacerCore

final class EngineQuotaHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    func testVerifiedCycleCacheExpiresMarkersAndAccountOrSourceChangeInvalidatesDetails() throws {
        var history = QuotaCycleHistory(), state = EngineQuotaHistory()
        let samples = DemoScenario.quota(at: now), snapshot = try XCTUnwrap(samples.last)
        for sample in samples { history.record(sample) }
        state.bind(home: URL(fileURLWithPath: "/synthetic/a"), customPath: "cli-a")
        state.receive(snapshot: snapshot, history: history, warning: "cache warning")
        func reading(_ snapshot: QuotaSnapshot?, _ date: Date) -> QuotaDashboardPresentation.Reading {
            .init(provider: .codex, period: .weekly, snapshot: snapshot, now: date)
        }
        let first = state.presentation(provider: .codex, snapshot: snapshot, weekly: reading(snapshot, now), error: nil, refreshing: false, now: now)
        XCTAssertEqual(first.chart?.points.count, history.cycles.first?.displayPoints().count)
        XCTAssertEqual(first.warning, "cache warning")
        let revision = state.chartRevision, context = state.accountContext
        let next = now.addingTimeInterval(1)
        _ = state.presentation(provider: .codex, snapshot: snapshot, weekly: reading(snapshot, next), error: nil, refreshing: false, now: next)
        XCTAssertEqual(state.chartRevision, revision, "Clock ticks cannot reformat every historical date")
        state.bind(home: URL(fileURLWithPath: "/synthetic/a"), customPath: "cli-a")
        XCTAssertEqual(state.accountContext, context, "Unrelated preferences cannot collapse account details")
        let expired = now.addingTimeInterval(12 * 3600)
        let after = state.presentation(provider: .codex, snapshot: snapshot, weekly: reading(snapshot, expired), error: "offline", refreshing: false, now: expired)
        XCTAssertEqual(after.chart?.expiries.count, 1); XCTAssertEqual(state.chartRevision, revision + 1)
        XCTAssertEqual(after.chart?.points, first.chart?.points)
        var other = snapshot; other.accountScope = "other-private-scope"
        state.receive(snapshot: other, history: history, warning: nil)
        let changed = state.presentation(provider: .codex, snapshot: other, weekly: reading(other, now), error: nil, refreshing: false, now: now)
        XCTAssertNil(changed.chart); XCTAssertNotEqual(state.accountContext, context)
        let accountContext = state.accountContext
        state.bind(home: URL(fileURLWithPath: "/synthetic/b"), customPath: "cli-a")
        XCTAssertNotEqual(state.accountContext, accountContext)
        let rebound = state.presentation(provider: .codex, snapshot: nil, weekly: reading(nil, now), error: nil, refreshing: false, now: now)
        XCTAssertNil(rebound.account); XCTAssertNil(rebound.chart)
    }
    func testDemoRuntimePublishesNativeHistoryWithoutPrivateIdentity() async throws {
        let capture = HistoryCapture(), now = now
        let runtime = EngineRuntime(demo: true, now: { now }, output: { capture.append($0) })
        _ = await runtime.receive(Data(#"{"protocolVersion":1,"id":"start","method":"initialize","params":{"enabledProviders":["codex"]}}"#.utf8))
        let value = try XCTUnwrap(capture.last()), history = try XCTUnwrap(value.quotaDashboard?.providers.first?.history)
        XCTAssertGreaterThan(try XCTUnwrap(history.chart?.points.count), 20)
        XCTAssertEqual(history.account?.balanceText.replacingOccurrences(of: ",", with: ""), "12500")
        let text = String(decoding: try JSONEncoder().encode(history), as: UTF8.self)
        XCTAssertFalse(text.contains("demo-reset")); XCTAssertFalse(text.contains("accountScope"))
        await runtime.stop()
    }
}

private final class HistoryCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: EngineSnapshot?
    func append(_ data: Data) {
        guard let value = try? JSONDecoder().decode(EngineSnapshot.self, from: data) else { return }
        lock.lock(); defer { lock.unlock() }; self.value = value
    }
    func last() -> EngineSnapshot? { lock.lock(); defer { lock.unlock() }; return value }
}
