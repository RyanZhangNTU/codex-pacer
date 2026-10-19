import XCTest
import PacerCore
@testable import PacerIsland

@MainActor
final class ActivityOpeningTests: XCTestCase {
    private final class Clock { var now = Date(timeIntervalSince1970: 1_800_000_000) }
    private func completion() throws -> (IslandModel, SessionActivity, Clock) {
        let clock = Clock()
        let model = IslandModel(demo: true, demoClock: { clock.now })
        model.setDemoStage(.completed)
        let activity = try XCTUnwrap(model.activities.first { $0.phase == .completed })
        XCTAssertTrue(model.isUnreadCompletion(activity))
        return (model, activity, clock)
    }

    func testVisibilitySwitchesAutomaticCadenceAndKeepsCompletionCards() throws {
        let (model, _, _) = try completion()
        let before = model.activities
        model.close()
        XCTAssertEqual(model.activityRefreshPolicy.interval, 5)
        model.hover(true)
        XCTAssertEqual(model.activityRefreshPolicy.interval, 1)
        model.togglePin(); model.close()
        XCTAssertEqual(model.activityRefreshPolicy.interval, 5)
        model.setInteractionSuspended(true); model.hover(true)
        XCTAssertEqual(model.activityRefreshPolicy.interval, 5)
        model.setInteractionSuspended(false); model.setExpanded(true)
        XCTAssertEqual(model.activityRefreshPolicy.interval, 1)
        XCTAssertEqual(model.activities, before)
    }

