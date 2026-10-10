import XCTest
import PacerCore
@testable import PacerIsland

@MainActor
final class AttentionDisplayTests: XCTestCase {
    func testAsyncRequestKeepsRunningTasksAndPersistsUntilExplicitResolution() async throws {
        let old = UserDefaults.standard.object(forKey: "inputReminder")
        defer { if let old { UserDefaults.standard.set(old, forKey: "inputReminder") } else { UserDefaults.standard.removeObject(forKey: "inputReminder") } }
        UserDefaults.standard.set(true, forKey: "inputReminder")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let model = IslandModel(demo: true, demoClock: { now })
        let before = model.activities
        let request = PendingAttentionRequest(id: "synthetic-question", threadID: "019a0000-0000-7000-8000-000000000001",
            sourceHostID: "remote-ssh-discovered:test", sourceName: "Synthetic", kind: .input, detectedAt: now)
        let quiet = model.headerActivity()
        model.observeAttentionRequests([request])
        XCTAssertEqual(model.activities, before)
        XCTAssertEqual(model.pendingInputRequests.count, 1)
        let attention = model.headerActivity()
        XCTAssertEqual(attention.attention, .input)
        XCTAssertEqual(attention.core, quiet.core, "The number keeps counting active tasks while a reply is needed")
        XCTAssertEqual(attention.orbit, quiet.orbit, "Running tasks keep their orbit beside the request")
        XCTAssertEqual(model.headerStatus, L10n.text("attention.input"))
        XCTAssertEqual(model.headerDisplayStatus, model.headerStatus)
        model.isAttached = true
        XCTAssertEqual(CompactIslandComponent.isVisible(.tps, model: model), !model.hidesHeaderRate)
        XCTAssertTrue(CompactIslandComponent.isVisible(.tps, model: model, showsStatus: false),
            "Hiding status text allows the chosen TPS component to remain visible during attention")
        XCTAssertEqual(model.headerDisplayStatus, L10n.text("attention.input"), "Notch retains the actionable meaning")
        XCTAssertEqual(model.headerStatus, L10n.text("attention.input"), "Accessibility retains the full meaning")
        let opened = expectation(description: "pending request destination opened")
        model.onOpenActivity = { activity in
            XCTAssertEqual(activity.threadID, request.threadID)
            opened.fulfill(); return .openedConversation
        }
        model.openCompletionOrPin()
        await fulfillment(of: [opened], timeout: 2)
        await Task.yield()
        XCTAssertEqual(model.pendingInputRequests.count, 1, "Opening is not answering")
        model.observeAttentionRequests([])
        XCTAssertTrue(model.pendingInputRequests.isEmpty)
        XCTAssertEqual(model.activities, before)
        XCTAssertEqual(model.headerActivity(), quiet)
    }
    func testDisabledInputReminderRetainsSourceStateWithoutShowingAnAlert() {
        let old = UserDefaults.standard.object(forKey: "inputReminder")
        defer { if let old { UserDefaults.standard.set(old, forKey: "inputReminder") } else { UserDefaults.standard.removeObject(forKey: "inputReminder") } }
        UserDefaults.standard.set(false, forKey: "inputReminder")
        let model = IslandModel(demo: true)
        model.observeAttentionRequests([PendingAttentionRequest(id: "synthetic", threadID: UUID().uuidString.lowercased(),
            sourceHostID: nil, sourceName: nil, kind: .approval, detectedAt: Date())])
        XCTAssertEqual(model.attentionRequests.count, 1)
        XCTAssertTrue(model.pendingInputRequests.isEmpty)
    }
    func testConnectionWarningDoesNotHideUnreadCompletion() throws {
        let old = UserDefaults.standard.object(forKey: "completionReminder")
        defer { if let old { UserDefaults.standard.set(old, forKey: "completionReminder") } else { UserDefaults.standard.removeObject(forKey: "completionReminder") } }
        UserDefaults.standard.set(true, forKey: "completionReminder")
        let oldSSH = UserDefaults.standard.object(forKey: "monitorSSH")
        defer { if let oldSSH { UserDefaults.standard.set(oldSSH, forKey: "monitorSSH") } else { UserDefaults.standard.removeObject(forKey: "monitorSSH") } }
        UserDefaults.standard.set(true, forKey: "monitorSSH")
        let model = IslandModel(demo: true)
        model.setDemoStage(.completed)
        let mixed = model.headerActivity(singleTask: .stage)
        let ending = try XCTUnwrap(mixed.ending)
        XCTAssertEqual(mixed.activeCount, 1)
        XCTAssertTrue(mixed.showsEndingMark, "An unread ending stays visible as a mark beside running work")
        XCTAssertEqual(mixed.core, .symbol(StatusSymbols.tool), "The running task keeps the core")
        let runningIDs = Set(model.running.map(\.id))
        model.activities = model.activities.filter { !runningIDs.contains($0.id) }
        let ended = model.headerActivity()
        XCTAssertEqual(ended.ending, ending)
        XCTAssertTrue(ended.endingIsCore); XCTAssertFalse(ended.showsEndingMark)
        XCTAssertEqual(ended.core, .symbol(ending.symbol), "With nothing active the unread ending fills the core")
        XCTAssertTrue(ended.orbit.isEmpty)
        model.unavailableSSH = ["Synthetic unavailable source"]
        XCTAssertTrue(CompactIslandComponent.isVisible(.sshWarning, model: model))
        XCTAssertEqual(model.headerStatus, model.completionSummary)
        model.isAttached = true
        XCTAssertEqual(model.headerDisplayStatus, model.completionSummary)
    }
    func testAttentionJoinsMatchingTaskWithoutDuplicatesAndRetainsUnmatchedRouting() {
        let old = UserDefaults.standard.object(forKey: "inputReminder")
        defer { if let old { UserDefaults.standard.set(old, forKey: "inputReminder") } else { UserDefaults.standard.removeObject(forKey: "inputReminder") } }
        UserDefaults.standard.set(true, forKey: "inputReminder")
        let model = IslandModel(demo: true)
        let task = model.activities[0]
        let request = PendingAttentionRequest(id: "matching", threadID: task.threadID!, sourceHostID: task.sourceHostID,
            sourceName: nil, kind: .input, detectedAt: model.now)
        let orphan = PendingAttentionRequest(id: "orphan", threadID: UUID().uuidString.lowercased(), sourceHostID: nil,
            sourceName: nil, kind: .approval, detectedAt: model.now)
        model.observeAttentionRequests([request, orphan, request])
        XCTAssertEqual(model.visibleActivities.filter { $0.id == task.id }.count, 1)
        XCTAssertEqual(model.visibleActivities.first { $0.id == task.id }?.phase, .running)
        XCTAssertEqual(model.attentionKind(for: task), .input)
        XCTAssertEqual(model.visibleActivities.filter { $0.id == orphan.activity.id }.count, 1)
        XCTAssertEqual(model.attentionKind(for: orphan.activity), .approval)
        model.observeAttentionRequests([])
        XCTAssertFalse(model.visibleActivities.contains { $0.id == orphan.activity.id })
        XCTAssertNil(model.attentionKind(for: task))
    }
    func testHeaderFollowsLatestTaskAndIgnoresQuotaOrConnectionWarnings() {
        let model = IslandModel(demo: true)
        let badge = model.headerActivity(singleTask: .stage)
        XCTAssertEqual(badge.core, .count(2), "Several tasks show their count even when a single task would show its stage")
        XCTAssertEqual(badge.orbit.values.reduce(0, +), model.running.count)
        XCTAssertNil(badge.attention); XCTAssertNil(badge.ending)
        XCTAssertEqual(model.headerStatus, L10n.text("activity.task_count_compact", "2"))
        XCTAssertEqual(model.headerDisplayStatus, L10n.text("activity.thinking"), "Visible status describes the stage; the task badge owns the count")
        model.unavailableSSH = ["Synthetic"]
        model.errorMessage = "Synthetic quota failure"
        XCTAssertEqual(model.headerActivity(singleTask: .stage), badge, "Quota and connection warnings stay in their own components")
        XCTAssertFalse(CompactIslandComponent.isVisible(.lowQuotaWarning, model: model), "An invalid quota does not produce a live low-quota warning")
        model.setDemoStage(.tool)
        for (stage, key) in [(DemoTaskStage.thinking, "activity.thinking"), (.tool, "activity.tool_compact"), (.responding, "activity.responding_compact")] {
            model.setDemoStage(stage)
            XCTAssertEqual(model.headerStatus, L10n.text("activity.task_count_compact", "2"))
            model.activities = [model.activities[0]]
            XCTAssertEqual(model.headerStatus, L10n.text(key), "A single task shows its current stage")
            let symbol = [DemoTaskStage.thinking: StatusSymbols.thinking, .tool: StatusSymbols.tool, .responding: StatusSymbols.replying][stage]
            XCTAssertEqual(model.headerActivity(singleTask: .stage).core, symbol.map(HeaderActivity.Core.symbol))
            XCTAssertEqual(model.headerActivity(singleTask: .count).core, .count(1), "The count choice keeps a single task numeric")
            model.isAttached = true
            XCTAssertEqual(model.headerDisplayStatus, model.headerStatus)
        }
        model.activities = []
        XCTAssertEqual(model.headerActivity(), HeaderActivity(core: .idle, activeCount: 0, orbit: [:]))
        XCTAssertEqual(model.headerStatus, L10n.text("activity.idle"))
    }
}
