import XCTest
@testable import PacerCore

final class DurableActivityStateTests: XCTestCase {
    private let thread = "019a0000-0000-7000-8000-000000000031", other = "019a0000-0000-7000-8000-000000000032"
    private let start = Date().addingTimeInterval(-120)

    private func turn(_ id: String, _ status: DurableTurnHistory.Status, thread: String? = nil, started: Double = 0,
                      completed: Double? = nil, percent: Int? = nil, report: String = "r1") -> DurableTurnHistory {
        DurableTurnHistory(threadID: thread ?? self.thread, name: "Synthetic Dot task", turnID: id, rootTurnID: nil, status: status,
            startedAt: start.addingTimeInterval(started), completedAt: completed.map { start.addingTimeInterval($0) },
            report: percent.map { .init(id: report, percent: $0, at: start.addingTimeInterval(started + 5)) })
    }

    func testTheCatalogAndLatestTurnsAloneMakeDotTasks() {
        var state = DurableActivityState()
        state.observe([turn("t1", .inProgress)], scope: "a", at: start.addingTimeInterval(10))
        XCTAssertTrue(state.activities.isEmpty, "Nothing shows before the catalog says which threads run here")
        state.setCatalog(DurableActivityCatalog(scope: "a", threadIDs: [thread]))
        state.observe([turn("t1", .inProgress, percent: 40), turn("t9", .inProgress, thread: other)], scope: "a", at: start.addingTimeInterval(10))
        XCTAssertEqual(state.activities.count, 1, "A thread outside the catalog is not this computer's")
        let running = state.activities.first
        XCTAssertEqual(running?.phase, .running); XCTAssertEqual(running?.sourceHostID, DurableActivityCatalog.hostID)
        XCTAssertEqual(running?.currentProgress?.percent, 40)
        XCTAssertEqual(state.scope, "a")

        state.observe([turn("t1", .completed, completed: 30, percent: 100, report: "r2")], scope: "a", at: start.addingTimeInterval(40))
        XCTAssertEqual(state.activities.first?.phase, .completed)
        state.observe([turn("t1", .completed, completed: 30, percent: 100, report: "r2")], scope: "a", at: start.addingTimeInterval(50))
        XCTAssertEqual(state.activities.first?.phase, .completed, "An ended turn is not replayed")
        state.observe([turn("t0", .inProgress, started: -60)], scope: "a", at: start.addingTimeInterval(55))
        XCTAssertEqual(state.activities.first?.turnID, "t1", "An older turn cannot replace a newer one")
        state.observe([turn("t2", .inProgress, thread: thread, started: 60)], scope: "other", at: start.addingTimeInterval(60))
        XCTAssertEqual(state.activities.first?.turnID, "t1", "Another account's turns are ignored")
    }

    func testAnotherAccountStartsOverAndAThreadThatLeavesTheCatalogLeavesTheList() {
        var state = DurableActivityState()
        state.setCatalog(DurableActivityCatalog(scope: "a", threadIDs: [thread, other]))
        state.observe([turn("t1", .inProgress), turn("t2", .inProgress, thread: other)], scope: "a", at: start.addingTimeInterval(10))
        XCTAssertEqual(state.activities.count, 2)
        state.setCatalog(DurableActivityCatalog(scope: "a", threadIDs: [thread]))
        XCTAssertEqual(state.activities.map(\.threadID), [thread])
        state.setCatalog(DurableActivityCatalog(scope: "b", threadIDs: [thread]))
        XCTAssertTrue(state.activities.isEmpty, "A new account starts with no tasks")
        state.setCatalog(nil)
        XCTAssertNil(state.scope)
    }
}
