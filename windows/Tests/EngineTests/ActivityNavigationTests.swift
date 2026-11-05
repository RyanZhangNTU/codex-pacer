@testable import PacerEngineSupport
import Foundation
import XCTest
@testable import PacerCore

private final class NavigationFrames: @unchecked Sendable {
    private let lock = NSLock(); private var values: [Data] = []
    func append(_ data: Data) { lock.lock(); values.append(data); lock.unlock() }
    var all: [Data] { lock.lock(); defer { lock.unlock() }; return values }
    var snapshot: EngineSnapshot? { all.compactMap { try? JSONDecoder().decode(EngineSnapshot.self, from: $0) }.last }
    var error: String? { all.reversed().compactMap { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["code"] as? String }.first }
    func plan() throws -> EngineNavigationPlan {
        struct Reply: Decodable { let value: EngineNavigationPlan }
        return try XCTUnwrap(all.compactMap { try? JSONDecoder().decode(Reply.self, from: $0).value }.last)
    }
}
private actor NavigationGate {
    var waiting = false
    private var resume: CheckedContinuation<EngineNavigationPlan, Never>?
    private var input: ActivityNavigationServices.Input?
    func resolve(_ input: ActivityNavigationServices.Input) async -> EngineNavigationPlan {
        self.input = input; waiting = true
        return await withCheckedContinuation { resume = $0 }
    }
    func release() {
        guard let input else { return }; resume?.resume(returning: .init(demoContext: input.context, provider: input.activity.provider)); resume = nil
    }
}
private actor HostActivationGate {
    var calls: [ActivityHostApplication] = []
    private var continuation: CheckedContinuation<Bool, Never>?
    private var released: Bool?
    func activate(_ host: ActivityHostApplication) async -> Bool {
        calls.append(host)
        if let released { return released }
        return await withCheckedContinuation { continuation = $0 }
    }
    func release(_ value: Bool) { released = value; continuation?.resume(returning: value); continuation = nil }
}

