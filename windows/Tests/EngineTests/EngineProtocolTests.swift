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

final class EngineProtocolTests: XCTestCase {
    private func command(_ method: String, _ params: [String: Any] = [:], version: Int = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["protocolVersion": version, "id": method, "method": method, "params": params])
    }
    func testDashboardProjectsBothStylesAndFiltersDisabledProviders() async throws {
        let capture = FrameCapture(), clock = Date(timeIntervalSince1970: 1_800_000_000)
        let runtime = EngineRuntime(demo: true, now: { clock }, output: { capture.append($0) })
        _ = await runtime.receive(try command("initialize"))
        let all = try XCTUnwrap(capture.snapshots().last?.quotaDashboard)
        XCTAssertEqual(all.schemaVersion, 1); XCTAssertEqual(all.providers.map(\.provider), AgentProvider.allCases)
        XCTAssertEqual(all.classic.slots.map(\.period), [.weekly, .weekly, .weekly])
        XCTAssertEqual(all.providers.first?.weekly.remainingPercent, 43)
        XCTAssertEqual(all.providers.first?.status?.state, .hidden); XCTAssertNil(all.providers.last?.status)
        XCTAssertNil(all.legacyCodex)
        _ = await runtime.receive(try command("configure", ["enabledProviders": ["claude"]]))
        let one = try XCTUnwrap(capture.snapshots().last?.quotaDashboard)
        XCTAssertEqual(one.providers.map(\.provider), [.claude]); XCTAssertEqual(one.split.kind, .splitSingle)
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
