import Foundation
import XCTest
@testable import PacerCore

/// A host behind a VPN or Wi-Fi that drops overnight backs off to 15 minutes.
/// When the network comes back, only failed SSH hosts reconnect at once.
final class SSHReconnectTests: XCTestCase {
    private final class Child: ChildProcessConnection, @unchecked Sendable {
        let alias: String
        let output: @Sendable (Data) async -> Void
        let ended: @Sendable () async -> Void
        let exited = ShutdownSignal(), ioClosed = ShutdownSignal()
        private let lock = NSLock()
        private var running = true, closes = 0
        init(alias: String, output: @escaping @Sendable (Data) async -> Void, ended: @escaping @Sendable () async -> Void) {
            self.alias = alias; self.output = output; self.ended = ended
        }
        var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
        var terminationStatus: Int32? { isRunning ? nil : 0 }
        var closeCount: Int { lock.lock(); defer { lock.unlock() }; return closes }
        func errorMessage() -> String { "" }
        func write(_ data: Data) throws {}
        func close() { lock.lock(); closes += 1; running = false; lock.unlock(); exited.finish(); ioClosed.finish() }
        func terminateImmediately() { close() }
    }
    private final class Launcher: HelperProcessLauncher, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Child] = []
        func launch(_ request: ChildProcessRequest, output: @escaping @Sendable (Data) async -> Void,
                    ended: @escaping @Sendable () async -> Void) throws -> any ChildProcessConnection {
            // Both monitors pass `... -- <host> <helper command>`.
            let child = Child(alias: request.arguments[request.arguments.count - 2], output: output, ended: ended)
            lock.lock(); values.append(child); lock.unlock()
            return child
        }
        var children: [Child] { lock.lock(); defer { lock.unlock() }; return values }
        func launches(_ alias: String) -> [Child] { children.filter { $0.alias == alias } }
    }
    private struct NoEvents: ActivityFileEvents {
        func watch(_ url: URL, isDirectory: Bool, changed: @escaping @Sendable (ActivityFileEvent) -> Void) -> (any ActivityFileWatch)? { nil }
    }
    private struct NoTelemetry: TelemetryTransport {
        func listen(port: UInt16, backlog: Int, accepted: @escaping @Sendable (any TelemetryConnection) -> Void) throws -> any TelemetryListener {
            throw TelemetryTransportFailure.unavailable
        }
    }
    private func target(_ alias: String, id: String? = nil) -> RemoteActivityTarget {
        RemoteActivityTarget(id: id ?? "remote-ssh-discovered:" + alias, name: alias, alias: alias, home: "~/.codex")
    }
    private func line(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) + Data([10]) }
    private func home() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("pacer-ssh-reconnect-" + UUID().uuidString) }

    func testBurstsSettleOnceAndRetriesStayApartWhileALinkFlaps() {
        var policy = SSHReconnectPolicy()
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(policy.delay(at: start), SSHReconnectPolicy.settle, "The first change waits only for the network to settle")
        policy.ran(at: start)
        XCTAssertEqual(policy.delay(at: start.addingTimeInterval(5)), SSHReconnectPolicy.spacing - 5, accuracy: 0.001)
        XCTAssertEqual(policy.delay(at: start.addingTimeInterval(14)), SSHReconnectPolicy.settle, accuracy: 0.001)
        XCTAssertEqual(policy.delay(at: start.addingTimeInterval(600)), SSHReconnectPolicy.settle)
    }

    func testCodexReconnectsOnlyFailedSSHHelpersAndKeepsLiveOnesAndWSL() async throws {
        let launcher = Launcher()
        let targets = [target("down"), target("up"), target("distro", id: ConnectionSource.wslPrefix + "distro")]
        let monitor = RealtimeActivityMonitor(services: .init(processes: launcher, ssh: URL(fileURLWithPath: "/fixture/ssh"),
            sshTargets: { _ in targets }, sshArguments: { ["-T", "--", $0.alias] }))
        let home = home()
        await monitor.startAsync(home: home, includeSSH: true) { _ in }
        XCTAssertEqual(launcher.children.count, 3)
        let up = try XCTUnwrap(launcher.launches("up").first)
        await up.output(try line(["kind": "status", "connected": true, "attached": 0]))
        // The VPN is down: these helpers die before their first frame.
        for alias in ["down", "distro"] { await launcher.launches(alias)[0].ended() }
        await monitor.startAsync(home: home, includeSSH: true) { _ in }
        XCTAssertEqual(launcher.children.count, 3, "The routine 30-second discovery keeps the backoff")

        await monitor.reconnectUnreachableSSH()
        XCTAssertEqual(launcher.launches("down").count, 2, "The network came back: the failed host reconnects now")
        XCTAssertEqual(launcher.launches("distro").count, 1, "WSL keeps its own schedule")
        XCTAssertEqual(launcher.launches("up").count, 1)
        XCTAssertEqual(up.closeCount, 0, "A live helper keeps its connection and state")
        await monitor.reconnectUnreachableSSH()
        XCTAssertEqual(launcher.launches("down").count, 2, "A helper already reconnecting is not started twice")
        let off = SSHHostMonitoring(offIDs: [targets[0].id])
        await launcher.launches("down")[1].ended()
        await monitor.updateSSHMonitoring(off)
        await monitor.reconnectUnreachableSSH()
        XCTAssertEqual(launcher.launches("down").count, 2)
        await monitor.updateSSHMonitoring(.init())
        XCTAssertEqual(launcher.launches("down").count, 3, "Re-enabling bypasses the previous backoff")
        XCTAssertEqual(up.closeCount, 0)
        await monitor.shutdown()
    }

    func testManagedSSHUsesItsDestinationAndKeepsItsDesktopIDAfterFailure() async throws {
        let launcher = Launcher()
        let managed = RemoteActivityTarget(id: "remote-ssh-codex-managed:fixture", name: "Build server",
            alias: "codex-fixture", home: "~/.codex", sshDestination: "fixture@build.example.test")
        let monitor = RealtimeActivityMonitor(services: .init(processes: launcher, ssh: URL(fileURLWithPath: "/fixture/ssh"),
            sshTargets: { _ in [managed] }, sshArguments: { $0.sshArguments(validDestination: { $0 == "fixture@build.example.test" }) }))
        await monitor.startAsync(home: home()) { _ in }
        let child = try XCTUnwrap(launcher.launches("fixture@build.example.test").first)
        XCTAssertTrue(launcher.launches(managed.alias).isEmpty)
        await child.output(try line(["kind": "status", "connected": true, "attached": 1]))
        let connected = await monitor.statuses()[managed.id]
        XCTAssertEqual(connected?.sourceName, managed.name)
        XCTAssertEqual(connected?.attachedThreads, 1)

        await child.ended()
        let failed = await monitor.statuses()[managed.id]
        XCTAssertEqual(failed?.sourceName, managed.name)
        XCTAssertEqual(failed?.hasConnectionFailure, true)
        await monitor.reconnectUnreachableSSH()
        XCTAssertEqual(launcher.launches("fixture@build.example.test").count, 2)
        await monitor.shutdown()
    }

    func testClaudeReconnectsOnlyFailedSSHHostsAndKeepsParkedHostsAndWSL() async throws {
        let launcher = Launcher()
        let targets = [target("down"), target("up"), target("nohome"), target("distro", id: ConnectionSource.wslPrefix + "distro")]
        let monitor = ClaudeActivityMonitor(sshExecutable: URL(fileURLWithPath: "/fixture/ssh"), processes: launcher,
            fileEvents: NoEvents(), telemetryTransport: NoTelemetry(), remoteMirrorSessionIDs: { _ in [] },
            files: TestFileSystem(), clock: { Date() }, sshArguments: { ["-T", "--", $0.alias] })
        await monitor.reconnectUnreachableSSH()
        XCTAssertTrue(launcher.children.isEmpty, "Nothing reconnects before the monitor starts or after it stops")
        await monitor.start(home: home(), remoteTargets: targets) { _, _, _, _ in }
        XCTAssertEqual(launcher.children.count, 4)
        let up = try XCTUnwrap(launcher.launches("up").first)
        await up.output(try line(["kind": "status", "connected": true, "watchingLogs": false]))
        await launcher.launches("nohome")[0].output(try line(["kind": "status", "connected": true, "claudeHome": false, "watchingLogs": false]))
        for alias in ["down", "distro"] { await launcher.launches(alias)[0].ended() }
        await monitor.updateRemoteTargets(targets)
        XCTAssertEqual(launcher.children.count, 4, "Routine discovery keeps both backoffs")

        await monitor.reconnectUnreachableSSH()
        XCTAssertEqual(launcher.launches("down").count, 2, "The network came back: the failed host reconnects now")
        XCTAssertEqual(launcher.launches("nohome").count, 1, "A host without a Claude home stays parked")
        XCTAssertEqual(launcher.launches("distro").count, 1, "WSL keeps its own schedule")
        XCTAssertEqual(up.closeCount, 0, "A live helper keeps its connection and state")
        let statuses = await monitor.statuses()
        XCTAssertEqual(statuses["remote-ssh-discovered:up"]?.connected, true)
        let off = SSHHostMonitoring(offIDs: [targets[0].id])
        let replacement = try XCTUnwrap(launcher.launches("down").last)
        await monitor.updateRemoteTargets(off.monitored(targets))
        XCTAssertEqual(replacement.closeCount, 1, "Switching off closes the live reader")
        await replacement.ended()
        await monitor.reconnectUnreachableSSH()
        await monitor.refresh(remoteTargetID: targets[0].id)
        XCTAssertEqual(launcher.launches("down").count, 2, "Late EOF, network changes and manual retry cannot restart it")
        await monitor.updateRemoteTargets(targets)
        XCTAssertEqual(launcher.launches("down").count, 3)
        XCTAssertEqual(up.closeCount, 0)
        await monitor.shutdown()
        await monitor.reconnectUnreachableSSH()
        XCTAssertEqual(launcher.children.count, 6)
    }
}
