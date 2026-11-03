import XCTest
@testable import PacerCore

final class ActivityTaskPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testShellDisplayStringsUseTheMacFormatters() throws {
        let activities = DemoScenario.subagentTasks(stage: .thinking, at: now)
        let value = ActivityTaskPresentation(activities: activities, requests: [], inbox: CompletionInbox(), at: now)
        let row = try XCTUnwrap(value.rows.first), rate = try XCTUnwrap(row.rate)
        XCTAssertEqual(row.rateText, String(format: "%.1f", rate.value))
        XCTAssertEqual(row.subagentText, "3")
        XCTAssertEqual(value.taskCountText, "1")
        for count in [0, 1, 99, 100, 1000] {
            let header = HeaderActivity(core: .count(count), activeCount: count, orbit: [:])
            XCTAssertEqual(header.activeCountText, count > 99 ? "99+" : String(count))
        }
    }

    func testTurnTimeUsesMacWordingAndEndedDurationStaysFixed() throws {
        var activity = DemoScenario.tasks(stage: .thinking, at: now)[0]
        let start = try XCTUnwrap(activity.turnStartedAt)
        XCTAssertEqual(ActivityTaskRowPresentation.turnTimeText(activity, phase: .running, now: start.addingTimeInterval(30)),
                       L10n.text("dashboard.countdown_soon"))
        XCTAssertEqual(ActivityTaskRowPresentation.turnTimeText(activity, phase: .running, now: start.addingTimeInterval(95)),
                       L10n.text("dashboard.countdown_minutes", 1))
        XCTAssertNil(ActivityTaskRowPresentation.turnTimeText(activity, phase: .running, now: start.addingTimeInterval(-1)))
        XCTAssertNil(ActivityTaskRowPresentation.turnTimeText(activity, phase: .completed, now: now))
        activity.consumeLive(["method": "turn/completed", "threadId": activity.threadID!, "turnId": activity.turnID!,
                              "status": "completed", "at": start.addingTimeInterval(3725).timeIntervalSince1970])
        XCTAssertEqual(ActivityTaskRowPresentation.turnTimeText(activity, phase: .completed, now: start.addingTimeInterval(90_000)),
                       L10n.text("dashboard.countdown_hours", 1, 2))
        XCTAssertEqual(CompactDuration.text(90_000), L10n.text("dashboard.countdown_days", 1, 1))
    }

    func testDimmedModelAndTruncationRulesMatchMacRows() {
        for phase in [ActivityPhase.completed, .interrupted] {
            XCTAssertTrue(ActivityTaskRowPresentation.isDimmed(phase: phase, unread: false, attention: false, failed: false))
            XCTAssertFalse(ActivityTaskRowPresentation.isDimmed(phase: phase, unread: true, attention: false, failed: false))
            XCTAssertFalse(ActivityTaskRowPresentation.isDimmed(phase: phase, unread: false, attention: true, failed: false))
            XCTAssertFalse(ActivityTaskRowPresentation.isDimmed(phase: phase, unread: false, attention: false, failed: true))
        }
        XCTAssertFalse(ActivityTaskRowPresentation.isDimmed(phase: .running, unread: false, attention: false, failed: false))
        XCTAssertFalse(ActivityTaskRowPresentation.isDimmed(phase: .waitingForInput, unread: false, attention: false, failed: false))
        XCTAssertEqual(ActivityTaskRowPresentation.middleTruncated("devbox-gpu-03.lab", limit: 16), "devbox-…u-03.lab")
        XCTAssertEqual(ActivityTaskRowPresentation.middleTruncated("devbox", limit: 16), "devbox")
        XCTAssertEqual(ActivityTaskRowPresentation.shortened("qwen3-coder-480b-a35b-instruct", limit: 22), "qwen3-coder-480b-a35b…")
        let activity = DemoScenario.claudeTask(stage: .thinking, at: now)
        let row = ActivityTaskRowPresentation(activity: activity, unread: false, at: now)
        XCTAssertEqual(row.model, ModelDisplay.name(activity.modelName!))
        XCTAssertEqual(row.effort, ModelDisplay.effortLabel(activity.reasoningEffort!))
    }

    func testChildAttentionUpdatesFamilyStatusAndHeaderWithoutChangingTaskCount() throws {
        let activities = DemoScenario.subagentTasks(stage: .tool, at: now)
        let child = activities[1]
        let requests = [PendingAttentionRequest(id: "decision", threadID: child.threadID!, sourceHostID: nil, sourceName: nil,
            kind: .decision, detectedAt: now), PendingAttentionRequest(id: "approval", threadID: child.threadID!, sourceHostID: nil,
            sourceName: nil, kind: .approval, detectedAt: now)]
        let value = ActivityTaskPresentation(activities: activities, requests: requests, inbox: CompletionInbox(), at: now)
        let row = try XCTUnwrap(value.rows.first)
        XCTAssertEqual(value.rows.count, 1)
        XCTAssertEqual(row.attention, .approval)
        XCTAssertEqual(row.symbol, .approval)
        XCTAssertEqual(row.phase, .running)
        XCTAssertEqual(row.subagents, 3)
        XCTAssertTrue(row.status.hasPrefix(L10n.text("attention.approval")))
        let header = value.header(symbol: { $0.rawValue })
        XCTAssertEqual(header.activeCount, 1)
        XCTAssertEqual(header.orbit, [.codex: 1])
        XCTAssertEqual(header.attention, .decision, "Header follows the first actionable request, as on Mac")
        XCTAssertEqual(header.core, .symbol("input"))
        XCTAssertEqual(value.header(singleTask: .count, symbol: { $0.rawValue }).core, .count(1))
    }

    func testEndedParentWithRunningChildrenHasNoEndingBadgeOrReadableCompletion() throws {
        var activities = DemoScenario.subagentTasks(stage: .thinking, at: now)
        activities[0].consumeLive(["method": "turn/completed", "threadId": activities[0].threadID!, "turnId": "demo-turn",
                                  "status": "completed", "at": now.timeIntervalSince1970])
        var inbox = CompletionInbox()
        inbox.observe(activities, at: now, retention: 300)
        let value = ActivityTaskPresentation(activities: activities, requests: [], inbox: inbox, at: now)
        XCTAssertEqual(value.rows.count, 1)
        XCTAssertEqual(value.rows[0].phase, .running)
        XCTAssertEqual(value.rows[0].symbol, .thinking)
        XCTAssertEqual(value.rows[0].status, L10n.text("activity.running_long"))
        XCTAssertFalse(value.rows[0].unread)
        XCTAssertTrue(value.pendingCompletions.isEmpty)
        XCTAssertTrue(value.readableCompletions.isEmpty)
        XCTAssertNil(value.header(symbol: { $0.rawValue }).ending)
        let childrenRate = activities.dropFirst().compactMap { $0.displayedOutputEstimate(at: now)?.value }.reduce(0, +)
        XCTAssertEqual(try XCTUnwrap(value.rows[0].rate?.value), childrenRate, accuracy: 1e-9)
    }

    func testSourceTitlesUseHostFactsAndHideProjectBeforeProjection() {
        let claude = DemoScenario.claudeTask(stage: .thinking, at: now)
        XCTAssertNil(ActivityTaskRowPresentation.sourceName(claude, options: .init()))
        XCTAssertEqual(ActivityTaskRowPresentation.sourceName(claude,
            options: .init(hostApplications: [claude.id: .init(name: "Synthetic Editor")])), "Synthetic Editor")
        XCTAssertNil(ActivityTaskRowPresentation.sourceName(claude,
            options: .init(hostApplications: [claude.id: .init(name: "Claude", isClaudeDesktop: true)])))
        let cloud = DemoScenario.claudeCloud(stage: .tool, at: now)
        let presentation = ActivityTaskPresentation(activities: cloud.activities, requests: cloud.attention,
            inbox: CompletionInbox(), options: .init(hideProjects: true), at: now)
        XCTAssertTrue(presentation.rows.allSatisfy { $0.title == L10n.text("activity.hidden_name") })
        XCTAssertTrue(presentation.rows.allSatisfy { $0.source == L10n.text("connections.kind.claude_cloud") })
        XCTAssertTrue(presentation.rows.allSatisfy { $0.sourceKind == "cloud" })
        let remote = DemoScenario.tasks(stage: .tool, at: now)[1]
        XCTAssertEqual(ActivityTaskRowPresentation.sourceName(remote, options: .init()), remote.sourceHost)
    }

    func testPaginationAndReadOnlyEndingDoNotChangeOtherRows() throws {
        let activities = DemoScenario.tasks(stage: .completed, at: now) + [DemoScenario.claudeTask(stage: .completed, at: now),
            DemoScenario.deepseekTask(stage: .completed, at: now)]
        var inbox = CompletionInbox()
        inbox.observe(activities, at: now, retention: 300)
        let value = ActivityTaskPresentation(activities: activities, requests: [], inbox: inbox, at: now)
        XCTAssertEqual(value.pagination.rowCapacity, 3)
        XCTAssertEqual(value.pagination.pageCount, 2)
        let ending = try XCTUnwrap(value.readableCompletions.first)
        XCTAssertTrue(inbox.dismiss(ending))
        let read = ActivityTaskPresentation(activities: activities, requests: [], inbox: inbox, at: now)
        let row = try XCTUnwrap(read.rows.first { $0.activity.id == ending.id })
        XCTAssertTrue(row.dimmed)
        XCTAssertFalse(row.unread)
        XCTAssertEqual(read.pagination, value.pagination)
        XCTAssertEqual(Set(read.visibleActivities.map(\.id)), Set(value.visibleActivities.map(\.id)))
    }
}