    func testSubagentRowsAndTotalsRemainWhenAnotherTaskStartsOrToolsRun() throws {
        let clock = Clock(), model = IslandModel(demo: true, demoClock: { clock.now })
        let formatter = ISO8601DateFormatter()
        func task(_ n: Int, parent: Int? = nil, tokens: Int = 600) throws -> SessionActivity {
            func id(_ value: Int) -> String { String(format: "019a0000-0000-7000-8000-%012d", value) }
            var value = SessionActivity(id: id(n), phaseAwareRate: true)
            var meta: [String: Any] = ["id": id(n)]
            if let parent { meta["parent_thread_id"] = id(parent) }
            value.consume(try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": meta]))
            for (type, ago, payload) in [("event_msg", -10.0, ["type": "task_started", "turn_id": "turn"]),
                ("response_item", 0.0, ["type": "message", "role": "assistant"]),
                ("token_usage_record", 0.0, ["thread_id": id(n), "turn_id": "turn", "response_id": "response", "usage": ["output_tokens": tokens]])]
                as [(String, Double, [String: Any])] {
                value.consume(try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": formatter.string(from: clock.now.addingTimeInterval(ago)), "payload": payload]))
            }
            return value
        }
        var parent = try task(1), child = try task(2, parent: 1, tokens: 300)
        let otherChild = try task(3, parent: 1, tokens: 200)
        func log(_ a: inout SessionActivity, _ type: String, _ payload: [String: Any]) throws {
            a.consume(try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": formatter.string(from: clock.now), "payload": payload]))
        }
        clock.now = clock.now.addingTimeInterval(1)
        try log(&parent, "response_item", ["type": "function_call", "name": "wait", "call_id": "tool"])
        model.now = clock.now; model.activities = [parent, child, otherChild]
        XCTAssertEqual(model.visibleActivities.count, 1)
        XCTAssertEqual(model.taskGroup(for: parent)?.runningSubagentCount, 2)
        XCTAssertEqual(model.rate, 110)
        XCTAssertEqual(model.headerRateText, "110")
        XCTAssertTrue(model.rateIsFresh)
        clock.now = clock.now.addingTimeInterval(1)
        try log(&parent, "event_msg", ["type": "task_started", "turn_id": "new"])
        var new = SessionActivity(id: "019a0000-0000-7000-8000-000000000004", phaseAwareRate: true)
        try log(&new, "event_msg", ["type": "task_started", "turn_id": "another"])
        model.now = clock.now; model.activities = [parent, child, otherChild, new]
        XCTAssertEqual(model.visibleActivities.count, 2)
        XCTAssertEqual(model.taskGroup(for: parent)?.displayedRate(at: clock.now)?.value, 110)
        XCTAssertEqual(model.rate, 110)
        XCTAssertEqual(model.headerRateText, "110")
        XCTAssertTrue(model.rateIsFresh)
        model.now = clock.now.addingTimeInterval(15)
        XCTAssertEqual(model.headerRateText, "110")
        XCTAssertFalse(model.rateIsFresh)
        model.now = clock.now
        try log(&child, "event_msg", ["type": "task_complete", "turn_id": "turn"])
        model.activities = [parent, child, otherChild, new]
        XCTAssertEqual(model.visibleActivities.count, 2)
        XCTAssertEqual(model.taskGroup(for: parent)?.runningSubagentCount, 1)
        XCTAssertEqual(model.rate, 80)
    }

    func testFailedOpenPreservesCardAndUnreadReminder() async throws {
        let (model, activity, _) = try completion()
        let finished = expectation(description: "open attempted")
        model.onOpenActivity = { _ in finished.fulfill(); return .failed("Synthetic open failure") }
        model.open(activity)
        await fulfillment(of: [finished], timeout: 2)
        await Task.yield()
        XCTAssertTrue(model.activities.contains { $0.id == activity.id })
        XCTAssertTrue(model.isUnreadCompletion(activity))
        XCTAssertEqual(model.navigationError, "Synthetic open failure")
    }

    func testQueuedOpenDoesNotLaunchAfterShutdown() async throws {
        let (model, activity, _) = try completion()
        var launches = 0
        model.onOpenActivity = { _ in launches += 1; return .openedConversation }
        model.open(activity)
        await model.shutdown()
        await Task.yield()
        XCTAssertEqual(launches, 0)
    }

    func testSuccessfulOpenDismissesOnlyRequestedCompletion() async throws {
        let (model, activity, _) = try completion()
        let finished = expectation(description: "open succeeded")
        model.onOpenActivity = { _ in finished.fulfill(); return .openedConversation }
        model.open(activity)
        await fulfillment(of: [finished], timeout: 2)
        await Task.yield()
        XCTAssertFalse(model.activities.contains { $0.id == activity.id })
        XCTAssertFalse(model.isUnreadCompletion(activity))
        XCTAssertTrue(model.activities.contains { $0.sourceHostID != nil })
        XCTAssertNil(model.navigationError)
    }

    func testLateOpenAcknowledgementCannotDismissNewerCompletion() async throws {
        let (model, old, clock) = try completion()
        let started = expectation(description: "opening")
        let finish = expectation(description: "finished")
        model.onOpenActivity = { _ in
            started.fulfill()
            try? await Task.sleep(nanoseconds: 40_000_000)
            finish.fulfill()
            return .openedConversation
        }
        model.open(old)
        await fulfillment(of: [started], timeout: 2)
        clock.now = clock.now.addingTimeInterval(31)
        model.setDemoStage(.thinking)
        model.setDemoStage(.completed)
        let latest = try XCTUnwrap(model.activities.first { $0.id == old.id })
        XCTAssertNotEqual(latest.phaseChangedAt, old.phaseChangedAt)
        await fulfillment(of: [finish], timeout: 2)
        await Task.yield()
        XCTAssertTrue(model.activities.contains { $0.id == latest.id && $0.phaseChangedAt == latest.phaseChangedAt })
        XCTAssertTrue(model.isUnreadCompletion(latest))
    }

    func testDuplicateClickDoesNotLaunchTwiceWhileOpening() async throws {
        let (model, activity, _) = try completion()
        let finish = expectation(description: "finished")
        var launches = 0
        model.onOpenActivity = { _ in
            launches += 1
            try? await Task.sleep(nanoseconds: 20_000_000)
            finish.fulfill(); return .openedConversation
        }
        model.open(activity); model.open(activity)
        await fulfillment(of: [finish], timeout: 2)
        XCTAssertEqual(launches, 1)
    }

    func testAppButtonsOfferEnabledModulesWithADesktopAppAndOpenOnlyThose() async throws {
        let domain = "com.codexpacer.app-button-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        func model(codex: ProviderModuleMode, demo: Bool = false) -> IslandModel {
            ProviderModules(codexMode: codex, claudeMode: .enabled).save(to: defaults)
            return IslandModel(demo: demo, defaults: defaults,
                installation: ProviderInstallationDetection(codexInstalled: false, claudeInstalled: false))
        }
        let codexApp = URL(fileURLWithPath: "/Applications/Synthetic Codex.app")
        let claudeApp = URL(fileURLWithPath: "/Applications/Synthetic Claude.app")

        // Only Codex has a desktop app; Claude is enabled but gets no button.
        let both = model(codex: .enabled)
        both.desktopApplicationResolver = { $0 == .codex ? codexApp : nil }
        let codexFound = expectation(description: "Codex app found")
        both.onLayoutChange = { codexFound.fulfill() }
        both.refreshDesktopApplications()
        await fulfillment(of: [codexFound], timeout: 2)
        both.onLayoutChange = nil
        XCTAssertEqual(both.appButtonProviders, [.codex])
        var opened: [(AgentProvider, URL)] = []
        let launched = expectation(description: "Codex opened")
        both.onOpenDesktopApplication = { provider, url in
            opened.append((provider, url)); launched.fulfill(); return .openedConversation
        }
        both.openDesktopApplication(.claude)
        both.openDesktopApplication(.codex)
        await fulfillment(of: [launched], timeout: 2)
        XCTAssertEqual(opened.map(\.0), [.codex]); XCTAssertEqual(opened.first?.1, codexApp)
        XCTAssertNil(both.navigationError)
        defaults.set(false, forKey: IslandModel.showsAppButtonsKey)
        XCTAssertEqual(both.appButtonProviders, [], "The setting hides every app button")
        both.openDesktopApplication(.codex)
        await Task.yield()
        XCTAssertEqual(opened.count, 1)
        defaults.removeObject(forKey: IslandModel.showsAppButtonsKey)

        // A disabled module is not looked up, even with its app installed.
        let claudeOnly = model(codex: .disabled)
        claudeOnly.desktopApplicationResolver = { $0 == .codex ? codexApp : claudeApp }
        let claudeFound = expectation(description: "Claude app found")
        claudeOnly.onLayoutChange = { claudeFound.fulfill() }
        claudeOnly.refreshDesktopApplications()
        await fulfillment(of: [claudeFound], timeout: 2)
        claudeOnly.onLayoutChange = nil
        XCTAssertEqual(claudeOnly.appButtonProviders, [.claude])
        XCTAssertNil(claudeOnly.desktopApplications[.codex])

        // Demo shows every enabled module without looking up real apps, and a
        // failed open explains itself like a failed task open.
        let demo = model(codex: .enabled, demo: true)
        demo.desktopApplicationResolver = { _ in XCTFail("Demo never resolves real apps"); return nil }
        demo.refreshDesktopApplications()
        XCTAssertEqual(demo.appButtonProviders, [.codex, .claude])
        let failed = expectation(description: "open attempted")
        demo.onOpenDesktopApplication = { _, _ in failed.fulfill(); return .failed("Synthetic open failure") }
        demo.openDesktopApplication(.claude)
        await fulfillment(of: [failed], timeout: 2)
        await Task.yield()
        XCTAssertEqual(demo.navigationError, "Synthetic open failure")
    }
}
