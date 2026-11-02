import XCTest
@testable import PacerCore

final class ActivityApplicationStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let visible = ActivityVisibilityOptions()

    private func task(_ number: Int = 1, host: String? = nil, parent: Int? = nil,
                      ended: Bool = false, embedded: Bool = false) -> SessionActivity {
        func id(_ number: Int) -> String { String(format: "019a0000-0000-7000-8000-%012d", number) }
        let thread = id(number)
        var value = SessionActivity(id: AgentProvider.codex.activityID(sessionID: thread, sourceHostID: host), sourceHostID: host)
        value.consumeLive(["method": "turn/started", "threadId": thread, "turnId": "first", "at": now.addingTimeInterval(-5).timeIntervalSince1970])
        if let parent { value.updateParent(id(parent)) }
        value.setCodexOrigin(.init(embedded: embedded, ignored: false))
        if ended { value.consumeLive(["method": "turn/completed", "threadId": thread, "turnId": "first", "status": "completed", "at": now.timeIntervalSince1970]) }
        return value
    }

    private func request(_ task: SessionActivity, kind: PendingAttentionRequest.Kind = .input, id: String = "question") -> PendingAttentionRequest {
        .init(id: id, threadID: task.threadID!, sourceHostID: task.sourceHostID, sourceName: nil,
              kind: kind, detectedAt: now, provider: task.provider)
    }

    func testDemoModuleFilteringDoesNotChangeObservedInputRules() {
        let codex = task(), claude = DemoScenario.claudeTask(stage: .thinking, at: now)
        let deepseek = DemoScenario.deepseekTask(stage: .thinking, at: now)
        var state = ActivityApplicationState()
        state.localActivities = [codex]; state.claudeActivities = [claude]; state.deepseekActivities = [deepseek]
        state.claudeReceivedRequests = [request(claude)]
        state.reconcile(at: now, retention: 300, visibility: visible)
        XCTAssertEqual(Set(state.activities.map(\.provider)), Set(AgentProvider.allCases))
        XCTAssertEqual(state.requests.map(\.provider), [.claude])
        state.demoActivities = [codex, claude, deepseek]; state.demoRequests = [request(claude)]
        state.includesDemoMetadata = true
        state.applyDemoSnapshot(enabled: [.deepseek], at: now, visibility: visible)
        XCTAssertEqual(state.activities.map(\.provider), [.deepseek])
        XCTAssertTrue(state.requests.isEmpty)
        state.reconcile(at: now, retention: 300, visibility: visible)
        XCTAssertEqual(Set(state.activities.map(\.provider)), Set(AgentProvider.allCases), "Observed snapshots do not inherit demo module filtering")
        XCTAssertEqual(state.requests.map(\.provider), [.claude])
    }

    func testHiddenEmbeddedFamilyRetainsUnreadEndingAndReturnsWithoutAcknowledgment() {
        var state = ActivityApplicationState()
        let root = task(embedded: true), child = task(2, parent: 1)
        state.localActivities = [child, root]
        state.reconcile(at: now, retention: 300, visibility: visible)
        state.localActivities = [task(2, parent: 1, ended: true), task(ended: true, embedded: true)]
        let hidden = ActivityVisibilityOptions(embeddedProviders: [.claude, .deepseek])
        state.reconcile(at: now, retention: 300, visibility: hidden)
        XCTAssertTrue(state.activities.isEmpty)
        XCTAssertEqual(state.inbox.unreadActivities.count, 2)
        XCTAssertFalse(state.markAllRead(at: now))
        state.reconcile(at: now, retention: 300, visibility: visible)
        XCTAssertEqual(state.presentation(at: now).rows.count, 1)
        XCTAssertEqual(state.presentation(at: now).readableCompletions.count, 2)
        XCTAssertTrue(state.markAllRead(at: now))
        XCTAssertTrue(state.inbox.unreadActivities.isEmpty)
        state.reconcile(at: now, retention: 300, visibility: visible)
        XCTAssertTrue(state.activities.isEmpty, "Reader replay cannot restore acknowledged family endings")
    }

    func testMarkAllReadAcrossPagesProtectsRequestsRunningFamiliesAndOtherHosts() {
        var state = ActivityApplicationState()
        let endings = (1...8).map { task($0, ended: true) }
        let remote = task(1, host: "remote-control:fixture", ended: true)
        let root = task(20, ended: true), child = task(21, parent: 20)
        state.localActivities = endings + [root, child]; state.remoteActivities = [remote]
        state.codexReceivedRequests = [request(endings[0])]
        state.reconcile(at: now, retention: 300, visibility: visible)
        XCTAssertGreaterThan(state.presentation(at: now).pagination.pageCount, 1)
        XCTAssertTrue(state.markAllRead(at: now))
        XCTAssertEqual(Set(state.inbox.unreadActivities.map(\.id)), Set([endings[0].id, root.id]))
        XCTAssertEqual(state.requests.count, 1, "Acknowledgment never resolves a pending reply")
        XCTAssertTrue(state.activities.contains { $0.id == child.id })
        XCTAssertFalse(state.activities.contains { $0.id == remote.id }, "Another host's eligible ending can be read independently")
        state.codexReceivedRequests = []
        state.reconcile(at: now, retention: 300, visibility: visible)
        XCTAssertTrue(state.markRead(activityID: endings[0].id, at: now))
        XCTAssertEqual(state.inbox.unreadActivities.map(\.id), [root.id])
    }

    func testPerProviderNoticeBaselinesAndPendingReplySuppression() {
        var state = ActivityApplicationState()
        state.localActivities = [task()]
        state.claudeActivities = [DemoScenario.claudeTask(stage: .thinking, at: now)]
        state.deepseekActivities = [DemoScenario.deepseekTask(stage: .thinking, at: now)]
        XCTAssertTrue(state.reconcile(at: now, retention: 300, visibility: visible).notices.isEmpty)
        let claude = DemoScenario.claudeTask(stage: .completed, at: now)
        state.localActivities = [task(ended: true)]; state.claudeActivities = [claude]
        state.deepseekActivities = [DemoScenario.deepseekTask(stage: .completed, at: now)]
        state.claudeReceivedRequests = [request(claude)]
        let notices = state.reconcile(at: now, retention: 300, visibility: visible).notices
        XCTAssertEqual(notices.filter { $0.kind == .completed }.count, 2)
        XCTAssertEqual(notices.filter { $0.kind == .waitingForInput }.count, 1)
        XCTAssertFalse(notices.contains { $0.kind == .completed && $0.id.hasPrefix(claude.id + ":") })
        XCTAssertTrue(state.reconcile(at: now.addingTimeInterval(1), retention: 300, visibility: visible).notices.isEmpty)
        state.codexAttention = AttentionPolicy()
        XCTAssertTrue(state.reconcile(at: now.addingTimeInterval(2), retention: 300, visibility: visible).notices.allSatisfy { $0.id.hasPrefix(state.localActivities[0].id) }, "Resetting one provider does not reset another provider's reminder baseline")
    }

    func testLogRequestIsSupersededOnlyByMatchingLiveEvidence() {
        var state = ActivityApplicationState()
        let value = task(), logged = request(value)
        state.localActivities = [value]; state.codexLogRequests = [logged]
        state.codexAttentionThreadIDs = [value.threadID!]
        state.remoteActivities = [task(host: "remote-control:other")]
        state.reconcile(at: now, retention: 300, visibility: visible)
        XCTAssertEqual(state.requests, [logged], "Disconnected or another-host evidence cannot answer a local request")
        var newer = value
        newer.consumeLive(["method": "turn/started", "threadId": value.threadID!, "turnId": "next", "at": now.addingTimeInterval(1).timeIntervalSince1970])
        state.remoteActivities = [newer]
        state.reconcile(at: now.addingTimeInterval(1), retention: 300, visibility: visible)
        XCTAssertTrue(state.requests.isEmpty, "A proven later turn suppresses a stale logged question")
    }

    func testGroupingCacheIgnoresClockAndOptionsButRebuildsForChangedActivities() {
        var state = ActivityApplicationState()
        state.replaceActivities([task()], at: now)
        _ = state.presentation(at: now); _ = state.taskGroups(); _ = state.overview(at: now)
        let original = state.taskGroupingComputations
        _ = state.presentation(at: now.addingTimeInterval(1), options: .init(hideProjects: true))
        state.replaceActivities([task()], at: now)
        XCTAssertEqual(state.taskGroupingComputations, original)
        state.replacePendingRequests([request(task())])
        XCTAssertEqual(state.presentation(at: now).rows[0].attention, .input)
        XCTAssertEqual(state.taskGroupingComputations, original)
        state.replaceActivities([task(ended: true)], at: now)
        XCTAssertEqual(state.presentation(at: now).rows[0].phase, .completed)
        XCTAssertEqual(state.taskGroupingComputations, original + 1)
    }

    func testLatestFirstOutputRejectsInvalidSamplesAndSurvivesRemovedCards() {
        var state = ActivityApplicationState()
        state.rememberFirstOutput(2, reportedAt: now.addingTimeInterval(-10), at: now)
        for latency in [-1, Double.nan, .infinity, 3601] {
            state.rememberFirstOutput(latency, reportedAt: now.addingTimeInterval(-1), at: now)
        }
        state.rememberFirstOutput(1, reportedAt: now.addingTimeInterval(1), at: now)
        state.rememberFirstOutput(3, reportedAt: now.addingTimeInterval(-20), at: now)
        state.replaceActivities([], at: now)
        XCTAssertEqual(state.latestFirstOutput?.seconds, 2)
        state.rememberFirstOutput(0, reportedAt: now, at: now)
        XCTAssertEqual(state.latestFirstOutput?.seconds, 0)
        state.clearFirstOutput()
        XCTAssertNil(state.latestFirstOutput)
    }

    func testDesktopMetadataAppliesToLoggedTaskWithoutRecreatingReleasedStream() throws {
        var state = ActivityApplicationState()
        let original = task()
        var renamed = original
        renamed.consumeLive(["method": "metadata", "threadId": original.threadID!, "name": "Synthetic task label",
                             "at": now.addingTimeInterval(1).timeIntervalSince1970])
        let name = try XCTUnwrap(SessionNameUpdate(renamed))
        state.localActivities = [original]
        state.applyCodexMetadata(names: [name], performance: [])
        state.reconcile(at: now.addingTimeInterval(1), retention: 300, visibility: visible)
        XCTAssertEqual(state.activities.first?.title, "Synthetic task label")
        XCTAssertTrue(state.remoteActivities.isEmpty, "Metadata does not fabricate runtime lifecycle evidence")
        XCTAssertEqual(state.activities.first?.turnID, original.turnID)
        XCTAssertEqual(state.activities.first?.phaseChangedAt, original.phaseChangedAt)
    }

    func testDisplayDeadlinePrunesRetentionWithoutChangingRequestBaseline() {
        var state = ActivityApplicationState()
        let ended = task(ended: true), pending = request(task(2))
        state.localActivities = [ended]; state.codexReceivedRequests = [pending]
        XCTAssertEqual(state.reconcile(at: now, retention: 10, visibility: visible).notices.filter { $0.kind == .waitingForInput }.count, 1)
        XCTAssertEqual(state.nextDisplayDeadline(at: now, retention: 10), now.addingTimeInterval(10))
        state.prune(at: now.addingTimeInterval(11), retention: 10)
        XCTAssertTrue(state.activities.isEmpty)
        XCTAssertEqual(state.requests, [pending])
        XCTAssertTrue(state.reconcile(at: now.addingTimeInterval(11), retention: 10, visibility: visible).notices.isEmpty)
        XCTAssertNil(state.nextDisplayDeadline(at: now.addingTimeInterval(11), retention: 10))
    }

    func testPendingEndingBufferIsBoundedAndReconcilesBeforeStreamRelease() {
        var state = ActivityApplicationState()
        state.rememberCodexEndings((1...300).map { task($0, ended: true) })
        XCTAssertEqual(state.pendingCodexEndings.count, 256)
        state.reconcile(at: now, retention: 300, visibility: visible)
        XCTAssertTrue(state.pendingCodexEndings.isEmpty)
        XCTAssertEqual(state.inbox.unreadActivities.count, 256)
    }

    func testRateExpiryUsesExactClockAndOnlyInvalidatesTheTimedProjection() throws {
        let thread = "019a0000-0000-7000-8000-000000000001"
        var value = SessionActivity(id: "local:" + thread, phaseAwareRate: true)
        value.consumeLive(["method": "turn/started", "threadId": thread, "turnId": "turn", "at": now.addingTimeInterval(-10).timeIntervalSince1970])
        value.consumeLive(["method": "item/agentMessage/delta", "threadId": thread, "turnId": "turn", "hasText": true, "at": now.timeIntervalSince1970])
        value.consumeLive(["method": "thread/tokenUsage/updated", "threadId": thread, "turnId": "turn", "outputTokens": 600, "lastOutputTokens": 600, "at": now.timeIntervalSince1970])
        var state = ActivityApplicationState()
        state.localActivities = [value]
        state.reconcile(at: now, retention: 300, visibility: visible)
        let expiry = try XCTUnwrap(value.rateExpiresAt)
        XCTAssertEqual(state.nextDisplayDeadline(at: now, retention: 300), expiry)
        let before = state.presentation(at: expiry.addingTimeInterval(-0.001))
        XCTAssertTrue(before.rows[0].rate?.isFresh == true)
        let computations = state.taskGroupingComputations
        state.prune(at: expiry.addingTimeInterval(0.001), retention: 300)
        let after = state.presentation(at: expiry.addingTimeInterval(0.001))
        XCTAssertFalse(after.rows[0].rate?.isFresh == true)
        XCTAssertEqual(after.rows[0].rate?.value, before.rows[0].rate?.value)
        XCTAssertEqual(state.localActivities, [value], "Display expiry never changes collector input")
        XCTAssertEqual(state.taskGroupingComputations, computations)
        XCTAssertEqual(state.nextDisplayDeadline(at: expiry.addingTimeInterval(0.001), retention: 300), value.turnStartedAt?.addingTimeInterval(60))
    }

    func testUnknownTaskExpiresFromDisplayAtItsOwnDeadline() {
        let activity = PendingAttentionRequest(id: "orphan", threadID: "019a0000-0000-7000-8000-000000000003",
            sourceHostID: nil, sourceName: nil, kind: .input, detectedAt: now).activity
        var observed = activity
        observed.consumeLive(["method": "thread/status/changed", "threadId": activity.threadID!, "status": "notLoaded", "at": now.timeIntervalSince1970])
        var state = ActivityApplicationState()
        state.replaceActivities([observed], at: now)
        XCTAssertEqual(state.nextDisplayDeadline(at: now, retention: 0), now.addingTimeInterval(900))
        XCTAssertEqual(state.presentation(at: now.addingTimeInterval(899.999)).rows.count, 1)
        XCTAssertTrue(state.presentation(at: now.addingTimeInterval(900.001)).rows.isEmpty)
        XCTAssertNil(state.nextDisplayDeadline(at: now.addingTimeInterval(900.001), retention: 0))
    }
}
