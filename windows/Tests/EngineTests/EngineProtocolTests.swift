@testable import PacerEngineSupport
import Foundation
import XCTest
@testable import PacerCore

private final class FrameCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Data] = []
    func append(_ frame: Data) { lock.lock(); defer { lock.unlock() }; frames.append(frame) }
    func all() -> [Data] { lock.lock(); defer { lock.unlock() }; return frames }
    func snapshots() throws -> [EngineSnapshot] {
        try all().filter { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["type"] as? String == "snapshot" }
            .map { try JSONDecoder().decode(EngineSnapshot.self, from: $0) }
    }
}

private final class ReferenceDisplayClock: @unchecked Sendable {
    private let lock = NSLock()
    private var fired: (@Sendable () -> Void)?
    func arm(_ fired: @escaping @Sendable () -> Void) { lock.lock(); self.fired = fired; lock.unlock() }
    func date() -> Date {
        lock.lock(); let callback = fired; fired = nil; lock.unlock()
        callback?()
        return Date(timeIntervalSince1970: 1_800_000_000)
    }
}

private actor ScaleHarnessMonitor: LocalHarnessMonitor {
    let provider: AgentProvider
    let clock: @Sendable () -> Date
    private var publish: (@Sendable (HarnessActivity) async -> Void)?

    init(provider: AgentProvider, clock: @escaping @Sendable () -> Date) {
        self.provider = provider; self.clock = clock
    }

    func start(home: URL, policy: ActivityRefreshPolicy, publish: @escaping @Sendable (HarnessActivity) async -> Void) async {
        self.publish = publish
        await refresh()
    }
    func refresh() async {
        let rows = (0..<8).map {
            SessionActivity.observedSession(provider: provider, session: "native-session-\($0)", stage: .working, at: clock())
        }
        await publish?(.init(activities: rows, status: .ready))
    }
    func updatePolicy(_ policy: ActivityRefreshPolicy) {}
    func stop() { publish = nil }
}

private actor ReportedHarnessMonitor: LocalHarnessMonitor {
    let provider: AgentProvider
    let clock: Date
    private var publish: (@Sendable (HarnessActivity) async -> Void)?

    init(provider: AgentProvider, clock: Date) { self.provider = provider; self.clock = clock }
    func start(home: URL, policy: ActivityRefreshPolicy, publish: @escaping @Sendable (HarnessActivity) async -> Void) async {
        self.publish = publish
        await refresh()
    }
    func refresh() async {
        var activity = SessionActivity.observedSession(provider: provider, session: "test-session", stage: .working, at: clock)
        activity.applyObservedTurn(.working(.working), id: "test-turn", started: clock, at: clock, live: true)
        activity.reportProgress(37, at: clock, turnID: "test-turn")
        await publish?(.init(activities: [activity], status: .ready))
    }
    func updatePolicy(_ policy: ActivityRefreshPolicy) {}
    func stop() { publish = nil }
}

final class EngineProtocolTests: XCTestCase {
    func testTerminalPlanPayloadsRoundTripWithoutHostCapabilities() throws {
        for kind in ["terminal", "wslTerminal"] {
            let plan = EngineNavigationPlan(context: UUID().uuidString, provider: .claude, terminal: "e30=", kind: kind)
            let bytes = try JSONEncoder().encode(plan), decoded = try JSONDecoder().decode(EngineNavigationPlan.self, from: bytes)
            let row = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            XCTAssertEqual(row["terminal"] as? String, "e30="); XCTAssertEqual(row["kind"] as? String, kind)
            XCTAssertNil(row["hostApplication"]); XCTAssertNil(row["pid"]); XCTAssertNil(row["started"])
            XCTAssertEqual(decoded, plan); XCTAssertNil(decoded.hostApplication)
        }
    }
    private func command(_ method: String, _ params: [String: Any] = [:], version: Int = 1,
                         harnessModules: Bool? = nil) throws -> Data {
        var message: [String: Any] = ["protocolVersion": version, "id": method, "method": method, "params": params]
        if let harnessModules { message["supportsHarnessModules"] = harnessModules }
        return try JSONSerialization.data(withJSONObject: message)
    }

