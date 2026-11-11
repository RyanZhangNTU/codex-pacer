#if canImport(PacerMacSupport)
import PacerMacSupport
#else
@testable import PacerEngineSupport
#endif
import XCTest
@testable import PacerCore

final class SharedActivityMonitorTests: XCTestCase {
    private struct NoEvents: ActivityFileEvents {
        func watch(_ url: URL, isDirectory: Bool, changed: @escaping @Sendable (ActivityFileEvent) -> Void) -> (any ActivityFileWatch)? { nil }
    }
    private struct NoTelemetry: TelemetryTransport {
        func listen(port: UInt16, backlog: Int, accepted: @escaping @Sendable (any TelemetryConnection) -> Void) throws -> any TelemetryListener { throw TelemetryTransportFailure.unavailable }
    }
    private final class Child: ChildProcessConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var running = true, closes = 0, kills = 0
        private var controls: [Data] = []
        let output: @Sendable (Data) async -> Void
        let ended: @Sendable () async -> Void
        let exited = ShutdownSignal(), ioClosed = ShutdownSignal()
        let ignoresClose: Bool
        init(ignoresClose: Bool, output: @escaping @Sendable (Data) async -> Void, ended: @escaping @Sendable () async -> Void) {
            self.ignoresClose = ignoresClose; self.output = output; self.ended = ended
        }
        var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
        var terminationStatus: Int32? { isRunning ? nil : 0 }
        func errorMessage() -> String { "" }
        func write(_ data: Data) throws { lock.lock(); controls.append(data); lock.unlock() }
        var waitingUpdates: [[String]] {
            lock.lock(); defer { lock.unlock() }
            return controls.compactMap { data in
                (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["waitingSessionIDs"] as? [String]
            }
        }
        func close() {
            lock.lock(); closes += 1; if !ignoresClose { running = false }; lock.unlock()
            if !ignoresClose { exited.finish(); ioClosed.finish() }
        }
        func terminateImmediately() { lock.lock(); kills += 1; running = false; lock.unlock(); exited.finish(); ioClosed.finish() }
        var counts: (close: Int, kill: Int) { lock.lock(); defer { lock.unlock() }; return (closes, kills) }
    }
    private final class Launcher: HelperProcessLauncher, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Child] = []
        var ignoresClose = false
        func launch(_ request: ChildProcessRequest, output: @escaping @Sendable (Data) async -> Void,
                    ended: @escaping @Sendable () async -> Void) throws -> any ChildProcessConnection {
            let child = Child(ignoresClose: ignoresClose, output: output, ended: ended)
            lock.lock(); values.append(child); lock.unlock()
            return child
        }
        var children: [Child] { lock.lock(); defer { lock.unlock() }; return values }
    }
    private final class Observations: @unchecked Sendable {
        private let lock = NSLock()
        private var updates = 0
        func receive() { lock.lock(); updates += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return updates }
    }
    private func monitor(_ launcher: Launcher) -> ClaudeActivityMonitor {
        ClaudeActivityMonitor(sshExecutable: FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-ssh"), processes: launcher,
            fileEvents: NoEvents(), telemetryTransport: NoTelemetry(), remoteMirrorSessionIDs: { _ in [] }, files: TestFileSystem(), clock: { Date() }, sshArguments: {
                $0.sshArguments(validDestination: { ClaudeSSHRouteResolver.validDestination($0, normalizeIPv6: { _ in nil }) })
            })
    }
    private func target(_ id: String = "fixture") -> RemoteActivityTarget {
        RemoteActivityTarget(id: "remote-ssh-discovered:" + id, name: "Synthetic SSH", alias: id, home: "~/.claude")
    }
    private func row(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) + Data([10]) }
    func testRemoteHelperReceivesConfirmedWaitsAndTheirResolutionOnce() async throws {
        let launcher = Launcher(), monitor = monitor(launcher)
        await monitor.start(home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), remoteTargets: [target()]) { _, _, _, _ in }
        let child = try XCTUnwrap(launcher.children.first), date = Date().timeIntervalSince1970
        func event(_ kind: String, at: Double) throws -> Data {
            try row(["kind": kind, "origin": "hook", "sessionId": "fixture-session", "promptId": "fixture-turn", "itemId": "fixture-item", "at": at])
        }
        await child.output(try event("prompt", at: date) + event("approval", at: date + 1))
        await child.output(try event("approval", at: date + 1))
        XCTAssertEqual(child.waitingUpdates, [["fixture-session"]])
        await child.output(try event("attentionCleared", at: date + 2))
        XCTAssertEqual(child.waitingUpdates, [["fixture-session"], []])
        await monitor.shutdown()
    }
    func testFragmentedTerminalFramesHeartbeatEOFAndLateResultsShareOneLifecycle() async throws {
        let launcher = Launcher(), monitor = monitor(launcher), target = target(), observations = Observations()
        await monitor.start(home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), remoteTargets: [target]) { _, _, _, _ in observations.receive() }
        let child = try XCTUnwrap(launcher.children.first), date = Date().timeIntervalSince1970
        let bytes = try row(["kind": "status", "connected": true, "watchingLogs": false, "loopIterations": 3])
            + row(["kind": "prompt", "origin": "hook", "sessionId": "fixture-session", "promptId": "fixture-turn", "at": date])
            + row(["kind": "stopVerified", "origin": "transcript", "sessionId": "fixture-session", "promptId": "fixture-turn", "at": date + 0.01])
        for offset in stride(from: 0, to: bytes.count, by: 17) { await child.output(bytes.subdata(in: offset..<min(bytes.count, offset + 17))) }
        let live = await monitor.statuses(), activities = await monitor.activities()
        XCTAssertEqual(live[target.id]?.helperLoopIterations, 3)
        XCTAssertEqual(live[target.id]?.connected, true)
        XCTAssertEqual(activities.first { $0.sourceHostID == target.id }?.phase, .completed)
        await child.ended()
        let ended = await monitor.statuses(), retained = await monitor.activities()
        XCTAssertEqual(ended[target.id]?.connected, false)
        XCTAssertEqual(retained.first { $0.sourceHostID == target.id }?.phase, .completed)
        XCTAssertEqual(child.counts.close, 1)
        await monitor.shutdown()
        let count = observations.count
        await child.output(bytes); await child.ended()
        XCTAssertEqual(observations.count, count)
        let stopped = await monitor.statuses(); XCTAssertNil(stopped[target.id])
    }
    func testRemoteCapParkBackoffAndExplicitRefreshRetainHealthyChildren() async throws {
        let launcher = Launcher(), monitor = monitor(launcher)
        let targets = (0..<9).map { target("fixture-\($0)") }
        await monitor.start(home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), remoteTargets: targets) { _, _, _, _ in }
        XCTAssertEqual(launcher.children.count, 8)
        for child in launcher.children {
            await child.output(try row(["kind": "status", "connected": true, "watchingLogs": false]))
        }
        let first = try XCTUnwrap(launcher.children.first)
        await first.output(try row(["kind": "status", "connected": true, "claudeHome": false, "watchingLogs": false]))
        XCTAssertEqual(first.counts.close, 1)
        let statuses = await monitor.statuses()
        XCTAssertEqual(statuses.values.filter { $0.sourceAvailable == false }.count, 1)
        XCTAssertFalse(statuses.filter { $0.key != "local" }.values.contains { $0.hasConnectionFailure })
        await monitor.updateRemoteTargets(targets)
        XCTAssertEqual(launcher.children.count, 8, "Routine reconcile retains the missing-home backoff")
        await monitor.refresh()
        XCTAssertEqual(launcher.children.count, 9)
        XCTAssertTrue(launcher.children.dropFirst().prefix(7).allSatisfy { $0.counts.close == 0 })
        await monitor.shutdown()
        XCTAssertTrue(launcher.children.allSatisfy { $0.counts.close == 1 })
    }
    func testShutdownDeadlineEscalatesWhenChildAndReaderIgnoreClose() async throws {
        let launcher = Launcher(); launcher.ignoresClose = true
        let monitor = monitor(launcher)
        await monitor.start(home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), remoteTargets: [target()]) { _, _, _, _ in }
        let child = try XCTUnwrap(launcher.children.first), started = ProcessInfo.processInfo.systemUptime
        await monitor.shutdown(deadline: ShutdownDeadline(timeout: 0.05))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, ShutdownDeadline.maximumWait)
        XCTAssertEqual(child.counts.close, 1); XCTAssertEqual(child.counts.kill, 1)
        XCTAssertFalse(child.isRunning)
    }
}
