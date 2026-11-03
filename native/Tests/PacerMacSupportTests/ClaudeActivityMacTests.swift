import XCTest
import Darwin
@testable import PacerCore

final class ClaudeActivityMacTests: XCTestCase {
    private let session = "a5a9fbea-c065-46d8-885c-d87413816c90"
    private let turn = "dc0520e2-1720-42a8-a1d1-d2031bf2b145"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func consume(_ kind: String, state: inout ClaudeActivityState, offset: Double, extra: [String: Any] = [:], attaching: Bool = false) {
        let record: [String: Any] = ["kind": kind, "origin": "hook", "sessionId": session, "promptId": turn, "at": now.timeIntervalSince1970 + offset]
        state.consume(ClaudeActivityRecord.encode(record.merging(extra) { _, newer in newer })!, now: now.addingTimeInterval(100), attaching: attaching)
    }
    private func nextStepBox(_ endTurn: Any?, promptID: String? = nil) -> [Data] {
        var raw: [String: Any] = ["type": "user", "sessionId": session, "uuid": "result-box", "timestamp": "2027-01-15T08:00:03Z",
            "entrypoint": "claude-desktop", "toolUseResult": [["type": "text", "text": "PRIVATE box"]],
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "box-1", "content": "PRIVATE recap"]]]]
        if let promptID { raw["promptId"] = promptID }
        if let endTurn { raw["mcpMeta"] = ["_meta": ["claude/endTurn": endTurn]] }
        return ClaudeActivityRecord.transcript(ClaudeActivityRecord.encode(raw)!, sessionID: session)
    }
    func testRemoteHelperEOFAndClosedOutputTerminatePromptly() throws {
        // This suite now precedes the shared Python tests. Separate the
        // runner's first Python/import setup from the helper and EOF deadlines.
        let warmup = Process()
        warmup.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        warmup.arguments = ["-c", "__name__='pacer_fixture'\n" + ClaudeActivityProbe.script]
        warmup.standardInput = FileHandle.nullDevice; warmup.standardOutput = FileHandle.nullDevice; warmup.standardError = FileHandle.nullDevice
        try warmup.run()
        let warmupDeadline = Date().addingTimeInterval(10)
        while warmup.isRunning && Date() < warmupDeadline { Thread.sleep(forTimeInterval: 0.01) }
        if warmup.isRunning { warmup.terminate(); warmup.waitUntilExit(); XCTFail("The runner could not prepare Python for the helper fixture"); return }
        warmup.waitUntilExit(); XCTAssertEqual(warmup.terminationStatus, 0)
        let home = URL(fileURLWithPath: "/private/tmp/pacer-claude-helper-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: home) }
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); child.arguments = ["-u", "-c", ClaudeActivityProbe.script, Data(home.path.utf8).base64EncodedString(), "5"]
        child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice; try child.run()
        var readiness = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
        let ready = Darwin.poll(&readiness, 1, 2000)
        guard ready > 0 else {
            child.terminate(); child.waitUntilExit(); XCTFail("Helper must emit its startup status promptly"); return
        }
        var buffer = [UInt8](repeating: 0, count: 1024)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(output.fileHandleForReading.fileDescriptor, $0.baseAddress!, 1024) }
        XCTAssertGreaterThan(count, 0)
        try input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(2); while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertFalse(child.isRunning, "Owned stdin EOF must stop the actual helper within two seconds")
        if child.isRunning { child.terminate() }; child.waitUntilExit(); XCTAssertEqual(child.terminationStatus, 0)
    }
    /// Projects the same transcript lines with the native reader and the SSH helper.
    private func nativeAndSshRows(_ fixtures: [[String: Any]]) throws -> ([[String: Any]], [[String: Any]], Data) {
        let native = fixtures.flatMap { fixture in ClaudeActivityRecord.transcript(ClaudeActivityRecord.encode(fixture)!, sessionID: session, promptID: turn) }
        let expected = try native.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        let fixtureData = try JSONSerialization.data(withJSONObject: fixtures)
        let program = Data(ClaudeActivityProbe.script.utf8).base64EncodedString()
        let script = "import base64,json,sys\nexec(base64.b64decode('" + program + "').decode(),globals())\nrows=[]\nfor value in json.loads(base64.b64decode(sys.argv[1])):\n rows.extend(transcript(json.dumps(value).encode(),sys.argv[2],None,sys.argv[3]))\nprint(json.dumps(rows,separators=(',',':')))\n"
        // Set a library name before evaluating so no helper listener starts.
        let child = Process(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "__name__='fixture'\n" + script, fixtureData.base64EncodedString(), session, turn]
        child.standardInput = FileHandle.nullDevice; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        try child.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        return (expected, try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [[String: Any]]), bytes)
    }
}
