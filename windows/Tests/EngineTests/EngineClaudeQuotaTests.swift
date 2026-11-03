@testable import PacerEngineSupport
import Foundation
import XCTest
@testable import PacerCore

private final class ClaudeRuntimeFrames: @unchecked Sendable {
    private let lock = NSLock(); private var frames: [Data] = []
    func append(_ value: Data) { lock.lock(); defer { lock.unlock() }; frames.append(value) }
    func all() -> [Data] { lock.lock(); defer { lock.unlock() }; return frames }
    func latest() -> EngineSnapshot? { all().compactMap { try? JSONDecoder().decode(EngineSnapshot.self, from: $0) }.last }
    func lastError() throws -> String? { (try JSONSerialization.jsonObject(with: XCTUnwrap(all().last)) as? [String: Any])?["code"] as? String }
}
private actor ClaudeRuntimeClient: ClaudeQuotaConnection {
    let snapshot: QuotaSnapshot
    init() throws {
        snapshot = try ClaudeQuotaDecoder.decodeUsage(Data(#"{"five_hour":{"utilization":25,"resets_at":1800001800},"seven_day":{"utilization":40,"resets_at":1800604800}}"#.utf8),
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000), accountScope: ClaudeQuotaDecoder.digest("private-account-scope"))
    }
    func readQuota() -> QuotaSnapshot { snapshot }
    func currentAccountScope() -> String? { snapshot.accountScope }
    func organizations() -> [ClaudeWebOrganization] { [.init(id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", name: "Private synthetic workspace")] }
    func currentSource() -> ClaudeQuotaSource? { .webSession }
    func nextRetryAt() -> Date? { nil }
    func shutdown() {}
}

final class EngineClaudeQuotaTests: XCTestCase {
    private func command(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": "claude-runtime", "method": method, "params": params])
    }
    private func waitForQuota(_ frames: ClaudeRuntimeFrames) async throws {
        for _ in 0..<200 {
            if frames.latest()?.quota.contains(where: { $0.provider == "claude" }) == true { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("The synthetic Claude quota did not reach a routine snapshot")
    }
    func testRealEngineProjectsClaudeQuotaHistoryAndRecoveryWithoutPublishingPrivateAccountMetadata() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-claude-runtime-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let frames = ClaudeRuntimeFrames(), client = try ClaudeRuntimeClient()
        let runtime = EngineRuntime(demo: false, now: { Date(timeIntervalSince1970: 1_800_000_000) }, dismissalStore: nil,
            claudeServices: .init(makeClient: { _, _, _ in client }, history: nil),
            installationDetection: { .init(codexInstalled: false, claudeInstalled: false, deepseekInstalled: false) }, output: { frames.append($0) })
        _ = await runtime.receive(try command("initialize", ["enabledProviders": [String]()]))
        _ = await runtime.receive(try command("configure", ["enabledProviders": ["claude"], "claudeHome": EngineCodexSourceReport.path(home)]))
        _ = await runtime.receive(try command("setClaudeWebHost", ["webAvailable": true]))
        try await waitForQuota(frames)
        let snapshot = try XCTUnwrap(frames.latest())
        XCTAssertEqual(snapshot.quota.map(\.provider), ["claude"])
        XCTAssertEqual(snapshot.quotaDashboard?.providers.first?.weekly.remainingPercent, 60)
        XCTAssertEqual(snapshot.claudeConnection?.state, "signedIn"); XCTAssertNotNil(snapshot.quotaDashboard?.providers.first?.history)
        XCTAssertTrue(snapshot.sources.contains { $0.id == "claude:quota" && $0.available })
        let text = String(data: try JSONEncoder().encode(snapshot), encoding: .utf8)!
        XCTAssertFalse(text.contains("cookieHeader")); XCTAssertFalse(text.contains("Private synthetic workspace")); XCTAssertFalse(text.contains("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        _ = await runtime.receive(try command("inspectClaudeAccount"))
        let report = try XCTUnwrap((JSONSerialization.jsonObject(with: XCTUnwrap(frames.all().last)) as? [String: Any])?["value"] as? [String: Any])
        XCTAssertEqual((report["organizations"] as? [[String: Any]])?.first?["name"] as? String, "Private synthetic workspace")
        let context = try XCTUnwrap(snapshot.claudeConnection?.context)
        _ = await runtime.receive(try command("pauseClaudeConnection", ["context": context]))
        let paused = try XCTUnwrap(frames.latest())
        XCTAssertTrue(paused.quota.isEmpty); XCTAssertEqual(paused.claudeConnection?.state, "paused")
        _ = await runtime.receive(try command("resetClaudeConnection", ["context": context]))
        XCTAssertEqual(try frames.lastError(), "staleContext")
        _ = await runtime.receive(try command("resetClaudeConnection", ["context": try XCTUnwrap(paused.claudeConnection?.context)]))
        try await waitForQuota(frames)
        _ = await runtime.receive(try command("configure", ["enabledProviders": [String]()]))
        XCTAssertTrue(try XCTUnwrap(frames.latest()).quota.isEmpty)
        await runtime.stop()
    }
    func testInvalidWorkspaceIsAtomicAndUnsolicitedCookieRepliesAreRejected() async throws {
        let frames = ClaudeRuntimeFrames(), client = try ClaudeRuntimeClient()
        let runtime = EngineRuntime(demo: false, dismissalStore: nil, claudeServices: .init(makeClient: { _, _, _ in client }, history: nil), output: { frames.append($0) })
        _ = await runtime.receive(try command("initialize", ["enabledProviders": [String]()]))
        let sequence = try XCTUnwrap(frames.latest()).sequence
        _ = await runtime.receive(try command("configure", ["claudeOrganization": "invalid", "hideProjects": true]))
        XCTAssertEqual(try frames.lastError(), "invalidConfiguration"); XCTAssertEqual(frames.latest()?.sequence, sequence)
        _ = await runtime.receive(try command("claudeWebResult", ["requestID": UUID().uuidString, "context": UUID().uuidString, "claudeSession": ["state": "signedOut"]]))
        XCTAssertEqual(try frames.lastError(), "staleWebReply")
        await runtime.stop()
    }
}