    func testLegacyShellDoesNotReceiveNewModulesAndNewShellGetsTheirDefaults() async throws {
        for supports in [nil, true] as [Bool?] {
            let capture = FrameCapture()
            let runtime = EngineRuntime(demo: false, installationDetection: { .init(installed: []) },
                output: { capture.append($0) })
            await runtime.hello()
            let hello = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(capture.all().first)) as? [String: Any])
            XCTAssertEqual(hello["harnessModules"] as? [String], ["workbuddy"])
            let modes = Dictionary(uniqueKeysWithValues: HarnessRegistry.legacyIDs.map { ($0.rawValue, "disabled") })
            _ = await runtime.receive(try command("initialize", ["providerModes": modes], harnessModules: supports))
            let snapshot = try XCTUnwrap(capture.snapshots().last)
            let modules = try XCTUnwrap(snapshot.modules)
            XCTAssertEqual(Array(modules.prefix(3).map(\.provider)), HarnessRegistry.legacyIDs.map(\.rawValue))
            if supports == true {
                let extra = try XCTUnwrap(modules.first { $0.provider == "workbuddy" })
                XCTAssertEqual(extra.mode, "disabled")
                XCTAssertEqual(extra.displayName, "WorkBuddy")
                XCTAssertEqual(extra.hasTaskProgress, true)
                XCTAssertEqual(extra.reportsSessionUsage, true)
                XCTAssertFalse(extra.enabled)
                XCTAssertNil(extra.status)
            } else { XCTAssertEqual(modules.count, 3) }
            XCTAssertTrue(snapshot.tasks.isEmpty)
            XCTAssertTrue(snapshot.quotaDashboard?.providers.isEmpty == true)
            await runtime.stop()
        }
    }

    func testWorkBuddyProgressVisibilityDoesNotStopTaskObservation() async throws {
        let capture = FrameCapture(), clock = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = try XCTUnwrap(AgentProvider(rawValue: "workbuddy"))
        let definition = LocalHarnessDefinition(descriptor: .init(id: provider, name: "WorkBuddy", symbol: "briefcase", hasTaskProgress: true),
            platforms: [.windows], home: ".fixture-workbuddy-progress", dataFile: "example", windowsExecutables: [],
            makeMonitor: { _ in ReportedHarnessMonitor(provider: provider, clock: clock) })
        let runtime = EngineRuntime(demo: false, now: { clock }, dismissalStore: nil,
            localHarnessDefinitions: [definition], installationDetection: { .init(installed: [provider]) }, output: { capture.append($0) })
        _ = await runtime.receive(try command("initialize", ["enabledProviders": [provider.rawValue], "enabledHarnessProgress": [provider.rawValue],
            "monitorSSH": false, "monitorWSL": false], harnessModules: true))
        let shown = try XCTUnwrap(capture.snapshots().last?.presentation.rows.first)
        XCTAssertEqual(shown.progressFraction, 0.37)
        _ = await runtime.receive(try command("configure", ["enabledHarnessProgress": []]))
        let hidden = try XCTUnwrap(capture.snapshots().last?.presentation.rows.first)
        XCTAssertEqual(hidden.id, shown.id)
        XCTAssertEqual(hidden.phase, shown.phase)
        XCTAssertNil(hidden.progressState)
        _ = await runtime.receive(try command("refreshLocalHarness", ["provider": provider.rawValue]))
        _ = await runtime.receive(try command("configure", ["enabledHarnessProgress": [provider.rawValue]]))
        XCTAssertEqual(try capture.snapshots().last?.presentation.rows.first?.progressFraction, 0.37)
        await runtime.stop()
    }

    func testHundredRegisteredHarnessesFitTheWireAndRemainIsolatedAcrossDisable() async throws {
        let capture = FrameCapture(), clock = Date(timeIntervalSince1970: 1_800_000_000)
        let ids = (0..<100).map { AgentProvider(registeredID: "fixture-\($0)") }
        let definitions = ids.map { id in
            LocalHarnessDefinition(descriptor: .init(id: id, name: id.rawValue, symbol: "circle"),
                platforms: [.windows], home: ".fixture-" + id.rawValue, dataFile: "example", windowsExecutables: [],
                makeMonitor: { _ in ScaleHarnessMonitor(provider: id, clock: { clock }) })
        }
        let runtime = EngineRuntime(demo: false, now: { clock }, dismissalStore: nil,
            localHarnessDefinitions: definitions, installationDetection: { .init(installed: Set(ids)) },
            output: { capture.append($0) })
        await runtime.hello()
        let hello = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(capture.all().first)) as? [String: Any])
        XCTAssertEqual(hello["harnessModules"] as? [String], ids.map(\.rawValue))
        let modes = Dictionary(uniqueKeysWithValues: HarnessRegistry.legacyIDs.map { ($0.rawValue, "disabled") } +
            ids.map { ($0.rawValue, "enabled") })
        _ = await runtime.receive(try command("initialize", ["providerModes": modes, "monitorSSH": false, "monitorWSL": false],
            harnessModules: true))
        let all = try XCTUnwrap(capture.snapshots().last)
        XCTAssertEqual(all.modules?.count, 103)
        XCTAssertEqual(all.modules?.filter { $0.status == "ready" }.count, 100)
        XCTAssertEqual(Set(all.tasks.map(\.provider)).count, 100)
        XCTAssertEqual(all.tasks.count, 256)
        XCTAssertEqual(Set(all.tasks.map(\.id)).count, all.tasks.count)
        XCTAssertLessThan(try JSONEncoder().encode(all).count, EngineProtocol.maximumSnapshotBytes)
        let removed = ids[63].rawValue
        _ = await runtime.receive(try command("configure", ["providerModes": [removed: "disabled"]]))
        let remaining = try XCTUnwrap(capture.snapshots().last)
        XCTAssertFalse(remaining.tasks.contains { $0.provider == removed })
        XCTAssertEqual(Set(remaining.tasks.map(\.provider)).count, 99)
        XCTAssertTrue(remaining.notices.isEmpty)
        await runtime.stop()
    }
    func testDashboardProjectsBothStylesAndFiltersDisabledProviders() async throws {
        let capture = FrameCapture(), clock = Date(timeIntervalSince1970: 1_800_000_000)
        let runtime = EngineRuntime(demo: true, now: { clock }, output: { capture.append($0) })
        _ = await runtime.receive(try command("initialize"))
        let all = try XCTUnwrap(capture.snapshots().last?.quotaDashboard)
        XCTAssertEqual(all.schemaVersion, 1); XCTAssertEqual(all.providers.map(\.provider), HarnessRegistry.legacyIDs)
        XCTAssertEqual(all.classic.slots.map(\.period), [.weekly, .weekly, .weekly])
        XCTAssertEqual(all.providers.first?.weekly.remainingPercent, 43)
        XCTAssertEqual(all.providers.first?.status?.state, .hidden); XCTAssertNil(all.providers.last?.status)
        // The panel can give Codex a section of its own, so its bars come with every snapshot that has Codex.
        XCTAssertEqual(all.legacyCodex?.buckets.first?.windows.first?.remainingPercent, 43)
        _ = await runtime.receive(try command("configure", ["enabledProviders": ["claude"]]))
        let one = try XCTUnwrap(capture.snapshots().last?.quotaDashboard)
        XCTAssertEqual(one.providers.map(\.provider), [.claude]); XCTAssertEqual(one.split.kind, .splitSingle)
        XCTAssertNil(one.legacyCodex)
        XCTAssertEqual(one.classic.slots.map(\.id), ["claude:5h", "claude:7d"])
        _ = await runtime.receive(try command("configure", ["enabledProviders": ["codex"]]))
        let codex = try XCTUnwrap(capture.snapshots().last?.quotaDashboard)
        XCTAssertEqual(codex.split.kind, .splitSingle); XCTAssertEqual(codex.classic.kind, .legacyCodex)
        XCTAssertEqual(codex.legacyCodex?.buckets.first?.windows.first?.remainingPercent, 43)
        _ = await runtime.receive(try command("retryQuota", ["provider": "codex"]))
        XCTAssertEqual(try capture.snapshots().last?.quotaDashboard?.providers.first?.weekly.remainingPercent, 43)
        _ = await runtime.receive(try command("retryQuota", ["provider": "claude"]))
        let rejected = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(capture.all().last)) as? [String: Any])
        XCTAssertEqual(rejected["code"] as? String, "invalidCommand")
        _ = await runtime.receive(try command("configure", ["enabledProviders": [String]()]))
        let none = try XCTUnwrap(capture.snapshots().last)
        XCTAssertTrue(try XCTUnwrap(none.quotaDashboard).providers.isEmpty)
        XCTAssertTrue(none.quota.isEmpty); XCTAssertNil(none.wallet)
        await runtime.stop()
    }

    func testSplitUnicodeCommandsAndCRLFKeepTheirOrder() throws {
        let first = try command("configure", ["codexHome": "C:\\用户\\Codex 数据"])
        let second = try command("refresh")
        let wire = first + Data([13, 10]) + second + Data([10])
        var framer = EngineFramer(), frames: [Data] = []
        for byte in wire { frames += try framer.append(Data([byte])) }
        XCTAssertEqual(frames, [first, second])
        XCTAssertEqual(try EngineCommand.decode(frames[0]).params?.codexHome, "C:\\用户\\Codex 数据")
        XCTAssertNil(try framer.finish())
        var oversized = EngineFramer()
        XCTAssertThrowsError(try oversized.append(Data(repeating: 97, count: EngineProtocol.maximumCommandBytes + 1)))
    }

    func testVersionAndInitializationErrorsCannotStartSources() async throws {
        let capture = FrameCapture(), runtime = EngineRuntime(demo: true, output: { capture.append($0) })
        _ = await runtime.receive(try command("refresh"))
        _ = await runtime.receive(try command("initialize", version: 2))
        XCTAssertTrue(try capture.snapshots().isEmpty)
        _ = await runtime.receive(try command("initialize"))
        XCTAssertEqual(try capture.snapshots().count, 1)
        await runtime.stop()
    }

    func testDemoUsesSharedProviderProjectionAndHidesNamesBeforeSerialization() async throws {
        let capture = FrameCapture()
        let runtime = EngineRuntime(demo: true, now: { Date(timeIntervalSince1970: 1_800_000_000) }, output: { capture.append($0) })
        _ = await runtime.receive(try command("initialize"))
        let visible = try XCTUnwrap(capture.snapshots().last)
        XCTAssertEqual(Set(visible.tasks.map(\.provider)), Set(["codex", "claude", "deepseek"]))
        XCTAssertTrue(visible.sources.allSatisfy { $0.transport == "demo" })
        XCTAssertGreaterThan(visible.runningCount, 0)
        _ = await runtime.receive(try command("configure", ["hideProjects": true]))
        let hidden = try XCTUnwrap(capture.snapshots().last)
        XCTAssertTrue(hidden.tasks.allSatisfy { $0.title == L10n.text("activity.local_task") })
        let projectSources = Set(visible.tasks.filter { $0.sourceID == ClaudeCloudProjectState.sourceID }.map(\.source))
        XCTAssertFalse(projectSources.isEmpty)
        XCTAssertFalse(hidden.tasks.contains { projectSources.contains($0.source) }, "Cloud source labels also contain project names")
        XCTAssertGreaterThan(hidden.sequence, visible.sequence)
        _ = await runtime.receive(try command("demoStage", ["demoStage": DemoTaskStage.completed.rawValue]))
        let ended = try XCTUnwrap(capture.snapshots().last)
        XCTAssertTrue(ended.tasks.contains { $0.phase == "completed" && $0.unread })
        await runtime.stop()
    }

    func testInvalidConfigurationDoesNotPartiallyChangePrivacyOrSources() async throws {
        let capture = FrameCapture(), runtime = EngineRuntime(demo: true, output: { capture.append($0) })
        _ = await runtime.receive(try command("initialize"))
        let original = try XCTUnwrap(capture.snapshots().last)
        _ = await runtime.receive(try command("configure", ["hideProjects": true, "codexHome": "relative/path"]))
        _ = await runtime.receive(try command("refresh"))
        let after = try XCTUnwrap(capture.snapshots().last)
        XCTAssertEqual(after.tasks.map(\.title), original.tasks.map(\.title))
        await runtime.stop()
    }

    func testWireTaskContainsOnlyTheMetadataProjection() throws {
        var activity = SessionActivity(id: "00000000-0000-4000-8000-000000000001", project: "Allowed project", phaseAwareRate: true)
        activity.applyRuntime(["method": "metadata", "threadId": "00000000-0000-4000-8000-000000000001",
            "at": 1000, "title": "Allowed title", "text": "PRIVATE_SENTINEL", "arguments": "PRIVATE_SENTINEL", "auth": "PRIVATE_SENTINEL"])
        let dto = EngineTask(activity, unread: false, hideProjects: false, at: Date(timeIntervalSince1970: 1000))
        let encoded = String(decoding: try JSONEncoder().encode(dto), as: UTF8.self)
        XCTAssertFalse(encoded.contains("PRIVATE_SENTINEL"))
        XCTAssertFalse(encoded.contains("arguments"))
        XCTAssertFalse(encoded.contains("auth"))
    }

    func testMalformedParametersRetainOnlyAValidatedCorrelationID() async throws {
        let capture = FrameCapture(), runtime = EngineRuntime(demo: true, output: { capture.append($0) })
        _ = await runtime.receive(try command("initialize"))
        _ = await runtime.receive(try command("demoStage", ["demoStage": "wrong type"]))
        let error = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(capture.all().last)) as? [String: Any])
        XCTAssertEqual(error["id"] as? String, "demoStage")
        XCTAssertEqual(error["code"] as? String, "invalidCommand")
        XCTAssertNil(EngineCommand.correlationID(Data(#"{"id":"unsafe\nidentifier"}"#.utf8)))
        await runtime.stop()
    }

    func testAcknowledgmentRejectsAnOldSnapshotAndKeepsLiveTasks() async throws {
        let capture = FrameCapture()
        let runtime = EngineRuntime(demo: true, now: { Date(timeIntervalSince1970: 1_800_000_000) }, output: { capture.append($0) })
        _ = await runtime.receive(try command("initialize"))
        _ = await runtime.receive(try command("demoStage", ["demoStage": DemoTaskStage.completed.rawValue]))
        let ended = try XCTUnwrap(capture.snapshots().last)
        let task = try XCTUnwrap(ended.tasks.first { $0.provider == "codex" && $0.phase == "completed" && $0.parentThreadID == nil && $0.unread })
        let count = try capture.snapshots().count
        _ = await runtime.receive(try command("markRead", ["snapshotSequence": ended.sequence - 1, "activityID": task.id]))
        XCTAssertEqual(try capture.snapshots().count, count, "A stale action must not acknowledge a later ending")
        _ = await runtime.receive(try command("markRead", ["snapshotSequence": ended.sequence, "activityID": task.id]))
        let acknowledged = try XCTUnwrap(capture.snapshots().last)
        XCTAssertFalse(acknowledged.tasks.contains { $0.id == task.id })
        XCTAssertEqual(acknowledged.runningCount, ended.runningCount)
        _ = await runtime.receive(try command("refresh"))
        XCTAssertFalse(try XCTUnwrap(capture.snapshots().last).tasks.contains { $0.id == task.id && $0.unread })
        await runtime.stop()
    }

    func testDemoCanReplayAStageAfterCompletionWithoutDroppingTaskFamilies() async throws {
        let capture = FrameCapture()
        let runtime = EngineRuntime(demo: true, now: { Date(timeIntervalSince1970: 1_800_000_000) }, output: { capture.append($0) })
        _ = await runtime.receive(try command("initialize"))
        let original = try XCTUnwrap(capture.snapshots().last)
        _ = await runtime.receive(try command("demoStage", ["demoStage": 3]))
        _ = await runtime.receive(try command("demoStage", ["demoStage": 0]))
        let replay = try XCTUnwrap(capture.snapshots().last)
        XCTAssertEqual(replay.tasks.map(\.id), original.tasks.map(\.id))
        XCTAssertEqual(replay.presentation.rows.map(\.id), original.presentation.rows.map(\.id))
        XCTAssertEqual(replay.runningCount, original.runningCount)
        XCTAssertTrue(replay.requests.isEmpty)
        await runtime.stop()
    }

    func testMissingMarkReadTargetCannotAcknowledgeAllTasks() async throws {
        let capture = FrameCapture()
        let runtime = EngineRuntime(demo: true, now: { Date(timeIntervalSince1970: 1_800_000_000) }, output: { capture.append($0) })
        _ = await runtime.receive(try command("initialize"))
        _ = await runtime.receive(try command("demoStage", ["demoStage": 3]))
        let before = try XCTUnwrap(capture.snapshots().last)
        XCTAssertTrue(before.tasks.contains(where: \.unread))
        _ = await runtime.receive(try command("markRead", ["snapshotSequence": before.sequence]))
        let after = try XCTUnwrap(capture.snapshots().last)
        XCTAssertEqual(after.tasks, before.tasks)
        XCTAssertEqual(after.requests, before.requests)
        await runtime.stop()
    }

    func testElapsedTimerCannotPublishWhenTheReferenceClockHasNotExpired() async throws {
        let capture = FrameCapture(), clock = ReferenceDisplayClock()
        let runtime = EngineRuntime(demo: true, now: { clock.date() }, output: { capture.append($0) })
        _ = await runtime.receive(try command("initialize"))
        let before = try capture.snapshots()
        let wake = expectation(description: "display timer checks the injected clock")
        clock.arm { wake.fulfill() }
        await fulfillment(of: [wake], timeout: 5)
        // Queue behind the timer's synchronous actor turn before inspecting it.
        _ = await runtime.receive(try command("inspectClaudeLocalState"))
        XCTAssertEqual(try capture.snapshots(), before, "A frozen reference clock cannot produce a new or identical display snapshot")
        await runtime.stop()
    }
}
