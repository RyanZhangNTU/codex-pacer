import Foundation
import XCTest
@testable import PacerCore

private actor ResumableCloudFixture: ClaudeCloudConnection {
    private(set) var scopeChecks = [Bool]()
    private(set) var updates: [ClaudeCloudProjectMonitor.Update] = []
    private var input: ClaudeCloudServices.Input?
    private(set) var suspensions = 0
    private(set) var stopped = false

    func bind(_ input: ClaudeCloudServices.Input) -> Self { self.input = input; return self }
    func start(expanded: Bool, update: @escaping ClaudeCloudProjectMonitor.Update) async {
        guard let input, !stopped else { return }
        scopeChecks.append(await input.observedScope("synthetic-account"))
        updates.append(update)
    }
    func setExpanded(_ value: Bool) {}
    func refresh() {}
    func suspend() { suspensions += 1 }
    func shutdown() { stopped = true }
    func emit(_ activities: [SessionActivity], index: Int) async {
        guard updates.indices.contains(index) else { return }
        await updates[index](activities, nil, [])
    }
}

final class ClaudeCloudCoordinatorTests: XCTestCase {
    func testWakeKeepsAccountBindingAndRejectsDataFromTheOldPoll() async {
        let client = ResumableCloudFixture()
        let coordinator = ClaudeCloudCoordinator(services: .init { input in await client.bind(input) }, output: { _ in })
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-cloud-fixture")
        await coordinator.configure(home: home, organization: "", enabled: true, webAvailable: true, context: 1)
        await coordinator.startAfterPublication()
        await coordinator.waitUntilStarted()
        let activities = DemoScenario.claudeCloud(stage: .tool, at: Date()).activities
        await client.emit(activities, index: 0)
        let before = await coordinator.currentState()
        XCTAssertFalse(before.activities.isEmpty)

        await coordinator.suspend()
        await coordinator.resume(context: 2)
        await coordinator.waitUntilStarted()
        await client.emit([], index: 0)
        let resumed = await coordinator.currentState()
        XCTAssertEqual(resumed.context, 2)
        XCTAssertEqual(resumed.connectionContext, before.connectionContext)
        XCTAssertEqual(resumed.verifiedScope, before.verifiedScope)
        XCTAssertEqual(resumed.purgeRevision, before.purgeRevision)
        XCTAssertEqual(resumed.activities, before.activities)
        let checks = await client.scopeChecks, suspensions = await client.suspensions
        XCTAssertEqual(checks, [true, true])
        XCTAssertEqual(suspensions, 1)

        await client.emit([], index: 1)
        let updated = await coordinator.currentState()
        XCTAssertTrue(updated.activities.isEmpty)
        await coordinator.stop()
    }
}
