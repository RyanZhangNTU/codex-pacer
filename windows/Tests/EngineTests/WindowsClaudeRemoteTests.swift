import Foundation
import XCTest
@testable import PacerCore
@testable import PacerEngineSupport

private final class RemoteClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return time }
    func advance(_ seconds: TimeInterval) { lock.lock(); time += seconds; lock.unlock() }
}
private actor RemoteSetupCapture {
    var rows: [EngineClaudeRemoteSetup] = []
    var calls = 0, stops = 0, refreshes = 0
    var failure: ClaudeRemoteSetup.Failure? = .invalidSettings
    var held: CheckedContinuation<Void, Never>?
    var hold = false
    func install() async throws -> ClaudeHookInstaller.Status {
        calls += 1
        if hold { await withCheckedContinuation { held = $0 } }
        if let failure { throw failure }
        return .init(hooksConfigured: true, telemetryConfigured: true, statusLineConfigured: true, telemetryConflict: false)
    }
    func setFailure(_ value: ClaudeRemoteSetup.Failure?) { failure = value }
    func setHold() { hold = true }
    func release() { hold = false; held?.resume(); held = nil }
    func stop() { stops += 1 }
    func publish(_ values: [EngineClaudeRemoteSetup]) { rows = values }
    func refreshed() { refreshes += 1 }
}

