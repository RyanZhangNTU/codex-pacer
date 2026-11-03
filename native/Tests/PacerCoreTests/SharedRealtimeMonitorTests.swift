import Foundation
import XCTest
@testable import PacerCore

private struct NoRealtimeHelper: HelperProcessLauncher {
    func launch(_ request: ChildProcessRequest, output: @escaping @Sendable (Data) async -> Void,
                ended: @escaping @Sendable () async -> Void) throws -> any ChildProcessConnection {
        throw CodexClientError.disconnected
    }
}
private struct SharedRealtimeServices {
    let makeConnection: @Sendable (URL, TimeInterval, @escaping @Sendable (Data) async -> Void,
                                  @escaping @Sendable () async -> Void) -> any DesktopActivityChannel
    func makeMonitor(retryInterval: TimeInterval = 30) -> RealtimeActivityMonitor {
        let catalog = RemoteControlCatalog(fetch: { _ in throw CodexClientError.invalidResponse },
            files: TestFileSystem(), makeClient: { _ in nil })
        return RealtimeActivityMonitor(controlCatalog: catalog, services: .init(
            desktopAvailable: { _ in true }, controlAvailable: { _ in false },
            makeDesktop: { home, _, _, interval, frame, closed in makeConnection(home, interval, frame, closed) },
            processes: NoRealtimeHelper(), python: URL(fileURLWithPath: "/unused/python"), ssh: URL(fileURLWithPath: "/unused/ssh")),
            retryInterval: retryInterval)
    }
}
private struct SharedRealtimeValue: Sendable {
    let context: UInt64
    let activities: [SessionActivity]
    let attention: [PendingAttentionRequest]
    let attentionThreads: Set<String>
    let names: [SessionNameUpdate]
    let performance: [SessionPerformanceUpdate]
    let status: RuntimeStreamStatus
}
private actor DesktopTestConnection: DesktopActivityChannel {
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
    var services: SharedRealtimeServices {
        .init { [self] _, _, frame, closed in
            let connection = DesktopTestConnection(frame: frame, closed: closed)
            lock.lock(); created.append(connection); lock.unlock(); return connection
        }
    }
    func all() -> [DesktopTestConnection] { lock.lock(); defer { lock.unlock() }; return created }
}
private actor DesktopMonitorStates {
    var values: [SharedRealtimeValue] = []
    func append(_ value: SharedRealtimeValue) { values.append(value) }
}
// Test adapter preserves the old assertion inputs while exercising Core's
// public lifecycle. It owns no reconnect, parser, state or delivery task.
private struct RealtimeMonitorFixture {
    let monitor: RealtimeActivityMonitor
    let output: @Sendable (SharedRealtimeValue) async -> Void
    init(services: SharedRealtimeServices, retryInterval: TimeInterval = 30,
         output: @escaping @Sendable (SharedRealtimeValue) async -> Void) {
        monitor = services.makeMonitor(retryInterval: retryInterval); self.output = output
    }
    func configure(home: URL, enabled: Bool, expanded: Bool, context: UInt64) async {
        guard enabled else { await monitor.shutdown(); return }
        await monitor.startAsync(home: home, includeSSH: false, includeRemoteControl: false, useSSHFallback: false,
            refreshPolicy: expanded ? .expanded : .collapsed) { value in
                await output(.init(context: context, activities: value.activities,
                    attention: value.localDesktopAttention,
                    attentionThreads: value.attentionThreads, names: value.names, performance: value.performance, status: value.localDesktopStatus))
            }
    }
    func discover(_ threads: [String]) async { await monitor.discover(threads) }
    func setExpanded(_ value: Bool) async { await monitor.updateRefreshPolicy(value ? .expanded : .collapsed, flushPending: value) }
    func stop() async { await monitor.shutdown() }
}

final class SharedRealtimeMonitorTests: XCTestCase {
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
        let monitor = RealtimeMonitorFixture(services: factory.services) { await capture.append($0) }
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
    func testReconnectNeedsNewRuntimeEvidenceAndRejectsThePreviousPipeCallbacks() async throws {
        let factory = DesktopTestFactory(), capture = DesktopMonitorStates()
        let monitor = RealtimeMonitorFixture(services: factory.services, retryInterval: 0.02) { await capture.append($0) }
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
    func testDisconnectKeepsRuntimeAvailabilityEvidenceUntilANewPipeOpens() async throws {
        let factory = DesktopTestFactory(), capture = DesktopMonitorStates()
        let monitor = RealtimeMonitorFixture(services: factory.services) { await capture.append($0) }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-eof-evidence")
        await monitor.configure(home: home, enabled: true, expanded: false, context: 1)
        let first = try XCTUnwrap(factory.all().first)
        try await first.send(frame("runtimeBatch", ["events": [event("turn/started", at: Date())]]))
        await first.disconnect()
        let closed = await capture.values.last
        XCTAssertEqual(closed?.status.connected, false)
        XCTAssertEqual(closed?.status.sourceAvailable, true)
        await monitor.configure(home: home.appendingPathComponent("next"), enabled: true, expanded: false, context: 2)
        let opened = await capture.values.last
        XCTAssertEqual(opened?.status.sourceAvailable, false)
        XCTAssertTrue(opened?.activities.isEmpty == true)
        await monitor.stop()
    }
}
