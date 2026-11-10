import Foundation
import XCTest
@testable import PacerCore
@testable import PacerEngineSupport

private final class WSLHookClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: Double) { lock.lock(); date += seconds; lock.unlock() }
}
private final class WSLHookDigests: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func read() -> [String: String] { lock.lock(); defer { lock.unlock() }; return values }
    func write(_ values: [String: String]) { lock.lock(); self.values = values; lock.unlock() }
}
private actor WSLHookJobs {
    var calls: [String: Int] = [:], rows: [EngineClaudeRemoteSetup] = []
    var fail: Set<String> = [], hold: Set<String> = []
    var waiting: [String: CheckedContinuation<Void, Never>] = [:]
    func flags(fail: Set<String> = [], hold: Set<String> = []) { self.fail = fail; self.hold = hold }
    func install(_ target: RemoteActivityTarget) async throws -> ClaudeHookInstaller.Status {
        calls[target.alias, default: 0] += 1
        if hold.contains(target.alias) { await withCheckedContinuation { waiting[target.alias] = $0 } }
        if fail.contains(target.alias) { throw ClaudeRemoteSetup.Failure.invalidSettings }
        return .init(hooksConfigured: true, telemetryConfigured: true, statusLineConfigured: true)
    }
    func publish(_ rows: [EngineClaudeRemoteSetup]) { self.rows = rows }
    func release(_ alias: String) { hold.remove(alias); waiting.removeValue(forKey: alias)?.resume() }
    func count() -> Int { calls.values.reduce(0, +) }
}
private final class WSLHookChild: ChildProcessConnection, @unchecked Sendable {
    let exited = ShutdownSignal(), ioClosed = ShutdownSignal()
    let output: @Sendable (Data) async -> Void
    private let lock = NSLock()
    private var closes = 0, kills = 0
    init(output: @escaping @Sendable (Data) async -> Void) { self.output = output }
    var isRunning: Bool { !exited.isFinished }
    var terminationStatus: Int32? { isRunning ? nil : 0 }
    func errorMessage() -> String { "" }
    func write(_ data: Data) throws {}
    func close() { lock.lock(); closes += 1; lock.unlock(); exited.finish(); ioClosed.finish() }
    func terminateImmediately() { lock.lock(); kills += 1; lock.unlock(); exited.finish(); ioClosed.finish() }
    func counts() -> (Int, Int) { lock.lock(); defer { lock.unlock() }; return (closes, kills) }
    func complete() async {
        await output(Data(#"{"hooksConfigured":true,"telemetryConfigured":true,"statusLineConfigured":true,"telemetryConflict":false,"telemetryConflictReason":"none"}"#.utf8))
        exited.finish(); ioClosed.finish()
    }
}
private final class WSLHookLaunch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (ChildProcessRequest, Data, WSLHookChild)?
    func start(_ request: ChildProcessRequest, _ data: Data, _ output: @escaping @Sendable (Data) async -> Void) -> WSLHookChild {
        let child = WSLHookChild(output: output); lock.lock(); value = (request, data, child); lock.unlock(); return child
    }
    func read() -> (ChildProcessRequest, Data, WSLHookChild)? { lock.lock(); defer { lock.unlock() }; return value }
}
final class WindowsWSLHookTests: XCTestCase {
    private let ssh = RemoteActivityTarget(id: "remote-ssh-discovered:fixture", name: "SSH", alias: "fixture", home: "~/.claude")
    private let wsl = RemoteActivityTarget(id: "wsl:fixture", name: "WSL", alias: "wsl-fixture-old", home: "/home/fixture/.claude")
    private func status() -> RuntimeStreamStatus { var value = RuntimeStreamStatus(); value.connected = true; value.sourceAvailable = true; return value }
    private func wait(_ condition: () async -> Bool) async throws {
        let end = Date().addingTimeInterval(TestWait.limit)
        while !(await condition()), Date() < end { try await Task.sleep(nanoseconds: 5_000_000) }
        let ready = await condition(); XCTAssertTrue(ready)
        if !ready { throw ClaudeRemoteSetup.Failure.timedOut }
    }
    private func services(_ jobs: WSLHookJobs, _ digests: WSLHookDigests, digest: String) -> EngineClaudeRemoteServices {
        .init(digest: { _ in digest }, install: { target, _, _ in try await jobs.install(target) }, shutdown: {}, loadDigests: { digests.read() }, saveDigests: { digests.write($0) })
    }
    func testSSHAndWSLUseOneVersionCacheBackoffAndManualRetryPolicy() async throws {
        let jobs = WSLHookJobs(), clock = WSLHookClock(), digests = WSLHookDigests(), digest = String(repeating: "a", count: 64)
        await jobs.flags(fail: [ssh.alias, wsl.alias])
        let coordinator = WindowsClaudeRemoteCoordinator(services: services(jobs, digests, digest: digest), now: { clock.now() }, maximumTargets: 16)
        let targets = [ssh, wsl], statuses = [ssh.id: status(), wsl.id: status()]
        func configure() async { await coordinator.configure(targets: targets, statuses: statuses, enabled: true, version: 1, update: { rows, _ in await jobs.publish(rows) }) }
        await configure(); try await wait { await jobs.rows.filter { $0.message != nil }.count == 2 }
        let first = await jobs.rows, calls = await jobs.count()
        XCTAssertEqual(calls, 2); XCTAssertEqual(Set(first.compactMap(\.retryAt)), [clock.now().addingTimeInterval(1800).timeIntervalSince1970])
        clock.advance(1799); await configure(); let before = await jobs.count(); XCTAssertEqual(before, 2)
        clock.advance(1); await configure(); try await wait { let count = await jobs.count(), rows = await jobs.rows; return count == 4 && rows.allSatisfy { !$0.inFlight } }
        await jobs.flags()
        for target in targets {
            let rows = await jobs.rows, row = try XCTUnwrap(rows.first { $0.sourceID == target.id })
            let accepted = await coordinator.retry(sourceID: target.id, context: row.context); XCTAssertTrue(accepted)
            try await wait { await jobs.rows.first { $0.sourceID == target.id }?.configured == true }
        }
        await configure(); let stable = await jobs.count(); XCTAssertEqual(stable, 6)
        XCTAssertEqual(Set(digests.read().keys), [ssh.alias, wsl.alias])
        await coordinator.shutdown()
        let upgraded = WindowsClaudeRemoteCoordinator(services: services(jobs, digests, digest: String(repeating: "b", count: 64)), now: { clock.now() }, maximumTargets: 16)
        await upgraded.configure(targets: targets, statuses: statuses, enabled: true, version: 2, update: { _, _ in })
        try await wait { await jobs.count() == 8 }; await upgraded.shutdown()
    }
    func testWSLRootReplacementRevokesRetryContextAndLateSuccessCannotClaimTheNewSlot() async throws {
        let jobs = WSLHookJobs(), digests = WSLHookDigests()
        var replacement = wsl
        replacement = .init(id: replacement.id, name: replacement.name, alias: "wsl-fixture-new", home: "/home/fixture/other-claude")
        await jobs.flags(hold: [wsl.alias, replacement.alias])
        let coordinator = WindowsClaudeRemoteCoordinator(services: services(jobs, digests, digest: String(repeating: "c", count: 64)), maximumTargets: 16)
        await coordinator.configure(targets: [wsl], statuses: [wsl.id: status()], enabled: true, version: 1, update: { rows, _ in await jobs.publish(rows) })
        try await wait { await jobs.waiting[self.wsl.alias] != nil }
        let originalRows = await jobs.rows, prior = try XCTUnwrap(originalRows.first?.context)
        await coordinator.configure(targets: [replacement], statuses: [replacement.id: status()], enabled: true, version: 1, update: { rows, _ in await jobs.publish(rows) })
        try await wait { await jobs.waiting[replacement.alias] != nil }
        let changed = await jobs.rows.first?.context
        XCTAssertNotEqual(prior, changed)
        let stale = await coordinator.retry(sourceID: wsl.id, context: prior); XCTAssertFalse(stale)
        await jobs.release(wsl.alias)
        XCTAssertTrue(digests.read().isEmpty)
        let pending = await jobs.rows.first; XCTAssertTrue(pending?.inFlight == true); XCTAssertFalse(pending?.configured == true)
        await jobs.release(replacement.alias); try await wait { await jobs.rows.first?.configured == true }
        XCTAssertNil(digests.read()[wsl.alias]); XCTAssertNotNil(digests.read()[replacement.alias])
        await coordinator.shutdown()
    }
    func testWSLSupervisorKeepsStdinUntilCompletionAndDropsRevokedResults() async throws {
        let profile = WindowsWSLProfile(distro: "Fixture", user: "fixture", uid: 1000, home: "/home/fixture", identity: "2:40",
            codexHome: "/home/fixture/.codex", claudeHome: "/home/fixture/.claude", codexIdentity: "2:41", claudeIdentity: "2:42")
        let registry = WindowsWSLRegistry(), launch = WSLHookLaunch()
        XCTAssertTrue(registry.accept([profile], installed: ["fixture"], ticket: registry.begin()))
        let wsl = WindowsWSLServices(registry: registry, start: { request, input, output, _ in launch.start(request, input, output) })
        let arguments = try wsl.setupArguments(XCTUnwrap(profile.target(.claude)))
        let operation = WindowsClaudeSetupOperation(executable: wsl.executable, arguments: arguments, environment: ["WSLENV": "PRIVATE"], wsl: wsl)
        try operation.start()
        let capture = try XCTUnwrap(launch.read())
        XCTAssertTrue(capture.0.arguments.contains { $0.contains("os.killpg") })
        XCTAssertLessThan(capture.0.arguments.joined().utf8.count, 30000); XCTAssertNil(capture.0.environment["WSLENV"])
        XCTAssertEqual(capture.2.counts().0, 0, "WSL setup needs a live stdin owner until its Linux child finishes")
        await capture.2.complete()
        let response = try XCTUnwrap(operation.result()), status = try ClaudeRemoteSetup.status(data: response.data, exitStatus: response.exitStatus)
        XCTAssertTrue(status.hooksConfigured); XCTAssertTrue(status.statusLineConfigured)
        registry.suspend()
        XCTAssertThrowsError(try operation.result()) { XCTAssertEqual($0 as? ClaudeRemoteSetup.Failure, .cancelled) }
        operation.abort(.cancelled)
        XCTAssertGreaterThan(capture.2.counts().0, 0); XCTAssertGreaterThan(capture.2.counts().1, 0)
    }
    func testCombinedTargetsStayBoundedWithoutDroppingTheWSLGroup() async throws {
        let jobs = WSLHookJobs(), digests = WSLHookDigests()
        let targets = (0..<8).flatMap { index in [
            RemoteActivityTarget(id: ConnectionSource.sshPrefix + "host\(index)", name: "SSH", alias: "host\(index)", home: "~/.claude"),
            RemoteActivityTarget(id: ConnectionSource.wslPrefix + "host\(index)", name: "WSL", alias: "wsl-host\(index)", home: "/home/fixture/.claude")] }
        let coordinator = WindowsClaudeRemoteCoordinator(services: services(jobs, digests, digest: String(repeating: "d", count: 64)), maximumTargets: 16)
        await coordinator.configure(targets: targets + [ssh], statuses: Dictionary(uniqueKeysWithValues: (targets + [ssh]).map { ($0.id, status()) }),
            enabled: true, version: 1, update: { rows, _ in await jobs.publish(rows) })
        try await wait { let count = await jobs.count(), rows = await jobs.rows; return count == 16 && rows.filter(\.configured).count == 16 }
        let rows = await jobs.rows
        XCTAssertEqual(rows.filter { $0.sourceID.hasPrefix(ConnectionSource.wslPrefix) }.count, 8)
        XCTAssertEqual(rows.filter { $0.sourceID.hasPrefix(ConnectionSource.sshPrefix) }.count, 8)
        XCTAssertEqual(digests.read().count, 16)
        await coordinator.shutdown()
    }
}
