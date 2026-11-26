import XCTest
import PacerCore
@testable import PacerIsland
import PacerTestSupport

@MainActor
final class CodexRemoteProgressAutoSetupTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let model: IslandModel
        let defaults: UserDefaults
        let target: RemoteActivityTarget
        /// The installer request the last run sent to the host.
        func request() throws -> [String: Any] {
            let command = try String(contentsOf: root.appendingPathComponent("fixture.command"))
            let payload = try XCTUnwrap(command.split(separator: " ").last.flatMap { Data(base64Encoded: String($0)) })
            return try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        }
    }

    /// The fake SSH executable records the remote command and answers as the installer would.
    private func fixture(failing: Bool = false) throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/pacer-codex-remote-progress-" + UUID().uuidString)
        let codexHome = root.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let installer = root.appendingPathComponent("fixture-ssh")
        try Data("""
        #!/usr/bin/env python3
        import json,pathlib,sys
        if \(failing ? "True" : "False"):sys.exit(255)
        root=pathlib.Path(\(String(reflecting: root.path)))
        alias=sys.argv[sys.argv.index('--')+1]
        (root/(alias+'.command')).write_text(sys.argv[-1])
        print(json.dumps({'configured':True,'conflict':False}))
        """.utf8).write(to: installer)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installer.path)
        let domain = testDefaultsName("codex-remote-progress-tests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.set(codexHome.path, forKey: "codexHome")
        defaults.set(true, forKey: "monitorSSH")
        ProviderModules(codexMode: .enabled, claudeMode: .disabled).save(to: defaults)
        let model = IslandModel(demo: true, demoArguments: nil, defaults: defaults,
            installation: ProviderInstallationDetection(codexInstalled: false, claudeInstalled: false),
            claudeRemoteSetup: ClaudeRemoteSetup(executable: installer, timeout: 5))
        addTeardownBlock {
            await model.shutdown()
            removeTestDefaults(domain)
            try? FileManager.default.removeItem(at: root)
        }
        let target = RemoteActivityTarget(id: "remote-ssh-discovered:fixture", name: "fixture", alias: "fixture", home: "/srv/codex-home")
        return Fixture(root: root, model: model, defaults: defaults, target: target)
    }

    func testRemoteRunCarriesTheRingAndRecordsItsDigest() async throws {
        let fixture = try fixture(), model = fixture.model
        model.setSSHHost(fixture.target.id, monitored: false)
        let skipped = await model.configureCodexRemoteProgress(target: fixture.target)
        XCTAssertNil(skipped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("fixture.command").path))
        model.setSSHHost(fixture.target.id, monitored: true)
        let on = await model.configureCodexRemoteProgress(target: fixture.target)
        XCTAssertEqual(on, CodexRemoteProgressSetup.Status(configured: true, conflict: false))
        var request = try fixture.request()
        XCTAssertEqual(request["enabled"] as? Bool, true, "The ring is on until the user turns it off")
        XCTAssertEqual(request["home"] as? String, "/srv/codex-home", "The tool goes into the host's Codex home, not the local one")
        XCTAssertFalse(((request["reporter"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()).isEmpty)
        XCTAssertEqual(CodexRemoteProgressSetup.configuredDigests(defaults: fixture.defaults)["fixture"],
                       try CodexRemoteProgressSetup.digest(enabled: true))

        fixture.defaults.set(false, forKey: IslandModel.codexProgressRingKey)
        // CI has read the earlier value right after this write; act once the model sees it.
        let ringOff = try await TestWait.until { !model.showsCodexProgressRing }
        XCTAssertTrue(ringOff, "The model must see the ring switched off before the run")
        let off = await model.configureCodexRemoteProgress(target: fixture.target)
        XCTAssertNotNil(off)
        request = try fixture.request()
        XCTAssertEqual(request["enabled"] as? Bool, false, "Off is stated, so the host loses Pacer's entries")
        XCTAssertNil(request["reporter"])
        XCTAssertEqual(CodexRemoteProgressSetup.configuredDigests(defaults: fixture.defaults)["fixture"],
                       try CodexRemoteProgressSetup.digest(enabled: false))
    }

    func testFailedRunRecordsNothing() async throws {
        let fixture = try fixture(failing: true)
        let result = await fixture.model.configureCodexRemoteProgress(target: fixture.target)
        XCTAssertNil(result)
        XCTAssertNil(CodexRemoteProgressSetup.configuredDigests(defaults: fixture.defaults)["fixture"],
                     "A failed run leaves the host unrecorded, so it is retried after the backoff")
    }

    func testOnlyConnectedHostsRunAndTheRingOffVisitsOnlyHostsThisMacSetUp() throws {
        let on = try CodexRemoteProgressSetup.digest(enabled: true), off = try CodexRemoteProgressSetup.digest(enabled: false)
        let managed = RemoteActivityTarget(id: "remote-ssh-codex-managed:fixture", name: "Build server",
            alias: "codex-fixture", home: "~/.codex", sshDestination: "fixture@build.example.test")
        let targets = ["a", "b", "c"].map { RemoteActivityTarget(id: "remote-ssh-discovered:" + $0, name: $0, alias: $0, home: "~/.codex") } + [managed]
        var connected = RuntimeStreamStatus(); connected.connected = true
        var missing = connected; missing.sourceAvailable = false
        let statuses = ["remote-ssh-discovered:a": connected, "remote-ssh-discovered:b": connected,
                        "remote-ssh-discovered:c": missing, managed.id: connected]
        let now = Date()
        func pending(ring: Bool, configured: [String: String], failures: [String: Date] = [:], checkedAt: [String: Date] = [:]) -> [String] {
            IslandModel.codexRemoteProgressPending(targets: targets, statuses: statuses, configured: configured, ring: ring,
                digest: ring ? on : off, failures: failures, inFlight: [], checkedAt: checkedAt, now: now).map(\.alias)
        }
        XCTAssertEqual(pending(ring: true, configured: [:]), ["a", "b", "codex-fixture"],
                       "Hosts added in Desktop are set up like SSH config aliases; a host without a Codex source is skipped")
        XCTAssertEqual(pending(ring: true, configured: ["a": on], checkedAt: ["remote-ssh-discovered:a": now]), ["b", "codex-fixture"],
                       "A host checked this launch stays quiet until the recheck interval")
        XCTAssertEqual(pending(ring: true, configured: ["a": on]), ["a", "b", "codex-fixture"], "A host set up by an earlier launch is checked once again")
        XCTAssertEqual(pending(ring: true, configured: [:], failures: ["remote-ssh-discovered:a": now.addingTimeInterval(-60)]), ["b", "codex-fixture"],
                       "A failed host backs off")
        XCTAssertEqual(pending(ring: true, configured: [:], failures: ["remote-ssh-discovered:a": now.addingTimeInterval(-31 * 60)]), ["a", "b", "codex-fixture"])
        XCTAssertEqual(pending(ring: false, configured: ["a": on]), ["a"], "Off removes the tool only where this Mac installed it")
        XCTAssertEqual(pending(ring: false, configured: ["a": off], checkedAt: ["remote-ssh-discovered:a": now]), [])
    }
}
