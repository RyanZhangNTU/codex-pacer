import XCTest
@testable import PacerCore

final class ProgressSetupQueueTests: XCTestCase {
    private struct Target: Equatable, Sendable { let home: String; let enabled: Bool }

    func testRequestsRunInOrderAndOnlyTheNewestPublishes() async throws {
        var queue = ProgressSetupQueue<Target>()
        let first = Target(home: "a", enabled: true)
        let one = try XCTUnwrap(queue.request(first))
        XCTAssertNil(one.previous)
        XCTAssertNil(queue.request(first), "An unchanged target needs no new setup")
        let release = AsyncStream<Void>.makeStream()
        let order = OrderLog()
        queue.track(Task {
            for await _ in release.stream { break }
            await order.append("first")
        })
        let two = try XCTUnwrap(queue.request(Target(home: "b", enabled: true)))
        XCTAssertEqual(two.previous, first, "A new home revokes the one the switch left")
        let second = Task { await two.waitForPrevious(); await order.append("second") }
        queue.track(second)
        release.continuation.yield(); release.continuation.finish()
        await second.value
        let recorded = await order.values
        XCTAssertEqual(recorded, ["first", "second"])
        XCTAssertFalse(queue.finish(one), "A superseded result is dropped")
        XCTAssertTrue(queue.finish(two))
        XCTAssertNotNil(queue.request(Target(home: "b", enabled: true), force: true), "Retry forces the same target again")
    }

    private actor OrderLog {
        private(set) var values: [String] = []
        func append(_ value: String) { values.append(value) }
    }
}
