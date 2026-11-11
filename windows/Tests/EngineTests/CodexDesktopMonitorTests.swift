@testable import PacerEngineSupport
import Foundation
import XCTest
@testable import PacerCore

private actor DesktopTestConnection: CodexDesktopConnection {
    let frame: @Sendable (Data) async -> Void
    let closed: @Sendable () async -> Void
    let initialFrames: [Data]
    var stopped = false
    var interval: TimeInterval = 5
    var flushes = 0
    init(frame: @escaping @Sendable (Data) async -> Void, closed: @escaping @Sendable () async -> Void, initialFrames: [Data]) {
        self.frame = frame; self.closed = closed; self.initialFrames = initialFrames
    }
    func start() async { for bytes in initialFrames { await frame(bytes) } }
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
    private let initialFrames: [Data]
    init(initialFrames: [Data] = []) { self.initialFrames = initialFrames }
    var services: CodexDesktopServices { services(supportsDurable: false) }
    func services(supportsDurable: Bool) -> CodexDesktopServices {
        .init(makeConnection: { [self] _, _, frame, closed in
            let connection = DesktopTestConnection(frame: frame, closed: closed, initialFrames: initialFrames)
            lock.lock(); created.append(connection); lock.unlock(); return connection
        }, supportsDurable: supportsDurable)
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
    private func frame(_ kind: String, _ extra: [String: Any] = [:], host: String = "local") throws -> Data {
        var row = extra; row["kind"] = kind; row["hostId"] = host
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

    func testDotRowsShowProgressAndCompletionUntilTheAccountIsRevoked() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-dot-engine-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(), factory = DesktopTestFactory(), snapshots = DesktopEngineSnapshots()
        let runtime = EngineRuntime(demo: false, now: { date.addingTimeInterval(5) }, dismissalStore: nil,
            desktopServices: factory.services(supportsDurable: true), output: { snapshots.append($0) })
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex"],
            "codexHome": EngineCodexSourceReport.path(root), "monitorRemoteControl": false, "codexProgressRing": true]))
        let connection = try XCTUnwrap(factory.all().first)
        let host = DurableActivityCatalog.hostID
        let firstScope = String(repeating: "a", count: 64), nextScope = String(repeating: "b", count: 64)
        let progress = try frame("runtimeBatch", ["events": [event("turn/started", at: date),
            event("progress/reported", at: date.addingTimeInterval(1), ["percent": 25])]], host: host)
        await connection.send(progress)
        XCTAssertTrue(snapshots.all().last?.tasks.isEmpty == true)
        try await connection.send(frame("durableScope", ["scope": firstScope], host: host))
        await connection.send(progress)
        let running = try XCTUnwrap(snapshots.all().last?.presentation.rows.first)
        XCTAssertEqual(running.sourceLabel, "Dot"); XCTAssertEqual(running.progressFraction, 0.25)

        try await connection.send(frame("runtimeBatch", ["events": [
            event("turn/completed", at: date.addingTimeInterval(2), ["status": "completed"])]], host: host))
        let ending = try XCTUnwrap(snapshots.all().last?.presentation.rows.first)
        XCTAssertEqual(ending.sourceLabel, "Dot"); XCTAssertEqual(ending.phase, "completed"); XCTAssertTrue(ending.unread)

        try await connection.send(frame("durableSuspended", host: host))
        await connection.send(progress)
        XCTAssertTrue(snapshots.all().last?.tasks.isEmpty == true, "Unverified credentials expose neither saved nor late live rows")
        XCTAssertTrue(snapshots.all().last?.activityLinks?.isEmpty == true)
        try await connection.send(frame("durableScope", ["scope": firstScope], host: host))
        let restored = try XCTUnwrap(snapshots.all().last?.presentation.rows.first)
        XCTAssertEqual(restored.phase, "completed"); XCTAssertTrue(restored.unread, "The same account restores the unread ending without history replay")

        try await connection.send(frame("durableSuspended", ["scope": nextScope], host: host))
        await connection.send(progress)
        XCTAssertTrue(snapshots.all().last?.tasks.isEmpty == true, "Verified credentials do not grant live access before the new catalog")
        try await connection.send(frame("durableScope", ["scope": nextScope], host: host))
        XCTAssertTrue(snapshots.all().last?.tasks.isEmpty == true, "The new account cannot inherit an unread ending for the same thread ID")

        try await connection.send(frame("durableScope", ["scope": NSNull()], host: host))
        await connection.send(progress)
        XCTAssertTrue(snapshots.all().last?.tasks.isEmpty == true, "Revoking the account must remove the ending and reject a late report")
        await runtime.stop()
    }

    func testPendingDotEndingSurvivesSuspensionOnlyForTheSameAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-dot-pending-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = DurableActivityCatalog.hostID, date = Date()
        let firstScope = String(repeating: "a", count: 64), otherScope = String(repeating: "b", count: 64)
        for nextScope in [firstScope, otherScope, nil] {
            let factory = DesktopTestFactory(initialFrames: try [
                frame("durableScope", ["scope": firstScope], host: host),
                frame("runtimeBatch", ["events": [event("turn/started", at: date),
                    event("turn/completed", at: date.addingTimeInterval(1), ["status": "completed"])]], host: host),
                frame("durableSuspended", host: host)
            ])
            let snapshots = DesktopEngineSnapshots()
            let runtime = EngineRuntime(demo: false, now: { date.addingTimeInterval(2) }, dismissalStore: nil,
                desktopServices: factory.services(supportsDurable: true), output: { snapshots.append($0) })
            _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex"],
                "codexHome": EngineCodexSourceReport.path(root), "monitorRemoteControl": false]))
            let connection = try XCTUnwrap(factory.all().first)
            XCTAssertTrue(snapshots.all().allSatisfy { $0.tasks.isEmpty && $0.notices.isEmpty && $0.activityLinks?.isEmpty != false },
                "The buffered ending remains hidden during initialization and suspension")
            try await connection.send(frame("durableScope", ["scope": nextScope.map { $0 as Any } ?? NSNull()], host: host))
            if nextScope == firstScope {
                let restored = try XCTUnwrap(snapshots.all().last?.presentation.rows.first)
                XCTAssertEqual(restored.phase, "completed")
                XCTAssertTrue(restored.unread)
                XCTAssertEqual(snapshots.all().flatMap(\.notices).filter { $0.kind == "completed" }.count, 1)
            } else {
                try await connection.send(frame("durableScope", ["scope": firstScope], host: host))
                XCTAssertTrue(snapshots.all().last?.tasks.isEmpty == true, "Changing or revoking the account discards the buffered ending")
                XCTAssertTrue(snapshots.all().flatMap(\.notices).isEmpty)
            }
            await runtime.stop()
        }
    }

}
