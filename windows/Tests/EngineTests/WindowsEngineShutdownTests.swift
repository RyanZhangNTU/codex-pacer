@testable import PacerEngineSupport
import Foundation
import XCTest
@testable import PacerCore

private actor StubbornQuotaConnection: CodexQuotaConnection {
    nonisolated let reading = ShutdownSignal(), closing = ShutdownSignal()
    private var read: CheckedContinuation<QuotaSnapshot, Error>?
    private var close: CheckedContinuation<Void, Never>?
    func readQuota() async throws -> QuotaSnapshot {
        try await withCheckedThrowingContinuation { read = $0; reading.finish() }
    }
    func currentAccountScope() -> String? { nil }
    func shutdown() async { await withCheckedContinuation { close = $0; closing.finish() } }
    func release() {
        read?.resume(throwing: CodexClientError.disconnected); read = nil
        close?.resume(); close = nil
    }
}

private actor StuckOutputConsumer {
    private var pending: CheckedContinuation<Void, Never>?
    func block(_ started: XCTestExpectation) async {
        await withCheckedContinuation { pending = $0; started.fulfill() }
    }
    func release() { pending?.resume(); pending = nil }
}

final class WindowsEngineShutdownTests: XCTestCase {
    func testSourceChangeAndStopReturnWhenReadAndClientShutdownIgnoreCancellation() async throws {
        for switching in [true, false] {
            let client = StubbornQuotaConnection()
            let monitor = CodexQuotaMonitor(services: .init(makeClient: { _, _ in client }, history: nil), output: { _ in })
            await monitor.configure(home: URL(fileURLWithPath: "/synthetic/a"), customPath: "", enabled: true, context: 1)
            await monitor.refreshIfDue(expanded: false)
            let began = await client.reading.wait(until: ShutdownDeadline())
            XCTAssertTrue(began)
            let started = DispatchTime.now().uptimeNanoseconds
            if switching {
                await monitor.configure(home: URL(fileURLWithPath: "/synthetic/b"), customPath: "", enabled: true, context: 2)
            } else {
                await monitor.stop()
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
            XCTAssertLessThan(elapsed, 0.95)
            XCTAssertTrue(client.closing.isFinished)
            await client.release()
            await monitor.stop()
        }
    }
    #if os(Windows)
    func testOwnedProcessWaitIsBoundedWhenItsOutputConsumerIsStuck() async throws {
        let started = expectation(description: "owned child produced output")
        let consumer = StuckOutputConsumer()
        let system = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        let process = WindowsCodexProcess(executable: URL(fileURLWithPath: system).appendingPathComponent("System32/cmd.exe"),
            arguments: ["/d", "/c", "echo fixture & ping -n 60 127.0.0.1 > nul"], environment: ProcessInfo.processInfo.environment,
            received: { _ in await consumer.block(started) }, closed: {})
        await fulfillment(of: [started], timeout: 3)
        let before = DispatchTime.now().uptimeNanoseconds
        process.stop()
        await process.waitForExit()
        XCTAssertLessThan(Double(DispatchTime.now().uptimeNanoseconds - before) / 1e9, 0.95)
        XCTAssertFalse(process.ioClosed.isFinished, "The output consumer is still blocked")
        await consumer.release()
        let closed = await process.ioClosed.wait(until: ShutdownDeadline())
        XCTAssertTrue(closed)
    }
    #endif
}
