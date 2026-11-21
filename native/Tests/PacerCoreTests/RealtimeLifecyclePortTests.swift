import Foundation
import XCTest
@testable import PacerCore

private actor RealtimeTestGate {
    let entered = ShutdownSignal()
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered.finish()
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { open = true; let current = waiters; waiters = []; for waiter in current { waiter.resume() } }
}
private final class RealtimeStalledChild: ChildProcessConnection, @unchecked Sendable {
    let exited = ShutdownSignal(), ioClosed = ShutdownSignal()
    private let lock = NSLock()
    private var running = true
    private(set) var closed = false
    private(set) var forced = false
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    var terminationStatus: Int32? { isRunning ? nil : 0 }
    func errorMessage() -> String { "" }
    func write(_ data: Data) throws {}
    func close() { lock.lock(); closed = true; lock.unlock() }
    func terminateImmediately() {
        lock.lock(); running = false; forced = true; lock.unlock()
        exited.finish(); ioClosed.finish()
    }
}
private final class RealtimeStalledLauncher: HelperProcessLauncher, @unchecked Sendable {
    let child = RealtimeStalledChild()
    private(set) var request: ChildProcessRequest?
    private(set) var output: (@Sendable (Data) async -> Void)?
    func launch(_ request: ChildProcessRequest, output: @escaping @Sendable (Data) async -> Void,
                ended: @escaping @Sendable () async -> Void) throws -> any ChildProcessConnection {
        guard child.isRunning else { throw CodexClientError.disconnected }
        self.request = request; self.output = output; return child
    }
}
final class RealtimeLifecyclePortTests: XCTestCase {
    /// One SSH host whose helper the stalled launcher owns.
    private func services(_ launcher: RealtimeStalledLauncher) -> RealtimeActivityServices {
        let target = RemoteActivityTarget(id: "remote-ssh-discovered:fixture", name: "fixture", alias: "fixture", home: "~/.codex")
        return .init(processes: launcher, ssh: URL(fileURLWithPath: "/fixture/ssh"),
                     sshTargets: { _ in [target] }, sshArguments: { _ in ["--", "fixture"] })
    }
    func testStalledHelperAndConsumerStillCloseAndForceOnlyTheOwnedChild() async throws {
        let gate = RealtimeTestGate(), launcher = RealtimeStalledLauncher()
        let monitor = RealtimeActivityMonitor(services: services(launcher))
        await monitor.startAsync(home: FileManager.default.temporaryDirectory) { value in
            if !value.activities.isEmpty { await gate.wait() }
        }
        XCTAssertEqual(launcher.request?.executable.lastPathComponent, "ssh")
        XCTAssertEqual(launcher.request?.arguments.prefix(2), ["--", "fixture"])
        var bytes = try JSONSerialization.data(withJSONObject: ["kind": "status", "connected": true]) + Data([10])
        bytes += try JSONSerialization.data(withJSONObject: ["kind": "runtimeBatch", "events": [[
            "method": "turn/started", "threadId": "019a0000-0000-7000-8000-000000000001", "turnId": "current",
            "at": Date().timeIntervalSince1970]]]) + Data([10])
        let delivery = Task { await launcher.output?(bytes) }
        let entered = await gate.entered.wait(until: ShutdownDeadline())
        XCTAssertTrue(entered)
        let started = ProcessInfo.processInfo.systemUptime
        await monitor.shutdown()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, ShutdownDeadline.maximumWait + 0.25)
        XCTAssertTrue(launcher.child.closed); XCTAssertTrue(launcher.child.forced); XCTAssertFalse(launcher.child.isRunning)
        await gate.release(); await delivery.value
        await launcher.output?(bytes)
        let activities = await monitor.activities()
        XCTAssertTrue(activities.isEmpty)
    }
    func testReplacingHomeForcesTheOldHelperWithinTheSameBudget() async throws {
        actor Publications { var count = 0; func append() { count += 1 } }
        let launcher = RealtimeStalledLauncher(), publications = Publications()
        let monitor = RealtimeActivityMonitor(services: services(launcher))
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-switch-home")
        await monitor.startAsync(home: home) { _ in await publications.append() }
        let oldOutput = launcher.output, started = ProcessInfo.processInfo.systemUptime
        await monitor.startAsync(home: home.appendingPathComponent("next")) { _ in await publications.append() }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, ShutdownDeadline.maximumWait + 0.25)
        XCTAssertTrue(launcher.child.closed); XCTAssertTrue(launcher.child.forced); XCTAssertFalse(launcher.child.isRunning)
        let count = await publications.count
        await oldOutput?(Data("{\"kind\":\"status\",\"connected\":true}\n".utf8))
        let after = await publications.count
        XCTAssertEqual(after, count)
        await monitor.shutdown()
    }
}
