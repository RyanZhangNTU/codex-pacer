import PacerMacSupport
import XCTest
@testable import PacerCore

final class CodexSessionOriginMacTests: XCTestCase {
    private let session = "019a0000-0000-7000-8000-0000000000a1"
    private let child = "019a0000-0000-7000-8000-0000000000a2"

    // CodexSessionOriginTests in PacerCore covers the native reader, metadata
    // and desktop rules on every host. These cases add the SSH and realtime
    // Python probes and a real file writer, which run only on the Mac.

    /// After a revert on an SSH or WSL host, the earlier rollout stays beside
    /// the current one (#259). The probe's log snapshot reports the thread from
    /// its newest rollout, so the running turn and its progress are not
    /// replaced by the reverted one's finished turn.
    func testSSHSnapshotReportsARevertedThreadFromItsCurrentRollout() throws {
        let root = try directory(), now = Date()
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"
        let folder = root.appendingPathComponent("sessions/" + formatter.string(from: now))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter()
        func lines(_ records: [(String, Double, [String: Any])]) throws -> Data {
            try records.reduce(into: Data()) { data, record in
                data += try JSONSerialization.data(withJSONObject: ["type": record.0, "timestamp": stamp.string(from: now.addingTimeInterval(record.1)),
                                                                    "payload": record.2]) + Data([10])
            }
        }
        func report(_ percent: Int) -> [String: Any] {
            ["type": "McpToolCall", "id": "call", "server": "pacer_progress", "tool": "report_progress", "arguments": ["percent": percent],
             "status": "completed", "result": ["isError": false, "content": [["type": "text", "text": "pacer-progress:accepted"]]]]
        }
        let meta: [String: Any] = ["id": session, "originator": "codex-tui", "cwd": "/fixture/project", "history_mode": "paginated"]
        let original = folder.appendingPathComponent("rollout-2026-11-19T05-00-00-" + session + ".jsonl")
        try lines([("session_meta", -60, meta), ("event_msg", -59, ["type": "task_started", "turn_id": "turn-0"]),
                   ("event_msg", -58, ["type": "item_completed", "thread_id": session, "turn_id": "turn-0", "item": report(100)]),
                   ("event_msg", -57, ["type": "task_complete", "turn_id": "turn-0"])]).write(to: original)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-57)], ofItemAtPath: original.path)
        let current = folder.appendingPathComponent("rollout-2026-11-19T06-00-00-" + session + "_" + child + ".jsonl")
        try lines([("session_meta", -2, meta), ("event_msg", -1, ["type": "task_started", "turn_id": "turn-1"]),
                   ("event_msg", 0, ["type": "item_completed", "thread_id": session, "turn_id": "turn-1", "item": report(70)])]).write(to: current)

        let output = try python(SessionLogProbe.library + "\nprint(json.dumps(snapshot()))", home: root)
        let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual((frame["sessions"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [current.lastPathComponent],
                       "Only the current rollout reports the thread")
        var state = RuntimeEventState(sourceID: "remote-ssh:fixture", sourceName: "SSH")
        state.consume(frame)
        XCTAssertEqual(state.activities.map(\.turnID), ["turn-1"])
        XCTAssertEqual(state.activities.first?.phase, .running)
        XCTAssertEqual(state.activities.first?.currentProgress?.percent, 70)

        // Should both rollouts still arrive, in either order, the newer turn stays.
        func row(_ file: URL) throws -> [String: Any] {
            let records = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
                .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) }
            return ["id": file.lastPathComponent, "records": records, "reset": true]
        }
        let pair = [try row(current), try row(original)]
        for order in [pair, Array(pair.reversed())] {
            var other = RuntimeEventState(sourceID: "remote-ssh:fixture", sourceName: "SSH")
            other.consume(["sessions": order])
            XCTAssertEqual(other.activities.map(\.turnID), ["turn-1"])
            XCTAssertEqual(other.activities.first?.currentProgress?.percent, 70)
        }
    }

    func testSSHProbeSkipsIgnoredRolloutsAndChildren() throws {
        let root = try directory(), now = Date()
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"
        let folder = root.appendingPathComponent("sessions/" + formatter.string(from: now))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for number in 1...40 {
            let id = String(format: "019a0000-0000-7000-8000-%012d", number)
            let url = folder.appendingPathComponent("rollout-" + id + ".jsonl")
            try log(id, origin: "@agentclientprotocol/codex-acp", cwd: "/fixture/zotero-chat/translate", now: now).write(to: url)
        }
        var childData = try metadata(child, origin: nil, parent: "019a0000-0000-7000-8000-000000000001")
        childData.append(10)
        try childData.write(to: folder.appendingPathComponent("rollout-" + child + ".jsonl"))
        let official = folder.appendingPathComponent("rollout-" + session + ".jsonl")
        try log(session, origin: "codex-tui", now: now).write(to: official)
        let ssh = try python(SessionLogProbe.library + "\nprint(json.dumps(snapshot()))", home: root)
        let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ssh.utf8)) as? [String: Any])
        XCTAssertEqual((snapshot["sessions"] as? [[String: Any]])?.count, 1)
    }

    func testRealtimeProbeExcludesATranslationWithoutResumingIt() throws {
        let root = try directory(), file = root.appendingPathComponent("sessions/rollout-" + session + ".jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try metadata(session, origin: "@agentclientprotocol/codex-acp", cwd: "/fixture/zotero-chat/translate").write(to: file)
        let script = #"""
        class Fake:
            def __init__(self):self.sent=[]
            def send(self,value):self.sent.append(value)
        tid='019a0000-0000-7000-8000-0000000000a1'
        ws=Fake();s=Session(ws);s.ready=True;s.pending.clear()
        s.request('thread/read',{'threadId':tid},'read',tid);rid=ws.sent[-1]['id']
        s.receive({'id':rid,'result':{'thread':{'id':tid,'path':str(home/'sessions'/('rollout-'+tid+'.jsonl')),'status':{'type':'active'}}}})
        assert tid in s.excluded and not s.queue
        assert not any(v.get('method')=='thread/resume' for v in ws.sent)
        print('excluded')
        """#
        XCTAssertEqual(try python(RealtimeProbe.library + "\n" + script, home: root).trimmingCharacters(in: .whitespacesAndNewlines), "excluded")
    }

    func testOpenRolloutOwnershipAndPidReuseWithARealWriter() throws {
        let root = try directory(), file = root.appendingPathComponent("rollout-" + session + ".jsonl")
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", "import sys,time\nf=open(sys.argv[1],'a')\nprint('ready',flush=True)\ntime.sleep(30)", file.path]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        _ = output.fileHandleForReading.availableData
        XCTAssertEqual(CodexRolloutOwners.holders(rollouts: [session: file])[session], process.processIdentifier)
        var calls = 0
        XCTAssertTrue(CodexRolloutOwners.holders(rollouts: [session: file], processes: { [42] }, files: { _ in [file] },
            processStart: { _ in calls += 1; return Date(timeIntervalSince1970: Double(calls)) }).isEmpty)
        process.terminate(); process.waitUntilExit()
        XCTAssertNil(CodexRolloutOwners.holders(rollouts: [session: file])[session])
    }

    func testSSHProbeKeepsTheLatestLaunchAcrossChunkBoundaries() throws {
        let root = try directory(), file = root.appendingPathComponent("sessions/rollout-" + session + ".jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        for bytes in [64 * 1024, 160 * 1024] {
            var data = try metadata(session, origin: "@agentclientprotocol/codex-acp")
            data.append(10)
            data.append(try metadata(session, origin: "codex-tui", at: "2026-10-15T00:00:02Z")); data.append(10)
            data.append(try JSONSerialization.data(withJSONObject: ["type": "response_item", "payload": ["text": String(repeating: "S", count: bytes)]])); data.append(10)
            data.append(try metadata(session, origin: "private-client-name", at: "2026-10-15T00:00:01Z")); data.append(10)
            try data.write(to: file)
            let output = try python(SessionLogProbe.library + "\nr=rollout_origin(home/'sessions'/'\(file.lastPathComponent)')\nprint(json.dumps(r['embedded']))", home: root)
            XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "false")
        }
    }

    func testSSHProbeInheritsAParentsExclusionAndRereadsIt() throws {
        let root = try directory(), format = DateFormatter(); format.dateFormat = "yyyy/MM/dd"
        let folder = root.appendingPathComponent("sessions/" + format.string(from: Date()))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try metadata(session, origin: "@agentclientprotocol/codex-acp", cwd: "/fixture/zotero-chat/translate")
            .write(to: folder.appendingPathComponent("rollout-" + session + ".jsonl"))
        try metadata(child, origin: nil, parent: session).write(to: folder.appendingPathComponent("rollout-" + child + ".jsonl"))
        let grandchild = "019a0000-0000-7000-8000-0000000000a3"
        try metadata(grandchild, origin: "codex-tui", parent: child).write(to: folder.appendingPathComponent("rollout-" + grandchild + ".jsonl"))
        let script = #"""
        tid='019a0000-0000-7000-8000-0000000000a3'
        path=next(p for p in candidates() if p.stem.endswith(tid))
        thread={'id':tid,'path':str(path)}
        assert thread_origin(thread)['ignoredSession']
        # Parent metadata is read again, even if a previous snapshot cached it.
        parent='019a0000-0000-7000-8000-0000000000a1'
        path=next(p for p in candidates() if p.stem.endswith(parent))
        with path.open('w') as f:json.dump({'type':'session_meta','timestamp':'2026-10-15T00:00:02Z','payload':{'id':parent,'originator':'codex-tui'}},f)
        assert not thread_origin(thread)['ignoredSession']
        print('inherited')
        """#
        XCTAssertEqual(try python(SessionLogProbe.library + "\n" + script, home: root).trimmingCharacters(in: .whitespacesAndNewlines), "inherited")
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-origin-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func metadata(_ id: String, origin: String?, cwd: String = "/fixture/Zotero-Agent", parent: String? = nil,
                          at: String = "2026-10-15T00:00:00Z") throws -> Data {
        var payload: [String: Any] = ["id": id, "cwd": cwd, "source": "vscode"]
        if let origin { payload["originator"] = origin }
        if let parent { payload["parent_thread_id"] = parent }
        return try JSONSerialization.data(withJSONObject: ["type": "session_meta", "timestamp": at, "payload": payload])
    }
    private func log(_ id: String, origin: String, cwd: String = "/fixture/Zotero-Agent", parent: String? = nil, now: Date) throws -> Data {
        var data = try metadata(id, origin: origin, cwd: cwd, parent: parent)
        data.append(10)
        data.append(try JSONSerialization.data(withJSONObject: ["timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(-1)),
            "type": "event_msg", "payload": ["type": "task_started", "turn_id": "synthetic-turn"]]))
        data.append(10); return data
    }
    private func python(_ script: String, home: URL = URL(fileURLWithPath: "/private/tmp/pacer-no-user-data")) throws -> String {
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", script, Data(home.path.utf8).base64EncodedString()]
        process.standardOutput = output; process.standardError = error
        try process.run(); let result = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        return String(decoding: result, as: UTF8.self)
    }

    /// On SSH and WSL hosts too, a long turn's log can outgrow the anchor
    /// search. Snapshots that skip appends starting, ending or setting no turn
    /// keep the turn, so its progress carries on; a new turn still resets.
    func testSSHSnapshotKeepsALongTurnAcrossALargeAppend() throws {
        let root = try directory()
        let script = #"""
        import datetime
        tid='019a0000-0000-7000-8000-0000000000a1'
        folder=home/'sessions'/datetime.datetime.now().strftime('%Y/%m/%d');folder.mkdir(parents=True)
        path=folder/('rollout-2026-11-19T06-00-00-'+tid+'.jsonl')
        stamp=lambda:datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%fZ')
        def record(kind,p):return json.dumps({'timestamp':stamp(),'type':kind,'payload':p})+'\n'
        def progress(percent):return record('event_msg',{'type':'item_completed','thread_id':tid,'turn_id':'turn-1','item':{'type':'McpToolCall','id':'c','server':'pacer_progress','tool':'report_progress','arguments':{'percent':percent},'status':'completed','result':{'isError':False,'content':[{'type':'text','text':'pacer-progress:accepted'}]}}})
        path.write_text(record('session_meta',{'id':tid,'originator':'codex-tui','cwd':'/fixture/project'})+record('event_msg',{'type':'task_started','turn_id':'turn-1'})+progress(30))
        frames=[snapshot()]
        # About 10 MB in 1 MB steps, a snapshot after each; the last step reports 60%.
        for step in range(10):
            with path.open('a') as f:
                for _ in range(16):f.write(record('response_item',{'type':'function_call_output','call_id':'c','output':'x'*65536}))
                if step==9:f.write(progress(60))
            frames.append(snapshot())
        same=len(frames)
        with path.open('a') as f:
            f.write(record('event_msg',{'type':'task_complete','turn_id':'turn-1'})+record('event_msg',{'type':'task_started','turn_id':'turn-2'}))
            for _ in range(3):f.write(record('response_item',{'type':'function_call_output','call_id':'c','output':'y'*65536}))
        frames.append(snapshot())
        print(json.dumps({'same':same,'frames':frames}))
        """#
        let output = try python(SessionLogProbe.library + "\n" + script, home: root)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let frames = try XCTUnwrap(result["frames"] as? [[String: Any]]), same = try XCTUnwrap(result["same"] as? Int)
        XCTAssertEqual(frames.count, 12)
        for frame in frames[1..<same] {
            XCTAssertEqual((frame["sessions"] as? [[String: Any]])?.first?["reset"] as? Bool, false, "The same turn is not started over")
        }
        var state = RuntimeEventState(sourceID: "remote-ssh:fixture", sourceName: "SSH")
        for frame in frames[..<same] { state.consume(frame) }
        XCTAssertEqual(state.activities.map(\.turnID), ["turn-1"])
        XCTAssertEqual(state.activities.first?.phase, .running)
        XCTAssertEqual(state.activities.first?.currentProgress?.percent, 60)
        XCTAssertEqual((frames[same]["sessions"] as? [[String: Any]])?.first?["reset"] as? Bool, true, "A new turn in the skipped part starts over")
        state.consume(frames[same])
        XCTAssertEqual(state.activities.map(\.turnID), ["turn-2"])
    }
}
