#if canImport(PacerMacSupport)
import PacerMacSupport
#else
@testable import PacerEngineSupport
#endif
import Foundation
import XCTest
@testable import PacerCore

final class ClaudeRemoteSetupContractTests: XCTestCase {
    private let success = #"{"hooksConfigured":true,"telemetryConfigured":true,"statusLineConfigured":true,"telemetryConflict":false}"#
    private var target: RemoteActivityTarget { RemoteActivityTarget(id: "fixture-host", name: "Fixture", alias: "fixture-host", home: "/private-codex-home") }

    func testAutomaticSetupRunsOncePerDigestForConnectedHostsAndBacksOffFailures() throws {
        let suite = "pacer-claude-auto-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }

        func host(_ alias: String) -> RemoteActivityTarget {
            RemoteActivityTarget(id: "remote-ssh-discovered:" + alias, name: alias, alias: alias, home: "~/.claude")
        }
        func stream(connected: Bool, source: Bool? = true) -> RuntimeStreamStatus {
            var status = RuntimeStreamStatus(); status.connected = connected; status.sourceAvailable = source; return status
        }
        let targets = ["current", "outdated", "fresh", "offline", "no-claude", "busy", "failed", "failed-long-ago"].map(host)
        var statuses = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, stream(connected: true)) })
        statuses[host("offline").id] = stream(connected: false, source: nil)
        statuses[host("no-claude").id] = stream(connected: false, source: false)
        let now = Date()
        let pending = ClaudeRemoteAutoSetup.pending(targets: targets, statuses: statuses,
            configured: ["current": "digest-2", "outdated": "digest-1"], digest: "digest-2",
            failures: [host("failed").id: now.addingTimeInterval(-60), host("failed-long-ago").id: now.addingTimeInterval(-ClaudeRemoteAutoSetup.retryInterval)],
            inFlight: [host("busy").id], now: now)
        XCTAssertEqual(pending.map(\.alias), ["outdated", "fresh", "failed-long-ago"])

        for index in 0..<40 { ClaudeRemoteAutoSetup.recordConfigured(alias: String(format: "host-%02d", index), digest: "digest", defaults: defaults) }
        let recorded = ClaudeRemoteAutoSetup.configuredDigests(defaults: defaults)
        XCTAssertEqual(recorded.count, 32)
        XCTAssertEqual(recorded["host-39"], "digest")
        XCTAssertFalse(try ClaudeRemoteSetup.adapterDigest().isEmpty)
        XCTAssertEqual(try ClaudeRemoteSetup.adapterDigest(), try ClaudeRemoteSetup.adapterDigest())
        // Switching the progress ring changes the digest, so configured hosts are set up again.
        XCTAssertNotEqual(try ClaudeRemoteSetup.adapterDigest(progressRing: true), try ClaudeRemoteSetup.adapterDigest())
        func payload(_ ring: Bool) throws -> [String: Any] {
            let command = try ClaudeRemoteSetup.command(progressRing: ring)
            let encoded = try XCTUnwrap(command.split(separator: " ").last.map(String.init))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: encoded))) as? [String: Any])
        }
        XCTAssertEqual(try payload(false)["progressRing"] as? Bool, false, "Off is stated, so a host loses an earlier ring")
        XCTAssertNil(try payload(false)["progressServer"])
        XCTAssertEqual(try payload(true)["progressRing"] as? Bool, true)
        XCTAssertEqual((try payload(true)["progressServer"] as? String).flatMap { Data(base64Encoded: $0) }, try ClaudeRemoteSetup.progressServer())
    }

    func testSSHArgumentsRequireSafeAliasAndReturnOnlyStrictBooleanStatus() throws {
        let args = try ClaudeRemoteSetup.arguments(target: target)
        XCTAssertEqual(Array(args.dropLast(3)), ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ForwardAgent=no",
            "-o", "ClearAllForwardings=yes", "-o", "ConnectTimeout=6", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2"])
        XCTAssertEqual(args[args.count - 3], "--"); XCTAssertEqual(args[args.count - 2], target.alias)
        XCTAssertFalse(args.last!.contains(target.home))
        for alias in ["-oProxyCommand=bad", "fixture host", "host\n", "host;private"] {
            XCTAssertThrowsError(try ClaudeRemoteSetup.arguments(target: RemoteActivityTarget(id: "fixture", name: "Fixture", alias: alias, home: "~/.claude")))
        }
        XCTAssertTrue(try ClaudeRemoteSetup.status(data: Data(success.utf8), exitStatus: 0).telemetryConfigured)
        for text in [success.replacingOccurrences(of: "true", with: "1"), success.dropLast() + #", "privatePath":"PRIVATE"}"#] {
            XCTAssertThrowsError(try ClaudeRemoteSetup.status(data: Data(text.utf8), exitStatus: 0))
        }
        XCTAssertThrowsError(try ClaudeRemoteSetup.status(data: Data(), exitStatus: 255)) { error in
            XCTAssertEqual(error as? ClaudeRemoteSetup.Failure, .connectionFailed)
        }
    }

    /// Removal sends only the operation and home, and accepts only a strict
    /// boolean answer; a removed host's record goes so a return sets it up again.
    func testRemovalCommandReplyAndForgottenHost() throws {
        let command = try ClaudeRemoteSetup.removalCommand()
        let encoded = try XCTUnwrap(command.split(separator: " ").last.map(String.init))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: encoded))) as? [String: String])
        XCTAssertEqual(payload, ["operation": "uninstall", "home": "~/.claude"])
        XCTAssertTrue(command.hasPrefix("python3 -u -c 'import base64;exec(base64.b64decode(\""))
        XCTAssertThrowsError(try ClaudeRemoteSetup.removalCommand(home: "host\nhome"))
        XCTAssertThrowsError(try ClaudeRemoteSetup.removalCommand(home: ""))

        XCTAssertTrue(try ClaudeRemoteSetup.removal(data: Data(#"{"removed":true}"#.utf8), exitStatus: 0))
        XCTAssertFalse(try ClaudeRemoteSetup.removal(data: Data(#"{"removed":false}"#.utf8), exitStatus: 0))
        for text in [#"{"removed":1}"#, #"{"removed":true,"path":"PRIVATE"}"#, "{}", success] {
            XCTAssertThrowsError(try ClaudeRemoteSetup.removal(data: Data(text.utf8), exitStatus: 0)) { error in
                XCTAssertEqual(error as? ClaudeRemoteSetup.Failure, .invalidResponse, text)
            }
        }
        for (text, failure) in [(#"{"error":"invalidSettings"}"#, ClaudeRemoteSetup.Failure.invalidSettings),
                                (#"{"error":"changedSettings"}"#, .changedSettings), (#"{"error":"invalidPayload"}"#, .setupFailed)] {
            XCTAssertThrowsError(try ClaudeRemoteSetup.removal(data: Data(text.utf8), exitStatus: 1)) { error in
                XCTAssertEqual(error as? ClaudeRemoteSetup.Failure, failure, text)
            }
        }
        XCTAssertThrowsError(try ClaudeRemoteSetup.removal(data: Data(), exitStatus: 255)) { error in
            XCTAssertEqual(error as? ClaudeRemoteSetup.Failure, .connectionFailed)
        }

        let suite = "pacer-claude-forget-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        ClaudeRemoteAutoSetup.recordConfigured(alias: "kept", digest: "digest", defaults: defaults)
        ClaudeRemoteAutoSetup.recordConfigured(alias: "removed", digest: "digest", defaults: defaults)
        ClaudeRemoteAutoSetup.forget(alias: "removed", defaults: defaults)
        ClaudeRemoteAutoSetup.forget(alias: "never-configured", defaults: defaults)
        XCTAssertEqual(ClaudeRemoteAutoSetup.configuredDigests(defaults: defaults), ["kept": "digest"])
        ClaudeRemoteAutoSetup.forget(alias: "kept", defaults: defaults)
        XCTAssertNil(defaults.object(forKey: ClaudeRemoteAutoSetup.digestsKey), "The last record takes its key with it")
    }
}
