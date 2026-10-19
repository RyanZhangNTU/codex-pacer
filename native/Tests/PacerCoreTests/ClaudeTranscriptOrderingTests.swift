import Foundation
import XCTest
@testable import PacerCore

final class ClaudeTranscriptOrderingTests: XCTestCase {
    private let session = "00000000-0000-4000-8000-000000000001"
    private let prompt = "00000000-0000-4000-8000-000000000002"
    private let now = Date(timeIntervalSince1970: 1_800_000_100)

    private func row(_ type: String, id: String, parent: String? = nil, prompt: String? = nil,
                     second: Int = 0, extra: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = ["type": type, "sessionId": session, "uuid": id,
            "timestamp": "2027-01-15T08:00:" + String(format: "%02d", second) + "Z"]
        if let parent { value["parentUuid"] = parent }
        if let prompt { value["promptId"] = prompt }
        return value.merging(extra) { _, new in new }
    }
    private var ending: [[String: Any]] {
        [row("user", id: "start", prompt: prompt, extra: ["origin": ["kind": "human"],
            "message": ["role": "user", "content": "PRIVATE synthetic prompt"]]),
         // The attachment was persisted ahead of its parent tool result.
         row("attachment", id: "bridge", parent: "result", second: 3),
         row("assistant", id: "tool", parent: "start", second: 1,
             extra: ["message": ["role": "assistant", "content": [["type": "tool_use", "id": "tool-one", "name": "Bash"]]]]),
         row("user", id: "result", parent: "tool", prompt: prompt, second: 2,
             extra: ["message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "tool-one", "content": "PRIVATE result"]]]]),
         row("assistant", id: "answer", parent: "bridge", second: 4,
             extra: ["message": ["role": "assistant", "stop_reason": "end_turn", "content": [["type": "text", "text": "PRIVATE answer"]]]]),
         row("system", id: "stop", parent: "answer", second: 5,
             extra: ["subtype": "stop_hook_summary", "preventedContinuation": false, "hookErrors": [String](), "hookAdditionalContext": [String]()])]
    }
    private func bytes(_ rows: [[String: Any]]) -> Data {
        rows.reduce(into: Data()) { $0.append(ClaudeActivityRecord.encode($1)!); $0.append(10) }
    }
    private func runningState(remote: Bool = false) -> ClaudeActivityState {
        var state = ClaudeActivityState(sourceID: remote ? "synthetic-ssh" : nil, sourceName: nil)
        state.consume(ClaudeActivityRecord.encode(["kind": "prompt", "origin": "hook", "sessionId": session,
            "promptId": prompt, "at": 1_800_000_000.0])!, now: now)
        return state
    }
    private func ssh(_ program: String, arguments: [String]) throws -> Data {
        let script = Data(ClaudeActivityProbe.script.utf8).base64EncodedString()
        let child = Process(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "__name__='fixture'\nimport base64,json,sys,pathlib\nexec(base64.b64decode('" + script + "').decode(),globals())\n" + program] + arguments
        child.standardInput = FileHandle.nullDevice; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        try child.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        return data
    }

    func testNativeAndSshEndTheOwnedTurnWhenAnAttachmentPrecedesItsParentAcrossReads() throws {
        let home = URL(fileURLWithPath: "/private/tmp/pacer-claude-order-" + UUID().uuidString)
        let project = home.appendingPathComponent("projects/synthetic")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = project.appendingPathComponent(session + ".jsonl")
        let rows = ending
        try bytes([rows[0]]).write(to: file)
        var reader = ClaudeActivityReader(), native = runningState()
        for record in reader.read(home: home, discover: true, now: now).records { native.consume(record, now: now) }
        var projected: [Data] = []
        for row in rows.dropFirst() {
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd(); try handle.write(contentsOf: bytes([row])); try handle.close()
            let result = reader.read(home: home, discover: false, now: now)
            XCTAssertTrue(result.caughtUp)
            projected += result.records
            for record in result.records { native.consume(record, now: now) }
        }
        XCTAssertEqual(native.activities.first?.phase, .completed)
        XCTAssertEqual(native.activities.first?.turnID, prompt)
        XCTAssertFalse(native.activities.first?.isHistoricalCompletion ?? true)
        XCTAssertEqual(reader.scans, 1, "Ordinary append ownership does not need rediscovery")
        XCTAssertFalse(projected.contains { String(decoding: $0, as: UTF8.self).contains("PRIVATE") })

        // Exercise the real SSH Tailer with the same per-append boundaries.
        try bytes([rows[0]]).write(to: file)
        let fixture = home.appendingPathComponent("rows.json")
        try JSONSerialization.data(withJSONObject: Array(rows.dropFirst())).write(to: fixture)
        let program = "tailer=Tailer(pathlib.Path(sys.argv[1]));tailer.discover();chunks=[tailer.read()]\nfor row in json.loads(pathlib.Path(sys.argv[3]).read_text()):\n with open(sys.argv[2],'ab') as stream:stream.write((json.dumps(row)+'\\n').encode())\n tailer.poll();chunks.append(tailer.read())\ntailer.close();print(json.dumps(chunks))\n"
        let output = try ssh(program, arguments: [home.path, file.path, fixture.path])
        let chunks = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [[[String: Any]]])
        var remote = runningState(remote: true)
        for chunk in chunks { remote.consume(ClaudeActivityRecord.encode(["kind": "claudeBatch", "records": chunk])!, now: now) }
        XCTAssertEqual(remote.activities.first?.phase, .completed)
        XCTAssertEqual(remote.activities.first?.turnID, prompt)
        XCTAssertFalse(String(decoding: output, as: UTF8.self).contains("PRIVATE"))

        var historicalReader = ClaudeActivityReader(), history = ClaudeActivityState()
        for record in historicalReader.read(home: home, discover: true, now: now).records { history.consume(record, now: now) }
        XCTAssertEqual(history.activities.first?.phase, .completed)
        XCTAssertTrue(history.activities.first?.isHistoricalCompletion ?? false)
    }

    func testParentWrittenAfterTheEndingReleasesTheDeferredEndingInNativeSshAndReplay() throws {
        let home = URL(fileURLWithPath: "/private/tmp/pacer-claude-late-parent-" + UUID().uuidString)
        let project = home.appendingPathComponent("projects/synthetic")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = project.appendingPathComponent(session + ".jsonl")
        // The answer and stop reach the file before the tool result they
        // descend from; the result carries no promptId of its own.
        var rows = ending
        rows[3].removeValue(forKey: "promptId")
        rows = [rows[0], rows[2], rows[1], rows[4], rows[5], rows[3]]
        try bytes([rows[0]]).write(to: file)
        var reader = ClaudeActivityReader(), native = runningState()
        for record in reader.read(home: home, discover: true, now: now).records { native.consume(record, now: now) }
        var projected: [Data] = []
        for (index, row) in rows.dropFirst().enumerated() {
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd(); try handle.write(contentsOf: bytes([row])); try handle.close()
            let result = reader.read(home: home, discover: false, now: now)
            projected += result.records
            for record in result.records { native.consume(record, now: now) }
            if index == 3 { XCTAssertEqual(native.activities.first?.phase, .running, "An ending without a proven owner waits") }
        }
        XCTAssertEqual(native.activities.first?.phase, .completed)
        XCTAssertEqual(native.activities.first?.turnID, prompt)
        XCTAssertFalse(native.activities.first?.isHistoricalCompletion ?? true)
        let nativeText = projected.map { String(decoding: $0, as: UTF8.self) }.joined()
        XCTAssertFalse(nativeText.contains("PRIVATE") || nativeText.contains(ClaudeTranscriptContext.pendingOwner))

        try bytes([rows[0]]).write(to: file)
        let fixture = home.appendingPathComponent("rows.json")
        try JSONSerialization.data(withJSONObject: Array(rows.dropFirst())).write(to: fixture)
        let program = "tailer=Tailer(pathlib.Path(sys.argv[1]));tailer.discover();chunks=[tailer.read()]\nfor row in json.loads(pathlib.Path(sys.argv[3]).read_text()):\n with open(sys.argv[2],'ab') as stream:stream.write((json.dumps(row)+'\\n').encode())\n tailer.poll();chunks.append(tailer.read())\ntailer.close();print(json.dumps(chunks))\n"
        let output = try ssh(program, arguments: [home.path, file.path, fixture.path])
        let chunks = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [[[String: Any]]])
        var remote = runningState(remote: true)
        for (index, chunk) in chunks.enumerated() {
            remote.consume(ClaudeActivityRecord.encode(["kind": "claudeBatch", "records": chunk])!, now: now)
            if index == 4 { XCTAssertEqual(remote.activities.first?.phase, .running) }
        }
        XCTAssertEqual(remote.activities.first?.phase, .completed)
        XCTAssertEqual(remote.activities.first?.turnID, prompt)
        let remoteText = String(decoding: output, as: UTF8.self)
        XCTAssertFalse(remoteText.contains("PRIVATE") || remoteText.contains(ClaudeTranscriptContext.pendingOwner))

        var historicalReader = ClaudeActivityReader(), history = ClaudeActivityState()
        for record in historicalReader.read(home: home, discover: true, now: now).records { history.consume(record, now: now) }
        XCTAssertEqual(history.activities.first?.phase, .completed)
        XCTAssertTrue(history.activities.first?.isHistoricalCompletion ?? false)
    }

