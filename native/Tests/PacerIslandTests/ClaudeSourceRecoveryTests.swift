import XCTest
import Darwin
import AppKit
@testable import PacerCore
@testable import PacerIsland

@MainActor
final class ClaudeSourceRecoveryTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let home: URL
        let model: IslandModel
        let monitor: ClaudeActivityMonitor
        let defaults: UserDefaults
        func launches(_ alias: String) throws -> [Int32] {
            try String(contentsOf: root.appendingPathComponent(alias + ".pids")).split(separator: "\n").compactMap { Int32($0) }
        }
    }
    private func executable(_ name: String, root: URL, script: String) throws -> URL {
        let file = root.appendingPathComponent(name)
        try Data(("#!/usr/bin/env python3\n" + script).utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }
    private func fixture(failingSetup: Bool = false, blockingSetup: Bool = false) throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/pacer-source-recovery-" + UUID().uuidString)
        let home = root.appendingPathComponent(".claude")
        let codexHome = root.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let collector = try executable("fixture-collector", root: root, script: """
        import json,os,pathlib,sys
        root=pathlib.Path(\(String(reflecting: root.path)))
        alias=sys.argv[sys.argv.index('--')+1]
        with (root/(alias+'.pids')).open('a') as file:file.write(str(os.getpid())+'\\n')
        ready=(root/(alias+'.ready')).exists()
        sys.stdout.write(json.dumps({'kind':'status','connected':True,'claudeHome':ready,'watchingLogs':False})+'\\n')
        sys.stdout.flush();sys.stdin.read()
        """)
        let installer = try executable("fixture-installer", root: root, script: """
        import json,os,pathlib,sys,time
        if \(failingSetup ? "True" : "False"):sys.exit(1)
        root=pathlib.Path(\(String(reflecting: root.path)))
        alias=sys.argv[sys.argv.index('--')+1]
        if \(blockingSetup ? "True" : "False"):
            (root/(alias+'.installer-pid')).write_text(str(os.getpid()))
            while not (root/(alias+'.install-continue')).exists():time.sleep(.01)
            (root/(alias+'.settings-mutated')).write_text('simulated remote write')
        (root/(alias+'.ready')).write_text('ready')
        print(json.dumps({'hooksConfigured':True,'telemetryConfigured':True,'statusLineConfigured':True,'telemetryConflict':False}))
        """)
        let domain = "com.codexpacer.source-recovery-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.set(codexHome.path, forKey: "codexHome")
        defaults.set(home.path, forKey: "claudeHome")
        let connections = ["fixture", "other"].map { ["source": "discovered", "hostId": "remote-ssh-discovered:" + $0, "alias": $0] }
        try JSONSerialization.data(withJSONObject: ["codex-managed-remote-connections": connections,
            "remote-connection-auto-connect-by-host-id": ["remote-ssh-discovered:fixture": true, "remote-ssh-discovered:other": true]])
            .write(to: codexHome.appendingPathComponent(".codex-global-state.json"))
        defaults.set(true, forKey: "monitorSSH")
        ProviderModules(codexMode: .disabled, claudeMode: .enabled).save(to: defaults)
        let monitor = ClaudeActivityMonitor(sshExecutable: collector)
        let model = IslandModel(demo: true, defaults: defaults,
            installation: ProviderInstallationDetection(codexInstalled: false, claudeInstalled: false),
            claudeMonitor: monitor, claudeRemoteSetup: ClaudeRemoteSetup(executable: installer, timeout: blockingSetup ? 5 : 2))
        addTeardownBlock {
            await model.shutdown()
            UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(root: root, home: home, model: model, monitor: monitor, defaults: defaults)
    }
    private func start(_ fixture: Fixture, recovered: XCTestExpectation? = nil) async throws {
        let parked = expectation(description: "both unconfigured sources parked")
        final class Seen: @unchecked Sendable {
            let lock = NSLock(); var parked = false; var recovered = false
            func take(_ recovery: Bool) -> Bool {
                lock.lock(); defer { lock.unlock() }
                if recovery { if recovered { return false }; recovered = true }
                else { if parked { return false }; parked = true }
                return true
            }
        }
        let seen = Seen(), model = fixture.model
        let targets = model.claudeRemoteTargets
        await fixture.monitor.start(home: fixture.home, remoteTargets: targets) { values, statuses, requests, performance in
            await MainActor.run { model.receiveClaudeUpdate(values, statuses: statuses, requests: requests, performance: performance) }
            if targets.allSatisfy({ statuses[$0.id]?.sourceAvailable == false }), seen.take(false) { parked.fulfill() }
            if let recovered, statuses["remote-ssh-discovered:fixture"]?.connected == true, seen.take(true) { recovered.fulfill() }
        }
        await fulfillment(of: [parked], timeout: 5)
        XCTAssertFalse(model.hasSSHConnectionIssue)
    }

    func testSuccessfulRemoteSetupImmediatelyRechecksOnlyItsPausedHost() async throws {
        let fixture = try fixture(), recovered = expectation(description: "setup resumes configured source")
        try await start(fixture, recovered: recovered)
        let before = try fixture.launches("fixture"), other = try fixture.launches("other")
        XCTAssertEqual(before.count, 1); XCTAssertEqual(other.count, 1)
        let result = await fixture.model.configureClaudeRemote(targetID: "remote-ssh-discovered:fixture")
        XCTAssertNil(result)
        await fulfillment(of: [recovered], timeout: 5)
        XCTAssertEqual(try fixture.launches("fixture").count, 2, "Setup must bypass the existing 30-minute backoff")
        XCTAssertEqual(try fixture.launches("other"), other, "Setup must not reconnect another paused host")
        XCTAssertEqual(fixture.model.providerStreamStatuses(.claude)["remote-ssh-discovered:fixture"]?.sourceAvailable, true)
        XCTAssertEqual(fixture.model.providerStreamStatuses(.claude)["remote-ssh-discovered:other"]?.sourceAvailable, false)
        XCTAssertEqual(fixture.model.claudeRemoteSetupStatus["remote-ssh-discovered:fixture"]?.hooksConfigured, true)
        let targets = fixture.model.claudeRemoteTargets
        XCTAssertEqual(targets.map { fixture.model.claudeRemoteConfigured($0) }, targets.map { $0.alias == "fixture" },
            "Success records the shipped adapter digest for that alias only, so automatic setup stays quiet")
        XCTAssertNil(fixture.model.claudeRemoteSetupFailures["remote-ssh-discovered:fixture"])
    }

    func testFailedRemoteSetupDoesNotBypassSourceBackoff() async throws {
        let fixture = try fixture(failingSetup: true)
        try await start(fixture)
        let before = try fixture.launches("fixture")
        let result = await fixture.model.configureClaudeRemote(targetID: "remote-ssh-discovered:fixture")
        XCTAssertNotNil(result)
        XCTAssertEqual(try fixture.launches("fixture"), before)
        XCTAssertNil(fixture.model.claudeRemoteSetupStatus["remote-ssh-discovered:fixture"])
        XCTAssertNotNil(fixture.model.claudeRemoteSetupFailures["remote-ssh-discovered:fixture"], "Settings shows the failure with a retry")
        XCTAssertFalse(fixture.model.claudeRemoteTargets.contains { fixture.model.claudeRemoteConfigured($0) })
    }

    private func installerPID(_ fixture: Fixture, differentFrom previous: Int32? = nil) async throws -> Int32 {
        let file = fixture.root.appendingPathComponent("fixture.installer-pid")
        for _ in 0..<300 {
            if let text = try? String(contentsOf: file), let pid = Int32(text), pid != previous { return pid }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return try XCTUnwrap(nil as Int32?, "Fixture installer did not start")
    }

    private func assertInstallerExited(_ pid: Int32) async throws {
        for _ in 0..<200 {
            if kill(pid, 0) == -1, errno == ESRCH { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Cancellation must stop the owned installer process")
    }

    func testRemoteSetupCancellationStopsWritesAndDoesNotReportSetupFailure() async throws {
        enum Change: CaseIterable { case module, ssh, home, aliases, sleep, shutdown, caller }
        let targetID = "remote-ssh-discovered:fixture"
        for change in Change.allCases {
            let fixture = try fixture(blockingSetup: true), model = fixture.model
            if change == .sleep { model.start() }
            let operation = Task { await model.configureClaudeRemote(targetID: targetID) }
            let pid = try await installerPID(fixture)
            XCTAssertTrue(model.configuringClaudeHosts.contains(targetID))
            switch change {
            case .module:
                ProviderModules(codexMode: .disabled, claudeMode: .disabled).save(to: fixture.defaults)
                model.applySettings(sourceChanged: false)
            case .ssh:
                fixture.defaults.set(false, forKey: "monitorSSH"); model.applySettings(sourceChanged: false)
            case .home:
                fixture.defaults.set(fixture.root.path, forKey: "claudeHome"); model.applySettings(sourceChanged: false)
            case .aliases:
                model.reconcileClaudeRemoteTargets(model.claudeRemoteTargets.filter { $0.alias == "other" })
            case .sleep:
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
            case .shutdown: await model.shutdown()
            case .caller: operation.cancel()
            }
            // Check exit before awaiting the operation: simply waiting for its
            // five-second timeout must not count as successful cancellation.
            try await assertInstallerExited(pid)
            let result = await operation.value
            XCTAssertNil(result, "A discarded setup is not a user-facing failure: \(change)")
            try Data().write(to: fixture.root.appendingPathComponent("fixture.install-continue"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("fixture.settings-mutated").path),
                "The cancelled installer must not write remote settings: \(change)")
            XCTAssertTrue(model.configuringClaudeHosts.isEmpty)
            XCTAssertTrue(model.claudeRemoteSetupFailures.isEmpty)
            XCTAssertTrue(model.claudeRemoteSetupStatus.isEmpty)
            XCTAssertFalse(model.claudeRemoteTargets.contains { model.claudeRemoteConfigured($0) })
            if [.module, .ssh, .sleep, .shutdown].contains(change) {
                let blocked = await model.configureClaudeRemote(targetID: targetID)
                XCTAssertNil(blocked)
                XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("fixture.installer-pid")), String(pid),
                    "Disabled, sleeping or stopped monitoring must not start an installer")
            }
            await model.shutdown()
        }
    }

    func testSourceResetAllowsReplacementSetupWithoutOldRequestClearingOrCancellingIt() async throws {
        let fixture = try fixture(blockingSetup: true), model = fixture.model
        let targetID = "remote-ssh-discovered:fixture"
        let previous = Task { await model.configureClaudeRemote(targetID: targetID) }
        let previousPID = try await installerPID(fixture)
        fixture.defaults.set(fixture.root.path, forKey: "claudeHome")
        model.applySettings(sourceChanged: false)
        let replacement = Task { await model.configureClaudeRemote(targetID: targetID) }
        let replacementPID = try await installerPID(fixture, differentFrom: previousPID)
        let previousResult = await previous.value
        XCTAssertNil(previousResult)
        try await assertInstallerExited(previousPID)
        XCTAssertTrue(model.configuringClaudeHosts.contains(targetID), "Old cleanup must not clear the replacement's in-flight state")
        XCTAssertEqual(kill(replacementPID, 0), 0, "Source reset must not cancel a newly started installer")
        try Data().write(to: fixture.root.appendingPathComponent("fixture.install-continue"))
        let replacementResult = await replacement.value
        XCTAssertNil(replacementResult)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("fixture.settings-mutated").path))
        XCTAssertEqual(model.claudeRemoteSetupStatus[targetID]?.hooksConfigured, true)
        XCTAssertTrue(model.configuringClaudeHosts.isEmpty)
        XCTAssertTrue(model.claudeRemoteSetupFailures.isEmpty)
        XCTAssertTrue(model.claudeRemoteTargets.first { $0.id == targetID }.map { model.claudeRemoteConfigured($0) } ?? false)
    }
}
