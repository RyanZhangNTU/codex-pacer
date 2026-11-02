import Foundation
import XCTest
@testable import PacerCore

private final class CloudOwnerFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [ClaudeWebHostMessage] = [], states: [ClaudeCloudState] = [], snapshots: [EngineSnapshot] = []
    func host(_ value: ClaudeWebHostMessage) { lock.lock(); messages.append(value); lock.unlock() }
    func state(_ value: ClaudeCloudState) { lock.lock(); states.append(value); lock.unlock() }
    func frame(_ bytes: Data) { guard let value = try? JSONDecoder().decode(EngineSnapshot.self, from: bytes) else { return }; lock.lock(); snapshots.append(value); lock.unlock() }
    var requests: [ClaudeWebHostMessage] { lock.lock(); defer { lock.unlock() }; return messages.filter { $0.type == "hostRequest" } }
    var latest: EngineSnapshot? { lock.lock(); defer { lock.unlock() }; return snapshots.last }
}
private actor CloudScopeSignals {
    var observed: [String?] = [], changes = 0
    func observe(_ scope: String?) -> Bool { observed.append(scope); return true }
    func changed() { changes += 1 }
}
private actor CloudOwnerClient: ClaudeCloudConnection {
    var callback: ClaudeCloudProjectMonitor.Update?
    var stopped = false, expanded = false
    func start(expanded: Bool, update: @escaping ClaudeCloudProjectMonitor.Update) { self.expanded = expanded; callback = update }
    func setExpanded(_ value: Bool) { expanded = value }
    func refresh() {}
    func shutdown() { stopped = true }
    func emit(_ values: [SessionActivity]) async {
        var status = RuntimeStreamStatus(); status.connected = true; status.sourceAvailable = true
        await callback?(values, status, [])
    }
}
private actor CloudOwnerFactory {
    var values: [(ClaudeCloudServices.Input, CloudOwnerClient)] = []
    func make(_ input: ClaudeCloudServices.Input) -> CloudOwnerClient {
        let client = CloudOwnerClient(); values.append((input, client)); return client
    }
    var count: Int { values.count }
    func value(_ index: Int) -> (ClaudeCloudServices.Input, CloudOwnerClient) { values[index] }
}