    func testCompressedChainsStayCheapRepeatedRecordsKeepOwnersAndDeferredRowsStayBounded() throws {
        var context = ClaudeTranscriptContext()
        var records: [[String: Any]] = [], expected: [String?] = []
        func resolve(_ value: [String: Any]) -> String? {
            let owner = context.promptID(for: ClaudeActivityRecord.encode(value)!, sessionID: session, parentID: nil)
            records.append(value); expected.append(owner)
            return owner
        }
        // A window that starts mid-turn and an ownerless legacy root both
        // leave long unresolved chains; neither is walked again per record.
        var parent = "before-window"
        for i in 0..<1500 { XCTAssertNil(resolve(row("attachment", id: "lost-\(i)", parent: parent))); parent = "lost-\(i)" }
        XCTAssertNil(resolve(row("user", id: "legacy-root")))
        parent = "legacy-root"
        for i in 0..<1500 { XCTAssertNil(resolve(row("attachment", id: "legacy-\(i)", parent: parent))); parent = "legacy-\(i)" }
        XCTAssertLessThan(context.parentLookups, 4 * records.count, "Unresolved links are compressed")

        XCTAssertEqual(resolve(row("user", id: "root", prompt: prompt)), prompt)
        XCTAssertEqual(resolve(row("assistant", id: "repeated", parent: "root")), prompt)
        XCTAssertEqual(resolve(row("assistant", id: "repeated", parent: "never-read")), prompt, "A repeated record keeps its proven owner")
        XCTAssertEqual(resolve(row("system", id: "after-repeat", parent: "repeated")), prompt)

        var bounded = ClaudeTranscriptContext()
        func wait(_ id: String, on parent: String, item: Int) {
            XCTAssertNil(bounded.promptID(for: ClaudeActivityRecord.encode(row("system", id: id, parent: parent))!, sessionID: session, parentID: nil))
            bounded.deferLast([ClaudeActivityRecord.encode(["kind": "stopVerified", "origin": "transcript", "sessionId": session,
                "promptId": ClaudeTranscriptContext.pendingOwner, "itemId": "item-\(item)", "at": 1_800_000_000.0])!], historical: false)
        }
        func arrive(_ id: String) -> [String] {
            XCTAssertEqual(bounded.promptID(for: ClaudeActivityRecord.encode(row("user", id: id, prompt: prompt))!, sessionID: session, parentID: nil), prompt)
            return bounded.takeReleased().flatMap(\.rows).compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                .map { ($0["promptId"] as? String ?? "") + "/" + ($0["itemId"] as? String ?? "") }
        }
        for i in 0..<100 { wait("same-\(i)", on: "shared-parent", item: i) }
        XCTAssertEqual(bounded.deferredRows, 64, "One awaited ID keeps its newest rows")
        let shared = (36..<100).map { prompt + "/item-\($0)" }
        XCTAssertEqual(arrive("shared-parent"), shared)
        for i in 0..<600 { wait("wait-\(i)", on: "missing-\(i)", item: i) }
        XCTAssertEqual(bounded.deferredRows, 16, "Only the newest awaited IDs are kept")
        XCTAssertEqual(arrive("missing-0"), [], "The oldest awaited ID was evicted")
        XCTAssertEqual(arrive("missing-599"), [prompt + "/item-599"])

        let fixture = URL(fileURLWithPath: "/private/tmp/pacer-claude-compressed-" + UUID().uuidString + ".json")
        try JSONSerialization.data(withJSONObject: records).write(to: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let program = "class Counting(dict):\n lookups=0\n def get(self,key,default=None):\n  Counting.lookups+=1;return dict.get(self,key,default)\ncursor={'session':sys.argv[1],'parent':None,'context':Counting()};tailer=Tailer(pathlib.Path('/synthetic'))\nowners=[tailer.prompt_context_record(row,cursor) for row in json.loads(pathlib.Path(sys.argv[2]).read_text())]\nlate={'session':sys.argv[1],'parent':None}\ndef wait(uid,parent,item):\n tailer.prompt_context_record({'type':'system','sessionId':sys.argv[1],'uuid':uid,'parentUuid':parent},late)\n tailer.defer_record(late,[{'kind':'stopVerified','promptId':PENDING_OWNER,'itemId':'item-%d'%item}],False)\ndef arrive(uid):\n tailer.prompt_context_record({'type':'user','sessionId':sys.argv[1],'uuid':uid,'promptId':sys.argv[3]},late)\n return [row['promptId']+'/'+row['itemId'] for row in late.pop('released',[])]\ndef deferred():return sum(slot[0] for slot in late.get('deferred',{}).values())\nfor i in range(100):wait('same-%d'%i,'shared-parent',i)\nchecks=[deferred(),arrive('shared-parent')]\nfor i in range(600):wait('wait-%d'%i,'missing-%d'%i,i)\nchecks+=[deferred(),arrive('missing-0'),arrive('missing-599')]\ntailer.close();print(json.dumps({'owners':owners,'lookups':Counting.lookups,'checks':checks}))\n"
        let output = try ssh(program, arguments: [session, fixture.path, prompt])
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(result["owners"] as? [Any]).map { $0 as? String }, expected, "SSH and native ownership agree")
        XCTAssertLessThan(try XCTUnwrap(result["lookups"] as? Int), 4 * records.count)
        let checks = try XCTUnwrap(result["checks"] as? [Any])
        XCTAssertEqual(checks[0] as? Int, 64)
        XCTAssertEqual(checks[1] as? [String], shared)
        XCTAssertEqual(checks[2] as? Int, 16)
        XCTAssertEqual(checks[3] as? [String], [])
        XCTAssertEqual(checks[4] as? [String], [prompt + "/item-599"])
    }

