import XCTest
import Darwin
@testable import PacerCore
@testable import PacerIsland

@MainActor
final class ClaudeSourceRecoveryTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let home: URL
        let model: IslandModel
        let monitor: ClaudeActivityMonitor
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
    private func fixture(failingSetup: Bool = false) throws -> Fixture {
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
        import json,pathlib,sys
        if \(failingSetup ? "True" : "False"):sys.exit(1)
        root=pathlib.Path(\(String(reflecting: root.path)))
        alias=sys.argv[sys.argv.index('--')+1]
        (root/(alias+'.ready')).write_text('ready')
        print(json.dumps({'hooksConfigured':True,'telemetryConfigured':True,'statusLineConfigured':True,'telemetryConflict':False}))
        """)
        let domain = "com.codexpacer.source-recovery-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.set(codexHome.path, forKey: "codexHome")
        defaults.set(home.path, forKey: "claudeHome")
        defaults.set("fixture other", forKey: "claudeSSHHosts")
        defaults.set(true, forKey: "monitorSSH")
        ProviderModules(codexMode: .disabled, claudeMode: .enabled).save(to: defaults)
        let monitor = ClaudeActivityMonitor(sshExecutable: collector)
        let model = IslandModel(demo: true, defaults: defaults,
            installation: ProviderInstallationDetection(codexInstalled: false, claudeInstalled: false),
            claudeMonitor: monitor, claudeRemoteSetup: ClaudeRemoteSetup(executable: installer, timeout: 2))
        addTeardownBlock {
            await model.shutdown()
            UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(root: root, home: home, model: model, monitor: monitor)
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
    }

    func testFailedRemoteSetupDoesNotBypassSourceBackoff() async throws {
        let fixture = try fixture(failingSetup: true)
        try await start(fixture)
        let before = try fixture.launches("fixture")
        let result = await fixture.model.configureClaudeRemote(targetID: "remote-ssh-discovered:fixture")
        XCTAssertNotNil(result)
        XCTAssertEqual(try fixture.launches("fixture"), before)
        XCTAssertNil(fixture.model.claudeRemoteSetupStatus["remote-ssh-discovered:fixture"])
    }
}
