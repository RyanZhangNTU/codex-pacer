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
                         version: UInt64 = 1, active: Bool = true) -> Tracking.Decision {
        tracking.prepare(provider: .codex, references: rows, activities: rows, inbox: .init(), version: version,
            now: date.addingTimeInterval(seconds), active: active, demo: false)
    }
    private func appendLaunch(to activity: inout SessionActivity, at offset: TimeInterval) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        activity.consume(["type": "session_meta", "timestamp": formatter.string(from: date.addingTimeInterval(offset)),
            "payload": ["id": activity.threadID!, "originator": "fixture-embedding-client"]])
    }
    private enum Failure: Error { case expectedScan, expectedRetry }
    private func scan(_ decision: Tracking.Decision) throws -> Tracking.Scan {
        guard case .scan(let value) = decision else { throw Failure.expectedScan }; return value
    }
    private func retry(_ decision: Tracking.Decision) throws -> Tracking.Retry {
        guard case .retry(let value) = decision else { throw Failure.expectedRetry }; return value
    }
    private func isIdle(_ decision: Tracking.Decision) -> Bool { if case .idle = decision { return true }; return false }
    func testConfirmedHostsAndEndingsNeedNoRetryAndReleasedReferencesLeaveTheCache() throws {
        var tracking = Tracking()
        let running = row(1), ended = row(2, ended: true), vanishing = row(3)
        let first = try scan(prepare(&tracking, [running, ended, vanishing], at: 0))
        XCTAssertEqual(first.sessions, [running.threadID!, ended.threadID!, vanishing.threadID!])
        XCTAssertTrue(tracking.complete(first, found: [running.threadID!: "Editor", vanishing.threadID!: "Terminal"], version: 1, active: true).accepted)
        XCTAssertTrue(isIdle(prepare(&tracking, [running, ended, vanishing], at: 1)))
        XCTAssertTrue(isIdle(prepare(&tracking, [running, ended, vanishing], at: 60)))
        XCTAssertTrue(isIdle(prepare(&tracking, [row(1, ended: true), ended], at: 61)))
        XCTAssertEqual(tracking.applications[.codex], [running.threadID!: "Editor"])
    }
    func testNewSessionsDuringAScanGetOneThrottledRetry() throws {
        var tracking = Tracking(); let firstRow = row(1), nextRow = row(2)
        let first = try scan(prepare(&tracking, [firstRow], at: 0))
        XCTAssertTrue(isIdle(prepare(&tracking, [firstRow, nextRow], at: 0.5)))
        _ = tracking.complete(first, found: [:], version: 1, active: true)
        let pending = try retry(prepare(&tracking, [firstRow, nextRow], at: 0.5))
        XCTAssertEqual(pending.delay, 1.5); XCTAssertEqual(pending.deadline, date.addingTimeInterval(2))
        XCTAssertTrue(isIdle(prepare(&tracking, [firstRow, nextRow], at: 0.6)))
        XCTAssertTrue(tracking.finishRetry(pending, version: 1, active: true))
        let next = try scan(prepare(&tracking, [firstRow, nextRow], at: 2))
        XCTAssertEqual(next.sessions, [firstRow.threadID!, nextRow.threadID!])
    }
    func testSleepAndSourceCancellationRejectOldResultsWithoutClearingTheReplacementScan() throws {
        var tracking = Tracking(); let activity = row(1)
        let old = try scan(prepare(&tracking, [activity], at: 0))
        tracking.cancel()
        XCTAssertTrue(isIdle(prepare(&tracking, [activity], at: 1, version: 2, active: false)))
        let next = try scan(prepare(&tracking, [activity], at: 1, version: 2))
        let stale = tracking.complete(old, found: [activity.threadID!: "Old"], version: 2, active: true)
        XCTAssertFalse(stale.owned); XCTAssertFalse(stale.accepted)
        XCTAssertTrue(isIdle(prepare(&tracking, [activity], at: 4, version: 2)))
        XCTAssertTrue(tracking.complete(next, found: [activity.threadID!: "New"], version: 2, active: true).accepted)
        XCTAssertEqual(tracking.applications[.codex]?[activity.threadID!], "New")
        tracking.cancel()
        XCTAssertTrue(isIdle(prepare(&tracking, [activity], at: 30, version: 2)))
        tracking.cancel(clearApplications: true)
        XCTAssertEqual(tracking.applications[.codex], [:])
        XCTAssertEqual(try scan(prepare(&tracking, [activity], at: 31, version: 3)).sessions, [activity.threadID!])
    }
    func testMissingHostGetsTwoRetriesThenWaitsForNewEvidence() throws {
        var tracking = Tracking(); let activity = row(1)
        let first = try scan(prepare(&tracking, [activity], at: 0))
        _ = tracking.complete(first, found: [:], version: 1, active: true)
        let second = try retry(prepare(&tracking, [activity], at: 0.5))
        XCTAssertEqual(second.deadline, date.addingTimeInterval(2))
        XCTAssertTrue(isIdle(prepare(&tracking, [activity], at: 1)))
        XCTAssertTrue(tracking.finishRetry(second, version: 1, active: true))
        let secondScan = try scan(prepare(&tracking, [activity], at: 2))
        _ = tracking.complete(secondScan, found: [:], version: 1, active: true)
        let third = try retry(prepare(&tracking, [activity], at: 2.5))
        XCTAssertEqual(third.deadline, date.addingTimeInterval(10))
        XCTAssertTrue(tracking.finishRetry(third, version: 1, active: true))
        let thirdScan = try scan(prepare(&tracking, [activity], at: 10))
        _ = tracking.complete(thirdScan, found: [:], version: 1, active: true)
        XCTAssertTrue(isIdle(prepare(&tracking, [activity], at: 120)))
    }
    func testRetrySuccessStopsScanningAndEndingCancelsAMiss() throws {
        var tracking = Tracking()
        let running = row(1), ending = row(2)
        let initial = try scan(prepare(&tracking, [running, ending], at: 0))
        _ = tracking.complete(initial, found: [:], version: 1, active: true)
        let pending = try retry(prepare(&tracking, [running, ending], at: 0.5))
        XCTAssertTrue(tracking.finishRetry(pending, version: 1, active: true))
        let second = try scan(prepare(&tracking, [running, ending], at: 2))
        _ = tracking.complete(second, found: [running.threadID!: "Terminal"], version: 1, active: true)
        let last = try retry(prepare(&tracking, [running, ending], at: 3))
        guard case .cancelRetry = prepare(&tracking, [running, row(2, ended: true)], at: 4) else {
            return XCTFail("Finishing a task should cancel its retry")
        }
        XCTAssertFalse(tracking.finishRetry(last, version: 1, active: true))
        XCTAssertTrue(isIdle(prepare(&tracking, [running, row(2, ended: true)], at: 10)))
        XCTAssertEqual(tracking.applications[.codex]?[running.threadID!], "Terminal")
    }
    func testNewSessionAdvancesAPendingRetryWithoutTakingAnEarlyAttempt() throws {
        var tracking = Tracking()
        let original = row(1), new = row(2)
        let first = try scan(prepare(&tracking, [original], at: 0))
        _ = tracking.complete(first, found: [:], version: 1, active: true)
        let second = try scan(prepare(&tracking, [original], at: 2))
        _ = tracking.complete(second, found: [:], version: 1, active: true)
        let late = try retry(prepare(&tracking, [original], at: 2.5))
        let early = try retry(prepare(&tracking, [original, new], at: 3))
        XCTAssertEqual(early.deadline, date.addingTimeInterval(4))
        XCTAssertFalse(tracking.finishRetry(late, version: 1, active: true))
        XCTAssertTrue(tracking.finishRetry(early, version: 1, active: true))
        XCTAssertEqual(try scan(prepare(&tracking, [original, new], at: 4)).sessions, [new.threadID!])
    }
    func testNewLaunchRejectsAnInFlightResultAndIgnoresOlderOrRepeatedRecords() throws {
        var tracking = Tracking()
        var original = row(1)
        appendLaunch(to: &original, at: -1)
        let first = try scan(prepare(&tracking, [original], at: 0))
        var reopened = original
        appendLaunch(to: &reopened, at: 0.5)
        XCTAssertTrue(isIdle(prepare(&tracking, [reopened], at: 0.5)))
        XCTAssertFalse(tracking.complete(first, found: [original.threadID!: "Old"], version: 1, active: true).changed)
        let next = try scan(prepare(&tracking, [reopened], at: 2))
        XCTAssertTrue(tracking.complete(next, found: [reopened.threadID!: "New"], version: 1, active: true).changed)
        XCTAssertTrue(isIdle(prepare(&tracking, [original], at: 3)))
        XCTAssertTrue(isIdle(prepare(&tracking, [reopened], at: 4)))
        XCTAssertEqual(tracking.applications[.codex]?[reopened.threadID!], "New")
    }
    func testConfirmedHostIsRecheckedOnlyAfterNewLaunchEvidence() throws {
        var tracking = Tracking()
        var activity = row(1)
        let first = try scan(prepare(&tracking, [activity], at: 0))
        _ = tracking.complete(first, found: [activity.threadID!: "Editor"], version: 1, active: true)
        activity.noteHostLaunch(at: date.addingTimeInterval(-5))
        XCTAssertTrue(isIdle(prepare(&tracking, [activity], at: 3)), "Historical metadata can arrive after the first scan")
        activity.noteHostLaunch(at: date.addingTimeInterval(4))
        let reopened = try scan(prepare(&tracking, [activity], at: 5))
        _ = tracking.complete(reopened, found: [activity.threadID!: "Terminal"], version: 1, active: true)
        XCTAssertTrue(isIdle(prepare(&tracking, [activity], at: 10)))
        XCTAssertEqual(tracking.applications[.codex]?[activity.threadID!], "Terminal")
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
