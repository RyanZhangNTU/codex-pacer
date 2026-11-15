import Foundation
import XCTest
import notify
import PacerMacSupport

final class MacNetworkChangesTests: XCTestCase {
    private final class Count: @unchecked Sendable {
        private let lock = NSLock(); private var value = 0
        func add() { lock.lock(); value += 1; lock.unlock() }
        var current: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testEachNoticeCallsBackUntilTheObserverIsReleased() async throws {
        // configd posts the real name as root; a user process cannot, so the
        // observer is checked on its own name with the same notify plumbing.
        let name = "com.codexpacer.tests.network-change." + UUID().uuidString, count = Count()
        let queue = DispatchQueue(label: "pacer.tests.network-change")
        var observer: MacNetworkChanges? = MacNetworkChanges(name: name, queue: queue) { count.add() }
        XCTAssertNotNil(observer)
        XCTAssertEqual(notify_post(name), UInt32(NOTIFY_STATUS_OK))
        let delivered = try await TestWait.until { count.current == 1 }
        XCTAssertTrue(delivered)
        observer = nil
        queue.sync {}
        XCTAssertEqual(notify_post(name), UInt32(NOTIFY_STATUS_OK))
        try await Task.sleep(nanoseconds: 300_000_000)
        queue.sync {}
        XCTAssertEqual(count.current, 1, "A released observer cancels its registration")
    }
}
