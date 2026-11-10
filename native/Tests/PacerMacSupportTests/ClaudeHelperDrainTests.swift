import XCTest
@testable import PacerCore

/// Drives the shipped Claude helper over a read that its budget splits.
final class ClaudeHelperDrainTests: XCTestCase {
    /// One ended response block, then a large line without rows that spills
    /// past the 128 KiB append budget: the helper must close that read with
    /// a drained batch even though its rest yields nothing.
    func testSplitReadEndsWithADrainedBatchWithoutRows() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-helper-drain-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let helper = folder.appendingPathComponent("claude_activity.py"), driver = folder.appendingPathComponent("driver.py")
        try Data(ClaudeActivityProbe.script.utf8).write(to: helper)
        try Data(Self.driver.utf8).write(to: driver)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = ["python3", "-I", driver.path, helper.path]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let batches = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let open = try XCTUnwrap(batches.firstIndex { ($0["kinds"] as? [String])?.contains("modelBlock") == true })
        XCTAssertEqual(batches[open]["final"] as? Bool, false, "The budget split the read")
        XCTAssertTrue(batches[(open + 1)...].contains { $0["final"] as? Bool == true }, "A drained batch closes the read")
    }

    private static let driver = #"""
import base64, json, os, subprocess, sys, tempfile, time, uuid, datetime, pathlib
script = sys.argv[1]
home = pathlib.Path(tempfile.mkdtemp(prefix='pacer-helper-')) / '.claude'
project = home / 'projects' / '-tmp-x'; project.mkdir(parents=True)
session = str(uuid.uuid4()); path = project / (session + '.jsonl')
def now(): return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')
def bare(record): return (json.dumps(dict(record)) + '\n').encode()
def line(record): return (json.dumps(dict(record, sessionId=session, timestamp=now(), cwd='/tmp/x')) + '\n').encode()
path.write_bytes(line({'type': 'user', 'uuid': 'u1', 'promptId': 'p1', 'origin': {'kind': 'human'}, 'message': {'role': 'user', 'content': 'x'}}))
child = subprocess.Popen([sys.executable, '-u', script, base64.b64encode(str(home).encode()).decode(), '0.2'], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
os.set_blocking(child.stdout.fileno(), False)
buf = b''; frames = []
def pump(seconds, until=None):
    global buf
    end = time.time() + seconds
    while time.time() < end and not (until and until()):
        try: chunk = child.stdout.read()
        except BlockingIOError: chunk = None
        if chunk: buf += chunk
        while b'\n' in buf:
            raw, buf = buf.split(b'\n', 1); frame = json.loads(raw)
            if frame.get('kind') == 'claudeBatch': frames.append(frame); print(json.dumps({'final': frame['baselineFinal'], 'kinds': [r.get('kind') for r in frame['records']]}), flush=True)
        time.sleep(0.05)
pump(4, lambda: len(frames) >= 1)
block = line({'type': 'assistant', 'uuid': 'a1', 'parentUuid': 'u1', 'requestId': 'req1', 'message': {'id': 'm1', 'role': 'assistant', 'stop_reason': 'tool_use', 'usage': {'output_tokens': 50}, 'content': [{'type': 'tool_use', 'id': 't1', 'name': 'Bash', 'input': {'command': 'sleep 1'}}]}})
padding = bare({'type': 'system', 'uuid': 's1', 'parentUuid': 'a1', 'subtype': 'informational', 'content': 'p' * 200000})
with open(path, 'ab') as handle: handle.write(block + padding)
pump(10, lambda: len(frames) >= 3)
child.stdin.close(); child.wait(5)
import shutil; shutil.rmtree(home.parent, ignore_errors=True)
"""#
}
