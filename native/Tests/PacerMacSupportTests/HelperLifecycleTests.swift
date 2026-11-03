import XCTest
@testable import PacerCore

final class HelperLifecycleTests: XCTestCase {
    private func exitedPromptly(_ child: Process) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if child.isRunning { child.terminate(); child.waitUntilExit(); return false }
        child.waitUntilExit()
        return true
    }
    private func brokenOutput(_ script: String) throws {
        let home = URL(fileURLWithPath: "/private/tmp/pacer-eof-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let child = Process(), output = Pipe()
        try output.fileHandleForReading.close()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-u", "-c", script, Data(home.path.utf8).base64EncodedString()]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output.fileHandleForWriting
        child.standardError = FileHandle.nullDevice
        try child.run()
        try output.fileHandleForWriting.close()
        XCTAssertTrue(exitedPromptly(child), "A closed output must exit, never enter the reconnect loop")
        XCTAssertEqual(child.terminationStatus, 0)
    }
    func testRemoteHelperExitsInsteadOfSpinningWhenOutputReaderDisappears() throws {
        try brokenOutput(RealtimeProbe.script)
    }
    func testDesktopHelperExitsInsteadOfSpinningWhenOutputReaderDisappears() throws {
        try brokenOutput(DesktopEventProbe.script)
    }
    func testSshOwnerInputEofStopsHelperWithoutWaitingForHeartbeat() throws {
        let home = URL(fileURLWithPath: "/private/tmp/pacer-owner-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-u", "-c", RealtimeProbe.script, Data(home.path.utf8).base64EncodedString(), "ssh-lifetime"]
        child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        try child.run()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(child.isRunning)
        try input.fileHandleForWriting.close()
        XCTAssertTrue(exitedPromptly(child))
        XCTAssertEqual(child.terminationStatus, 0)
    }
    func testRemoteHelperOutputFailureAlsoExitsWithExistingHealthySocket() throws {
        // Make the transport ready without touching a real Codex service.
        let simulated = #"""
        class TestWS:
            def __init__(self,path):self.buf=b'';self.s=0;self.last_receive=time.monotonic()
            def close(self):pass
        class TestSession:
            def __init__(self,ws):
                self.ready=True;self.pending={};self.attached=set();self.evidenced=set();self.queue=[];self.notices=0;self.last_list=time.monotonic()
        WebSocket=TestWS;Session=TestSession
        """#
        let main = String(RealtimeProbe.script.dropFirst(RealtimeProbe.library.count))
        try brokenOutput(RealtimeProbe.library + "\n" + simulated + main)
    }
}
