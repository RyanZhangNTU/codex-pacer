import Foundation
import XCTest
@testable import PacerCore

final class HarnessActivityStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private final class DummyWatch: ActivityFileWatch { func stop() {} }
    private struct DummyFileEvents: ActivityFileEvents {
        func watch(_ url: URL, isDirectory: Bool, changed: @escaping @Sendable (ActivityFileEvent) -> Void) -> (any ActivityFileWatch)? { DummyWatch() }
    }

    func testWatchBudgetLeavesSlotsForOtherProvidersAndReleasesOnce() throws {
        let url = FileManager.default.temporaryDirectory
        let budget = HarnessWatchBudget(maximum: 4, perProvider: 2)
        let a = HarnessWatchBudget.Events(provider: .codex, underlying: DummyFileEvents(), budget: budget)
        let b = HarnessWatchBudget.Events(provider: .claude, underlying: DummyFileEvents(), budget: budget)
        let c = HarnessWatchBudget.Events(provider: .deepseek, underlying: DummyFileEvents(), budget: budget)
        let first = try XCTUnwrap(a.watch(url, isDirectory: true) { _ in })
        let second = try XCTUnwrap(a.watch(url, isDirectory: true) { _ in })
        XCTAssertNil(a.watch(url, isDirectory: true) { _ in })
        let other = try XCTUnwrap(b.watch(url, isDirectory: true) { _ in })
        let third = try XCTUnwrap(c.watch(url, isDirectory: true) { _ in })
        XCTAssertNil(c.watch(url, isDirectory: true) { _ in })
        first.stop(); first.stop()
        let restored = try XCTUnwrap(c.watch(url, isDirectory: true) { _ in })
        XCTAssertNil(a.watch(url, isDirectory: true) { _ in })
        withExtendedLifetime([second, other, third, restored]) {
            first.stop(); first.stop()
        }
    }

    func testHundredProvidersDoNotShareRowsOrLoseStateOnAGap() {
        var store = HarnessActivityStore()
        let providers = (0..<100).map { AgentProvider(registeredID: "fixture-\($0)") }
        for provider in providers {
            store.bind(provider, generation: 1)
            let source = HarnessSourceKey(provider: provider, stream: "local", scope: "fixture")
            let row = SessionActivity.observedSession(provider: provider, session: "shared-native-id", stage: .working, at: now)
            let batch = HarnessActivityBatch(source: source, generation: 1, sequence: 1,
                                             change: .baseline(.init(activities: [row], status: .ready)))
            XCTAssertEqual(store.accept(batch), .accepted)
        }
        XCTAssertEqual(store.snapshots().count, 100)
        XCTAssertEqual(Set(store.snapshots().values.flatMap(\.activities).map(\.id)).count, 100)
        let target = providers[63]
        let source = HarnessSourceKey(provider: target, stream: "local", scope: "fixture")
        let removed = Set(store.projection(for: target)!.activities.map(\.id))
        XCTAssertEqual(store.accept(.init(source: source, generation: 1, sequence: 3,
            change: .delta(.init(removedActivityIDs: removed)))), .needsSnapshot)
        XCTAssertEqual(store.accept(.init(source: source, generation: 1, sequence: 2,
            change: .health(.unavailable))), .needsSnapshot)
        XCTAssertEqual(store.projection(for: target)?.activities.count, 1)
        XCTAssertEqual(store.accept(.init(source: source, generation: 1, sequence: 4,
            change: .snapshot(.init(status: .ready)))), .accepted)
        XCTAssertEqual(store.projection(for: target)?.activities.count, 0)
        XCTAssertEqual(store.snapshots().values.filter { $0.activities.count == 1 }.count, 99)
        store.bind(target, generation: 2)
        XCTAssertEqual(store.accept(.init(source: source, generation: 1, sequence: 5,
            change: .baseline(.init()))), .stale)
    }

    func testBaselineDoesNotAlertAndRetirementClearsOnlyItsSource() {
        var store = HarnessActivityStore()
        let id = WorkBuddyHarness.id
        let first = HarnessSourceKey(provider: id, stream: "local", scope: "first")
        let second = HarnessSourceKey(provider: id, stream: "local", scope: "second")
        let question = PendingAttentionRequest(id: "question", threadID: "task", sourceHostID: nil,
            sourceName: "WorkBuddy", kind: .input, detectedAt: now, provider: id)
        store.bind(id, generation: 7)
        XCTAssertEqual(store.accept(.init(source: first, generation: 7, sequence: 1,
            change: .baseline(.init(requests: [question])))), .accepted)
        XCTAssertEqual(store.accept(.init(source: second, generation: 7, sequence: 1,
            change: .baseline(.init(status: .ready)))), .accepted)
        XCTAssertTrue(store.projection(for: id)?.requests.first?.suppressesNotice == true)
        store.retire(first)
        XCTAssertEqual(store.projection(for: id)?.requests.count, 0)
        XCTAssertEqual(store.projection(for: id)?.status, .ready)
        XCTAssertEqual(store.accept(.init(source: first, generation: 7, sequence: 1,
            change: .baseline(.init(requests: [question])))), .stale)
        XCTAssertEqual(store.projection(for: id)?.requests.count, 0)
    }

    func testHealthChangesRetainUsageAndScopeChangeClearsIt() throws {
        let id = WorkBuddyHarness.id
        var projections = HarnessActivitySources()
        projections.bind(id, home: FileManager.default.temporaryDirectory, generation: 4)
        var data = HarnessActivity(status: .ready)
        data.scope = "owner-a"
        data.usage = .init(contextUsed: 10, contextCapacity: 100, sessionCredits: 1.5, measuredAt: now)
        let baseline = try XCTUnwrap(projections.receive(id, snapshot: data))
        XCTAssertFalse(baseline.scopeChanged)
        XCTAssertTrue(baseline.needsSourceBinding)
        data.status = .unavailable
        let refresh = try XCTUnwrap(projections.receive(id, snapshot: data))
        XCTAssertEqual(refresh.activity.usage?.sessionCredits, 1.5)
        XCTAssertFalse(refresh.needsSourceBinding)
        var next = HarnessActivity(status: .ready)
        next.scope = "owner-b"
        let update = try XCTUnwrap(projections.receive(id, snapshot: next))
        XCTAssertTrue(update.scopeChanged)
        XCTAssertTrue(update.needsSourceBinding)
        XCTAssertNil(update.activity.usage)
        XCTAssertEqual(update.activity.scope, "owner-b")
    }
}
