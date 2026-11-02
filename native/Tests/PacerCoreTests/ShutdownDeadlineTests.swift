import Foundation
import XCTest
@testable import PacerCore

final class ShutdownDeadlineTests: XCTestCase {
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if released { lock.unlock(); continuation.resume(); return }
                self.continuation = continuation; lock.unlock()
            }
        }
        func release() {
            lock.lock(); released = true
            let continuation = self.continuation; self.continuation = nil; lock.unlock()
            continuation?.resume()
        }
    }
    private final class StubbornChild: ChildProcessConnection, @unchecked Sendable {
        let exited = ShutdownSignal(), ioClosed = ShutdownSignal()
        private let lock = NSLock()
        private var forced = false
        func write(_ data: Data) throws {}
        var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return !forced }
        var terminationStatus: Int32? { isRunning ? nil : 9 }
        func errorMessage() -> String { "" }
        func close() {} // Ignores graceful termination and never completes IO cleanup.
        func terminateImmediately() { lock.lock(); forced = true; lock.unlock(); exited.finish() }
    }

    func testShutdownReturnsWhenReaderAndSeveralChildrenIgnoreCancellation() async {
        let gate = Gate(), finished = ShutdownSignal(), children = [StubbornChild(), StubbornChild(), StubbornChild()]
        let reader = Task { await gate.wait(); finished.finish() }
        reader.cancel()
        for child in children { child.close() }
        let started = Date()
        await ShutdownDeadline().finish(readers: [finished], children: children)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.9, "Every reader and child shares the 650 ms budget")
        XCTAssertFalse(finished.isFinished, "Cancellation alone must not make this reader finish")
        XCTAssertTrue(children.allSatisfy { !$0.isRunning })
        gate.release(); await reader.value
    }

    func testDeadlineDoesNotJoinUncooperativeCleanupTask() async {
        let gate = Gate(), finished = ShutdownSignal(), deadline = ShutdownDeadline(timeout: 0.04)
        let started = Date()
        let completed = await deadline.perform([{ await gate.wait(); finished.finish() }])
        XCTAssertFalse(completed)
        XCTAssertFalse(finished.isFinished)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.3)
        gate.release()
        let released = await finished.wait(until: ShutdownDeadline())
        XCTAssertTrue(released)
    }

    func testCompletedSignalsReturnWithoutUsingTheGracePeriod() async {
        let finished = ShutdownSignal(); finished.finish()
        let started = Date()
        let completed = await finished.wait(until: ShutdownDeadline())
        XCTAssertTrue(completed)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1)
    }
}
