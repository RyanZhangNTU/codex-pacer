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
        XCTAssertEqual(value.rows[0].status, L10n.text("subagent.waiting_parent"), "Only its subagents are at work")
        let bar = CompactBarContext(activities: activities, requests: [], completions: [], sources: [], now: now)
        XCTAssertEqual(bar.statusText(.stage, language: .english), L10n.text("subagent.waiting_parent", language: .english))
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
        let codex = DemoScenario.tasks(stage: .tool, at: now)
        XCTAssertNil(ActivityTaskRowPresentation.sourceName(codex[0], options: .init()))
        XCTAssertEqual(ActivityTaskRowPresentation.sourceName(codex[1], options: .init()), codex[1].sourceHost)
    }

    func testContinuingCodexTurnsKeepFinishedChildrenUntilAnIndependentRequest() throws {
        let tasks = DemoScenario.subagentTasks(stage: .completed, at: now).dropFirst()
        var root = DemoScenario.subagentTasks(stage: .thinking, at: now)[0]
        func row() throws -> ActivityTaskRowPresentation {
            try XCTUnwrap(ActivityTaskPresentation(activities: [root] + tasks, requests: [], inbox: CompletionInbox(), at: now).rows.first)
        }
        for index in 1...2 {
            root.consumeLive(["method": "turn/started", "threadId": root.threadID!, "turnId": "wake-\(index)",
                              "rootTurnId": "demo-turn", "at": now.timeIntervalSince1970 + Double(index)])
            XCTAssertEqual(try row().subagentDotStates, [.completed, .completed, .completed])
        }
        root.consumeLive(["method": "turn/started", "threadId": root.threadID!, "turnId": "independent", "at": now.timeIntervalSince1970 + 3])
        XCTAssertTrue(try row().subagentDotStates.isEmpty)
    }

    func testBackgroundWaitNamesRunningSubagentsInRowAndAllCompactModes() throws {
        var codex = DemoScenario.subagentTasks(stage: .thinking, at: now)
        codex[0].consumeLive(["method": "item/started", "itemType": "collabToolCall", "waitingForAgents": true,
                              "itemId": "wait", "threadId": codex[0].threadID!, "turnId": "demo-turn", "at": now.timeIntervalSince1970])
        var claude = DemoScenario.claudeTask(stage: .thinking, at: now)
        claude.waitForBackground(kinds: ["shell", "subagent"], wakeups: 0, at: now)
        var child = SessionActivity(id: "child", provider: .claude, sessionID: "child")
        child.updateParent(claude.threadID)
        child.applyRuntime(["method": "turn/started", "threadId": "child", "turnId": "turn", "at": now.timeIntervalSince1970])
        for (tasks, running) in [(codex, 3), ([claude, child], 1), ([claude], 0)] {
            let row = try XCTUnwrap(ActivityTaskPresentation(activities: tasks, requests: [], inbox: CompletionInbox(), at: now).rows.first)
            XCTAssertEqual(row.status, L10n.text(running > 0 ? "subagent.waiting_parent" : "activity.background_wait"))
            let bar = CompactBarContext(activities: tasks, requests: [], completions: [], sources: [], now: now)
            guard running > 0 else {
                let expected = L10n.text("activity.background_wait_compact", language: .english)
                XCTAssertEqual(bar.headerStatusText(language: .english), expected)
                for mode in [CompactComponentOptions.StatusShow.urgent, .stage, .count] { XCTAssertEqual(bar.statusText(mode, language: .english), expected) }
                continue
            }
            // The default status counts the subagents at work; the stage says the task waits for them.
            let count = String(format: L10n.text(running == 1 ? "activity.subagent_running" : "activity.subagents_running", language: .english), running)
            XCTAssertEqual(bar.statusText(.urgent, language: .english), count)
            XCTAssertEqual(bar.statusText(.stage, language: .english), L10n.text("subagent.waiting_parent", language: .english))
        }
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

    func testSubagentsShowAsDotsAndLinesWithEndedOnesQuiet() throws {
        var activities = DemoScenario.subagentTasks(stage: .thinking, at: now)
        for index in [1, 2] {
            activities[index].consumeLive(["method": "turn/completed", "threadId": activities[index].threadID!, "turnId": "demo-turn",
                                           "status": "completed", "at": now.timeIntervalSince1970])
        }
        let row = try XCTUnwrap(ActivityTaskPresentation(activities: activities, requests: [], inbox: CompletionInbox(), at: now).rows.first)
        XCTAssertEqual(row.subagentDotStates, [.running, .completed, .completed], "Working ones first")
        XCTAssertEqual(row.subagentLines.map(\.state), [.running, .completed, .completed], "Working ones first")
        XCTAssertNil(row.foldedSubagents)
        XCTAssertNotNil(row.subagentLines[0].rateText)
        XCTAssertNil(row.subagentLines[1].rateText, "An ended subagent shows no speed")
        XCTAssertTrue(row.subagentLines[1].detail.hasPrefix(L10n.text("subagent.completed")))
        XCTAssertEqual(row.subagents, 1)
        let live = [activities[0], activities[3]].compactMap { $0.displayedOutputEstimate(at: now)?.value }.reduce(0, +)
        XCTAssertEqual(try XCTUnwrap(row.rate?.value), live, accuracy: 1e-9, "Finished subagents add no speed")
        XCTAssertEqual(row.subagentDotsAccessibility, L10n.text("subagent.dots_accessibility", 3, 1))
    }
    func testManySubagentsFoldIntoOneLineAndAFinishedTaskKeepsOnlyItsDots() throws {
        var activities = DemoScenario.subagentTasks(stage: .thinking, at: now)
        let parent = try XCTUnwrap(activities[0].threadID)
        for index in 4...7 {
            var child = SessionActivity(id: String(format: "019a0000-0000-7000-8000-%012d", 200 + index), phaseAwareRate: true,
                                    sessionID: String(format: "019a0000-0000-7000-8000-%012d", 200 + index))
            child.updateParent(parent)
            child.consumeLive(["method": "turn/started", "threadId": child.threadID!, "turnId": "demo-turn", "at": now.timeIntervalSince1970])
            child.consumeLive(["method": "turn/completed", "threadId": child.threadID!, "turnId": "demo-turn", "status": "completed",
                               "at": now.timeIntervalSince1970])
            activities.append(child)
        }
        let row = try XCTUnwrap(ActivityTaskPresentation(activities: activities, requests: [], inbox: CompletionInbox(), at: now).rows.first)
        XCTAssertEqual(row.subagentLines.count, ActivityTaskRowPresentation.subagentLineLimit)
        XCTAssertTrue(row.subagentLines.allSatisfy { $0.state == .running })
        XCTAssertEqual(row.foldedSubagents, .init(active: 0, ended: 4, failed: 0))
        XCTAssertEqual(row.foldedSubagents?.text, L10n.text("subagent.folded_done", 4))
        XCTAssertEqual(row.subagentDotStates.count, 7)
        // Once nothing runs, the lines go and the dots stay until the task clears.
        let ended = activities.map { value -> SessionActivity in
            var value = value
            value.consumeLive(["method": "turn/completed", "threadId": value.threadID!, "turnId": "demo-turn", "status": "completed",
                               "at": now.addingTimeInterval(1).timeIntervalSince1970])
            return value
        }
        for root in [activities[0], ended[0]] {
            let tasks = [root] + ended.dropFirst()
            let done = try XCTUnwrap(ActivityTaskPresentation(activities: tasks, requests: [], inbox: CompletionInbox(), at: now.addingTimeInterval(2)).rows.first)
            XCTAssertTrue(done.subagentLines.isEmpty); XCTAssertNil(done.foldedSubagents)
            XCTAssertEqual(done.subagentDotStates, Array(repeating: .completed, count: 7))
        }
    }

    func testEndedLinesAreSelectedByEndTimeAndParentOnlyChildStaysGrey() throws {
        var children = DemoScenario.subagentTasks(stage: .thinking, at: now)
        var parent = children.removeFirst()
        let synthetic = "019a0000-0000-7000-8000-000000000700"
        parent.consumeLive(["method": "subagents/updated", "turnId": "demo-turn", "threadId": parent.threadID!,
                            "states": [synthetic: "completed"], "at": now.addingTimeInterval(1).timeIntervalSince1970])
        let projected = try XCTUnwrap(ActivityTaskGroup.make([parent]).first)
        let dot = ActivityTaskRowPresentation(activity: parent, group: projected, unread: false, at: now)
        XCTAssertNil(projected.members.first { $0.threadID == synthetic }?.turnStartedAt)
        XCTAssertEqual(dot.subagentDotStates, [.completed]); XCTAssertTrue(dot.subagentLines.isEmpty)
        XCTAssertEqual(dot.subagentDotsAccessibility, L10n.text("subagent.dots_accessibility_singular", 1, 0))
        // The oldest start finishes last and a later start finishes first.
        for index in children.indices {
            let at = now.addingTimeInterval([30, 0, 20][index])
            children[index].consumeLive(["method": "turn/completed", "threadId": children[index].threadID!, "turnId": "demo-turn",
                                         "status": "interrupted", "at": at.timeIntervalSince1970])
        }
        let active = "019a0000-0000-7000-8000-000000000701"
        parent.consumeLive(["method": "subagents/updated", "turnId": "demo-turn", "threadId": parent.threadID!,
                            "states": [synthetic: "completed", active: "running"], "at": now.addingTimeInterval(2).timeIntervalSince1970])
        let group = try XCTUnwrap(ActivityTaskGroup.make([parent] + children).first)
        let row = ActivityTaskRowPresentation(activity: parent, group: group, unread: false, at: now.addingTimeInterval(31))
        XCTAssertEqual(Set(row.subagentLines.compactMap(\.row.activity.threadID)), Set([active, children[0].threadID!, children[2].threadID!]))
        XCTAssertEqual(row.foldedSubagents?.text, L10n.text("subagent.folded_ended", 2))
    }

    func testFoldedSubagentsUseTheirOwnOutcomeAndCount() {
        typealias Fold = ActivityTaskRowPresentation.FoldedSubagents
        for count in [1, 2] {
            let suffix = count == 1 ? "_singular" : ""
            XCTAssertEqual(Fold(active: count, ended: 0, failed: 0).text, L10n.text("subagent.folded_more" + suffix, count))
            XCTAssertEqual(Fold(active: 0, ended: count, failed: 0).text, L10n.text("subagent.folded_done" + suffix, count))
            XCTAssertEqual(Fold(active: 0, ended: count, failed: 0, stopped: 1).text, L10n.text("subagent.folded_ended" + suffix, count))
            XCTAssertEqual(Fold(active: 0, ended: count, failed: 1).text, L10n.text("subagent.folded_failed" + suffix, count, 1))
        }
    }

    func testCrowdedLinesKeepAttentionThenCurrentRequestBeforeOlderRunningChildren() throws {
        let tasks = DemoScenario.subagentTasks(stage: .thinking, at: now)
        let parent = tasks[0]
        func child(_ index: Int, at offset: Double, flag: String? = nil) -> SessionActivity {
            let id = String(format: "019a0000-0000-7000-8000-%012d", index)
            var child = SessionActivity(id: id, sessionID: id)
            child.updateParent(parent.threadID)
            let at = now.timeIntervalSince1970 + offset
            child.consumeLive(["method": "turn/started", "threadId": id, "turnId": "run", "at": at])
            if let flag {
                child.consumeLive(["method": "thread/status/changed", "threadId": id, "turnId": "run",
                                   "status": "active", "flags": [flag], "at": at + 1])
            }
            return child
        }
        let previous = child(501, at: -90), approval = child(503, at: -4, flag: "waitingOnApproval")
        let input = child(502, at: -2, flag: "waitingOnUserInput")
        let row = try XCTUnwrap(ActivityTaskPresentation(activities: [input, previous, approval] + tasks,
            requests: [], inbox: CompletionInbox(), at: now).rows.first)
        XCTAssertEqual(row.subagentLines.map(\.state), [.approval, .input, .running])
        XCTAssertEqual(row.subagentLines.map(\.row.activity.threadID), [approval.threadID, input.threadID, tasks[1].threadID])
        XCTAssertEqual(row.subagentDotStates, [.attention, .attention] + Array(repeating: .running, count: 4))
        XCTAssertEqual(row.foldedSubagents?.active, 3)
    }

    func testACrowdedRowKeepsWaitingAndRunningDotsAndFoldsDoneOnes() throws {
        var activities = DemoScenario.subagentTasks(stage: .thinking, at: now)
        let parent = try XCTUnwrap(activities[0].threadID)
        // Nine more that started earlier and are done: they would fill the row by age.
        for index in 1...9 {
            let thread = String(format: "019a0000-0000-7000-8000-%012d", 300 + index)
            var child = SessionActivity(id: thread, phaseAwareRate: true, sessionID: thread)
            child.updateParent(parent)
            child.consumeLive(["method": "turn/started", "threadId": thread, "turnId": "early", "at": now.addingTimeInterval(-25).timeIntervalSince1970])
            child.consumeLive(["method": "turn/completed", "threadId": thread, "turnId": "early", "status": "completed",
                               "at": now.addingTimeInterval(-20).timeIntervalSince1970])
            activities.insert(child, at: 1)
        }
        let row = try XCTUnwrap(ActivityTaskPresentation(activities: activities, requests: [], inbox: CompletionInbox(), at: now).rows.first)
        XCTAssertEqual(row.subagentDotStates.count, 12)
        let wide = row.subagentDots(limit: ActivityTaskRowPresentation.subagentDotLimit)
        XCTAssertEqual(wide.shown, [.running, .running, .running] + Array(repeating: .completed, count: 5))
        XCTAssertEqual(wide.more, 4, "The folded ones are done ones")
        let narrow = row.subagentDots(limit: ActivityTaskRowPresentation.compactSubagentDotLimit)
        XCTAssertEqual(narrow.shown, [.running, .running, .running, .completed, .completed])
        XCTAssertEqual(narrow.more, 7)
        XCTAssertEqual(row.subagentDotsAccessibility, L10n.text("subagent.dots_accessibility", 12, 3))
    }
}
