#if canImport(PacerMacSupport)
import PacerMacSupport
#else
@testable import PacerEngineSupport
#endif
import XCTest
@testable import PacerCore

final class HelperProcessPortTests: XCTestCase {
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if released { lock.unlock(); continuation.resume() }
                else { self.continuation = continuation; lock.unlock() }
            }
        }
        func open() { lock.lock(); released = true; let value = continuation; continuation = nil; lock.unlock(); value?.resume() }
    }
    private func launch(output: @escaping @Sendable (Data) async -> Void) throws -> any ChildProcessConnection {
        #if canImport(PacerMacSupport)
        let launcher: any HelperProcessLauncher = MacHelperProcessLauncher()
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        #else
        let launcher: any HelperProcessLauncher = WindowsHelperProcessLauncher()
        let python = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["PACER_TEST_PYTHON"]))
        #endif
        let script = "import signal,sys,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\nsys.stdout.write('ready\\n');sys.stdout.flush()\nwhile True:time.sleep(1)"
        return try launcher.launch(.init(executable: python, arguments: ["-S", "-u", "-c", script],
            environment: ProcessInfo.processInfo.environment), output: output, ended: {})
    }
    func testIgnoredEOFAndTerminationStillReleaseOwnedHelper() async throws {
        let ready = expectation(description: "owned fixture ready")
        ready.assertForOverFulfill = false
        let child = try launch { _ in ready.fulfill() }; defer { child.close() }
        await fulfillment(of: [ready], timeout: 3)
        let started = ProcessInfo.processInfo.systemUptime, deadline = ShutdownDeadline()
        child.close(); await deadline.finish(readers: [], children: [child])
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, ShutdownDeadline.maximumWait + 0.25)
        let exited = await child.waitForExit(); XCTAssertTrue(exited); XCTAssertFalse(child.isRunning)
    }
    func testBlockedConsumerCannotExtendTheShutdownDeadline() async throws {
        let entered = expectation(description: "stdout consumer is blocked"), gate = Gate()
        let child = try launch { _ in entered.fulfill(); await gate.wait() }
        defer { gate.open(); child.close() }
        await fulfillment(of: [entered], timeout: 3)
        let started = ProcessInfo.processInfo.systemUptime, deadline = ShutdownDeadline()
        child.close(); await deadline.finish(readers: [], children: [child])
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, ShutdownDeadline.maximumWait + 0.25)
        gate.open()
        let exited = await child.waitForExit(); XCTAssertTrue(exited); XCTAssertFalse(child.isRunning)
    }
}
