import XCTest
@testable import PacerCore

final class DemoScenarioTests: XCTestCase {
    func testSubagentRatesSurviveEpochRoundingAtLaunch() throws {
        let base = 815_800_000.0
        let boundary = Date(timeIntervalSinceReferenceDate: base.nextUp.nextUp.nextUp)
        XCTAssertGreaterThan(Date(timeIntervalSince1970: boundary.timeIntervalSince1970), boundary,
            "The fixture must exercise an epoch round-trip that rounds into the future")
        for stage in DemoTaskStage.allCases {
            var reference = base
            for _ in 0..<128 {
                let now = Date(timeIntervalSinceReferenceDate: reference)
                reference = reference.nextUp
                let tasks = DemoScenario.subagentTasks(stage: stage, at: now)
                XCTAssertEqual(tasks.count, 4)
                let group = try XCTUnwrap(ActivityTaskGroup.make(tasks).first)
                var total = 0.0
                for task in tasks {
                    let rate = try XCTUnwrap(task.displayedOutputEstimate(at: now), "stage \(stage), clock \(reference)")
                    XCTAssertGreaterThan(rate.value, 0)
                    XCTAssertLessThanOrEqual(rate.reportedAt, now)
                    XCTAssertTrue(rate.isFresh)
                    total += rate.value
                }
                XCTAssertEqual(try XCTUnwrap(group.displayedRate(at: now)).value, total, accuracy: 0.0001)
                XCTAssertEqual(group.runningSubagentCount, stage == .completed ? 0 : 3)
                let overview = ActivityOverview(activities: tasks, at: now)
                if stage == .completed {
                    XCTAssertNil(overview.displayedRate, "Completion cards retain TPS without contributing to the running total")
                } else {
                    XCTAssertEqual(try XCTUnwrap(overview.displayedRate), total, accuracy: 0.0001)
                }
            }
        }
    }
}
