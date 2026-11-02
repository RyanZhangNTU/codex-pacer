import Foundation
import XCTest
@testable import PacerCore

private actor DesktopTestConnection: CodexDesktopConnection {
    let frame: @Sendable (Data) async -> Void
    let closed: @Sendable () async -> Void
    var stopped = false
    var interval: TimeInterval = 5
    var flushes = 0
    init(frame: @escaping @Sendable (Data) async -> Void, closed: @escaping @Sendable () async -> Void) {
        self.frame = frame; self.closed = closed
    }
    func start() {}
    func discover(_ threads: [String]) {}
    func setInterval(_ seconds: TimeInterval, flushPending: Bool) { interval = seconds; if flushPending { flushes += 1 } }
    func stop() { stopped = true }
    // Deliberately permits callbacks after stop to exercise generation guards.
    func send(_ bytes: Data) async { await frame(bytes) }
    func disconnect() async { await closed() }
}
private final class DesktopTestFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var created: [DesktopTestConnection] = []
    var services: CodexDesktopServices {
        .init { [self] _, _, frame, closed in
            let connection = DesktopTestConnection(frame: frame, closed: closed)
            lock.lock(); created.append(connection); lock.unlock(); return connection
        }
    }
    func all() -> [DesktopTestConnection] { lock.lock(); defer { lock.unlock() }; return created }
}
private actor DesktopMonitorStates {
    var values: [CodexDesktopState] = []
    func append(_ value: CodexDesktopState) { values.append(value) }
}
private final class DesktopEngineSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [EngineSnapshot] = []
    func append(_ data: Data) {
        guard let value = try? JSONDecoder().decode(EngineSnapshot.self, from: data) else { return }
        lock.lock(); values.append(value); lock.unlock()
    }
    func all() -> [EngineSnapshot] { lock.lock(); defer { lock.unlock() }; return values }
}

