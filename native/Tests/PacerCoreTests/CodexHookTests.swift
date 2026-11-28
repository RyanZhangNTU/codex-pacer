import XCTest
@testable import PacerCore

final class CodexHookTests: XCTestCase {
    private let thread = "019a0000-0000-7000-8000-000000000001"

    private func line(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func row(_ extra: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = ["v": 1, "hook": 1, "at": 1_800_000_000.25, "event": "Stop", "thread": thread, "turn": "turn-1",
                                    "agent": NSNull(), "agentType": NSNull(), "transcript": "/home/a/.codex/sessions/2026/11/21/rollout.jsonl",
                                    "agentTranscript": NSNull(), "approval": NSNull(), "reason": NSNull()]
        for (key, item) in extra { value[key] = item }
        return value
    }

    func testSpoolRowsDecodeOnlyKnownEventsWithIdentifiersAndAbsolutePaths() throws {
        let decoded = try XCTUnwrap(CodexHookEvent.decode(line(row())))
        XCTAssertEqual(decoded.kind, .stop); XCTAssertEqual(decoded.thread, thread); XCTAssertEqual(decoded.turn, "turn-1")
        XCTAssertEqual(decoded.at.timeIntervalSince1970, 1_800_000_000.25)
        XCTAssertEqual(CodexHookEvent.decode(try line(row(["event": "PermissionRequest", "approval": "exec"])))?.approval, .exec)
        XCTAssertNil(CodexHookEvent.decode(try line(row(["v": 2]))), "A newer spool format is not guessed at")
        XCTAssertNil(CodexHookEvent.decode(try line(row(["event": "PreToolUse"]))))
        XCTAssertNil(CodexHookEvent.decode(try line(row(["thread": "../escape"]))))
        XCTAssertNil(CodexHookEvent.decode(try line(row(["turn": "has space"]))))
        XCTAssertNil(CodexHookEvent.decode(try line(row(["approval": "anything"]))))
        XCTAssertNil(CodexHookEvent.decode(try line(row(["transcript": 3]))))
        XCTAssertNil(CodexHookEvent.decode(Data("{\"v\":1".utf8)))
        XCTAssertNil(CodexHookEvent.decode(Data(repeating: 32, count: 9 * 1024)))
    }

    func testOnlyRolloutsInsideTheCodexHomeAreAccepted() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-codex-hook-paths", isDirectory: true)
        let home = root.appendingPathComponent(".codex", isDirectory: true)
        func path(_ relative: String, in base: URL? = nil) -> String { (base ?? home).appendingPathComponent(relative).path }
        XCTAssertNotNil(CodexHookSpool.transcript(path("sessions/2026/11/21/rollout-x.jsonl"), home: home))
        XCTAssertNotNil(CodexHookSpool.transcript(path("archived_sessions/rollout-x.jsonl"), home: home))
        XCTAssertNil(CodexHookSpool.transcript(home.path + "/sessions/../auth.jsonl", home: home))
        XCTAssertNil(CodexHookSpool.transcript(path("config.jsonl"), home: home))
        XCTAssertNil(CodexHookSpool.transcript(path("sessions/rollout.json"), home: home))
        XCTAssertNil(CodexHookSpool.transcript(path("sessions/rollout.jsonl", in: root.appendingPathComponent("other")), home: home))
        XCTAssertNil(CodexHookSpool.transcript(path("sessions/rollout.jsonl", in: root.appendingPathComponent(".codex-other")), home: home),
                     "A sibling whose name starts with the home's is outside it")
        XCTAssertNil(CodexHookSpool.transcript(home.path + "/sessions/../../outside/sessions/rollout.jsonl", home: home))
        XCTAssertNil(CodexHookSpool.transcript("sessions/rollout.jsonl", home: home))
        XCTAssertNil(CodexHookSpool.transcript(nil, home: home))
        let otherCase = path("sessions/2026/11/21/rollout-x.jsonl", in: root.appendingPathComponent(".CODEX", isDirectory: true))
        #if os(Windows)
        XCTAssertNotNil(CodexHookSpool.transcript(otherCase, home: home), "Windows compares names without case")
        #else
        XCTAssertNil(CodexHookSpool.transcript(otherCase, home: home), "POSIX paths keep their case")
        #endif
        // The home's own form decides, on every platform.
        let windowsHome = URL(fileURLWithPath: "/C:/Users/a/.codex", isDirectory: true)
        XCTAssertNotNil(CodexHookSpool.transcript(#"C:\Users\A\.CODEX\sessions\2026\11\21\rollout-x.jsonl"#, home: windowsHome),
                        "A Windows home compares names without case")
        XCTAssertNil(CodexHookSpool.transcript(#"C:\Users\a\.codex\sessions\..\auth.jsonl"#, home: windowsHome))
        XCTAssertNil(CodexHookSpool.transcript("/Users/a/.codex/sessions/rollout-x.jsonl", home: windowsHome))
    }

    func testThePluginDefinesTheFixedHooksAndOnlySessionEndWaits() throws {
        let files = try CodexHookPlugin.files(command: "'/home/a/.codex/pacer/bin/codex-hook'", commandWindows: nil)
        XCTAssertEqual(files.map(\.relativePath), [".agents/plugins/marketplace.json", "plugins/pacer-hooks/.codex-plugin/plugin.json",
                                                   "plugins/pacer-hooks/hooks/hooks.json"])
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: files[1].data) as? [String: Any])
        XCTAssertEqual(manifest["version"] as? String, "1.0.0", "A new version makes Codex ask the user to review every hook again")
        XCTAssertEqual(manifest["hooks"] as? String, "./hooks/hooks.json")
        let hooks = try XCTUnwrap((JSONSerialization.jsonObject(with: files[2].data) as? [String: Any])?["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(Set(hooks.keys), Set(CodexHookEvent.Kind.allCases.map(\.rawValue)))
        for (event, groups) in hooks {
            XCTAssertEqual(groups.count, 1, event)
            let handlers = try XCTUnwrap(groups[0]["hooks"] as? [[String: Any]])
            XCTAssertEqual(handlers.count, 1, event)
            let handler = handlers[0]
            XCTAssertEqual(handler["command"] as? String, "'/home/a/.codex/pacer/bin/codex-hook'")
            XCTAssertNil(handler["commandWindows"])
            XCTAssertEqual(handler["async"] as? Bool, event == "SessionEnd" ? nil : true, event)
            XCTAssertLessThanOrEqual(handler["timeout"] as? Int ?? 99, ["SessionEnd", "Interrupt"].contains(event) ? 3 : 10, event)
            XCTAssertEqual(groups[0]["matcher"] as? String, event == "PermissionRequest" ? "*" : nil, event)
        }
        let windows = try CodexHookPlugin.files(command: nil, commandWindows: "& \"C:\\Users\\a\\.codex\\pacer\\bin\\codex-hook.cmd\"")
        let stop = try XCTUnwrap(((JSONSerialization.jsonObject(with: windows[2].data) as? [String: Any])?["hooks"] as? [String: [[String: Any]]])?["Stop"])
        XCTAssertNil((stop[0]["hooks"] as? [[String: Any]])?[0]["command"])
        XCTAssertNotNil((stop[0]["hooks"] as? [[String: Any]])?[0]["commandWindows"])
        XCTAssertThrowsError(try CodexHookPlugin.files(command: nil, commandWindows: nil))
        XCTAssertEqual(try CodexHookPlugin.files(command: "c", commandWindows: nil).map(\.data),
                       try CodexHookPlugin.files(command: "c", commandWindows: nil).map(\.data), "The definitions are byte-stable")
    }

    func testThePOSIXLauncherQuotesItsPathsAndNeverAnswersAHook() {
        let home = URL(fileURLWithPath: "/Users/a b/it's/.codex")
        XCTAssertEqual(CodexHookProgram.posixCommand(home: home), "'/Users/a b/it'\\''s/.codex/pacer/bin/codex-hook'")
        let launcher = String(decoding: CodexHookProgram.posixLauncher(home: home), as: UTF8.self)
        XCTAssertTrue(launcher.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(launcher.contains("exec python3 -S -B '/Users/a b/it'\\''s/.codex/pacer/codex_hook.py' hook '/Users/a b/it'\\''s/.codex' >/dev/null 2>&1"))
        XCTAssertNotNil(CodexHookProgram.source)
    }

    func testHooksListReadsEventNameAndEffectiveTrustForPacersPlugin() throws {
        let plugin = CodexHookPlugin.id
        let hooks: [[String: Any]] = [
            ["pluginId": plugin, "eventName": "postCompact", "trustStatus": "modified"],
            ["pluginId": "other", "eventName": "stop", "trustStatus": "untrusted"],
            ["pluginId": plugin, "eventName": "userPromptSubmit", "trustStatus": "trusted", "enabled": true],
            ["pluginId": plugin, "eventName": "preCompact", "trustStatus": "trusted", "enabled": false],
            ["pluginId": plugin, "eventName": "stop"]
        ]
        let bytes = try line(["data": [["hooks": hooks], ["hooks": hooks]]])
        XCTAssertEqual(try CodexClient.decodeHookTrust(bytes, pluginID: plugin), [
            .init(event: .postCompact, state: "modified"), .init(event: .userPromptSubmit, state: "trusted"),
            .init(event: .preCompact, state: "disabled"), .init(event: .stop, state: "unknown")
        ])
    }

    func testStatusNeedsEveryCoreHookTrustedAndNoticesASilentHook() {
        let now = Date(), all = CodexHookEvent.Kind.allCases.map { CodexHookTrust(event: $0, state: "trusted") }
        func status(enabled: Bool = true, supports: Bool? = true, installed: Bool? = true, trust: [CodexHookTrust]? = all,
                    hook: Date? = nil, turn: Date? = nil) -> CodexHookStatus {
            CodexHookStatus.evaluate(enabled: enabled, supportsHooks: supports, installed: installed, trust: trust,
                                     lastHookEvent: hook, lastCodexTurn: turn, now: now)
        }
        XCTAssertEqual(status(enabled: false), .off)
        XCTAssertEqual(status(supports: false), .needsCodexUpdate)
        XCTAssertEqual(status(installed: nil), .installFailed)
        XCTAssertEqual(status(installed: false), .notInstalled)
        func optionalPending(_ trust: [CodexHookTrust]) -> Int {
            CodexHookSetupResult(supportsHooks: true, installed: true, trust: trust).optionalPending
        }
        let core = all.filter { $0.event != .preCompact && $0.event != .postCompact }
        let optional = [CodexHookTrust(event: .postCompact, state: "modified"), .init(event: .preCompact, state: "untrusted")]
        XCTAssertEqual(all.count, 9)
        XCTAssertEqual(optionalPending(all), 0)
        XCTAssertEqual(status(trust: optional + core), .running)
        XCTAssertEqual(optionalPending(optional + core), 2)
        XCTAssertEqual(status(trust: optional + core, turn: now), .notRunning)
        let mixed = optional + core.dropFirst() + [.init(event: core[0].event, state: "disabled")]
        XCTAssertEqual(status(trust: mixed), .needsApproval(count: 1))
        XCTAssertEqual(optionalPending(mixed), 2)
        XCTAssertEqual(status(trust: [.init(event: core[0].event, state: "untrusted"), .init(event: core[1].event, state: "modified")]
                              + core.dropFirst(2)), .needsApproval(count: 2))
        XCTAssertEqual(core.count, 7)
        XCTAssertEqual(status(trust: core), .running)
        XCTAssertEqual(optionalPending(core), 0)
        XCTAssertEqual(status(trust: Array(mixed.dropLast())), .installFailed, "Optional events cannot stand in for a missing core event")
        XCTAssertEqual(status(trust: core.dropFirst() + [core[1]]), .installFailed, "A duplicate cannot stand in for a missing event")
        XCTAssertEqual(status(trust: nil), .notInstalled, "Installed hooks whose trust Codex did not report are not running yet")
        XCTAssertTrue(CodexHookSetupResult(supportsHooks: true, installed: true, trust: nil).awaitsTrust)
        XCTAssertFalse(CodexHookSetupResult(supportsHooks: true, installed: true, trust: all).awaitsTrust)
        XCTAssertFalse(CodexHookSetupResult(supportsHooks: false, installed: true, trust: nil).awaitsTrust)
        XCTAssertFalse(CodexHookSetupResult(supportsHooks: nil, installed: nil, trust: nil).awaitsTrust)
        XCTAssertEqual(status(), .running)
        XCTAssertEqual(status(turn: now.addingTimeInterval(-30)), .notRunning, "Codex ran a turn and no hook wrote a row")
        XCTAssertEqual(status(hook: now.addingTimeInterval(-40), turn: now.addingTimeInterval(-30)), .running)
        XCTAssertEqual(status(turn: now.addingTimeInterval(-3600)), .running, "Old Codex activity proves nothing")
        XCTAssertEqual(CodexHookStatus.evaluate(enabled: true, supportsHooks: true, installed: true, trust: all, lastHookEvent: nil,
                                                lastCodexTurn: now.addingTimeInterval(-30), trustedAt: now.addingTimeInterval(-20), now: now),
                       .running, "A turn before the user allowed the hooks ran without them")
        XCTAssertEqual(CodexHookStatus.evaluate(enabled: true, supportsHooks: true, installed: true, trust: all, lastHookEvent: nil,
                                                lastCodexTurn: now.addingTimeInterval(-10), trustedAt: now.addingTimeInterval(-20), now: now),
                       .notRunning)
    }

    func testTrustIsAskedWhenCodexConfigChangesOrOnceAMinuteForAnHour() {
        let start = Date(timeIntervalSince1970: 1_000_000), stamp = start.addingTimeInterval(-500)
        var watch = CodexHookTrustWatch(stamp: stamp, now: start)
        XCTAssertFalse(watch.shouldCheck(stamp: stamp, now: start.addingTimeInterval(2)), "An unchanged config asks nothing")
        XCTAssertTrue(watch.shouldCheck(stamp: start.addingTimeInterval(3), now: start.addingTimeInterval(4)), "Codex wrote its config")
        XCTAssertFalse(watch.shouldCheck(stamp: start.addingTimeInterval(3), now: start.addingTimeInterval(6)), "Once per change")
        XCTAssertFalse(watch.shouldCheck(stamp: start.addingTimeInterval(3), now: start.addingTimeInterval(63)))
        XCTAssertTrue(watch.shouldCheck(stamp: start.addingTimeInterval(3), now: start.addingTimeInterval(64)), "A minute later it asks anyway")
        var later = start.addingTimeInterval(64)
        for _ in 1..<CodexHookTrustWatch.fallbackLimit {
            later += CodexHookTrustWatch.fallback
            XCTAssertTrue(watch.shouldCheck(stamp: start.addingTimeInterval(3), now: later))
        }
        XCTAssertFalse(watch.shouldCheck(stamp: start.addingTimeInterval(3), now: later + 3600), "The fallback gives up after an hour")
        XCTAssertTrue(watch.shouldCheck(stamp: nil, now: later + 3601), "A config change still asks")

        var retry = CodexHookTrustWatch(stamp: stamp, now: start, due: true)
        XCTAssertTrue(retry.shouldCheck(stamp: stamp, now: start.addingTimeInterval(2)), "A trust read that failed is asked again at once")
        XCTAssertFalse(retry.shouldCheck(stamp: stamp, now: start.addingTimeInterval(4)), "and then like any other wait")
        XCTAssertTrue(retry.shouldCheck(stamp: stamp, now: start.addingTimeInterval(62)))

        var missing = CodexHookTrustWatch(stamp: nil, now: start)
        XCTAssertFalse(missing.shouldCheck(stamp: nil, now: start.addingTimeInterval(2)))
        XCTAssertTrue(missing.shouldCheck(stamp: start, now: start.addingTimeInterval(4)), "Codex created its config")
        XCTAssertEqual(CodexHookTrustWatch.trustFile(home: URL(fileURLWithPath: "/h/.codex")).path, "/h/.codex/config.toml")
        XCTAssertEqual(CodexHookTrustWatch.settingsURL.absoluteString, "codex://settings")
    }

    func testCodexClientRefusesMethodsThatCouldStartOrSteerATurn() {
        for method in ["turn/start", "thread/start", "thread/resume", "turn/interrupt", "thread/archive", "command/exec"] {
            XCTAssertFalse(CodexClient.allowedMethods.contains(method), method)
        }
        XCTAssertTrue(CodexClient.allowedMethods.isSuperset(of: ["hooks/list", "thread/read", "thread/list", "thread/goal/get"]))
    }
}

final class CodexHookStateTests: XCTestCase {
    private let thread = "019a0000-0000-7000-8000-000000000011", child = "019a0000-0000-7000-8000-000000000012"
    private func home() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-hook-state-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: CodexHookSpool.folder(home: home), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }
    private func signature(_ url: URL) -> (identity: String, size: UInt64)? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (values[.size] as? NSNumber)?.uint64Value else { return nil }
        return (String((values[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0), size)
    }
    private func append(_ home: URL, _ event: String, turn: String? = nil, agent: String? = nil, approval: String? = nil,
                        transcript: String? = nil, agentTranscript: String? = nil, at: Date = Date(), to url: URL? = nil) throws {
        let row: [String: Any] = ["v": 1, "hook": 1, "at": at.timeIntervalSince1970, "event": event, "thread": thread,
            "turn": turn ?? NSNull(), "agent": agent ?? NSNull(), "agentType": NSNull(),
            "transcript": transcript ?? home.appendingPathComponent("sessions/2026/11/21/rollout-\(thread).jsonl").path,
            "agentTranscript": agentTranscript ?? NSNull(), "approval": approval ?? NSNull(), "reason": NSNull()]
        let file = url ?? CodexHookSpool.current(home: home)
        var data = (try? Data(contentsOf: file)) ?? Data()
        data += try JSONSerialization.data(withJSONObject: row) + Data([10])
        try data.write(to: file)
    }

    func testTurnsApprovalsAndEndingsFollowTheSpoolInOrder() throws {
        let home = try home(); var state = CodexHookState(), now = Date()
        try append(home, "UserPromptSubmit", turn: "t1")
        XCTAssertTrue(state.read(home: home, now: now, signature: signature))
        XCTAssertEqual(state.threads[thread]?.openTurn, "t1")
        XCTAssertEqual(state.transcripts(now: now, recent: 60).count, 1)
        try append(home, "PermissionRequest", turn: "t1", approval: "exec")
        state.read(home: home, now: now, signature: signature)
        XCTAssertEqual(state.threads[thread]?.approval?.kind, .exec)
        try append(home, "Stop", turn: "t1")
        state.read(home: home, now: now, signature: signature)
        XCTAssertNil(state.threads[thread]?.openTurn); XCTAssertNil(state.threads[thread]?.approval)
        XCTAssertFalse(state.read(home: home, now: now, signature: signature), "Nothing new, nothing changed")
        try append(home, "UserPromptSubmit", turn: "t2"); try append(home, "SessionEnd")
        state.read(home: home, now: now, signature: signature)
        XCTAssertNil(state.threads[thread]?.openTurn); XCTAssertNotNil(state.threads[thread]?.endedAt)
        XCTAssertEqual(state.transcripts(now: now.addingTimeInterval(120), recent: 60).count, 0, "An ended, quiet thread is no longer followed")
    }

    func testRotationKeepsReadingTheOldTailBeforeTheNewFile() throws {
        let home = try home(); var state = CodexHookState(), now = Date()
        try append(home, "UserPromptSubmit", turn: "t1")
        state.read(home: home, now: now, signature: signature)
        try append(home, "Stop", turn: "t1")
        try FileManager.default.moveItem(at: CodexHookSpool.current(home: home), to: CodexHookSpool.previous(home: home))
        try append(home, "UserPromptSubmit", turn: "t2")
        state.read(home: home, now: now, signature: signature)
        XCTAssertEqual(state.threads[thread]?.openTurn, "t2", "The rotated file's Stop and the new file's start both apply, in order")
    }

    func testOldRowsAndForeignTranscriptsAreIgnored() throws {
        let home = try home(); var state = CodexHookState(), now = Date()
        try append(home, "UserPromptSubmit", turn: "old", at: now.addingTimeInterval(-CodexHookState.retention - 60))
        try append(home, "UserPromptSubmit", turn: "t1", transcript: "/etc/rollout.jsonl")
        state.read(home: home, now: now, signature: signature)
        XCTAssertEqual(state.threads[thread]?.openTurn, "t1")
        XCTAssertNil(state.threads[thread]?.transcript, "A transcript outside the Codex home is never followed")
    }

    func testSubagentsAreFoundByNameWhileRunningAndByPathWhenTheyStop() throws {
        let home = try home(); var state = CodexHookState(), now = Date()
        let parent = home.appendingPathComponent("sessions/2026/11/21/rollout-2026-11-21T10-00-00-\(thread).jsonl")
        let childFile = parent.deletingLastPathComponent().appendingPathComponent("rollout-2026-11-21T10-01-00-\(child).jsonl")
        try FileManager.default.createDirectory(at: parent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: parent); try Data().write(to: childFile)
        try append(home, "UserPromptSubmit", turn: "t1", transcript: parent.path)
        try append(home, "SubagentStart", turn: "c1", agent: child, transcript: parent.path)
        state.read(home: home, now: now, signature: signature)
        XCTAssertNil(state.children[child]?.transcript)
        state.locateChildren(home: home, now: now) { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
        XCTAssertEqual(state.children[child]?.transcript?.lastPathComponent, childFile.lastPathComponent)
        XCTAssertEqual(Set(state.transcripts(now: now, recent: 60).map(\.url.lastPathComponent)), [parent.lastPathComponent, childFile.lastPathComponent])
        try append(home, "SubagentStop", turn: "c1", agent: child, transcript: parent.path, agentTranscript: childFile.path)
        state.read(home: home, now: now, signature: signature)
        XCTAssertNotNil(state.children[child]?.stoppedAt)
    }
}

final class CodexHookReaderTests: XCTestCase {
    private let thread = "019a0000-0000-7000-8000-000000000021"
    private func record(_ type: String, _ payload: [String: Any], at date: Date) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": ISO8601DateFormatter().string(from: date), "payload": payload]) + Data([10])
    }
    private func temporaryHome(_ prefix: String) -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }
    /// A rollout that opens turn `t1` at `start`.
    private func rollout(_ home: URL, _ id: String, day: String = "2026/11/21", start: Date) throws -> URL {
        let folder = home.appendingPathComponent("sessions/" + day, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("rollout-2026-11-21T10-00-00-\(id).jsonl")
        try (record("session_meta", ["id": id, "originator": "Codex Desktop", "cwd": "/fixture"], at: start)
            + record("event_msg", ["type": "task_started", "turn_id": "t1"], at: start)).write(to: file)
        return file
    }
    private func append(_ file: URL, _ data: Data) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
    private func phase(_ activities: [SessionActivity], _ thread: String) -> ActivityPhase? {
        activities.first { $0.threadID == thread }?.phase
    }

    func testRolloutAndHooksShareCompactionEvidenceAcrossReads() async throws {
        let home = temporaryHome("pacer-context-"), start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let file = try rollout(home, thread, start: start)
        let reader = LocalActivityReader()
        func at(_ seconds: Int) -> Date { start.addingTimeInterval(Double(seconds)) }
        func hook(_ event: String, _ seconds: Int) throws {
            try CodexHookFixture.announce([file], home: home, event: event, turn: "t1", at: at(seconds))
        }
        func read(_ seconds: Int) async throws -> SessionActivity {
            let snapshot = await reader.read(home: home, now: at(seconds))
            return try XCTUnwrap(snapshot.activities.first)
        }
        func usage(_ used: Int, _ seconds: Int) throws {
            try append(file, record("event_msg", ["type": "token_count", "info": [
                "last_token_usage": ["total_tokens": used], "model_context_window": 112_000,
                "total_token_usage": ["total_tokens": 1_000_000]]], at: at(seconds)))
        }
        try hook("UserPromptSubmit", 0)
        try usage(76_000, 1)
        try hook("PreCompact", 2)
        let compacting = try await read(3)
        XCTAssertEqual(compacting.contextLevel?.fraction, 0.64)
        XCTAssertEqual(compacting.compactingSince(at: at(3)), at(2))
        try append(file, record("compacted", [:], at: at(5)))
        let compacted = try await read(5)
        XCTAssertNil(compacted.contextLevel)
        XCTAssertNil(compacted.compactingSince(at: at(5)))
        try usage(13_000, 6)
        try hook("PostCompact", 7)
        let after = try await read(7)
        XCTAssertEqual(after.contextLevel?.usedTokens, 13_000)
        try append(file, record("event_msg", ["type": "item_completed", "thread_id": thread, "turn_id": "t1",
                                               "item": ["type": "ContextCompaction"]], at: at(10)))
        let marker = try await read(10)
        XCTAssertNil(marker.contextLevel)
        XCTAssertEqual(marker.phase, .running)
        try usage(26_000, 11)
        try hook("PreCompact", 12)
        try hook("PostCompact", 13)
        try CodexHookFixture.announce([file], home: home, turn: "next", at: at(14))
        try append(file, record("event_msg", ["type": "task_started", "turn_id": "next"], at: at(14)))
        let newerTurn = try await read(15)
        XCTAssertNil(newerTurn.contextLevel, "A new prompt cannot revive usage invalidated by the previous turn's PostCompact")
        XCTAssertNil(newerTurn.compactingSince(at: at(15)))
    }

    /// A Codex that crashed sends no Stop or SessionEnd. A turn the reader already
    /// follows stops running once neither its log nor its hook has said anything
    /// for the hook's limit, while a turn whose log keeps moving runs on, however long.
    func testACrashedTurnStopsRunningAfterTheHookLimitWhileALongActiveTurnRunsOn() async throws {
        let home = temporaryHome("pacer-hook-crash-"), start = Date().addingTimeInterval(-5 * 3600)
        let crashed = "019a0000-0000-7000-8000-000000000031", active = "019a0000-0000-7000-8000-000000000032"
        let crashedFile = try rollout(home, crashed, start: start), activeFile = try rollout(home, active, start: start)
        try CodexHookFixture.announce([crashedFile, activeFile], home: home, turn: "t1", at: start)
        let reader = LocalActivityReader()
        let first = await reader.read(home: home, now: start.addingTimeInterval(2))
        XCTAssertEqual(phase(first.activities, crashed), .running)
        XCTAssertEqual(phase(first.activities, active), .running)

        // Four hours on, the active turn writes every ten minutes; the crashed one says nothing.
        for minute in stride(from: 10, through: 240, by: 10) {
            let at = start.addingTimeInterval(TimeInterval(minute * 60))
            try append(activeFile, record("event_msg", ["type": "token_count", "turn_id": "t1"], at: at))
            let result = await reader.read(home: home, now: at.addingTimeInterval(1))
            XCTAssertEqual(phase(result.activities, active), .running, "A turn whose log moves runs on at minute \(minute)")
            if minute <= 170 {
                XCTAssertEqual(phase(result.activities, crashed), .running, "The hook holds a quiet turn open for three hours, minute \(minute)")
            }
        }
        let late = await reader.read(home: home, now: start.addingTimeInterval(4 * 3600 + 60))
        XCTAssertNotEqual(phase(late.activities, crashed), .running, "Four hours without a word from the log or the hook")
        XCTAssertNotNil(phase(late.activities, crashed), "The task stays listed, unconfirmed")
        XCTAssertEqual(phase(late.activities, active), .running)
    }

    /// A Codex killed or shut down mid-turn sends nothing more. Once the turn's log
    /// has been quiet for two minutes, Pacer asks whether any process still holds
    /// its rollout open; none means the writer is gone, long before the hook's limit.
    func testAQuietTurnWhoseRolloutNoProcessHoldsStopsRunning() async throws {
        final class Calls: @unchecked Sendable {
            private let lock = NSLock(); private var names: [String] = []
            func note(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
            var all: [String] { lock.lock(); defer { lock.unlock() }; return names }
        }
        let home = temporaryHome("pacer-hook-writer-"), start = Date().addingTimeInterval(-3600)
        let lost = "019a0000-0000-7000-8000-000000000041", held = "019a0000-0000-7000-8000-000000000042"
        let unknown = "019a0000-0000-7000-8000-000000000043"
        let files = try [lost, held, unknown].map { try rollout(home, $0, start: start) }
        try CodexHookFixture.announce(files, home: home, turn: "t1", at: start)
        let calls = Calls()
        let reader = LocalActivityReader(writerProbe: { file, _ in
            calls.note(file.lastPathComponent)
            if file.lastPathComponent.contains(lost) { return false }
            return file.lastPathComponent.contains(held) ? true : nil
        })

        let early = await reader.read(home: home, now: start.addingTimeInterval(60))
        for thread in [lost, held, unknown] { XCTAssertEqual(phase(early.activities, thread), .running) }
        XCTAssertTrue(calls.all.isEmpty, "A log quiet for a minute is a tool still running")

        let quiet = await reader.read(home: home, now: start.addingTimeInterval(180))
        XCTAssertEqual(phase(quiet.activities, lost), .unknown, "No process holds the rollout: the writer is gone")
        XCTAssertEqual(phase(quiet.activities, held), .running, "Codex still holds the rollout")
        XCTAssertEqual(phase(quiet.activities, unknown), .running, "An unanswered probe keeps the earlier limits")
        XCTAssertEqual(calls.all.count, 3)

        let soon = await reader.read(home: home, now: start.addingTimeInterval(200))
        XCTAssertEqual(calls.all.count, 3, "Asked at most once a minute")
        let next = await reader.nextRunningExpiry
        XCTAssertEqual(next, start.addingTimeInterval(240), "The next read is due when the next probe is")
        XCTAssertEqual(phase(soon.activities, held), .running)

        try append(files[1], record("event_msg", ["type": "token_count", "turn_id": "t1"], at: start.addingTimeInterval(230)))
        _ = await reader.read(home: home, now: start.addingTimeInterval(250))
        XCTAssertEqual(calls.all.filter { $0.contains(held) }.count, 1, "A log that moved again is not asked about until it is quiet again")
    }

    func testWriterExitSupersedesOnlyOlderRunningHints() async throws {
        let home = temporaryHome("pacer-child-writer-"), start = Date().addingTimeInterval(-600)
        let file = try rollout(home, thread, start: start)
        try CodexHookFixture.announce([file], home: home, turn: "t1", at: start)
        func hint(at time: Date) -> [String: SessionActivity.SubagentEvidence] {
            [thread: .init(parentThreadID: "019a0000-0000-7000-8000-000000000099", state: "running", observedAt: time)]
        }
        let reader = LocalActivityReader(writerProbe: { _, _ in false })
        let lost = await reader.read(home: home, now: start.addingTimeInterval(180), subagentStates: hint(at: start))
        XCTAssertEqual(phase(lost.activities, thread), .unknown)
        let later = start.addingTimeInterval(240)
        let recovered = await reader.read(home: home, now: later, subagentStates: hint(at: later))
        XCTAssertEqual(phase(recovered.activities, thread), .running)
    }

    func testPausedGoalKeepsItsDeadlineAfterThePhysicalTurnEnds() async throws {
        let home = temporaryHome("pacer-paused-goal-"), start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 600)
        let file = try rollout(home, thread, start: start)
        try CodexHookFixture.announce([file], home: home, turn: "t1", at: start)
        try append(file, record("event_msg", ["type": "thread_goal_updated", "threadId": thread, "turnId": "t1",
            "goal": ["status": "paused", "createdAt": start.timeIntervalSince1970, "updatedAt": start.timeIntervalSince1970 + 1]], at: start.addingTimeInterval(1)))
        try append(file, record("event_msg", ["type": "task_complete", "turn_id": "t1"], at: start.addingTimeInterval(2)))
        let reader = LocalActivityReader(writerProbe: { _, _ in XCTFail("A confirmed goal pause needs no writer check"); return false })
        let result = await reader.read(home: home, now: start.addingTimeInterval(182))
        XCTAssertNotNil(result.activities.first?.codexGoalPause)
        XCTAssertEqual(result.activities.first?.codexGoalDeadline, start.addingTimeInterval(902))
    }

    /// SessionEnd closes a turn the log never ended, and its open question with it;
    /// the thread's next turn can ask again.
    func testSessionEndClearsAPendingQuestionAndTheNextTurnCanAskAgain() async throws {
        let home = temporaryHome("pacer-hook-question-"), start = Date().addingTimeInterval(-120)
        let thread = "019a0000-0000-7000-8000-000000000033"
        let file = try rollout(home, thread, start: start)
        func question(_ turn: String, _ call: String, at second: TimeInterval) throws -> Data {
            try record("response_item", ["type": "function_call", "name": "request_user_input_async", "call_id": call,
                                         "arguments": #"{"questions":[{"title":"synthetic"}]}"#], at: start.addingTimeInterval(second))
                + record("response_item", ["type": "function_call_output", "call_id": call, "output": #"{"accepted":true}"#],
                         at: start.addingTimeInterval(second + 1))
        }
        try append(file, question("t1", "first", at: 2))
        try CodexHookFixture.announce([file], home: home, turn: "t1", at: start)
        let reader = LocalActivityReader()
        let asking = await reader.read(home: home, now: start.addingTimeInterval(4))
        XCTAssertEqual(asking.requests.filter { $0.kind == .input }.count, 1)

        try CodexHookFixture.announce([file], home: home, event: "SessionEnd", at: start.addingTimeInterval(5))
        let closed = await reader.read(home: home, now: start.addingTimeInterval(6))
        XCTAssertNotEqual(phase(closed.activities, thread), .running)
        XCTAssertTrue(closed.requests.isEmpty, "A closed session has no question waiting")

        try CodexHookFixture.announce([file], home: home, turn: "t2", at: start.addingTimeInterval(7))
        try append(file, record("event_msg", ["type": "task_started", "turn_id": "t2"], at: start.addingTimeInterval(7)) + question("t2", "second", at: 8))
        let next = await reader.read(home: home, now: start.addingTimeInterval(10))
        XCTAssertEqual(phase(next.activities, thread), .running)
        XCTAssertEqual(next.requests.filter { $0.kind == .input }.count, 1, "The next turn's question shows")
    }

    /// A long turn keeps writing its rollout with no other hook event; that is no
    /// silent hook. A turn Codex ran without the hooks writes a rollout that no
    /// open turn explains, in another conversation or after its own turn ended.
    func testALongTurnIsNoSilentHookButATurnWithoutItsHookIs() async throws {
        let now = Date(), formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy/MM/dd"
        let day = formatter.string(from: now), all = CodexHookEvent.Kind.allCases.map { CodexHookTrust(event: $0, state: "trusted") }
        func touch(_ file: URL) throws { try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-10)], ofItemAtPath: file.path) }
        func status(_ reader: LocalActivityReader, _ home: URL, trustedAt: Date? = nil) async -> CodexHookStatus {
            let evidence = await reader.hookEvidence(home: home, now: now)
            return CodexHookStatus.evaluate(enabled: true, supportsHooks: true, installed: true, trust: all, lastHookEvent: evidence.lastHookEvent,
                                            lastCodexTurn: evidence.lastCodexTurn, trustedAt: trustedAt, now: now)
        }

        let home = temporaryHome("pacer-hook-silence-"), start = now.addingTimeInterval(-4 * 3600)
        let long = "019a0000-0000-7000-8000-000000000041", file = try rollout(home, long, day: day, start: start)
        try CodexHookFixture.announce([file], home: home, turn: "t1", at: start)
        let reader = LocalActivityReader()
        _ = await reader.read(home: home, now: start)
        for second in stride(from: 600, through: 4 * 3600, by: 600) {
            try append(file, record("event_msg", ["type": "token_count", "turn_id": "t1"], at: start.addingTimeInterval(TimeInterval(second))))
            _ = await reader.read(home: home, now: start.addingTimeInterval(TimeInterval(second)))
        }
        try touch(file)
        let longTurn = await status(reader, home)
        XCTAssertEqual(longTurn, .running, "The same turn still writes after its quiet-hook allowance expires")

        let other = try rollout(home, "019a0000-0000-7000-8000-000000000042", day: day, start: now.addingTimeInterval(-20))
        try touch(other)
        let missed = await status(reader, home)
        XCTAssertEqual(missed, .notRunning, "Another conversation ran a turn that no hook announced")
        let earlier = await status(reader, home, trustedAt: now.addingTimeInterval(-5))
        XCTAssertEqual(earlier, .running, "Turns before the user allowed the hooks ran without them")

        // The same conversation's next turn, long after its hook said the last one stopped.
        let ended = temporaryHome("pacer-hook-ended-"), endedFile = try rollout(ended, long, day: day, start: now.addingTimeInterval(-20 * 60))
        try CodexHookFixture.announce([endedFile], home: ended, turn: "t1", at: now.addingTimeInterval(-20 * 60))
        try CodexHookFixture.announce([endedFile], home: ended, event: "Stop", turn: "t1", at: now.addingTimeInterval(-15 * 60))
        try append(endedFile, record("event_msg", ["type": "task_started", "turn_id": "t2"], at: now.addingTimeInterval(-20)))
        try touch(endedFile)
        let endedReader = LocalActivityReader()
        _ = await endedReader.read(home: ended, now: now)
        let unannounced = await status(endedReader, ended)
        XCTAssertEqual(unannounced, .notRunning, "A new turn in a conversation whose turn had ended, without its hook")
    }

    func testPermissionRequestsWaitUntilTheLogMovesOnAndSessionEndStopsARunningTurn() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-hook-reader-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let start = Date().addingTimeInterval(-60)
        let day = home.appendingPathComponent("sessions/2026/11/21", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent("rollout-2026-11-21T10-00-00-\(thread).jsonl")
        try (record("session_meta", ["id": thread, "originator": "Codex Desktop", "cwd": "/fixture"], at: start)
            + record("event_msg", ["type": "task_started", "turn_id": "t1"], at: start.addingTimeInterval(1))).write(to: file)
        let reader = LocalActivityReader()
        try CodexHookFixture.announce([file], home: home, turn: "t1", at: start.addingTimeInterval(1))
        try CodexHookFixture.announce([file], home: home, event: "PermissionRequest", turn: "t1", approval: "exec", at: start.addingTimeInterval(5))
        let waiting = await reader.read(home: home, now: start.addingTimeInterval(6))
        XCTAssertEqual(waiting.activities.first?.phase, .running)
        XCTAssertEqual(waiting.requests.map(\.kind), [.approval])
        XCTAssertEqual(waiting.requests.first?.threadID, thread)
        XCTAssertTrue(waiting.watchURLs.contains(CodexHookSpool.current(home: home)), "Appends to the spool wake the reader")

        // The command ran after the user's answer: the log moved past the request.
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        try handle.write(contentsOf: record("event_msg", ["type": "exec_command_end", "turn_id": "t1"], at: start.addingTimeInterval(9))); try handle.close()
        let answered = await reader.read(home: home, now: start.addingTimeInterval(10))
        XCTAssertTrue(answered.requests.isEmpty)
        XCTAssertEqual(answered.activities.first?.phase, .running)

        try CodexHookFixture.announce([file], home: home, event: "SessionEnd", at: start.addingTimeInterval(12))
        let closed = await reader.read(home: home, now: start.addingTimeInterval(13))
        XCTAssertNotEqual(closed.activities.first?.phase, .running, "A Codex that quit mid-turn cannot leave the task running")
        let last = await reader.lastHookRow
        XCTAssertEqual(last?.timeIntervalSince1970 ?? 0, start.addingTimeInterval(12).timeIntervalSince1970, accuracy: 0.01)
    }

    /// Codex Desktop's Approve for Me sends a turn's approvals to Codex's own reviewer, yet
    /// Codex still fires PermissionRequest; the command then runs with no answer from the user.
    /// A turn whose context names the user as reviewer waits for them, as before.
    func testAPermissionRequestCodexReviewsItselfDoesNotWaitForTheUser() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-hook-reviewer-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let start = Date().addingTimeInterval(-120)
        let day = home.appendingPathComponent("sessions/2026/11/21", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent("rollout-2026-11-21T10-00-00-\(thread).jsonl")
        try record("session_meta", ["id": thread, "originator": "Codex Desktop", "cwd": "/fixture"], at: start).write(to: file)
        let reader = LocalActivityReader()
        for (index, reviewer) in ["auto_review", "user", "guardian_subagent"].enumerated() {
            let turn = "t\(index + 1)", at = start.addingTimeInterval(Double(index) * 30)
            let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
            try handle.write(contentsOf: record("event_msg", ["type": "task_started", "turn_id": turn], at: at.addingTimeInterval(1))
                + record("turn_context", ["turn_id": turn, "model": "gpt-fixture", "approval_policy": "on-request", "approvals_reviewer": reviewer],
                         at: at.addingTimeInterval(1.1)))
            try handle.close()
            try CodexHookFixture.announce([file], home: home, turn: turn, at: at.addingTimeInterval(1))
            try CodexHookFixture.announce([file], home: home, event: "PermissionRequest", turn: turn, approval: "exec", at: at.addingTimeInterval(5))
            let read = await reader.read(home: home, now: at.addingTimeInterval(6))
            XCTAssertEqual(read.activities.first?.phase, .running, reviewer)
            XCTAssertEqual(read.requests.map(\.kind), reviewer == "user" ? [.approval] : [],
                           "\(reviewer): only a turn the user reviews waits for them")
        }
    }

    func testNewTurnShowsItsPermissionRequestBeforeItsContextArrives() async throws {
        let home = temporaryHome("pacer-reviewer-change-"), start = Date().addingTimeInterval(-60)
        let file = try rollout(home, thread, start: start)
        try append(file, record("turn_context", ["turn_id": "t1", "approvals_reviewer": "auto_review"], at: start.addingTimeInterval(1)))
        try CodexHookFixture.announce([file], home: home, turn: "t1", at: start)
        let reader = LocalActivityReader()
        let first = await reader.read(home: home, now: start.addingTimeInterval(2))
        XCTAssertEqual(first.activities.first?.codexReviewsApprovals, true)

        try append(file, record("event_msg", ["type": "task_complete", "turn_id": "t1"], at: start.addingTimeInterval(3))
            + record("event_msg", ["type": "task_started", "turn_id": "t2"], at: start.addingTimeInterval(4)))
        try CodexHookFixture.announce([file], home: home, turn: "t2", at: start.addingTimeInterval(4))
        try CodexHookFixture.announce([file], home: home, event: "PermissionRequest", turn: "t2", approval: "exec", at: start.addingTimeInterval(5))
        let next = await reader.read(home: home, now: start.addingTimeInterval(6))
        XCTAssertEqual(next.activities.first?.turnID, "t2")
        XCTAssertEqual(next.requests.map(\.kind), [.approval])
    }

    func testAttachingToALongTurnRecoversItsApprovalReviewer() async throws {
        let home = temporaryHome("pacer-reviewer-attach-"), start = Date().addingTimeInterval(-60)
        let file = try rollout(home, thread, start: start)
        try append(file, record("turn_context", ["turn_id": "t1", "approvals_reviewer": "guardian_subagent"], at: start.addingTimeInterval(1))
            + record("response_item", ["type": "function_call_output", "output": String(repeating: "x", count: 600_000)], at: start.addingTimeInterval(2)))
        try CodexHookFixture.announce([file], home: home, turn: "t1", at: start)
        try CodexHookFixture.announce([file], home: home, event: "PermissionRequest", turn: "t1", approval: "exec", at: start.addingTimeInterval(5))

        let read = await LocalActivityReader().read(home: home, now: start.addingTimeInterval(6))
        let activity = try XCTUnwrap(read.activities.first)
        XCTAssertEqual(activity.turnID, "t1")
        XCTAssertEqual(activity.phase, .running)
        XCTAssertTrue(activity.codexReviewsApprovals)
        XCTAssertTrue(read.requests.isEmpty)
    }

    func testASpoolAppendNamingANewRolloutIsFollowedByAMetricsOnlyRead() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-hook-append-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let start = Date().addingTimeInterval(-60)
        let reader = LocalActivityReader()
        func rollout(_ day: String, _ id: String) throws -> URL {
            let folder = home.appendingPathComponent("sessions/" + day, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("rollout-2026-11-21T10-00-00-\(id).jsonl")
            try (record("session_meta", ["id": id, "originator": "Codex Desktop", "cwd": "/fixture"], at: start)
                + record("event_msg", ["type": "task_started", "turn_id": "t1"], at: start.addingTimeInterval(1))).write(to: file)
            return file
        }
        let first = try rollout("2026/11/21", thread)
        try CodexHookFixture.announce([first], home: home, turn: "t1", at: start.addingTimeInterval(1))
        let initial = await reader.read(home: home, now: start.addingTimeInterval(2))
        XCTAssertEqual(initial.activities.count, 1)
        XCTAssertFalse(initial.watchURLs.contains(first.deletingLastPathComponent().deletingLastPathComponent()),
                       "The date folders are not watched, so the spool append is the only event for a new rollout")

        // A week-old conversation continues: only the spool file changed.
        let other = "019a0000-0000-7000-8000-000000000022"
        let older = try rollout("2026/11/14", other)
        try CodexHookFixture.announce([older], home: home, turn: "t1", at: start.addingTimeInterval(3))
        let appended = await reader.read(home: home, now: start.addingTimeInterval(4), metricsOnly: true)
        XCTAssertEqual(Set(appended.activities.compactMap(\.threadID)), [thread, other])
        XCTAssertTrue(appended.watchURLs.contains(older), "The newly named rollout is watched from then on")

        // Without new rows, a metrics-only read still only follows what it has.
        let quiet = await reader.read(home: home, now: start.addingTimeInterval(5), metricsOnly: true)
        XCTAssertEqual(quiet.activities.count, 2)
    }
}
