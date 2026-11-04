import Foundation
import XCTest
@testable import PacerCore
@testable import PacerEngineSupport

private actor IdleDesktopChannel: DesktopActivityChannel {
    func start() {}
    func discover(_ threads: [String]) {}
    func setHosts(_ hosts: Set<String>) {}
    func setBatchInterval(_ seconds: TimeInterval, flushPending: Bool) {}
    func stop() {}
}
private final class ReminderFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: EngineSnapshot?
    func append(_ data: Data) {
        guard let value = try? JSONDecoder().decode(EngineSnapshot.self, from: data) else { return }
        lock.lock(); snapshot = value; lock.unlock()
    }
    func last() -> EngineSnapshot? { lock.lock(); defer { lock.unlock() }; return snapshot }
}

final class EngineSSHReminderTests: XCTestCase {
    private let host = "remote-ssh-discovered:alias-a"
    private func command(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": UUID().uuidString, "method": method, "params": params])
    }
    private func until(_ message: String, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(15)
        while !condition() {
            if Date() >= end { XCTFail(message); throw ActivityNavigationError.unavailable }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// The Codex SSH helper is a real child process that exits before its
    /// first frame. Its stream status then leaves the snapshot and only the
    /// collector's failure record remains; the compact bar's SSH reminder must
    /// keep reporting it while the host is monitored.
    func testAnExitedCodexSSHHelperKeepsTheSSHReminderOnlyWhileMonitored() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SSH 提醒 " + UUID().uuidString)
        let home = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try JSONSerialization.data(withJSONObject: [
            "codex-managed-remote-connections": [["source": "discovered", "hostId": host, "alias": "alias-a"]],
            "remote-connection-auto-connect-by-host-id": [host: true]]).write(to: home.appendingPathComponent(".codex-global-state.json"))
        // The synthetic ssh records the call and exits with 255 before any frame.
        try Data().write(to: root.appendingPathComponent("disconnect"))
        let calls = root.appendingPathComponent("calls.jsonl")
        let fixture = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["PACER_SSH_FIXTURE"]))
        var environment = ProcessInfo.processInfo.environment
        environment["PACER_SSH_FIXTURE_ROOT"] = WindowsCodexExecutableDiscovery.path(root)
        let ssh = WindowsSSHServices(ssh: fixture, userHome: root, desktopFile: root.appendingPathComponent("ssh_configs.json"),
            environment: environment, resolve: { _, _ in nil })
        let frames = ReminderFrames()
        let runtime = EngineRuntime(demo: false, dismissalStore: nil,
            desktopServices: .init(makeConnection: { _, _, _, _ in IdleDesktopChannel() }), sshServices: ssh, output: { frames.append($0) })
        func reminders(_ warnings: [String]) -> [String: Any] { ["warnings": warnings, "lowLine": NSNull(), "spikeLine": NSNull()] }
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex"], "codexHome": EngineCodexSourceReport.path(home),
            "reminderSettings": reminders(["ssh"])]))
        func raised() -> Bool { frames.last()?.compactWarnings?.contains { $0.kind == .ssh } == true }
        func streaming() -> Bool { frames.last()?.sources.contains { $0.id == "codex:" + host } == true }
        func launched() -> Bool { (try? String(contentsOf: calls, encoding: .utf8))?.contains("alias-a") == true }
        // A starting helper already counts as disconnected; the boundary under
        // test is after its exit, when no stream status is left. The fixture
        // exits right after recording its call, well inside the settle delay.
        try await until("The helper did not run for the configured host", launched)
        try await until("The exited helper kept a stream status") { !streaming() }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(streaming(), "The helper must not reconnect inside its retry interval")
        XCTAssertTrue(raised(), "An exited SSH helper must keep the SSH reminder from its failure record")

        _ = await runtime.receive(try command("configure", ["monitorSSH": false]))
        try await until("An unmonitored host kept the SSH reminder") { !raised() }
        _ = await runtime.receive(try command("configure", ["monitorSSH": true, "reminderSettings": reminders([])]))
        _ = await runtime.receive(try command("refresh"))
        XCTAssertFalse(raised(), "A disabled SSH reminder stays hidden")
        await runtime.stop()
    }
}