final class CodexDesktopMonitorTests: XCTestCase {
    private let thread = "019a0000-0000-7000-8000-000000000001"
    private func frame(_ kind: String, _ extra: [String: Any] = [:]) throws -> Data {
        var row = extra; row["kind"] = kind; row["hostId"] = "local"
        return try JSONSerialization.data(withJSONObject: row)
    }
    private func event(_ method: String, at: Date, _ extra: [String: Any] = [:]) -> [String: Any] {
        var row = extra; row["method"] = method; row["threadId"] = thread; row["turnId"] = "current"; row["at"] = at.timeIntervalSince1970
        return row
    }
    private func command(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": UUID().uuidString, "method": method, "params": params])
    }
    func testTransportReadinessDoesNotSupplyActivityAndOldSourceCallbacksAreRevoked() async throws {
        let factory = DesktopTestFactory(), capture = DesktopMonitorStates()
        let monitor = CodexDesktopMonitor(services: factory.services) { await capture.append($0) }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-monitor-first")
        await monitor.configure(home: home, enabled: true, expanded: false, context: 1)
        await monitor.discover([thread])
        let first = try XCTUnwrap(factory.all().first)
        try await first.send(frame("status", ["connected": true]))
        var latest = await capture.values.last
        XCTAssertTrue(latest?.activities.isEmpty == true); XCTAssertEqual(latest?.status.sourceAvailable, false)
        let now = Date()
        try await first.send(frame("runtimeBatch", ["events": [event("turn/started", at: now)]]))
        latest = await capture.values.last
        XCTAssertEqual(latest?.activities.first?.phase, .running); XCTAssertEqual(latest?.status.sourceAvailable, true)
        let request = try frame("attention", ["threadId": thread, "requests": [["id": "permission", "kind": "approval"]]])
        await first.send(request)
        let detected = await capture.values.last?.attention.first?.detectedAt
        await first.send(request)
        latest = await capture.values.last
        XCTAssertEqual(latest?.attention.first?.detectedAt, detected)
        await monitor.setExpanded(true)
        let interval = await first.interval, flushes = await first.flushes
        XCTAssertEqual(interval, 1); XCTAssertGreaterThan(flushes, 0)

        await monitor.configure(home: home.appendingPathComponent("second"), enabled: true, expanded: true, context: 2)
        await monitor.discover([thread])
        let count = await capture.values.count
        try await first.send(frame("runtimeBatch", ["events": [event("turn/completed", at: now, ["status": "completed"])]]))
        await first.disconnect()
        let after = await capture.values.count, stopped = await first.stopped
        XCTAssertEqual(after, count); XCTAssertTrue(stopped)
        latest = await capture.values.last
        XCTAssertEqual(latest?.context, 2); XCTAssertTrue(latest?.activities.isEmpty == true)
        let second = try XCTUnwrap(factory.all().last)
        try await second.send(frame("runtimeBatch", ["events": [event("turn/started", at: now)]]))
        await monitor.configure(home: home.appendingPathComponent("second"), enabled: false, expanded: false, context: 3)
        let disabled = await capture.values.count
        try await second.send(frame("runtimeBatch", ["events": [event("turn/completed", at: now, ["status": "completed"])]]))
        let final = await capture.values.count; XCTAssertEqual(final, disabled)
        await monitor.stop()
    }
    func testEngineRetainsUnreadEndingAcrossReleaseEofAndOlderLogReplay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-desktop-engine-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let day = root.appendingPathComponent("sessions/2026/11/01")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let now = Date(), timestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-10))
        let rows: [[String: Any]] = [
            ["type": "session_meta", "timestamp": timestamp, "payload": ["id": thread, "source": "cli", "originator": "Codex Desktop", "cwd": "/synthetic"]],
            ["type": "event_msg", "timestamp": timestamp, "payload": ["type": "task_started", "turn_id": "current"]]
        ]
        var bytes = Data()
        for row in rows { bytes += try JSONSerialization.data(withJSONObject: row) + Data([10]) }
        try bytes.write(to: day.appendingPathComponent("rollout-" + thread + ".jsonl"))
        let factory = DesktopTestFactory(), snapshots = DesktopEngineSnapshots()
        let runtime = EngineRuntime(demo: false, now: { now.addingTimeInterval(5) }, dismissalStore: nil,
            desktopServices: factory.services, output: { snapshots.append($0) })
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex"], "codexHome": EngineCodexSourceReport.path(root)]))
        let connection = try XCTUnwrap(factory.all().first)
        try await connection.send(frame("status", ["connected": true]))
        XCTAssertEqual(snapshots.all().last?.runningCount, 1, "A successful handshake cannot replace the log task")
        XCTAssertEqual(snapshots.all().last?.sources.first { $0.id == "codex:desktop-runtime" }?.available, false)
        try await connection.send(frame("runtimeBatch", ["events": [event("turn/started", at: now),
            event("item/started", at: now, ["itemType": "commandExecution", "itemId": "tool"])]]))
        try await connection.send(frame("attention", ["threadId": thread, "requests": [["id": "approval", "kind": "approval"]]]))
        XCTAssertEqual(snapshots.all().last?.requests.count, 1)
        try await connection.send(frame("attention", ["threadId": thread, "requests": [[String: String]]()]))
        try await connection.send(frame("runtimeBatch", ["events": [
            event("turn/completed", at: now.addingTimeInterval(1), ["status": "completed"]),
            event("stream/released", at: now.addingTimeInterval(1))]]))
        await connection.disconnect()
        _ = await runtime.receive(try command("refresh"))
        let ending = try XCTUnwrap(snapshots.all().last?.tasks.first)
        XCTAssertEqual(ending.phase, "completed"); XCTAssertTrue(ending.unread)
        XCTAssertEqual(snapshots.all().last?.runningCount, 0); XCTAssertEqual(snapshots.all().last?.requests.count, 0)
        let sequence = try XCTUnwrap(snapshots.all().last?.sequence)
        _ = await runtime.receive(try command("markRead", ["snapshotSequence": sequence, "activityID": ending.id]))
        _ = await runtime.receive(try command("refresh"))
        XCTAssertTrue(snapshots.all().last?.tasks.isEmpty == true, "An older active log cannot revive an acknowledged ending")
        await runtime.stop()
        let stopped = snapshots.all().count
        try await connection.send(frame("runtimeBatch", ["events": [event("turn/started", at: now.addingTimeInterval(2))]]))
        XCTAssertEqual(snapshots.all().count, stopped)
    }
    func testReconnectNeedsNewRuntimeEvidenceAndRejectsThePreviousPipeCallbacks() async throws {
        let factory = DesktopTestFactory(), capture = DesktopMonitorStates()
        let monitor = CodexDesktopMonitor(services: factory.services, retryInterval: 0.02) { await capture.append($0) }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-reconnect")
        await monitor.configure(home: home, enabled: true, expanded: false, context: 1)
        await monitor.discover([thread])
        let first = try XCTUnwrap(factory.all().first), now = Date()
        try await first.send(frame("runtimeBatch", ["events": [event("turn/started", at: now),
            event("turn/completed", at: now.addingTimeInterval(1), ["status": "completed"])]]))
        await first.disconnect()
        let limit = ProcessInfo.processInfo.systemUptime + 1
        while factory.all().count < 2, ProcessInfo.processInfo.systemUptime < limit { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(factory.all().count, 2)
        let second = try XCTUnwrap(factory.all().last)
        try await second.send(frame("status", ["connected": true]))
        let latest = await capture.values.last
        XCTAssertEqual(latest?.status.sourceAvailable, false); XCTAssertTrue(latest?.activities.isEmpty == true)
        let count = await capture.values.count
        try await first.send(frame("runtimeBatch", ["events": [event("turn/started", at: now.addingTimeInterval(2))]]))
        await first.disconnect()
        let after = await capture.values.count; XCTAssertEqual(after, count)
        await monitor.stop()
    }
}
