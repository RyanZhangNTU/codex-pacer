@testable import PacerEngineSupport
import Foundation
import XCTest
@testable import PacerCore

/// Stands in for the catalog poll: it keeps the engine's callbacks and waits until cancelled.
private final class DurableTestFeed: @unchecked Sendable {
    typealias Publish = @Sendable (DurableActivityCatalog?) async -> Void
    typealias History = @Sendable (String, [DurableTurnHistory]) async -> Void
    private let lock = NSLock()
    private var callbacks: (Publish, History)?
    private var count = 0
    var starts: Int { lock.withLock { count } }
    var services: CodexDesktopServices {
        .init(observeDurable: { [self] _, publish, history in
            lock.withLock { callbacks = (publish, history); count += 1 }
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
        })
    }
    /// Callbacks of the latest poll, kept after it stops to check that late reports are ignored.
    func publish(_ catalog: DurableActivityCatalog?) async {
        let value = lock.withLock { callbacks?.0 }
        await value?(catalog)
    }
    func history(_ scope: String, _ turns: [DurableTurnHistory]) async {
        let value = lock.withLock { callbacks?.1 }
        await value?(scope, turns)
    }
}
private final class DurableEngineSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [EngineSnapshot] = []
    func append(_ data: Data) {
        guard let value = try? JSONDecoder().decode(EngineSnapshot.self, from: data) else { return }
        lock.lock(); values.append(value); lock.unlock()
    }
    func all() -> [EngineSnapshot] { lock.lock(); defer { lock.unlock() }; return values }
}

final class EngineDurableTests: XCTestCase {
    private let thread = "019a0000-0000-7000-8000-000000000001"
    private let scope = String(repeating: "a", count: 64)
    private func command(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": UUID().uuidString, "method": method, "params": params])
    }
    private func turn(_ status: DurableTurnHistory.Status, at date: Date, completed: TimeInterval? = nil,
                      percent: Int? = nil, report: String = "r1") -> DurableTurnHistory {
        DurableTurnHistory(threadID: thread, name: "Synthetic Dot task", turnID: "t1", rootTurnID: nil, status: status,
            startedAt: date, completedAt: completed.map { date.addingTimeInterval($0) },
            report: percent.map { .init(id: report, percent: $0, at: date.addingTimeInterval(1)) })
    }
    private func started(_ feed: DurableTestFeed, _ count: Int) async throws {
        let ready = try await TestWait.until { feed.starts == count }
        XCTAssertTrue(ready, "The engine did not start the Dot poll")
    }

    func testDotStaysOffUntilTheUserOptsIn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-dot-optin-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(), feed = DurableTestFeed(), snapshots = DurableEngineSnapshots()
        let runtime = EngineRuntime(demo: false, now: { date.addingTimeInterval(5) }, dismissalStore: nil,
            desktopServices: feed.services, output: { snapshots.append($0) })
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex"], "codexHome": EngineCodexSourceReport.path(root)]))
        XCTAssertEqual(feed.starts, 0, "Dot is off by default: no catalog poll")

        _ = await runtime.receive(try command("configure", ["monitorDurable": true]))
        try await started(feed, 1)
        await feed.publish(DurableActivityCatalog(scope: scope, threadIDs: [thread]))
        await feed.history(scope, [turn(.inProgress, at: date)])
        XCTAssertEqual(snapshots.all().last?.presentation.rows.first?.sourceLabel, "Dot")

        _ = await runtime.receive(try command("configure", ["monitorDurable": false]))
        XCTAssertTrue(snapshots.all().last?.tasks.isEmpty == true, "Turning Dot off hides its rows at once")
        await feed.history(scope, [turn(.inProgress, at: date, percent: 50)])
        XCTAssertTrue(snapshots.all().last?.tasks.isEmpty == true, "A stopped poll cannot add rows")
        _ = await runtime.receive(try command("configure", ["monitorDurable": true]))
        try await started(feed, 2)
        await runtime.stop()
    }

    func testDotRowsShowProgressAndCompletionUntilTheAccountIsRevoked() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-dot-engine-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(), feed = DurableTestFeed(), snapshots = DurableEngineSnapshots()
        let runtime = EngineRuntime(demo: false, now: { date.addingTimeInterval(5) }, dismissalStore: nil,
            desktopServices: feed.services, output: { snapshots.append($0) })
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex"],
            "codexHome": EngineCodexSourceReport.path(root), "monitorDurable": true, "codexProgressRing": true]))
        try await started(feed, 1)
        await feed.history(scope, [turn(.inProgress, at: date, percent: 25)])
        XCTAssertTrue(snapshots.all().last?.tasks.isEmpty == true, "Nothing shows before the catalog lists the thread")
        await feed.publish(DurableActivityCatalog(scope: scope, threadIDs: [thread]))
        await feed.history(scope, [turn(.inProgress, at: date, percent: 25)])
        let running = try XCTUnwrap(snapshots.all().last?.presentation.rows.first)
        XCTAssertEqual(running.sourceLabel, "Dot"); XCTAssertEqual(running.progressFraction, 0.25)

        await feed.history(scope, [turn(.completed, at: date, completed: 2, percent: 100, report: "r2")])
        let ending = try XCTUnwrap(snapshots.all().last?.presentation.rows.first)
        XCTAssertEqual(ending.sourceLabel, "Dot"); XCTAssertEqual(ending.phase, "completed"); XCTAssertTrue(ending.unread)
        await feed.publish(nil)
        await feed.history(scope, [turn(.inProgress, at: date, percent: 30)])
        XCTAssertTrue(snapshots.all().last?.tasks.isEmpty == true, "Revoking the account must remove the ending and reject a late report")
        await runtime.stop()
    }
}
