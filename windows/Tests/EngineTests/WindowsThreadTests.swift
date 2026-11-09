@testable import PacerEngineSupport
#if os(Windows)
import Foundation
import WinSDK
import XCTest

final class WindowsThreadTests: XCTestCase {
    /// Foundation's `Thread` on Windows never closed the handle that
    /// `_beginthreadex` returned, so every finished WinHTTP request thread left
    /// a handle to an exited thread behind.
    func testFinishedThreadsLeaveNoHandles() async throws {
        await runThreads(5)
        let before = handleCount()
        await runThreads(50)
        // Fifty threads that each kept their handle would add fifty.
        XCTAssertLessThan(handleCount() - before, 20)
    }

    func testThreadRunsItsWork() async throws {
        let value = await withCheckedContinuation { (done: CheckedContinuation<Int, Never>) in
            if !WindowsThread.start(name: "Pacer test", { done.resume(returning: 42) }) { done.resume(returning: -1) }
        }
        XCTAssertEqual(value, 42)
    }

    private func handleCount() -> Int {
        var count: DWORD = 0
        XCTAssertTrue(GetProcessHandleCount(GetCurrentProcess(), &count))
        return Int(count)
    }

    private func runThreads(_ count: Int) async {
        for _ in 0..<count {
            let started = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                if !WindowsThread.start(name: "Pacer test", { done.resume(returning: true) }) { done.resume(returning: false) }
            }
            XCTAssertTrue(started)
        }
    }
}
#endif
