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
        let monitor = RealtimeActivityMonitor(controlCatalog: RemoteControlCatalog(fetch: { _ in throw CodexClientError.invalidResponse },
            files: TestFileSystem(), makeClient: { _ in nil }), services: .init(
            desktopAvailable: { _ in false }, controlAvailable: { _ in false },
            makeDesktop: { _, _, _, _, _, _ in fatalError("no Desktop in this test") }, processes: launcher,
            python: URL(fileURLWithPath: "/fixture/python"), ssh: URL(fileURLWithPath: "/fixture/ssh"),
            sshTargets: { _ in targets }, sshArguments: { ["-T", "--", $0.alias] }))
        let home = home()
        await monitor.startAsync(home: home, includeSSH: true, includeRemoteControl: false) { _ in }
        XCTAssertEqual(launcher.children.count, 3)
        let up = try XCTUnwrap(launcher.launches("up").first)
        await up.output(try line(["kind": "status", "connected": true, "attached": 0]))
        // The VPN is down: these helpers die before their first frame.
        for alias in ["down", "distro"] { await launcher.launches(alias)[0].ended() }
        await monitor.startAsync(home: home, includeSSH: true, includeRemoteControl: false) { _ in }
        XCTAssertEqual(launcher.children.count, 3, "The routine 30-second discovery keeps the backoff")

        await monitor.reconnectUnreachableSSH()
        XCTAssertEqual(launcher.launches("down").count, 2, "The network came back: the failed host reconnects now")
        XCTAssertEqual(launcher.launches("distro").count, 1, "WSL keeps its own schedule")
        XCTAssertEqual(launcher.launches("up").count, 1)
        XCTAssertEqual(up.closeCount, 0, "A live helper keeps its connection and state")
        await monitor.reconnectUnreachableSSH()
        XCTAssertEqual(launcher.launches("down").count, 2, "A helper already reconnecting is not started twice")
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
        await monitor.shutdown()
        await monitor.reconnectUnreachableSSH()
        XCTAssertEqual(launcher.children.count, 5)
    }
}
