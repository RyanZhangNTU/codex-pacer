import Foundation
import PacerMacSupport
import XCTest
@testable import PacerCore

final class MacChildProcessShutdownTests: XCTestCase {
    func testSIGTERMIgnoringChildAndStalledReaderCannotBlockShutdown() async throws {
        let ready = expectation(description: "Synthetic child has installed its SIGTERM handler")
        let request = ChildProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import signal,time
        signal.signal(signal.SIGTERM,signal.SIG_IGN)
        print('ready',flush=True)
        while True:time.sleep(1)
        """], environment: ["PATH": "/usr/bin:/bin"])
        let child = try MacChildProcessLauncher().launch(request, output: { data in
            if String(decoding: data, as: UTF8.self).contains("ready") { ready.fulfill() }
        }, ended: {})
        defer { child.close(); child.terminateImmediately() }
        await fulfillment(of: [ready], timeout: 3)
        let stalledReader = ShutdownSignal(), started = Date()
        child.close()
        await ShutdownDeadline().finish(readers: [stalledReader], children: [child])
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.9)
        let exited = await child.waitForExit()
        XCTAssertTrue(exited)
        XCTAssertFalse(child.isRunning)
        XCTAssertEqual(child.terminationStatus, 9, "Only the owned child must receive SIGKILL")
    }
}
