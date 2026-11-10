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
        return .init(hooksConfigured: true, telemetryConfigured: true, statusLineConfigured: true)
    }
    func setFailure(_ value: ClaudeRemoteSetup.Failure?) { failure = value }
    func setHold() { hold = true }
    func release() { hold = false; held?.resume(); held = nil }
    func stop() { stops += 1 }
    func publish(_ values: [EngineClaudeRemoteSetup]) { rows = values }
    func refreshed() { refreshes += 1 }
}
private final class RingCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var installed: [Bool] = [], digests: [String: String] = [:]
    var rings: [Bool] { lock.lock(); defer { lock.unlock() }; return installed }
    var saved: [String: String] { lock.lock(); defer { lock.unlock() }; return digests }
    func install(_ ring: Bool) { lock.lock(); installed.append(ring); lock.unlock() }
    func save(_ value: [String: String]) { lock.lock(); digests = value; lock.unlock() }
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
        let services = EngineClaudeRemoteServices(digest: { _ in digest }, install: { _, _ in try await capture.install() },
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
        let changed = WindowsClaudeRemoteCoordinator(services: .init(digest: { _ in String(repeating: "b", count: 64) },
            install: { _, _ in try await capture.install() }, shutdown: {}, loadDigests: { ["alias-a": digest] }, saveDigests: { _ in }))
        await changed.configure(targets: [target], statuses: statuses, enabled: true, version: 2, update: { _, _ in })
        try await wait { await capture.calls == 4 }; await changed.shutdown()
    }
    func testRemovalSleepAndLateCompletionCannotRestoreOldSourceOrCache() async throws {
        let capture = RemoteSetupCapture(); await capture.setFailure(nil); await capture.setHold()
        let coordinator = WindowsClaudeRemoteCoordinator(services: .init(digest: { _ in String(repeating: "c", count: 64) },
            install: { _, _ in try await capture.install() }, shutdown: { await capture.stop() }, loadDigests: { [:] },
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
    func testProgressRingSetupInstallsSwitchAndPluginAndRemovesOnlyItsOwnEntries() async throws {
        let (root, exe, env) = try fixture(), home = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let settings = home.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: ["permissions": ["allow": ["Read"]], "enabledPlugins": ["other@market": true]]).write(to: settings)
        func current() throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]) }
        let setup = installer(exe, env: env)
        _ = try await setup.install(target: target, requireHome: true, progressRing: true)
        let pacer = home.appendingPathComponent("pacer"), flag = pacer.appendingPathComponent("progress-ring")
        XCTAssertEqual(try Data(contentsOf: flag), Data("tool\n".utf8))
        XCTAssertEqual(try Data(contentsOf: pacer.appendingPathComponent("plugin/pacer/progress_mcp.py")), try ClaudeRemoteSetup.progressServer())
        XCTAssertTrue(FileManager.default.fileExists(atPath: pacer.appendingPathComponent("plugin/.claude-plugin/marketplace.json").path))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: pacer.appendingPathComponent("plugin/pacer/.claude-plugin/plugin.json"))) as? [String: Any])
        let server = try XCTUnwrap((manifest["mcpServers"] as? [String: Any])?["pacer"] as? [String: Any])
        XCTAssertEqual(server["command"] as? String, "python3", "The remote host's own Python runs the server")
        var value = try current()
        XCTAssertEqual(value["enabledPlugins"] as? [String: Bool], ["other@market": true, "pacer@pacer": true])
        XCTAssertEqual((value["permissions"] as? [String: Any])?["allow"] as? [String], ["Read", ClaudeHookInstaller.progressTool])
        XCTAssertNotNil((value["extraKnownMarketplaces"] as? [String: Any])?["pacer"])
        // A hand-written mode is kept, and a current host sees no rewrite.
        try Data("tool 15\n".utf8).write(to: flag)
        let installed = try Data(contentsOf: settings)
        _ = try await setup.install(target: target, requireHome: true, progressRing: true)
        XCTAssertEqual(try Data(contentsOf: flag), Data("tool 15\n".utf8)); XCTAssertEqual(try Data(contentsOf: settings), installed)
        // Off removes the switch and exactly Pacer's entries; the user's stay.
        _ = try await setup.install(target: target, requireHome: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: flag.path))
        value = try current()
        XCTAssertEqual(value["enabledPlugins"] as? [String: Bool], ["other@market": true])
        XCTAssertEqual((value["permissions"] as? [String: Any])?["allow"] as? [String], ["Read"])
        XCTAssertNil(value["extraKnownMarketplaces"])
        await setup.shutdown()
    }
    func testRemoteProgressPluginRejectsNameCollisionsAndPreservesUntrackedPermissions() async throws {
        let (root, exe, env) = try fixture(), home = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let settings = home.appendingPathComponent("settings.json")
        let original: [String: Any] = ["extraKnownMarketplaces": ["pacer": ["source": ["source": "directory", "path": "/user/market"]]],
            "enabledPlugins": ["pacer@pacer": false], "permissions": ["allow": [ClaudeHookInstaller.progressTool, "Read"]]]
        let bytes = try JSONSerialization.data(withJSONObject: original); try bytes.write(to: settings)
        let setup = installer(exe, env: env)
        do { _ = try await setup.install(target: target, requireHome: true, progressRing: true); XCTFail("A foreign marketplace must not be replaced") }
        catch { }
        XCTAssertEqual(try Data(contentsOf: settings), bytes)
        _ = try await setup.install(target: target, requireHome: true)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        for key in ["extraKnownMarketplaces", "enabledPlugins", "permissions"] {
            XCTAssertTrue(NSDictionary(dictionary: value[key] as! [String: Any]).isEqual(to: original[key] as! [String: Any]), key)
        }
        await setup.shutdown()
    }

    func testRemoteProgressPluginRestoresPriorValuesAndPreservesARepointedNamespace() async throws {
        let (root, exe, env) = try fixture(), home = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let settings = home.appendingPathComponent("settings.json")
        let setup = installer(exe, env: env)
        func current() throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]) }
        // The Windows SSH fixture uses native Python paths. Capture its exact
        // marketplace spelling instead of inventing a different slash form.
        _ = try await setup.install(target: target, requireHome: true, progressRing: true)
        let marketplace = try XCTUnwrap(current()["extraKnownMarketplaces"])
        _ = try await setup.install(target: target, requireHome: true)
        let original: [String: Any] = ["extraKnownMarketplaces": marketplace,
            "enabledPlugins": ["pacer@pacer": false], "permissions": ["allow": [ClaudeHookInstaller.progressTool, "Read"]]]
        try JSONSerialization.data(withJSONObject: original).write(to: settings)
        _ = try await setup.install(target: target, requireHome: true, progressRing: true)
        XCTAssertEqual((try current()["enabledPlugins"] as? [String: Bool])?["pacer@pacer"], true)
        _ = try await setup.install(target: target, requireHome: true)
        let restored = try current()
        for key in ["extraKnownMarketplaces", "enabledPlugins", "permissions"] {
            XCTAssertTrue(NSDictionary(dictionary: restored[key] as! [String: Any]).isEqual(to: original[key] as! [String: Any]), key)
        }
        _ = try await setup.install(target: target, requireHome: true, progressRing: true)
        var edited = try current()
        edited["extraKnownMarketplaces"] = ["pacer": ["source": ["source": "directory", "path": "/user/replacement"]]]
        edited["enabledPlugins"] = ["pacer@pacer": false]
        try JSONSerialization.data(withJSONObject: edited).write(to: settings)
        _ = try await setup.install(target: target, requireHome: true)
        let kept = try current()
        for key in ["extraKnownMarketplaces", "enabledPlugins", "permissions"] {
            XCTAssertTrue(NSDictionary(dictionary: kept[key] as! [String: Any]).isEqual(to: edited[key] as! [String: Any]), key)
        }
        await setup.shutdown()
    }

    func testSwitchingTheProgressRingSetsConnectedHostsUpAgain() async throws {
        let capture = RingCapture(), off = String(repeating: "e", count: 64), on = String(repeating: "f", count: 64)
        let coordinator = WindowsClaudeRemoteCoordinator(services: .init(digest: { $0 ? on : off }, install: { _, ring in
            capture.install(ring); return .init(hooksConfigured: true, telemetryConfigured: true, statusLineConfigured: true)
        }, shutdown: {}, loadDigests: { [:] }, saveDigests: { capture.save($0) }))
        var connected = RuntimeStreamStatus(); connected.connected = true; connected.sourceAvailable = true
        let alias = target.alias, statuses = [target.id: connected], targets = [target]
        func configure(_ ring: Bool) async {
            await coordinator.configure(targets: targets, statuses: statuses, enabled: true, progressRing: ring, version: 1, update: { _, _ in })
        }
        await configure(false)
        try await wait { capture.rings == [false] && capture.saved[alias] == off }
        await configure(true)
        try await wait { capture.rings == [false, true] && capture.saved[alias] == on }
        await configure(true)
        XCTAssertEqual(capture.rings, [false, true], "A host that already has the ring is not set up again")
        await configure(false)
        try await wait { capture.rings == [false, true, false] && capture.saved[alias] == off }
        await coordinator.shutdown()
    }
    func testHelperForwardsOnlyTheRingsNumbersKindsAndWakeFlag() throws {
        let python = try XCTUnwrap(ProcessInfo.processInfo.environment["PACER_TEST_PYTHON"])
        let (root, _, _) = try fixture(), script = root.appendingPathComponent("helper.py"), input = root.appendingPathComponent("rows.jsonl")
        try Data(ClaudeActivityProbe.script.utf8).write(to: script)
        let rows: [[String: Any]] = [
            ["kind": "progress", "origin": "hook", "sessionId": "s", "at": 1.0, "promptId": "p", "progress": 40],
            ["kind": "progress", "origin": "hook", "sessionId": "s", "at": 1.0, "progress": 120],
            ["kind": "progress", "origin": "hook", "sessionId": "s", "at": 1.0, "progress": true],
            ["kind": "waiting", "origin": "hook", "sessionId": "s", "at": 1.0, "background": ["shell", "local_powershell"], "wakeups": 2, "description": "PRIVATE"],
            ["kind": "prompt", "origin": "hook", "sessionId": "s", "at": 1.0, "promptId": "p", "wake": true],
            ["kind": "prompt", "origin": "hook", "sessionId": "s", "at": 1.0, "promptId": "q", "wake": "yes"]]
        let lines = try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: input)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-S", "-c", "import json,sys\nns={'__name__':'helper'}\nexec(open(sys.argv[1],encoding='utf-8').read(),ns)\n" +
            "for line in open(sys.argv[2],encoding='utf-8'):print(json.dumps(ns['sanitized'](line),sort_keys=True))", script.path, input.path]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let results = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertEqual(results.count, rows.count)
        guard results.count == rows.count else { return }
        XCTAssertTrue(results[0].contains(#""progress": 40"#))
        XCTAssertEqual(results[1], "[]", "An estimate above 100 is dropped"); XCTAssertEqual(results[2], "[]", "A boolean is not an estimate")
        XCTAssertTrue(results[3].contains(#""background": ["shell", "local_powershell"]"#)); XCTAssertTrue(results[3].contains(#""wakeups": 2"#))
        XCTAssertFalse(results[3].contains("PRIVATE"), "A waiting row carries task kinds, never descriptions")
        XCTAssertTrue(results[4].contains(#""wake": true"#)); XCTAssertFalse(results[5].contains("wake"))
    }
}
