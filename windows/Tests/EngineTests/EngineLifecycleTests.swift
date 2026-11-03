import Foundation
import XCTest
@testable import PacerCore

private final class LifecycleFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = []
    func append(_ value: Data) { lock.lock(); values.append(value); lock.unlock() }
    var snapshot: EngineSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return values.compactMap { try? JSONDecoder().decode(EngineSnapshot.self, from: $0) }.last
    }
}
private actor LifecycleQuota: CodexQuotaConnection {
    nonisolated let entered = ShutdownSignal(), closing = ShutdownSignal()
    private var continuation: CheckedContinuation<Void, Never>?
    private let blocked: Bool
    private let date: Date
    init(blocked: Bool, date: Date) { self.blocked = blocked; self.date = date }
    func readQuota() async throws -> QuotaSnapshot {
        entered.finish()
        if blocked { await withCheckedContinuation { continuation = $0 } }
        return DemoScenario.quota(.codex, at: date).last!
    }
    func release() { continuation?.resume(); continuation = nil }
    func currentAccountScope() -> String? { nil }
    func shutdown() { closing.finish() }
}
private actor LifecycleClients {
    let first: LifecycleQuota, second: LifecycleQuota
    private var count = 0
    init(date: Date) {
        first = LifecycleQuota(blocked: true, date: date.addingTimeInterval(-60))
        second = LifecycleQuota(blocked: false, date: date)
    }
    func make() -> LifecycleQuota { count += 1; return count == 1 ? first : second }
}

final class EngineLifecycleTests: XCTestCase {
    private func command(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": UUID().uuidString, "method": method, "params": params])
    }
    func testSleepReleasesAStuckQuotaReadAndWakePublishesOnlyTheReplacement() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let clients = LifecycleClients(date: date), frames = LifecycleFrames()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-lifecycle-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = EngineRuntime(demo: false, now: { date }, dismissalStore: nil,
            quotaServices: .init(makeClient: { _, _ in await clients.make() }, history: nil), output: { frames.append($0) })
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex"], "codexHome": EngineCodexSourceReport.path(root)]))
        let first = clients.first, second = clients.second
        for _ in 0..<400 { if first.entered.isFinished { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(first.entered.isFinished)
        await runtime.prepareForSleep()
        XCTAssertTrue(first.closing.isFinished)
        XCTAssertTrue(frames.snapshot?.quota.isEmpty == true)
        await runtime.resumeAfterSleep()
        for _ in 0..<400 { if frames.snapshot?.quota.first?.capturedAt == date.timeIntervalSince1970 { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(second.entered.isFinished)
        XCTAssertEqual(frames.snapshot?.quota.first?.capturedAt, date.timeIntervalSince1970)
        let sequence = frames.snapshot?.sequence
        await first.release()
        await runtime.refresh(discover: false)
        XCTAssertEqual(frames.snapshot?.quota.first?.capturedAt, date.timeIntervalSince1970, "A late pre-sleep sample cannot replace the wake result")
        XCTAssertGreaterThan(frames.snapshot?.sequence ?? 0, sequence ?? 0)
        await runtime.stop()
        XCTAssertTrue(second.closing.isFinished)
    }
    func testSleepDoesNotCollectAndWakeKeepsUnreadCompletionCards() async throws {
        let frames = LifecycleFrames(), date = Date(timeIntervalSince1970: 1_800_000_000)
        let runtime = EngineRuntime(demo: true, now: { date }, output: { frames.append($0) })
        _ = await runtime.receive(try command("initialize"))
        _ = await runtime.receive(try command("demoStage", ["demoStage": 3]))
        let unread = Set(frames.snapshot?.tasks.filter(\.unread).map(\.id) ?? [])
        XCTAssertFalse(unread.isEmpty)
        await runtime.prepareForSleep()
        let sequence = frames.snapshot?.sequence
        await runtime.maintenanceRefresh()
        await runtime.refresh(discover: true)
        XCTAssertEqual(frames.snapshot?.sequence, sequence)
        await runtime.resumeAfterSleep()
        XCTAssertEqual(Set(frames.snapshot?.tasks.filter(\.unread).map(\.id) ?? []), unread)
        XCTAssertGreaterThan(frames.snapshot?.sequence ?? 0, sequence ?? 0)
        await runtime.stop()
        await runtime.resumeAfterSleep()
        let stopped = frames.snapshot?.sequence
        await runtime.refresh(discover: true)
        XCTAssertEqual(frames.snapshot?.sequence, stopped)
    }
}
