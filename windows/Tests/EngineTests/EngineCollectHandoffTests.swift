import XCTest
@testable import PacerEngineSupport

final class EngineCollectHandoffTests: XCTestCase {
    func testSkippedProjectionsPublishWithTheRunningCollectOrRunItAgain() {
        var handoff = EngineCollectHandoff()
        XCTAssertFalse(handoff.takePublication(), "A collect with nothing handed over may batch Codex metrics")

        XCTAssertFalse(handoff.skippedProjection(localSnapshot: true), "A collect that has not read the local sources yet includes the snapshot")
        XCTAssertTrue(handoff.takePublication(), "That collect must publish instead of batching")
        XCTAssertFalse(handoff.takePublication(), "One publication answers the handoff")

        handoff.readLocalSnapshots()
        XCTAssertTrue(handoff.skippedProjection(localSnapshot: true), "A snapshot after the read needs another collect")
        XCTAssertFalse(handoff.takePublication(), "The current collect holds the older snapshot")
        XCTAssertFalse(handoff.skippedProjection(localSnapshot: false), "A clock tick needs no new read")
        XCTAssertTrue(handoff.takePublication(), "A clock tick publishes with the running collect")

        handoff.endCollect()
        XCTAssertFalse(handoff.skippedProjection(localSnapshot: true), "The next collect reads the local sources again")
        XCTAssertTrue(handoff.takePublication())
    }
}
