import Foundation
import XCTest
@testable import PacerCore

final class HostApplicationTrackingStateTests: XCTestCase {
    private typealias Tracking = HostApplicationTrackingState<String>
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private func row(_ n: Int, ended: Bool = false) -> SessionActivity {
        let id = String(format: "019a0000-0000-7000-8000-%012d", n)
        var value = SessionActivity(id: AgentProvider.codex.activityID(sessionID: id), sessionID: id)
        value.setCodexOrigin(.init(embedded: true, ignored: false))
        let formatter = ISO8601DateFormatter()
        value.consume(["type": "event_msg", "timestamp": formatter.string(from: date), "payload": ["type": "task_started", "turn_id": "turn"]])
        if ended { value.consume(["type": "event_msg", "timestamp": formatter.string(from: date.addingTimeInterval(1)), "payload": ["type": "task_complete", "turn_id": "turn"]]) }
        return value
    }
    private func prepare(_ tracking: inout Tracking, _ rows: [SessionActivity], at seconds: Double,
                         version: UInt64 = 1, active: Bool = true, refreshRunning: Bool = true) -> Tracking.Decision {
        tracking.prepare(provider: .codex, references: rows, activities: rows, inbox: .init(), version: version,
            now: date.addingTimeInterval(seconds), active: active, demo: false, refreshRunning: refreshRunning)
    }
    private enum Failure: Error { case expectedScan, expectedRetry }
    private func scan(_ decision: Tracking.Decision) throws -> Tracking.Scan {
        guard case .scan(let value) = decision else { throw Failure.expectedScan }; return value
    }
    private func retry(_ decision: Tracking.Decision) throws -> Tracking.Retry {
        guard case .retry(let value) = decision else { throw Failure.expectedRetry }; return value
    }
    private func isIdle(_ decision: Tracking.Decision) -> Bool { if case .idle = decision { return true }; return false }
    func testRunningSessionsRescanWhileEndingsAreAttemptedOnceAndReleasedReferencesLeaveTheCache() throws {
        var tracking = Tracking()
        let running = row(1), ended = row(2, ended: true), vanishing = row(3)
        let first = try scan(prepare(&tracking, [running, ended, vanishing], at: 0))
        XCTAssertEqual(first.sessions, [running.threadID!, ended.threadID!, vanishing.threadID!])
        XCTAssertTrue(tracking.complete(first, found: [running.threadID!: "Editor", vanishing.threadID!: "Terminal"], version: 1, active: true).accepted)
        XCTAssertTrue(isIdle(prepare(&tracking, [running, ended, vanishing], at: 1)))
        let next = try scan(prepare(&tracking, [running, ended, vanishing], at: 3))
        XCTAssertEqual(next.sessions, [running.threadID!, vanishing.threadID!])
        _ = tracking.complete(next, found: [:], version: 1, active: true)
        XCTAssertTrue(isIdle(prepare(&tracking, [row(1, ended: true), ended], at: 3.1)))
        XCTAssertEqual(tracking.applications[.codex], [running.threadID!: "Editor"])
    }
    func testNewSessionsDuringAScanGetOneThrottledRetry() throws {
        var tracking = Tracking(); let firstRow = row(1), nextRow = row(2)
        let first = try scan(prepare(&tracking, [firstRow], at: 0))
        XCTAssertTrue(isIdle(prepare(&tracking, [firstRow, nextRow], at: 0.5)))
        _ = tracking.complete(first, found: [:], version: 1, active: true)
        let pending = try retry(prepare(&tracking, [firstRow, nextRow], at: 0.5, refreshRunning: false))
        XCTAssertEqual(pending.delay, 1.5); XCTAssertEqual(pending.deadline, date.addingTimeInterval(2))
        XCTAssertTrue(isIdle(prepare(&tracking, [firstRow, nextRow], at: 0.6)))
        XCTAssertTrue(tracking.finishRetry(pending, version: 1, active: true))
        let next = try scan(prepare(&tracking, [firstRow, nextRow], at: 2))
        XCTAssertEqual(next.sessions, [firstRow.threadID!, nextRow.threadID!])
    }
    func testSleepAndSourceCancellationRejectOldResultsWithoutClearingTheReplacementScan() throws {
        var tracking = Tracking(); let activity = row(1)
        tracking.record([activity.threadID!: "Retained"], provider: .codex)
        let old = try scan(prepare(&tracking, [activity], at: 0))
        tracking.cancel()
        XCTAssertTrue(isIdle(prepare(&tracking, [activity], at: 1, version: 2, active: false)))
        let next = try scan(prepare(&tracking, [activity], at: 1, version: 2))
        let stale = tracking.complete(old, found: [activity.threadID!: "Old"], version: 2, active: true)
        XCTAssertFalse(stale.owned); XCTAssertFalse(stale.accepted)
        XCTAssertTrue(isIdle(prepare(&tracking, [activity], at: 4, version: 2)))
        XCTAssertTrue(tracking.complete(next, found: [activity.threadID!: "New"], version: 2, active: true).accepted)
        XCTAssertEqual(tracking.applications[.codex]?[activity.threadID!], "New")
        tracking.cancel(clearApplications: true)
        XCTAssertEqual(tracking.applications[.codex], [:])
    }
    func testASlowScanDoesNotStartItselfAgainWithoutAnotherObservation() throws {
        var tracking = Tracking(); let activity = row(1)
        let first = try scan(prepare(&tracking, [activity], at: 0))
        _ = tracking.complete(first, found: [:], version: 1, active: true)
        XCTAssertTrue(isIdle(prepare(&tracking, [activity], at: 5, refreshRunning: false)))
        XCTAssertEqual(try scan(prepare(&tracking, [activity], at: 5)).sessions, [activity.threadID!])
    }
    func testLabelsUseTheProvenParentAndKeepOpaqueApplicationsUntilReferencesEnd() {
        var tracking = Tracking(); let parent = row(1); var child = row(2)
        child.updateParent(parent.threadID)
        tracking.record([parent.threadID!.uppercased(): "Editor"], provider: .codex)
        XCTAssertEqual(tracking.application(for: child, activities: [parent, child], inbox: .init()), "Editor")
        let labels = tracking.labels(for: [child], activities: [parent, child], inbox: .init()) { .init(name: $0, isClaudeDesktop: false) }
        XCTAssertEqual(labels[child.id]?.name, "Editor")
        tracking.cancel()
        XCTAssertEqual(tracking.application(for: child, activities: [parent, child], inbox: .init()), "Editor")
        _ = prepare(&tracking, [], at: 5, active: false)
        XCTAssertEqual(tracking.applications[.codex], [:])
    }
}
