import Foundation
import XCTest
@testable import PacerCore
@testable import PacerEngineSupport

private final class ConnectionSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var value: EngineSnapshot?
    func receive(_ data: Data) {
        guard let snapshot = try? JSONDecoder().decode(EngineSnapshot.self, from: data) else { return }
        lock.lock(); value = snapshot; lock.unlock()
    }
    func read() -> EngineSnapshot? { lock.lock(); defer { lock.unlock() }; return value }
}

final class EngineConnectionProjectionTests: XCTestCase {
    private func status(_ sessions: Int = 1) -> RuntimeStreamStatus {
        var result = RuntimeStreamStatus(); result.connected = true; result.sourceAvailable = true; result.attachedThreads = sessions; return result
    }
    private var profile: WindowsWSLProfile { .init(distro: "Fixture", user: "fixture", uid: 1000, home: "/home/fixture", identity: "2:4",
        codexHome: "/home/fixture/.codex", claudeHome: "/home/fixture/.claude", codexIdentity: "2:5", claudeIdentity: "2:6") }
    private var ssh: RemoteActivityTarget { .init(id: ConnectionSource.sshPrefix + "fixture", name: "SSH fixture", alias: "fixture", home: "~/.claude") }
    func testSSHAndWSLSetupFactsShareProblemOrderingRetryAndProviderColumns() throws {
        let profile = profile, targets = [ssh], context = UUID().uuidString
        let setups = [ssh.id, profile.id].map { EngineClaudeRemoteSetup(sourceID: $0, context: context, configured: false, inFlight: false,
            canRetry: true, message: "Synthetic setup failure", retryAt: 1800) }
        let streams: [AgentProvider: [String: RuntimeStreamStatus]] = [.codex: ["local": status(0), ssh.id: status(2), profile.id: status(3)], .claude: ["local": status(0), ssh.id: status(5), profile.id: status(7)]]
        let page = EngineConnectionProjection.make(enabled: [.codex, .claude], statuses: streams, targets: targets, setups: setups,
            profiles: [profile], activeWSL: [profile.id], canRetrySetup: true)
        XCTAssertEqual(page.state, "retrying"); XCTAssertEqual(page.sourceCount, 6); XCTAssertEqual(page.sessionCount, 5)
        XCTAssertEqual(page.hosts.count, 2); XCTAssertEqual(page.sources.count, 2)
        for host in page.hosts {
            XCTAssertEqual(host.modules.map(\.provider), ["codex", "claude"])
            let claude = try XCTUnwrap(host.modules.last)
            XCTAssertEqual(claude.state, "setupFailed"); XCTAssertTrue(claude.retrySetup); XCTAssertEqual(claude.sessions, 0)
            XCTAssertFalse(claude.label.isEmpty); XCTAssertFalse(host.modules[0].sessionsText.isEmpty)
            XCTAssertEqual(host.modules[0].readsQuota, host.kind == "WSL")
        }
        let codexOnly = EngineConnectionProjection.make(enabled: [.codex], statuses: streams, targets: targets, setups: setups,
            profiles: [profile], activeWSL: [], canRetrySetup: true)
        XCTAssertTrue(codexOnly.hosts.allSatisfy { $0.modules.count == 1 && $0.modules[0].provider == "codex" && !$0.modules[0].readsQuota })
        XCTAssertEqual(codexOnly.sessionCount, 5)
        var disconnected = streams
        disconnected[.claude] = ["local": status(0), ssh.id: RuntimeStreamStatus(), profile.id: RuntimeStreamStatus()]
        let brokenTransport = EngineConnectionProjection.make(enabled: [.codex, .claude], statuses: disconnected, targets: targets, setups: setups,
            profiles: [profile], activeWSL: [profile.id], canRetrySetup: true)
        XCTAssertTrue(brokenTransport.hosts.allSatisfy { $0.modules.last?.state == "retrying" && $0.modules.last?.retrySetup == false },
            "Both transports report the broken collector before a cached hook-setup failure")
    }
    func testVersionSetupAndProviderAbsenceCannotLookLikeAnActiveClaudeSession() throws {
        let profile = profile, id = profile.id
        let installing = EngineClaudeRemoteSetup(sourceID: id, context: UUID().uuidString, configured: false, inFlight: true, canRetry: false, message: nil, retryAt: nil)
        var streams: [AgentProvider: [String: RuntimeStreamStatus]] = [.claude: ["local": status(0), id: status(4)]]
        let page = EngineConnectionProjection.make(enabled: [.claude], statuses: streams, targets: [], setups: [installing], profiles: [profile], activeWSL: [id], canRetrySetup: true)
        XCTAssertEqual(page.state, "connecting"); XCTAssertEqual(page.sessionCount, 0)
        XCTAssertEqual(page.hosts.first?.modules.first?.state, "configuring"); XCTAssertFalse(page.hosts.first?.modules.first?.retrySetup == true)
        var absent = RuntimeStreamStatus(); absent.sourceAvailable = false; absent.remoteHostOnline = true
        streams[.claude]?[id] = absent
        let paused = EngineConnectionProjection.make(enabled: [.claude], statuses: streams, targets: [], setups: [installing], profiles: [], activeWSL: [], canRetrySetup: true)
        XCTAssertEqual(paused.state, "paused"); XCTAssertEqual(paused.sessionCount, 0)
        XCTAssertFalse(paused.hosts.first?.modules.first?.readsQuota == true)
    }
    func testSnapshotExtensionAndTaskRetryLeaveQuotaReadsAndConfigurationIndependent() async throws {
        let frames = ConnectionSnapshots(), runtime = EngineRuntime(demo: true, now: { Date(timeIntervalSince1970: 1_800_000_000) }, dismissalStore: nil, output: { frames.receive($0) })
        func command(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": UUID().uuidString, "method": method, "params": params])
        }
        _ = await runtime.receive(try command("initialize"))
        let before = try XCTUnwrap(frames.read())
        XCTAssertEqual(before.connections?.sources.count, 4); XCTAssertEqual(before.connections?.hosts.count, 1)
        XCTAssertTrue(before.connections?.sources.contains { $0.key == ClaudeCloudProjectState.sourceID } == true)
        _ = await runtime.receive(try command("refreshTaskSources"))
        _ = await runtime.receive(try command("configure", ["monitorSSH": false, "monitorWSL": false, "monitorRemoteControl": false]))
        let after = try XCTUnwrap(frames.read())
        XCTAssertEqual(after.quota, before.quota); XCTAssertEqual(after.tasks, before.tasks)
        XCTAssertEqual(after.connections?.sourceCount, 4); XCTAssertEqual(before.connections?.sourceCount, 5)
        XCTAssertTrue(after.connections?.hosts.isEmpty == true)
        let encoded = try JSONEncoder().encode(after), decoded = try JSONDecoder().decode(EngineSnapshot.self, from: encoded)
        XCTAssertEqual(decoded.connections, after.connections); XCTAssertEqual(decoded.protocolVersion, 1)
        await runtime.stop()
    }
}
