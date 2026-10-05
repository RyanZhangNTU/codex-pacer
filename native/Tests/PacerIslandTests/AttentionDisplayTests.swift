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
        model.observeAttentionRequests([request])
        XCTAssertEqual(model.activities, before)
        XCTAssertEqual(model.pendingInputRequests.count, 1)
        XCTAssertEqual(model.headerStatus, L10n.text("attention.input"))
        XCTAssertEqual(model.headerDisplayStatus, model.headerStatus)
        model.isAttached = true
        XCTAssertEqual(model.headerDisplayStatus, L10n.text("attention.input"), "Notch retains the actionable meaning")
        XCTAssertEqual(model.headerStatus, L10n.text("attention.input"), "Accessibility retains the full meaning")
        let opened = expectation(description: "pending request destination opened")
        model.onOpenActivity = { activity in
            XCTAssertEqual(activity.threadID, request.threadID)
            opened.fulfill(); return nil
        }
        model.openCompletionOrPin()
        await fulfillment(of: [opened], timeout: 2)
        await Task.yield()
        XCTAssertEqual(model.pendingInputRequests.count, 1, "Opening is not answering")
        model.observeAttentionRequests([])
        XCTAssertTrue(model.pendingInputRequests.isEmpty)
        XCTAssertEqual(model.activities, before)
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
    func testConnectionWarningDoesNotHideUnreadCompletion() {
        let old = UserDefaults.standard.object(forKey: "completionReminder")
        defer { if let old { UserDefaults.standard.set(old, forKey: "completionReminder") } else { UserDefaults.standard.removeObject(forKey: "completionReminder") } }
        UserDefaults.standard.set(true, forKey: "completionReminder")
        let model = IslandModel(demo: true)
        model.setDemoStage(.completed)
        model.unavailableSSH = ["Synthetic unavailable source"]
        XCTAssertTrue(model.hasConnectionIssue)
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
        XCTAssertEqual(model.headerSymbol, StatusSymbols.thinking, "The thinking fixture updates after the tool fixture")
        XCTAssertEqual(model.headerStatus, L10n.text("activity.task_count_compact", "2"))
        let tint = model.headerTint
        model.unavailableSSH = ["Synthetic"]
        model.errorMessage = "Synthetic quota failure"
        XCTAssertEqual(model.headerSymbol, StatusSymbols.thinking)
        XCTAssertEqual(model.headerTint, tint)
        XCTAssertNil(model.quotaWarningSymbol, "An invalid quota does not produce a live low-quota warning")
        model.setDemoStage(.tool)
        XCTAssertEqual(model.headerSymbol, StatusSymbols.tool)
        for (stage, key) in [(DemoTaskStage.thinking, "activity.thinking"), (.tool, "activity.tool_compact"), (.responding, "activity.responding_compact")] {
            model.setDemoStage(stage)
            XCTAssertEqual(model.headerStatus, L10n.text("activity.task_count_compact", "2"))
            model.activities = [model.activities[0]]
            XCTAssertEqual(model.headerStatus, L10n.text(key), "A single task shows its current stage")
            model.isAttached = true
            XCTAssertEqual(model.headerDisplayStatus, model.headerStatus)
        }
        model.activities = []
        XCTAssertEqual(model.headerSymbol, StatusSymbols.idle)
        XCTAssertEqual(model.headerStatus, L10n.text("activity.idle"))
    }
}