final class ClaudeCloudOwnerTests: XCTestCase {
    private let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-cloud-missing-fixture")
    private let organization = "11111111-1111-4111-8111-111111111111"
    private func until(_ condition: () async -> Bool) async throws {
        for _ in 0..<400 { if await condition() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("The scoped cloud operation did not reach its bounded checkpoint"); throw URLError(.timedOut)
    }
    private func reply(_ key: String, organization: String? = nil) -> ClaudeWebSessionReply {
        .init(state: "ok", cookieHeader: "sessionKey=" + key, sessionHash: ClaudeQuotaDecoder.digest(key), organizationID: organization)
    }
    private func complete(_ frames: CloudOwnerFrames, _ bridge: ClaudeWebBridge, at index: Int, reply: ClaudeWebSessionReply) async throws {
        try await until { frames.requests.count > index }
        let request = frames.requests[index]
        let accepted = await bridge.complete(id: request.requestID, context: request.context, reply: reply); XCTAssertTrue(accepted)
    }
    func testConcurrentStreamsCoalesceOnlyPendingCookieReadsAndRejectAChangedAccount() async throws {
        let frames = CloudOwnerFrames(), signals = CloudScopeSignals()
        let bridge = ClaudeWebBridge { frames.host($0) }; await bridge.setAvailable(true)
        let input = ClaudeCloudServices.Input(home: home, organization: organization, context: UUID().uuidString, localSessions: { [] },
            observedScope: { await signals.observe($0) }, changedScope: { await signals.changed() })
        let provider = ClaudeCloudCookieProvider(bridge: bridge, input: input)
        let first = Task { await provider.read() }, second = Task { await provider.read() }
        try await until { frames.requests.count == 1 }; try await Task.sleep(nanoseconds: 20_000_000)
        try await complete(frames, bridge, at: 0, reply: reply("synthetic-cloud-account-a"))
        let a = await first.value, b = await second.value
        XCTAssertEqual(a?.sessionHash, b?.sessionHash); XCTAssertNotNil(a); XCTAssertEqual(frames.requests.count, 1)
        let next = Task { await provider.read() }
        try await complete(frames, bridge, at: 1, reply: reply("synthetic-cloud-account-b"))
        let changed = await next.value; XCTAssertNil(changed)
        try await until { await signals.changes == 1 }
        let rejected = await provider.read(); XCTAssertNil(rejected); XCTAssertEqual(frames.requests.count, 2)
        let observations = await signals.observed; XCTAssertEqual(observations.count, 1)
        await provider.stop()
    }
    func testExplicitWorkspaceWinsOverCookieAndStoppingRevokesPendingWork() async throws {
        let frames = CloudOwnerFrames(), signals = CloudScopeSignals()
        let bridge = ClaudeWebBridge { frames.host($0) }; await bridge.setAvailable(true)
        let input = ClaudeCloudServices.Input(home: home, organization: organization, context: UUID().uuidString, localSessions: { [] },
            observedScope: { await signals.observe($0) }, changedScope: { await signals.changed() })
        let provider = ClaudeCloudCookieProvider(bridge: bridge, input: input)
        for (index, cookieOrg) in [organization, "22222222-2222-4222-8222-222222222222"].enumerated() {
            let read = Task { await provider.read() }; try await complete(frames, bridge, at: index, reply: reply("synthetic-cloud-account-a", organization: cookieOrg))
            let value = await read.value; XCTAssertNotNil(value)
        }
        let changes = await signals.changes; XCTAssertEqual(changes, 0)
        let pending = Task { await provider.read() }; try await until { frames.requests.count == 3 }
        await provider.stop(); let value = await pending.value; XCTAssertNil(value)
        let last = try XCTUnwrap(frames.requests.last)
        let accepted = await bridge.complete(id: last.requestID, context: last.context, reply: reply("synthetic-cloud-account-a")); XCTAssertFalse(accepted)
    }
    func testMonitorWaitsForPublicationPreservesHiddenAccountAndRevokesOldCallbacks() async throws {
        let factory = CloudOwnerFactory(), frames = CloudOwnerFrames()
        let monitor = ClaudeCloudMonitor(services: .init(makeClient: { await factory.make($0) })) { frames.state($0) }
        await monitor.configure(home: home, organization: organization, enabled: true, webAvailable: true, context: 1)
        let before = await factory.count; XCTAssertEqual(before, 0, "A host context must be published before the first cookie request")
        await monitor.startAfterPublication(); await monitor.waitUntilStarted()
        let (input, first) = await factory.value(0)
        let accepted = await input.observedScope("scope-a"); XCTAssertTrue(accepted)
        let sample = DemoScenario.claudeCloud(stage: .tool, at: Date()).activities
        await first.emit(sample); let initial = await monitor.currentState(); XCTAssertFalse(initial.activities.isEmpty)
        await monitor.configure(home: home, organization: organization, enabled: false, webAvailable: true, context: 2)
        await first.emit(sample); let hidden = await monitor.currentState()
        XCTAssertTrue(hidden.activities.isEmpty); XCTAssertEqual(hidden.purgeRevision, initial.purgeRevision)
        let stopped = await first.stopped; XCTAssertTrue(stopped)
        await monitor.configure(home: home, organization: organization, enabled: true, webAvailable: true, context: 3)
        await monitor.startAfterPublication(); await monitor.waitUntilStarted()
        let (again, second) = await factory.value(1); _ = await again.observedScope("scope-a")
        let shown = await monitor.currentState(); XCTAssertEqual(shown.purgeRevision, initial.purgeRevision)
        XCTAssertNotEqual(shown.connectionContext, initial.connectionContext)
        await second.emit(sample); await again.changedScope()
        try await until { await factory.count == 3 }; await monitor.waitUntilStarted()
        await second.emit(sample); let rebound = await monitor.currentState()
        XCTAssertTrue(rebound.activities.isEmpty); XCTAssertGreaterThan(rebound.purgeRevision, initial.purgeRevision)
        XCTAssertNotEqual(rebound.connectionContext, shown.connectionContext)
        await monitor.stop()
    }
    func testEngineKeepsHiddenCompletionsUnreadButPurgesThemOnWorkspaceChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-cloud-engine-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let factory = CloudOwnerFactory(), frames = CloudOwnerFrames(), date = Date()
        let runtime = EngineRuntime(demo: false, now: { date }, dismissalStore: nil,
            cloudServices: .init(makeClient: { await factory.make($0) }), output: { frames.frame($0) })
        func command(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": method, "method": method, "params": params])
        }
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["claude"], "claudeHome": EngineCodexSourceReport.path(root), "hideProjects": true]))
        _ = await runtime.receive(try command("setClaudeWebHost", ["webAvailable": true]))
        try await until { await factory.count == 1 }
        let (input, first) = await factory.value(0); _ = await input.observedScope("scope-a")
        try await until { await first.callback != nil }
        let project = ClaudeCloudProject(id: "chan_fixture1", name: "Private fixture project")
        let thread = "cmsg_fixture1", worker = "cse_fixture1"
        var graph = ClaudeCloudProjectState()
        graph.apply(.init(projects: [project], threads: [project.id: [.init(id: thread, projectID: project.id, status: .working,
            isWorking: true, sessionIDs: [worker])]], sessions: [worker: .init(id: worker, worker: .running)]), at: date.addingTimeInterval(-1))
        await first.emit(graph.activities)
        graph.apply(.init(projects: [project], threads: [project.id: [.init(id: thread, projectID: project.id, status: .resolved,
            hasUnread: true, lastReplyAt: date, sessionIDs: [worker], replyCount: 1)]], sessions: [worker: .init(id: worker, worker: .idle)]), at: date)
        let completed = graph.activities
        await first.emit(completed)
        let ended = try XCTUnwrap(frames.latest)
        XCTAssertTrue(ended.tasks.contains { $0.phase == "completed" && $0.unread })
        XCTAssertTrue(ended.tasks.allSatisfy { $0.title == L10n.text("activity.local_task") })
        _ = await runtime.receive(try command("configure", ["showClaudeCloudProjects": false]))
        XCTAssertTrue(try XCTUnwrap(frames.latest).tasks.isEmpty)
        _ = await runtime.receive(try command("markAllRead", ["snapshotSequence": try XCTUnwrap(frames.latest).sequence]))
        _ = await runtime.receive(try command("configure", ["showClaudeCloudProjects": true]))
        try await until { await factory.count == 2 }
        let (again, second) = await factory.value(1); _ = await again.observedScope("scope-a")
        try await until { await second.callback != nil }
        await second.emit(completed)
        XCTAssertTrue(try XCTUnwrap(frames.latest).tasks.contains { $0.phase == "completed" && $0.unread }, "Visible-only acknowledgement cannot dismiss hidden cloud endings")
        _ = await runtime.receive(try command("configure", ["claudeOrganization": organization]))
        XCTAssertTrue(try XCTUnwrap(frames.latest).tasks.isEmpty, "An old workspace's retained graph must be removed before the next source starts")
        await second.emit(completed)
        XCTAssertTrue(try XCTUnwrap(frames.latest).tasks.isEmpty)
        let json = String(decoding: try JSONEncoder().encode(try XCTUnwrap(frames.latest).claudeCloudConnection), as: UTF8.self)
        XCTAssertFalse(json.contains(organization)); XCTAssertFalse(json.contains("scope-a")); XCTAssertFalse(json.contains("cookie"))
        await runtime.stop()
    }
}