final class ActivityNavigationTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private var home: URL { FileManager.default.temporaryDirectory.appendingPathComponent("pacer-nav-source") }
    private func row(session: String = "11111111-1111-4111-8111-111111111111", turn: String = "first", ended: Bool = true, offset: TimeInterval = 0) -> SessionActivity {
        var row = SessionActivity(id: AgentProvider.codex.activityID(sessionID: session), provider: .codex, sessionID: session)
        let formatter = ISO8601DateFormatter()
        row.consume(["type": "event_msg", "timestamp": formatter.string(from: date.addingTimeInterval(offset)), "payload": ["type": "task_started", "turn_id": turn]])
        if ended { row.consume(["type": "event_msg", "timestamp": formatter.string(from: date.addingTimeInterval(offset + 1)), "payload": ["type": "task_complete", "turn_id": turn]]) }
        return row
    }
    private func inbox(_ row: SessionActivity) -> CompletionInbox {
        var inbox = CompletionInbox(); inbox.bindSourceHomes(provider: .codex, localHome: home)
        let running = self.row(session: row.threadID!, turn: row.turnID!, ended: false,
            offset: row.turnStartedAt!.timeIntervalSince(date))
        _ = inbox.observe([running], at: date, retention: 1800)
        _ = inbox.observe([row], at: date.addingTimeInterval(2), retention: 1800); return inbox
    }
    private func update(_ registry: inout ActivityNavigationRegistry, _ rows: [SessionActivity], inbox: CompletionInbox, cloud: String? = nil) {
        registry.update(activities: rows, requests: [], inbox: inbox, cloudContext: cloud, canOpen: { _ in true })
    }
    func testUnrelatedSnapshotsKeepTheLinkAndAcknowledgeOnlyItsEnding() throws {
        let first = row(), other = row(session: "22222222-2222-4222-8222-222222222222")
        var inbox = self.inbox(first), registry = ActivityNavigationRegistry()
        _ = inbox.observe([first, row(session: other.threadID!, ended: false)], at: date, retention: 1800)
        _ = inbox.observe([first, other], at: date.addingTimeInterval(2), retention: 1800)
        update(&registry, [first, other], inbox: inbox)
        let token = try XCTUnwrap(registry.entries[first.id]?.link.context)
        update(&registry, [other, first], inbox: inbox)
        XCTAssertEqual(registry.entries[first.id]?.link.context, token)
        XCTAssertTrue(registry.acknowledge(context: token, inbox: &inbox))
        XCTAssertFalse(inbox.isUnread(first)); XCTAssertTrue(inbox.isUnread(other))
    }
    func testNewTurnAndChangedHomeRevokeAnOlderOpen() throws {
        let first = row(); var inbox = self.inbox(first), registry = ActivityNavigationRegistry()
        update(&registry, [first], inbox: inbox)
        let old = try XCTUnwrap(registry.links.first?.context)
        let second = row(turn: "second", offset: 3)
        _ = inbox.observe([row(turn: "second", ended: false, offset: 3)], at: date.addingTimeInterval(3), retention: 1800)
        _ = inbox.observe([second], at: date.addingTimeInterval(5), retention: 1800)
        update(&registry, [second], inbox: inbox)
        XCTAssertFalse(registry.acknowledge(context: old, inbox: &inbox)); XCTAssertTrue(inbox.isUnread(second))
        let current = try XCTUnwrap(registry.links.first?.context)
        inbox.bindSourceHomes(provider: .codex, localHome: home.appendingPathComponent("other"))
        XCTAssertFalse(registry.acknowledge(context: current, inbox: &inbox))
    }
    func testParentResolutionUsesObservedIDsAndRejectsCyclesOrUnprovedChildren() throws {
        var parent = row(), child = row(session: "22222222-2222-4222-8222-222222222222", ended: false)
        parent.setCodexOrigin(.init(embedded: true, ignored: false)); child.setCodexOrigin(.init(embedded: true, ignored: false)); child.updateParent(parent.threadID)
        let inbox = self.inbox(parent)
        XCTAssertEqual(ActivityNavigationTarget.resolve(child, activities: [parent, child], inbox: inbox)?.threadID, parent.threadID)
        XCTAssertEqual(ActivityNavigationTarget.resolve(child, activities: [child], inbox: inbox)?.threadID, parent.threadID)
        var registry = ActivityNavigationRegistry()
        registry.update(activities: [child], requests: [], inbox: inbox, cloudContext: nil, canOpen: { $0.threadID == parent.threadID })
        XCTAssertEqual(registry.entries[child.id]?.target.threadID, parent.threadID, "Availability must validate the proven parent, not the child's CLI ID")
        parent.updateParent(child.threadID)
        XCTAssertNil(ActivityNavigationTarget.resolve(child, activities: [child, parent], inbox: inbox))
        var unproved = SessionActivity(id: child.id, provider: .codex, sessionID: child.threadID)
        unproved.setCodexOrigin(.init(embedded: true, ignored: false)); unproved.updateParent(parent.threadID)
        XCTAssertNil(ActivityNavigationTarget.resolve(unproved, activities: [parent], inbox: inbox))
    }
    func testCloudAccountContextRevokesEvenAnIdenticalRow() throws {
        var activity = SessionActivity(id: "cloud-fixture", sourceHostID: ClaudeCloudProjectState.sourceID, provider: .claude)
        activity.setClaudeCloud(.init(projectID: "chan_navigation", projectName: "Fixture", role: .coordinator))
        let inbox = CompletionInbox(); var registry = ActivityNavigationRegistry()
        update(&registry, [activity], inbox: inbox, cloud: "first-account")
        let old = try XCTUnwrap(registry.links.first?.context)
        update(&registry, [activity], inbox: inbox, cloud: "second-account")
        XCTAssertNil(registry.entry(context: old)); XCTAssertNotEqual(registry.links.first?.context, old)
    }
    private func command(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": method, "method": method, "params": params])
    }
    func testActualProtocolKeepsAcknowledgmentAcrossRateTicksAndRejectsReuse() async throws {
        let frames = NavigationFrames(), clock = date
        let runtime = EngineRuntime(demo: true, now: { clock }, output: { frames.append($0) })
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex"]]))
        _ = await runtime.receive(try command("demoStage", ["demoStage": 3]))
        let unread = Set(frames.snapshot?.tasks.filter(\.unread).map(\.id) ?? [])
        let link = try XCTUnwrap(frames.snapshot?.activityLinks?.first { unread.contains($0.activityID) })
        XCTAssertTrue(frames.snapshot?.tasks.contains { $0.id == link.activityID && $0.unread } == true)
        _ = await runtime.receive(try command("prepareActivityOpen", ["context": link.context]))
        XCTAssertEqual(try frames.plan().kind, "demo")
        _ = await runtime.receive(try command("refresh"))
        _ = await runtime.receive(try command("completeActivityOpen", ["context": link.context]))
        XCTAssertFalse(frames.snapshot?.tasks.contains { $0.id == link.activityID && $0.unread } == true)
        _ = await runtime.receive(try command("completeActivityOpen", ["context": link.context]))
        XCTAssertEqual(frames.error, "staleActivityOpen"); await runtime.stop()
    }
    func testSourceSwitchDuringPreparationCannotReturnAnOldDestination() async throws {
        let frames = NavigationFrames(), gate = NavigationGate()
        let runtime = EngineRuntime(demo: true, navigationServices: .init(resolve: { await gate.resolve($0) }), output: { frames.append($0) })
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex"]]))
        let context = try XCTUnwrap(frames.snapshot?.activityLinks?.first?.context)
        let request = try command("prepareActivityOpen", ["context": context])
        let preparing = Task { await runtime.receive(request) }
        try await TestWait.until { await gate.waiting }
        let waiting = await gate.waiting; XCTAssertTrue(waiting)
        _ = await runtime.receive(try command("configure", ["enabledProviders": ["claude"]]))
        await gate.release(); _ = await preparing.value
        XCTAssertEqual(frames.error, "staleActivityOpen"); await runtime.stop()
    }
    func testOpeningIsSingleFlightAndFailureKeepsTheCapturedEndingUnread() async throws {
        let frames = NavigationFrames(), clock = date
        // The error must outlive the hops before it is read on a slow runner.
        let runtime = EngineRuntime(demo: true, now: { clock }, navigationErrorDuration: 1, output: { frames.append($0) })
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex"]]))
        _ = await runtime.receive(try command("demoStage", ["demoStage": 3]))
        let link = try XCTUnwrap(frames.snapshot?.activityLinks?.first { link in frames.snapshot?.tasks.contains { $0.id == link.activityID && $0.unread } == true })
        _ = await runtime.receive(try command("prepareActivityOpen", ["context": link.context]))
        XCTAssertTrue(frames.snapshot?.openingActivityIDs?.contains(link.activityID) == true)
        _ = await runtime.receive(try command("prepareActivityOpen", ["context": link.context]))
        XCTAssertEqual(frames.error, "navigationInProgress")
        _ = await runtime.receive(try command("failActivityOpen", ["context": link.context, "navigationMessage": "Synthetic host unavailable"]))
        XCTAssertEqual(frames.snapshot?.navigationError?.message, "Synthetic host unavailable")
        XCTAssertTrue(frames.snapshot?.tasks.contains { $0.id == link.activityID && $0.unread } == true)
        XCTAssertFalse(frames.snapshot?.openingActivityIDs?.contains(link.activityID) == true)
        try await TestWait.until { frames.snapshot?.navigationError == nil }
        XCTAssertNil(frames.snapshot?.navigationError, "The shared error deadline publishes a display-only expiry")
        XCTAssertTrue(frames.snapshot?.tasks.contains { $0.id == link.activityID && $0.unread } == true)
        await runtime.stop()
    }
    func testHostActivationUsesAnOpaqueSingleUseCapabilityAndAcknowledgesOnlyAfterSuccess() async throws {
        let frames = NavigationFrames(), gate = HostActivationGate()
        let runtime = EngineRuntime(demo: true, navigationServices: .init { input in
            .init(context: input.context, provider: input.activity.provider, host: .init(identity: .init(pid: 42, started: 84),
                provider: nil, name: "Synthetic editor", home: input.home))
        }, activityHostServices: .init(resolve: { _ in [:] }, activate: { await gate.activate($0) }), output: { frames.append($0) })
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex"]]))
        _ = await runtime.receive(try command("demoStage", ["demoStage": 3]))
        let link = try XCTUnwrap(frames.snapshot?.activityLinks?.first { link in frames.snapshot?.tasks.contains { $0.id == link.activityID && $0.unread } == true })
        _ = await runtime.receive(try command("prepareActivityOpen", ["context": link.context]))
        XCTAssertEqual(try frames.plan().kind, "host")
        let data = try command("activateActivityHost", ["context": link.context])
        let activating = Task { await runtime.receive(data) }
        try await TestWait.until { await !gate.calls.isEmpty }
        let calls = await gate.calls
        XCTAssertEqual(calls.map(\.identity), [.init(pid: 42, started: 84)])
        XCTAssertTrue(frames.snapshot?.tasks.contains { $0.id == link.activityID && $0.unread } == true)
        _ = await runtime.receive(data)
        XCTAssertEqual(frames.error, "staleActivityOpen", "An OS launch capability can be consumed only once")
        await gate.release(true); _ = await activating.value
        XCTAssertTrue(frames.snapshot?.tasks.contains { $0.id == link.activityID && $0.unread } == true, "Activation alone never marks a completion read")
        _ = await runtime.receive(try command("completeActivityOpen", ["context": link.context]))
        XCTAssertFalse(frames.snapshot?.tasks.contains { $0.id == link.activityID && $0.unread } == true)
        await runtime.stop()
    }
    func testFailedHostRestartKeepsUnreadAndSleepRevokesThePendingCapability() async throws {
        let frames = NavigationFrames(), gate = HostActivationGate()
        let runtime = EngineRuntime(demo: true, navigationServices: .init { input in
            .init(context: input.context, provider: input.activity.provider, pid: 42, started: 84)
        }, activityHostServices: .init(resolve: { _ in [:] }, activate: { await gate.activate($0) }), output: { frames.append($0) })
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex"]]))
        _ = await runtime.receive(try command("demoStage", ["demoStage": 3]))
        let link = try XCTUnwrap(frames.snapshot?.activityLinks?.first { link in frames.snapshot?.tasks.contains { $0.id == link.activityID && $0.unread } == true })
        _ = await runtime.receive(try command("prepareActivityOpen", ["context": link.context]))
        let data = try command("activateActivityHost", ["context": link.context])
        let activating = Task { await runtime.receive(data) }
        try await TestWait.until { await !gate.calls.isEmpty }
        await gate.release(false); _ = await activating.value
        _ = await runtime.receive(try command("failActivityOpen", ["context": link.context, "navigationMessage": "Synthetic editor was removed"]))
        XCTAssertEqual(frames.snapshot?.navigationError?.message, "Synthetic editor was removed")
        XCTAssertTrue(frames.snapshot?.tasks.contains { $0.id == link.activityID && $0.unread } == true)
        _ = await runtime.receive(try command("prepareActivityOpen", ["context": link.context]))
        await runtime.prepareForSleep(); await runtime.resumeAfterSleep()
        _ = await runtime.receive(data)
        XCTAssertEqual(frames.error, "staleActivityOpen")
        let calls = await gate.calls; XCTAssertEqual(calls.count, 1, "Wake cannot reactivate a pre-sleep host capability")
        XCTAssertTrue(frames.snapshot?.tasks.contains { $0.id == link.activityID && $0.unread } == true)
        await runtime.stop()
    }
    func testAnotherProvidersSettingsDoNotRevokeAnOpen() async throws {
        let frames = NavigationFrames(), clock = date
        let runtime = EngineRuntime(demo: true, now: { clock }, output: { frames.append($0) })
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex", "claude"]]))
        _ = await runtime.receive(try command("demoStage", ["demoStage": 3]))
        let unread = Set(frames.snapshot?.tasks.filter(\.unread).map(\.id) ?? [])
        let link = try XCTUnwrap(frames.snapshot?.activityLinks?.first { $0.provider == "codex" && unread.contains($0.activityID) })
        _ = await runtime.receive(try command("prepareActivityOpen", ["context": link.context]))
        _ = await runtime.receive(try command("configure", ["claudeHome": EngineCodexSourceReport.path(home.appendingPathComponent("claude-other"))]))
        XCTAssertTrue(frames.snapshot?.openingActivityIDs?.contains(link.activityID) == true)
        _ = await runtime.receive(try command("completeActivityOpen", ["context": link.context]))
        XCTAssertFalse(frames.snapshot?.tasks.contains { $0.id == link.activityID && $0.unread } == true)
        await runtime.stop()
    }
    func testInputQueueCanSleepAndShutDownWhileAHostResolverIgnoresCancellation() async throws {
        let frames = NavigationFrames(), gate = NavigationGate()
        let runtime = EngineRuntime(demo: true, navigationServices: .init(resolve: { await gate.resolve($0) }), output: { frames.append($0) })
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex"]]))
        let context = try XCTUnwrap(frames.snapshot?.activityLinks?.first?.context)
        let accepted = await runtime.enqueue(try command("prepareActivityOpen", ["context": context]))
        XCTAssertTrue(accepted)
        try await TestWait.until { await gate.waiting }
        let waiting = await gate.waiting; XCTAssertTrue(waiting)
        let slept = expectation(description: "Sleep completes before the resolver is released")
        let sleeping = Task { await runtime.prepareForSleep(); slept.fulfill() }
        await fulfillment(of: [slept], timeout: 2)
        _ = await sleeping.value
        await runtime.resumeAfterSleep()
        XCTAssertFalse(frames.snapshot?.openingActivityIDs?.contains(frames.snapshot?.activityLinks?.first?.activityID ?? "") == true)
        let stopped = expectation(description: "Shutdown completes before the resolver is released")
        let stopping = Task { await runtime.stop(); stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 2)
        _ = await stopping.value
        await gate.release()
        for _ in 0..<200 {
            if frames.error == "staleActivityOpen" { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(frames.error, "staleActivityOpen")
        _ = await runtime.receive(try command("initialize"))
        XCTAssertEqual(frames.error, "unavailable", "A stopped runtime cannot restart collectors")
    }
}

final class ClaudeDesktopNavigationMetadataTests: XCTestCase {
    private let account = "11111111-1111-4111-8111-111111111111", organization = "22222222-2222-4222-8222-222222222222"
    private let cli = "33333333-3333-4333-8333-333333333333", desktop = "local_44444444-4444-4444-8444-444444444444"
    private func write(_ object: [String: Any], _ file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: file)
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-desktop-navigation-" + UUID().uuidString)
        try write(["lastKnownAccountUuid": account, "unrelatedToken": "synthetic-private-token"], root.appendingPathComponent("config.json"))
        return root
    }
    private func metadata(_ root: URL, name: String? = nil, extra: [String: Any] = [:]) throws {
        let id = name ?? desktop
        var values: [String: Any] = ["sessionId": id, "cliSessionId": cli, "bridgeSessionIds": ["session_bridge123"]]
        values.merge(extra) { _, new in new }
        try write(values, root.appendingPathComponent("claude-code-sessions/" + account + "/" + organization + "/" + id + ".json"))
    }
    func testUniqueLocalMappingRejectsRemoteAndAmbiguousDesktopContexts() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try metadata(root)
        var records = ClaudeDesktopRecords.load(configFiles: [root.appendingPathComponent("config.json")])
        XCTAssertEqual(ClaudeDesktopRecords.localSessionID(for: cli, records: records), desktop)
        XCTAssertEqual(records.first?.cloudIDs, ["bridge123"])
        try metadata(root, name: "local_55555555-5555-4555-8555-555555555555", extra: ["sshConfig": ["sshHost": "fixture-host"]])
        records = ClaudeDesktopRecords.load(configFiles: [root.appendingPathComponent("config.json")])
        XCTAssertEqual(ClaudeDesktopRecords.localSessionID(for: cli, records: records), desktop)
        try metadata(root, name: "local_66666666-6666-4666-8666-666666666666")
        records = ClaudeDesktopRecords.load(configFiles: [root.appendingPathComponent("config.json")])
        XCTAssertNil(ClaudeDesktopRecords.localSessionID(for: cli, records: records))
    }
    func testActiveAccountSwitchAndConflictingWindowsRootsCannotReuseAMapping() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try metadata(root)
        let config = root.appendingPathComponent("config.json"), other = root.appendingPathComponent("other/config.json")
        try write(["lastKnownAccountUuid": organization], other)
        XCTAssertTrue(ClaudeDesktopRecords.load(configFiles: [config, other]).isEmpty)
        try write(["lastKnownAccountUuid": organization], config)
        XCTAssertTrue(ClaudeDesktopRecords.load(configFiles: [config]).isEmpty)
    }
    func testMismatchedSessionMetadataAndOversizedDocumentsCannotCreateLinks() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try metadata(root, extra: ["sessionId": "local_55555555-5555-4555-8555-555555555555"])
        XCTAssertTrue(ClaudeDesktopRecords.load(configFiles: [root.appendingPathComponent("config.json")]).isEmpty)
        try metadata(root, extra: ["unused": String(repeating: "x", count: 2 * 1024 * 1024)])
        XCTAssertTrue(ClaudeDesktopRecords.load(configFiles: [root.appendingPathComponent("config.json")]).isEmpty)
    }
    #if os(Windows)
    func testRedirectedAccountDirectoryCannotSupplyADesktopSession() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("other-root"); try metadata(other)
        let parent = root.appendingPathComponent("claude-code-sessions"), alias = parent.appendingPathComponent(account)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = other.appendingPathComponent("claude-code-sessions/" + account)
        let system = WindowsEnvironment.value("SystemRoot", in: ProcessInfo.processInfo.environment) ?? "C:/Windows"
        let process = Process(); process.executableURL = URL(fileURLWithPath: system).appendingPathComponent("System32/WindowsPowerShell/v1.0/powershell.exe")
        process.arguments = ["-NoProfile", "-NonInteractive", "-Command", "$ErrorActionPreference='Stop'; New-Item -ItemType Junction -Path $env:PACER_NAV_TEST_LINK -Target $env:PACER_NAV_TEST_TARGET | Out-Null"]
        process.environment = WindowsEnvironment.replacing("PACER_NAV_TEST_LINK", with: WindowsCodexExecutableDiscovery.path(alias), in:
            WindowsEnvironment.replacing("PACER_NAV_TEST_TARGET", with: WindowsCodexExecutableDiscovery.path(target), in: ProcessInfo.processInfo.environment))
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        TestWait.whileRunning(process)
        if process.isRunning { process.terminate(); process.waitUntilExit(); XCTFail("The private account junction fixture exceeded its deadline"); return }
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(ClaudeDesktopRecords.load(configFiles: [root.appendingPathComponent("config.json")]).isEmpty)
    }
    #endif
}

