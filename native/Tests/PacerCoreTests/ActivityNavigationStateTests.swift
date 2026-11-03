import Foundation
import XCTest
@testable import PacerCore

final class ActivityNavigationStateTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private var home: URL { FileManager.default.temporaryDirectory.appendingPathComponent("pacer-navigation-state") }
    private func row(_ n: Int = 1, turn: String = "turn", offset: TimeInterval = 0, ended: Bool = true, parent: Int? = nil) -> SessionActivity {
        func session(_ n: Int) -> String { String(format: "019a0000-0000-7000-8000-%012d", n) }
        var value = SessionActivity(id: AgentProvider.codex.activityID(sessionID: session(n)), provider: .codex, sessionID: session(n))
        value.setCodexOrigin(.init(embedded: true, ignored: false))
        if let parent { value.updateParent(session(parent)) }
        let formatter = ISO8601DateFormatter()
        value.consume(["type": "event_msg", "timestamp": formatter.string(from: date.addingTimeInterval(offset)),
            "payload": ["type": "task_started", "turn_id": turn]])
        if ended {
            value.consume(["type": "event_msg", "timestamp": formatter.string(from: date.addingTimeInterval(offset + 1)),
                "payload": ["type": "task_complete", "turn_id": turn]])
        }
        return value
    }
    private func inbox(_ rows: [SessionActivity]) -> CompletionInbox {
        var value = CompletionInbox(); value.bindSourceHomes(provider: .codex, localHome: home)
        let running = rows.map { activity in
            row(Int(activity.threadID!.suffix(12))!, turn: activity.turnID!, offset: activity.turnStartedAt!.timeIntervalSince(date),
                ended: false, parent: activity.parentThreadID.flatMap { Int($0.suffix(12)) })
        }
        value.observe(running, at: date, retention: 1800)
        value.observe(rows, at: date.addingTimeInterval(2), retention: 1800)
        return value
    }
    func testFailureAndTerminalDispatchKeepTheCapturedEndingUnread() throws {
        for outcome in [ActivityOpenOutcome.failed("Synthetic failure"), .dispatchedTerminal] {
            let activity = row(); var rows = [activity], inbox = self.inbox(rows), state = ActivityNavigationState()
            let operation = try XCTUnwrap(state.begin(activity: activity, target: activity, version: 1, activities: rows, inbox: inbox, active: true))
            XCTAssertNil(state.begin(activity: activity, target: activity, version: 1, activities: rows, inbox: inbox, active: true))
            let result = state.complete(operation, outcome: outcome, version: 1, active: true, activities: &rows, inbox: &inbox, now: 100)
            XCTAssertTrue(result?.accepted == true)
            XCTAssertTrue(inbox.isUnread(activity)); XCTAssertEqual(rows, [activity])
            XCTAssertTrue(state.openingActivityIDs.isEmpty)
            XCTAssertEqual(state.failure?.message, outcome == .dispatchedTerminal ? nil : "Synthetic failure")
        }
    }
    func testSuccessfulOpenAcknowledgesOnlyTheCapturedFamily() throws {
        let parent = row(), child = row(2, parent: 1), other = row(3)
        var rows = [parent, child, other], inbox = self.inbox(rows), state = ActivityNavigationState()
        let operation = try XCTUnwrap(state.begin(activity: parent, target: parent, version: 1, activities: rows, inbox: inbox, active: true))
        XCTAssertEqual(operation.descendants.map(\.activity.id), [child.id])
        let result = state.complete(operation, outcome: .openedConversation, version: 1, active: true, activities: &rows, inbox: &inbox, now: 100)
        XCTAssertTrue(result?.accepted == true)
        XCTAssertEqual(Set(result?.removed.map(\.id) ?? []), [parent.id, child.id])
        XCTAssertFalse(inbox.isUnread(parent)); XCTAssertFalse(inbox.isUnread(child)); XCTAssertTrue(inbox.isUnread(other))
        XCTAssertEqual(rows, [other])
    }
    func testNewEndingAndChangedReaderScopeRejectAnOldAcknowledgment() throws {
        let first = row(); var rows = [first], inbox = self.inbox(rows), state = ActivityNavigationState()
        let operation = try XCTUnwrap(state.begin(activity: first, target: first, version: 1, activities: rows, inbox: inbox, active: true))
        let second = row(turn: "next", offset: 3)
        inbox.observe([row(turn: "next", offset: 3, ended: false)], at: date.addingTimeInterval(3), retention: 1800)
        inbox.observe([second], at: date.addingTimeInterval(5), retention: 1800); rows = [second]
        let result = state.complete(operation, outcome: .openedConversation, version: 1, active: true, activities: &rows, inbox: &inbox, now: 100)
        XCTAssertTrue(result?.removed.isEmpty == true); XCTAssertTrue(inbox.isUnread(second)); XCTAssertEqual(rows, [second])
        let next = try XCTUnwrap(state.begin(activity: second, target: second, version: 1, activities: rows, inbox: inbox, active: true))
        inbox.bindSourceHomes(provider: .codex, localHome: home.appendingPathComponent("other"))
        let stale = state.complete(next, outcome: .failed("Old source"), version: 1, active: true, activities: &rows, inbox: &inbox, now: 101)
        XCTAssertFalse(stale?.accepted == true); XCTAssertNil(state.failure)
    }
    func testChangedIntermediateAncestorKeepsTheGrandchildUnread() throws {
        let parent = row(), child = row(2, parent: 1), grandchild = row(3, parent: 2)
        var rows = [parent, child, grandchild], inbox = self.inbox(rows), state = ActivityNavigationState()
        let operation = try XCTUnwrap(state.begin(activity: parent, target: parent, version: 1, activities: rows, inbox: inbox, active: true))
        XCTAssertEqual(operation.descendants.count, 2)
        let nextChild = row(2, turn: "next", offset: 3, ended: false, parent: 1)
        rows = [parent, nextChild, grandchild]
        inbox.observe(rows, at: date.addingTimeInterval(3), retention: 1800)
        let result = state.complete(operation, outcome: .openedConversation, version: 1, active: true, activities: &rows, inbox: &inbox, now: 100)
        XCTAssertEqual(result?.removed.map(\.id), [parent.id])
        XCTAssertTrue(inbox.isUnread(grandchild)); XCTAssertTrue(rows.contains(nextChild)); XCTAssertTrue(rows.contains(grandchild))
    }
    func testAChildWhoseParentRouteChangedCannotAcknowledge() throws {
        let parent = row(), child = row(2, parent: 1)
        var rows = [parent, child], inbox = self.inbox(rows), state = ActivityNavigationState()
        let operation = try XCTUnwrap(state.begin(activity: child, target: parent, version: 1, activities: rows, inbox: inbox, active: true))
        var redirected = child; redirected.updateParent(row(3).threadID); rows = [parent, redirected]
        let result = state.complete(operation, outcome: .openedConversation, version: 1, active: true, activities: &rows, inbox: &inbox, now: 100)
        XCTAssertFalse(result?.accepted == true); XCTAssertTrue(inbox.isUnread(child))
    }
    func testOldCompletionCannotReleaseTheReplacementFlight() throws {
        let activity = row(); let rows = [activity], inbox = self.inbox(rows)
        var state = ActivityNavigationState()
        let old = try XCTUnwrap(state.begin(activity: activity, target: activity, version: 1, activities: rows, inbox: inbox, active: true))
        state.cancel(provider: .codex)
        let next = try XCTUnwrap(state.begin(activity: activity, target: activity, version: 2, activities: rows, inbox: inbox, active: true))
        state.abandon(old)
        XCTAssertTrue(state.owns(next)); XCTAssertFalse(state.owns(old)); XCTAssertEqual(state.openingActivityIDs, [activity.id])
        XCTAssertNil(state.begin(activity: row(3), target: row(3), version: 2, activities: rows, inbox: inbox, active: false))
    }
    func testFailureLifetimeAndReplacementUseThePublishedDeadline() {
        var state = ActivityNavigationState()
        let first = state.showFailure("First", now: 100)
        XCTAssertEqual(first.deadline, 130); XCTAssertFalse(state.expireFailure(first.id, now: 129.999))
        let second = state.showFailure("Second", now: 110)
        XCTAssertFalse(state.expireFailure(first.id, now: 200)); XCTAssertEqual(state.failure, second)
        XCTAssertFalse(state.expireFailure(second.id, now: 139.999))
        XCTAssertTrue(state.expireFailure(second.id, now: 140)); XCTAssertNil(state.failure)
    }
}