final class WindowsClaudeRemoteTests: XCTestCase {
    private let target = RemoteActivityTarget(id: "remote-ssh-discovered:alias-a", name: "Synthetic", alias: "alias-a", home: "~/.claude")
    private func fixture() throws -> (URL, URL, [String: String]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("远程 hooks " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let exe = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["PACER_SSH_FIXTURE"]))
        var env = ProcessInfo.processInfo.environment
        env["PACER_SSH_FIXTURE_ROOT"] = WindowsCodexExecutableDiscovery.path(root)
        return (root, exe, env)
    }
    private func wait(_ condition: @escaping () async -> Bool) async throws {
        if try await TestWait.until(condition) { return }
        XCTFail("The synthetic remote setup did not reach its boundary"); throw ClaudeRemoteSetup.Failure.timedOut
    }
    private func installer(_ exe: URL, env: [String: String], timeout: TimeInterval = 15) -> ClaudeRemoteSetup {
        .init(executable: exe, timeout: timeout, makeOperation: {
            WindowsClaudeSetupOperation(executable: $0, arguments: $1, environment: env)
        }, validDestination: { ClaudeSSHRouteResolver.validDestination($0) }, validIdentityFile: { WindowsSSHServices.validIdentity($0) })
    }
    func testSharedInstallerPreservesUserEntriesIsIdempotentAndRejectsInvalidSettings() async throws {
        let (root, exe, env) = try fixture(), home = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let settings = home.appendingPathComponent("settings.json")
        let user: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "echo user-original"]]]]],
            "statusLine": ["type": "command", "command": "echo user-renderer"]]
        try JSONSerialization.data(withJSONObject: user).write(to: settings)
        let setup = installer(exe, env: env)
        let status = try await setup.install(target: target, requireHome: true)
        XCTAssertTrue(status.hooksConfigured); XCTAssertTrue(status.telemetryConfigured); XCTAssertTrue(status.statusLineConfigured)
        let installed = try Data(contentsOf: settings), text = String(decoding: installed, as: UTF8.self)
        XCTAssertTrue(text.contains("echo user-original"))
        let manifest = try Data(contentsOf: home.appendingPathComponent("pacer/installation.json"))
        XCTAssertTrue(String(decoding: manifest, as: UTF8.self).contains("echo user-renderer"))
        XCTAssertTrue(text.contains("pacer")); XCTAssertFalse(text.contains("PRIVATE SENTINEL"))
        let second = try await setup.install(target: target, requireHome: true)
        XCTAssertEqual(second, status); XCTAssertEqual(try Data(contentsOf: settings), installed)
        let damaged = Data("{PRIVATE SENTINEL".utf8); try damaged.write(to: settings)
        do { _ = try await setup.install(target: target, requireHome: true); XCTFail("Invalid settings must be preserved") }
        catch { XCTAssertEqual(error as? ClaudeRemoteSetup.Failure, .invalidSettings) }
        XCTAssertEqual(try Data(contentsOf: settings), damaged)
        let calls = String(decoding: try Data(contentsOf: root.appendingPathComponent("calls.jsonl")), as: UTF8.self)
        XCTAssertFalse(calls.contains("PRIVATE SENTINEL")); XCTAssertFalse(calls.contains("user-original"))
        XCTAssertTrue(calls.contains("BatchMode=yes")); XCTAssertTrue(calls.contains("UpdateHostKeys=no"))
        await setup.shutdown()
    }
    func testMissingHomeDoesNotCreateItAndTelemetryConflictPreservesUserConfiguration() async throws {
        let (root, exe, env) = try fixture(), home = root.appendingPathComponent(".claude"), setup = installer(exe, env: env)
        do { _ = try await setup.install(target: target, requireHome: true); XCTFail("Automatic setup requires Claude") }
        catch { XCTAssertEqual(error as? ClaudeRemoteSetup.Failure, .missingHome) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let file = home.appendingPathComponent("settings.json")
        try Data(#"{"env":{"OTEL_TRACES_EXPORTER":"user-exporter"}}"#.utf8).write(to: file)
        let status = try await setup.install(target: target, requireHome: true)
        XCTAssertTrue(status.telemetryConflict); XCTAssertFalse(status.telemetryConfigured); XCTAssertTrue(status.hooksConfigured)
        XCTAssertTrue(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("user-exporter"))
        await setup.shutdown()
    }
    func testOneShotEOFArrivesBeforeTimeoutAndOwnedProcessIsStopped() async throws {
        let (root, exe, env) = try fixture()
        try Data("hang".utf8).write(to: root.appendingPathComponent("setup-mode"))
        let setup = installer(exe, env: env, timeout: 1), began = ProcessInfo.processInfo.systemUptime
        do { _ = try await setup.install(target: target, requireHome: true); XCTFail("A silent installer must time out") }
        catch { XCTAssertEqual(error as? ClaudeRemoteSetup.Failure, .timedOut) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("eof").path))
        await setup.shutdown()
    }
    func testThirtyMinuteBackoffManualRetryIdempotenceAndVersionRefreshUseSharedPolicy() async throws {
        let capture = RemoteSetupCapture(), clock = RemoteClock(), digest = String(repeating: "a", count: 64)
        let services = EngineClaudeRemoteServices(digest: digest, install: { _ in try await capture.install() },
            shutdown: { await capture.stop() }, loadDigests: { [:] }, saveDigests: { _ in })
        let coordinator = WindowsClaudeRemoteCoordinator(services: services, now: { clock.now() })
        var connected = RuntimeStreamStatus(); connected.connected = true; connected.sourceAvailable = true
        let statuses = [target.id: connected]
        func configure(_ values: [RemoteActivityTarget], _ state: [String: RuntimeStreamStatus] = [:]) async {
            await coordinator.configure(targets: values, statuses: state, enabled: true, version: 1,
                update: { rows, _ in await capture.publish(rows) }, didConfigure: { _, _ in await capture.refreshed() })
        }
        await configure([target]); let zero = await capture.calls; XCTAssertEqual(zero, 0)
        await configure([target], statuses)
        try await wait { await capture.rows.first?.message != nil }
        let first = await capture.rows.first, count = await capture.calls
        XCTAssertEqual(count, 1); XCTAssertEqual(first?.retryAt, clock.now().addingTimeInterval(1800).timeIntervalSince1970)
        clock.advance(1799); await configure([target], statuses); let before = await capture.calls; XCTAssertEqual(before, 1)
        clock.advance(1); await configure([target], statuses)
        try await wait { let count = await capture.calls, row = await capture.rows.first; return count == 2 && row?.inFlight == false }
        await capture.setFailure(nil)
        let context = await capture.rows.first?.context
        let accepted = await coordinator.retry(sourceID: target.id, context: try XCTUnwrap(context)); XCTAssertTrue(accepted)
        try await wait { await capture.rows.first?.configured == true }
        await configure([target], statuses)
        let final = await capture.calls, refreshes = await capture.refreshes
        XCTAssertEqual(final, 3); XCTAssertEqual(refreshes, 1)
        let stale = await coordinator.retry(sourceID: target.id, context: UUID().uuidString); XCTAssertFalse(stale)
        await coordinator.shutdown()
        let disabled = await coordinator.retry(sourceID: target.id, context: try XCTUnwrap(context)); XCTAssertFalse(disabled)
        // A new adapter digest must refresh a previously configured alias.
        let changed = WindowsClaudeRemoteCoordinator(services: .init(digest: String(repeating: "b", count: 64),
            install: { _ in try await capture.install() }, shutdown: {}, loadDigests: { ["alias-a": digest] }, saveDigests: { _ in }))
        await changed.configure(targets: [target], statuses: statuses, enabled: true, version: 2, update: { _, _ in })
        try await wait { await capture.calls == 4 }; await changed.shutdown()
    }
    func testRemovalSleepAndLateCompletionCannotRestoreOldSourceOrCache() async throws {
        let capture = RemoteSetupCapture(); await capture.setFailure(nil); await capture.setHold()
        let coordinator = WindowsClaudeRemoteCoordinator(services: .init(digest: String(repeating: "c", count: 64),
            install: { _ in try await capture.install() }, shutdown: { await capture.stop() }, loadDigests: { [:] },
            saveDigests: { _ in XCTFail("A removed source cannot update the digest cache") }))
        var status = RuntimeStreamStatus(); status.connected = true
        await coordinator.configure(targets: [target], statuses: [target.id: status], enabled: true, version: 1,
            update: { rows, _ in await capture.publish(rows) })
        try await wait { await capture.calls == 1 }
        let old = await capture.rows.first?.context
        var replacement = target; replacement.sshPort = 2222
        await coordinator.configure(targets: [], statuses: [:], enabled: true, version: 1, update: { rows, _ in await capture.publish(rows) })
        await coordinator.shutdown(); await capture.release()
        let rows = await capture.rows, stops = await capture.stops
        XCTAssertTrue(rows.isEmpty); XCTAssertGreaterThanOrEqual(stops, 1)
        let accepted = await coordinator.retry(sourceID: replacement.id, context: try XCTUnwrap(old)); XCTAssertFalse(accepted)
        let refreshes = await capture.refreshes; XCTAssertEqual(refreshes, 0)
    }
    func testDigestStorePersistsOnlyBoundedValidatedVersionedDataAndPreservesFutureFiles() throws {
        let (root, _, _) = try fixture(), file = root.appendingPathComponent("cache/state.json"), store = WindowsClaudeRemoteDigestStore(file: file)
        let digest = String(repeating: "d", count: 64)
        store.save(["alias-a": digest]); XCTAssertEqual(store.load(), ["alias-a": digest])
        XCTAssertEqual(WindowsClaudeRemoteDigestStore(file: file).load(), ["alias-a": digest])
        store.save(["unsafe;alias": digest]); XCTAssertEqual(store.load(), ["alias-a": digest])
        let future = Data(#"{"version":2,"claudeRemoteSetupDigests":{}}"#.utf8); try future.write(to: file)
        XCTAssertTrue(store.load().isEmpty); store.save(["alias-a": digest]); XCTAssertEqual(try Data(contentsOf: file), future)
        let oversized = Data(repeating: 65, count: 16385); try oversized.write(to: file)
        store.save(["alias-a": digest]); XCTAssertEqual(try Data(contentsOf: file), oversized)
    }
    func testWindowsIdentityInjectionDoesNotChangeDefaultMacArguments() throws {
        var windows = target; windows.sshIdentityFile = "C:/合成 key/id"
        XCTAssertThrowsError(try ClaudeRemoteSetup.arguments(target: windows, validDestination: { _ in true }))
        let args = try ClaudeRemoteSetup.arguments(target: windows, validDestination: { _ in true }, validIdentityFile: { WindowsSSHServices.validIdentity($0) })
        XCTAssertTrue(args.contains("C:/合成 key/id")); XCTAssertTrue(args.contains("BatchMode=yes")); XCTAssertFalse(args.contains("--prompt"))
        let normal = try ClaudeRemoteSetup.arguments(target: target, validDestination: { _ in true })
        let injected = try ClaudeRemoteSetup.arguments(target: target, validDestination: { _ in true }, validIdentityFile: { _ in true })
        XCTAssertEqual(normal, injected)
    }
}
