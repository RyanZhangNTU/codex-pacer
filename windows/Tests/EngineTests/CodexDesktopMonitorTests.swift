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
    func setHosts(_ hosts: Set<String>) {}
    func setBatchInterval(_ seconds: TimeInterval, flushPending: Bool) { interval = seconds; if flushPending { flushes += 1 } }
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
    func testEngineRetainsUnreadEndingAcrossReleaseEofAndOlderLogReplay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-desktop-engine-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy/MM/dd"
        let day = root.appendingPathComponent("sessions/" + formatter.string(from: now.addingTimeInterval(5)))
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-10))
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

}