#if os(Windows)
final class WindowsActivityNavigationTests: XCTestCase {
    private let session = "11111111-1111-4111-8111-111111111111", local = "local_22222222-2222-4222-8222-222222222222"
    private var root: URL { URL(fileURLWithPath: "C:/Users/NavigationFixture") }
    private func input(home: URL? = nil, provider: AgentProvider = .claude) -> ActivityNavigationServices.Input {
        .init(context: UUID().uuidString, activity: SessionActivity(id: provider.activityID(sessionID: session), provider: provider, sessionID: session),
              home: home ?? root.appendingPathComponent(provider == .claude ? ".claude" : ".codex"), transcript: root.appendingPathComponent("fixture.jsonl"))
    }
    func testDesktopMappingRequiresTheDefaultProfileAndLiveHostTakesPriority() throws {
        let records = [ClaudeDesktopRecords.Record(desktopID: local, cliID: session, isLocal: true, cloudIDs: [])]
        let mapped = try WindowsActivityNavigation.resolve(input(), userHome: root, records: records, writers: { _, _ in [] })
        XCTAssertEqual(mapped.url, "claude://code/continue?session=" + local)
        XCTAssertThrowsError(try WindowsActivityNavigation.resolve(input(home: root.appendingPathComponent("other")), userHome: root, records: records, writers: { _, _ in [] }))
        let owner = WindowsProcessHost(identity: .init(pid: 123, started: 456), provider: nil)
        let hosted = try WindowsActivityNavigation.resolve(input(), userHome: root, records: records,
            writers: { _, _ in [owner.identity] }, host: { _ in owner })
        XCTAssertEqual(hosted.kind, "host"); XCTAssertEqual(hosted.pid, 123); XCTAssertNil(hosted.url)
    }
    func testUnavailableOrConflictingWritersCannotBorrowDesktopMapping() {
        let records = [ClaudeDesktopRecords.Record(desktopID: local, cliID: session, isLocal: true, cloudIDs: [])]
        XCTAssertThrowsError(try WindowsActivityNavigation.resolve(input(), userHome: root, records: records, writers: { _, _ in nil }))
        XCTAssertThrowsError(try WindowsActivityNavigation.resolve(input(), userHome: root, records: records,
            writers: { _, _ in [.init(pid: 1, started: 10), .init(pid: 2, started: 20)] }, host: { .init(identity: $0, provider: nil) }))
    }
    func testCodexDefaultProfileUsesItsThreadButCustomProfilesCannotBorrowIt() throws {
        let plan = try WindowsActivityNavigation.resolve(input(provider: .codex), userHome: root)
        XCTAssertEqual(plan.url, "codex://threads/" + session)
        XCTAssertThrowsError(try WindowsActivityNavigation.resolve(input(home: root.appendingPathComponent("custom"), provider: .codex), userHome: root))
    }
    func testHostAncestryRejectsReusedProcessInstancesAndFindsExistingEditorWindow() {
        let writer = WindowsProcessIdentity(pid: 10, started: 100), editor = WindowsProcessIdentity(pid: 20, started: 50)
        let rows: [UInt32: WindowsProcessRecord] = [10: .init(identity: writer, parent: 20, executable: root.appendingPathComponent("cli.exe")),
                                                   20: .init(identity: editor, parent: 0, executable: root.appendingPathComponent("editor.exe"))]
        let lookup: WindowsProcessOwnership.Lookup = { pid, started in rows[pid].flatMap { started == 0 || started == $0.identity.started ? $0 : nil } }
        XCTAssertEqual(WindowsProcessHost.nearest(to: writer, lookup: lookup, available: { $0 == editor }, packageRoots: [:])?.identity, editor)
        XCTAssertNil(WindowsProcessHost.nearest(to: .init(pid: 10, started: 99), lookup: lookup, available: { _ in true }, packageRoots: [:]))
        XCTAssertNil(WindowsProcessHost.nearest(to: writer, lookup: lookup, available: { _ in false }, packageRoots: [:]))
        let shellRows = rows.merging([20: .init(identity: editor, parent: 0, executable: root.appendingPathComponent("explorer.exe"))]) { _, new in new }
        XCTAssertNil(WindowsProcessHost.nearest(to: writer, lookup: { pid, _ in shellRows[pid] }, available: { $0 == editor }, packageRoots: [:]),
            "The Windows shell is not the app that owns a conversation")
    }
}
#endif