    func testRowsDerivedFromTheDeferredFormMatchTheUnownedTranscriptInNativeAndSsh() throws {
        // Every row kind an unresolved descendant can produce, including the
        // reply-box ending that only an owned turn emits.
        let records = [
            row("user", id: "legacy-text", parent: "unread", second: 1,
                extra: ["message": ["role": "user", "content": "PRIVATE legacy prompt"]]),
            row("user", id: "legacy-block", parent: "unread", second: 1,
                extra: ["message": ["role": "user", "content": [["type": "text", "text": "PRIVATE legacy prompt"]]]]),
            row("assistant", id: "model", parent: "unread", second: 1, extra: ["requestId": "request-1", "cwd": "/private/tmp/synthetic",
                "message": ["role": "assistant", "id": "message-1", "model": "claude-synthetic", "usage": ["output_tokens": 12],
                    "stop_reason": "end_turn", "content": [["type": "thinking"], ["type": "text", "text": "PRIVATE answer"],
                        ["type": "tool_use", "id": "tool-one", "name": "AskUserQuestion"], ["type": "tool_use", "id": "tool-two", "name": "Agent"]]]]),
            row("user", id: "reply-box", parent: "unread", second: 2, extra: ["mcpMeta": ["_meta": ["claude/endTurn": true]],
                "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "tool-one", "content": "PRIVATE choice"]]]]),
            row("system", id: "stop", parent: "unread", second: 3,
                extra: ["subtype": "stop_hook_summary", "preventedContinuation": false, "hookErrors": [String](), "hookAdditionalContext": [String]()]),
            row("result", id: "result", parent: "unread", second: 4, extra: ["subtype": "success"]),
            row("attachment", id: "attachment", parent: "unread", second: 5)]
        func decoded(_ rows: [Data]) -> NSArray { rows.compactMap { try? JSONSerialization.jsonObject(with: $0) } as NSArray }
        var replyEnding = false
        for record in records {
            let parsed = try XCTUnwrap(ClaudeTranscriptFields(ClaudeActivityRecord.encode(record)!))
            let owned = ClaudeActivityRecord.transcript(parsed, sessionID: session, promptID: ClaudeTranscriptContext.pendingOwner)
            replyEnding = replyEnding || decoded(owned).contains { ($0 as? [String: Any])?["awaitsReply"] as? Bool == true }
            XCTAssertEqual(decoded(ClaudeTranscriptContext.unowned(owned)), decoded(ClaudeActivityRecord.transcript(parsed, sessionID: session)),
                record["uuid"] as? String ?? "")
        }
        XCTAssertTrue(replyEnding, "The fixture covers the owned-only ending")
        let data = try ssh("rows=json.loads(sys.argv[2])\nprint(json.dumps([unowned_rows(transcript_record(row,sys.argv[1],None,PENDING_OWNER))==transcript_record(row,sys.argv[1]) for row in rows]))\n",
            arguments: [session, String(decoding: try JSONSerialization.data(withJSONObject: records), as: UTF8.self)])
        XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Bool]), Array(repeating: true, count: records.count))
    }

    func testUnresolvedLegacyPromptPreservesTheCurrentTurnInNativeAndSsh() throws {
        let next = "00000000-0000-4000-8000-000000000003"
        let stop: [String: Any] = ["subtype": "stop_hook_summary", "preventedContinuation": false,
            "hookErrors": [String](), "hookAdditionalContext": [String]()]
        let appends = [
            row("user", id: "legacy", parent: "late-parent", second: 2,
                extra: ["message": ["role": "user", "content": "PRIVATE unresolved legacy prompt"]]),
            row("system", id: "legacy-stop", parent: "legacy", second: 3, extra: stop),
            row("user", id: "next-start", prompt: next, second: 4,
                extra: ["origin": ["kind": "human"], "message": ["role": "user", "content": "PRIVATE next prompt"]]),
            row("attachment", id: "late-parent", parent: "start", second: 1),
            row("system", id: "next-stop", parent: "next-start", second: 5, extra: stop)
        ]
        // No Hook: transcript fallback must protect both a running turn and
        // an already completed turn while the legacy record remains unowned.
        for completed in [false, true] {
            let home = URL(fileURLWithPath: "/private/tmp/pacer-claude-legacy-" + UUID().uuidString)
            let project = home.appendingPathComponent("projects/synthetic")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }
            let file = project.appendingPathComponent(session + ".jsonl")
            let baseline = [ending[0]] + (completed ? [row("system", id: "old-stop", parent: "start", second: 1, extra: stop)] : [])
            try bytes(baseline).write(to: file)
            var reader = ClaudeActivityReader(), native = ClaudeActivityState()
            for record in reader.read(home: home, discover: true, now: now).records { native.consume(record, now: now) }
            let originalPhase: ActivityPhase = completed ? .completed : .running
            XCTAssertEqual(native.activities.first?.phase, originalPhase)
            XCTAssertEqual(native.activities.first?.turnID, prompt)
            func check(_ state: ClaudeActivityState, at index: Int) {
                XCTAssertEqual(state.activities.first?.phase, index < 2 ? originalPhase : index < 4 ? .running : .completed)
                XCTAssertEqual(state.activities.first?.turnID, index < 2 ? prompt : next,
                    "Unknown legacy prompts cannot switch turns; their late replay cannot replace the next owned turn")
            }
            var projected = Data()
            for (index, value) in appends.enumerated() {
                let handle = try FileHandle(forWritingTo: file)
                try handle.seekToEnd(); try handle.write(contentsOf: bytes([value])); try handle.close()
                for record in reader.read(home: home, discover: false, now: now).records {
                    projected.append(record); native.consume(record, now: now)
                }
                check(native, at: index)
            }
            XCTAssertFalse(String(decoding: projected, as: UTF8.self).contains("PRIVATE"))
            XCTAssertFalse(String(decoding: projected, as: UTF8.self).contains(ClaudeTranscriptContext.pendingOwner))

            try bytes(baseline).write(to: file)
            let fixture = home.appendingPathComponent("appends.json")
            try JSONSerialization.data(withJSONObject: appends).write(to: fixture)
            let program = "tailer=Tailer(pathlib.Path(sys.argv[1]));tailer.discover();chunks=[tailer.read()]\nfor row in json.loads(pathlib.Path(sys.argv[3]).read_text()):\n with open(sys.argv[2],'ab') as stream:stream.write((json.dumps(row)+'\\n').encode())\n tailer.poll();chunks.append(tailer.read())\ntailer.close();print(json.dumps(chunks))\n"
            let output = try ssh(program, arguments: [home.path, file.path, fixture.path])
            let chunks = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [[[String: Any]]])
            XCTAssertEqual(chunks.count, appends.count + 1)
            var remote = ClaudeActivityState(sourceID: "synthetic-ssh", sourceName: nil)
            for (index, chunk) in chunks.enumerated() {
                remote.consume(ClaudeActivityRecord.encode(["kind": "claudeBatch", "records": chunk])!, now: now)
                if index == 0 {
                    XCTAssertEqual(remote.activities.first?.phase, originalPhase)
                    XCTAssertEqual(remote.activities.first?.turnID, prompt)
                } else { check(remote, at: index - 1) }
            }
            XCTAssertFalse(String(decoding: output, as: UTF8.self).contains("PRIVATE"))
            XCTAssertFalse(String(decoding: output, as: UTF8.self).contains(ClaudeTranscriptContext.pendingOwner))
        }
    }

    func testLateParentStaysBoundToItsOriginalPromptAndCannotEndTheNextPrompt() throws {
        let next = "00000000-0000-4000-8000-000000000003"
        let rows = [row("user", id: "old", prompt: prompt),
            row("attachment", id: "bridge", parent: "late"), row("user", id: "new", prompt: next, second: 1),
            row("user", id: "late", parent: "old", prompt: prompt, second: 2),
            row("system", id: "stop", parent: "bridge", second: 3,
                extra: ["subtype": "stop_hook_summary", "preventedContinuation": false, "hookErrors": [String](), "hookAdditionalContext": [String]()])]
        var context = ClaudeTranscriptContext(), state = runningState()
        var resolved: [String?] = []
        for row in rows {
            let raw = ClaudeActivityRecord.encode(row)!
            let owner = context.promptID(for: raw, sessionID: session, parentID: nil)
            resolved.append(owner)
            // Model the independently observed start of the user's next turn.
            if row["uuid"] as? String == "new" {
                state.consume(ClaudeActivityRecord.encode(["kind": "prompt", "origin": "hook", "sessionId": session,
                    "promptId": next, "at": 1_800_000_001.0])!, now: now)
            }
            for record in ClaudeActivityRecord.transcript(raw, sessionID: session, promptID: owner) { state.consume(record, now: now) }
        }
        XCTAssertEqual(resolved.last!, prompt)
        XCTAssertEqual(state.activities.first?.phase, .running)
        XCTAssertEqual(state.activities.first?.turnID, next)
        let data = try ssh("cursor={'session':sys.argv[1],'parent':None}\nrows=json.loads(sys.argv[2]);tailer=Tailer(pathlib.Path('/synthetic'))\nprint(json.dumps([tailer.prompt_context_record(row,cursor) for row in rows]))\ntailer.close()\n",
            arguments: [session, String(decoding: try JSONSerialization.data(withJSONObject: rows), as: UTF8.self)])
        let remote = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Any])
        XCTAssertEqual(remote.last as? String, prompt)
        XCTAssertTrue(remote[1] is NSNull, "An unresolved attachment does not borrow the currently active prompt")
    }

    func testMissingForeignCyclicAndEvictedParentsStayUnknownWhileLongOwnedChainsSurvive() throws {
        var context = ClaudeTranscriptContext()
        var records: [[String: Any]] = [], expected: [String?] = []
        func resolve(_ value: [String: Any]) -> String? {
            let owner = context.promptID(for: ClaudeActivityRecord.encode(value)!, sessionID: session, parentID: nil)
            records.append(value); expected.append(owner)
            return owner
        }
        XCTAssertEqual(resolve(row("user", id: "root", prompt: prompt)), prompt)
        XCTAssertNil(resolve(row("attachment", id: "pending", parent: "future")))
        XCTAssertNil(resolve(row("attachment", id: "cycle-a", parent: "cycle-b")))
        XCTAssertNil(resolve(row("attachment", id: "cycle-b", parent: "cycle-a")))
        XCTAssertNil(resolve(row("system", id: "cycle-end", parent: "cycle-b")))
        var foreign = row("user", id: "future", prompt: prompt); foreign["sessionId"] = "foreign-session"
        XCTAssertNil(resolve(foreign))
        XCTAssertNil(resolve(row("system", id: "missing-end", parent: "pending")))
        var parent = "root"
        for i in 0..<600 {
            let id = "chain-\(i)"
            XCTAssertEqual(resolve(row("attachment", id: id, parent: parent)), prompt)
            parent = id
        }
        XCTAssertNil(resolve(row("system", id: "evicted-root", parent: "root")))
        XCTAssertEqual(resolve(row("user", id: "future", prompt: prompt)), prompt)
        XCTAssertNil(resolve(row("system", id: "evicted-pending", parent: "pending")), "An evicted unresolved edge cannot guess ownership")
        context = ClaudeTranscriptContext()
        records.append(["reset": true])
        XCTAssertNil(resolve(row("system", id: "after-gap", parent: parent)), "Resetting after a gap drops all ownership links")
        let fixture = URL(fileURLWithPath: "/private/tmp/pacer-claude-context-" + UUID().uuidString + ".json")
        try JSONSerialization.data(withJSONObject: records).write(to: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let program = "cursor={'session':sys.argv[1],'parent':None};tailer=Tailer(pathlib.Path('/synthetic'));owners=[];largest=0\nfor row in json.loads(pathlib.Path(sys.argv[2]).read_text()):\n if row.get('reset'):\n  cursor={'session':sys.argv[1],'parent':None};continue\n owners.append(tailer.prompt_context_record(row,cursor));largest=max(largest,len(cursor.get('context',{})))\ntailer.close();print(json.dumps({'owners':owners,'largest':largest}))\n"
        let output = try ssh(program, arguments: [session, fixture.path])
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
        let owners = try XCTUnwrap(result["owners"] as? [Any]).map { $0 as? String }
        XCTAssertEqual(owners, expected, "SSH and native ownership decisions agree at every boundary")
        XCTAssertLessThanOrEqual(try XCTUnwrap(result["largest"] as? Int), 512)
    }
}
