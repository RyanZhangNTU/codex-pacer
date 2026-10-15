import XCTest
@testable import PacerCore

final class CodexSessionOriginTests: XCTestCase {
    private let session = "019a0000-0000-7000-8000-0000000000a1"
    private let child = "019a0000-0000-7000-8000-0000000000a2"

    func testOriginClassificationAndSanitizedSshParity() throws {
        let fixtures: [[String: Any]] = (CodexSessionOrigin.officialClients + ["@agentclientprotocol/codex-acp", "private-client-name"]).flatMap { origin in
            ["/fixture/Zotero-Agent", "/fixture/zotero-chat/translate", "/tmp/zotero-chat-catalog.synthetic"].map {
                ["type": "session_meta", "timestamp": "2026-10-15T00:00:00Z", "payload": ["id": session, "originator": origin, "cwd": $0, "source": "vscode"]] as [String: Any]
            }
        } + [["type": "session_meta", "payload": ["id": session, "cwd": "/fixture/zotero-chat/translate"]]]
        let input = try JSONSerialization.data(withJSONObject: fixtures).base64EncodedString()
        let script = "fixtures=json.loads(base64.b64decode('" + input + "').decode())\nprint(json.dumps([sanitize(v) for v in fixtures]))"
        let output = try python(SessionLogProbe.library + "\n" + script)
        XCTAssertFalse(output.contains("private-client-name")); XCTAssertFalse(output.contains("@agentclientprotocol"))
        let sanitized = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]])
        for (raw, reduced) in zip(fixtures, sanitized) {
            var native = SessionActivity(id: session), ssh = SessionActivity(id: session)
            native.consume(try JSONSerialization.data(withJSONObject: raw))
            ssh.consume(try JSONSerialization.data(withJSONObject: reduced))
            XCTAssertEqual(native.codexOrigin, ssh.codexOrigin, "Synthetic input: \(raw); reduced: \(reduced)")
            if let origin = raw["payload"] as? [String: Any], let name = origin["originator"] as? String {
                let embedded = !CodexSessionOrigin.officialClients.contains(name)
                XCTAssertEqual(native.launchedByEmbeddingApp, embedded)
                XCTAssertEqual(native.isIgnoredCodexSession, embedded && origin["cwd"] as? String != "/fixture/Zotero-Agent")
            } else { XCTAssertNil(native.codexOrigin) }
        }
    }

    func testNewestOriginAndParentClassificationWinWithoutCrossingHosts() throws {
        var parent = SessionActivity(id: session), descendant = SessionActivity(id: child)
        parent.consume(try metadata(session, origin: "@agentclientprotocol/codex-acp", cwd: "/fixture/zotero-chat/translate"))
        descendant.consume(try metadata(child, origin: "codex_cli_rs", parent: session))
        var remote = descendant
        remote = SessionActivity(id: "remote-ssh-discovered:synthetic:" + child, sourceHostID: "remote-ssh-discovered:synthetic")
        remote.consume(try metadata(child, origin: "codex_cli_rs", parent: session))
        let inherited = CodexSessionOrigin.inheriting([descendant, parent, remote])
        XCTAssertTrue(inherited[0].isIgnoredCodexSession); XCTAssertFalse(inherited[2].isIgnoredCodexSession)
        parent.consume(try metadata(session, origin: "codex-tui", at: "2026-10-15T00:00:02Z"))
        parent.consume(try metadata(session, origin: "private-client-name", at: "2026-10-15T00:00:01Z"))
        XCTAssertFalse(parent.launchedByEmbeddingApp)
        XCTAssertFalse(CodexSessionOrigin.inheriting([descendant, parent])[0].launchedByEmbeddingApp)

        // A delayed runtime metadata frame cannot override a newer official resume.
        var runtime = RuntimeEventState(sourceID: nil, sourceName: nil)
        runtime.consume(["kind": "status", "connected": true])
        let events: [[String: Any]] = [
            ["method": "metadata", "threadId": session, "at": 200.0, "embedded": false, "ignoredSession": false],
            ["method": "metadata", "threadId": session, "at": 100.0, "embedded": true, "ignoredSession": true],
            ["method": "turn/started", "threadId": session, "turnId": "synthetic", "at": 201.0]
        ]
        for event in events { runtime.consume(["kind": "runtime", "event": event]) }
        XCTAssertEqual(runtime.activities.count, 1)
        XCTAssertFalse(try XCTUnwrap(runtime.activities.first).launchedByEmbeddingApp)
    }

    func testIgnoredRolloutsAndChildrenDoNotConsumeReaderSlotsOrWatches() async throws {
        let root = try directory(), now = Date()
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"
        let folder = root.appendingPathComponent("sessions/" + formatter.string(from: now))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var ignored: [URL] = []
        for number in 1...40 {
            let id = String(format: "019a0000-0000-7000-8000-%012d", number)
            let url = folder.appendingPathComponent("rollout-" + id + ".jsonl")
            try log(id, origin: "@agentclientprotocol/codex-acp", cwd: "/fixture/zotero-chat/translate", now: now).write(to: url)
            ignored.append(url)
        }
        let parentID = "019a0000-0000-7000-8000-000000000001"
        let descendant = folder.appendingPathComponent("rollout-" + child + ".jsonl")
        var childData = try metadata(child, origin: nil, parent: parentID)
        childData.append(10)
        try childData.write(to: descendant)
        ignored.append(descendant)
        let official = folder.appendingPathComponent("rollout-" + session + ".jsonl")
        try log(session, origin: "codex-tui", now: now).write(to: official)
        let reader = LocalActivityReader()
        let result = await reader.read(home: root, now: now)
        XCTAssertEqual(result.activities.compactMap(\.threadID), [session])
        XCTAssertTrue(ignored.allSatisfy { !result.watchURLs.contains($0) })
        XCTAssertEqual(result.excludedIDs.count, ignored.count)
        let ssh = try python(SessionLogProbe.library + "\nprint(json.dumps(snapshot()))", home: root)
        let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ssh.utf8)) as? [String: Any])
        XCTAssertEqual((snapshot["sessions"] as? [[String: Any]])?.count, 1)

        // An official resume of an excluded file must be discoverable again.
        let revived = ignored[0]
        let handle = try FileHandle(forWritingTo: revived); try handle.seekToEnd()
        try handle.write(contentsOf: metadata(parentID, origin: "codex-tui", at: ISO8601DateFormatter().string(from: now)))
        try handle.write(contentsOf: Data([10])); try handle.close()
        let next = await reader.read(home: root, now: now)
        XCTAssertFalse(next.excludedIDs.contains("local:" + parentID))
        XCTAssertTrue(next.activities.contains { $0.threadID == parentID && !$0.launchedByEmbeddingApp })
    }

    func testTranslationCannotResumeThroughRuntimeOrFollowThroughDesktop() throws {
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
        final class Sent { var values: [[String: Any]] = [] }
        let sent = Sent(), remote = "remote-control:synthetic"
        var desktop = try NativeDesktopSession(hosts: ["local", remote]) { sent.values.append($0) }
        desktop.localOrigin = { _ in CodexRolloutMetadata.read(file) }
        try desktop.receive(JSONSerialization.data(withJSONObject: ["type": "response", "method": "initialize", "resultType": "success",
            "result": ["clientId": "019a0000-0000-7000-8000-0000000000b1"]]))
        try desktop.discover([.init(host: "local", thread: session), .init(host: remote, thread: session)])
        let follows = sent.values.filter { $0["method"] as? String == "thread-stream-following-changed" }.compactMap { $0["params"] as? [String: Any] }
        XCTAssertFalse(follows.contains { $0["hostId"] as? String == "local" && $0["following"] as? Bool == true })
        XCTAssertTrue(follows.contains { $0["hostId"] as? String == remote && $0["following"] as? Bool == true })
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

    func testMetadataHeadAndTailKeepTheLatestLaunchAcrossChunkBoundaries() throws {
        let root = try directory(), file = root.appendingPathComponent("sessions/rollout-" + session + ".jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        for bytes in [64 * 1024, 160 * 1024] {
            var data = try metadata(session, origin: "@agentclientprotocol/codex-acp")
            data.append(10)
            data.append(try metadata(session, origin: "codex-tui", at: "2026-10-15T00:00:02Z")); data.append(10)
            data.append(try JSONSerialization.data(withJSONObject: ["type": "response_item", "payload": ["text": String(repeating: "S", count: bytes)]])); data.append(10)
            data.append(try metadata(session, origin: "private-client-name", at: "2026-10-15T00:00:01Z")); data.append(10)
            try data.write(to: file)
            XCTAssertFalse(try XCTUnwrap(CodexRolloutMetadata.read(file)).origin.embedded)
            let output = try python(SessionLogProbe.library + "\nr=rollout_origin(home/'sessions'/'\(file.lastPathComponent)')\nprint(json.dumps(r['embedded']))", home: root)
            XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "false")
        }
    }

    func testNativePreflightInheritsAnUnsubscribedParentsExclusion() throws {
        let root = try directory(), format = DateFormatter(); format.dateFormat = "yyyy/MM/dd"
        let folder = root.appendingPathComponent("sessions/" + format.string(from: Date()))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try metadata(session, origin: "@agentclientprotocol/codex-acp", cwd: "/fixture/zotero-chat/translate")
            .write(to: folder.appendingPathComponent("rollout-" + session + ".jsonl"))
        try metadata(child, origin: nil, parent: session).write(to: folder.appendingPathComponent("rollout-" + child + ".jsonl"))
        let grandchild = "019a0000-0000-7000-8000-0000000000a3"
        try metadata(grandchild, origin: "codex-tui", parent: child).write(to: folder.appendingPathComponent("rollout-" + grandchild + ".jsonl"))
        let lookup = CodexOriginLookup(home: root)
        XCTAssertTrue(try XCTUnwrap(lookup.lookup(child)).origin.ignored)
        XCTAssertTrue(try XCTUnwrap(lookup.lookup(grandchild)).origin.ignored)
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
        // Restore the excluded root before testing native IPC follow preflight.
        try metadata(session, origin: "@agentclientprotocol/codex-acp", cwd: "/fixture/zotero-chat/translate")
            .write(to: folder.appendingPathComponent("rollout-" + session + ".jsonl"))
        final class Sent { var values: [[String: Any]] = [] }
        let sent = Sent()
        var desktop = try NativeDesktopSession(hosts: ["local"]) { sent.values.append($0) }
        desktop.localOrigin = { lookup.lookup($0) }
        try desktop.receive(JSONSerialization.data(withJSONObject: ["type": "response", "method": "initialize", "resultType": "success",
            "result": ["clientId": "019a0000-0000-7000-8000-0000000000b1"]]))
        try desktop.discover([.init(host: "local", thread: child), .init(host: "local", thread: grandchild)])
        XCTAssertFalse(sent.values.contains { $0["method"] as? String == "thread-stream-following-changed" })
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
}
