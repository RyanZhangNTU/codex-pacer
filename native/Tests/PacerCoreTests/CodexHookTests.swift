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
        XCTAssertNil(CodexHookSpool.transcript("sessions/rollout.jsonl", home: home))
        XCTAssertNil(CodexHookSpool.transcript(nil, home: home))
    }

    func testThePluginDefinesSevenFixedHooksAndOnlySessionEndWaits() throws {
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

    func testStatusNeedsEveryHookTrustedAndNoticesASilentHook() {
        let now = Date(), all = Array(repeating: "trusted", count: 7)
        func status(enabled: Bool = true, supports: Bool? = true, installed: Bool? = true, trust: [String]? = all,
                    hook: Date? = nil, turn: Date? = nil) -> CodexHookStatus {
            CodexHookStatus.evaluate(enabled: enabled, supportsHooks: supports, installed: installed, trust: trust,
                                     lastHookEvent: hook, lastCodexTurn: turn, now: now)
        }
        XCTAssertEqual(status(enabled: false), .off)
        XCTAssertEqual(status(supports: false), .needsCodexUpdate)
        XCTAssertEqual(status(installed: nil), .installFailed)
        XCTAssertEqual(status(installed: false), .notInstalled)
        XCTAssertEqual(status(trust: ["trusted", "untrusted", "modified", "trusted", "trusted", "trusted", "trusted"]), .needsApproval(count: 2))
        XCTAssertEqual(status(trust: ["trusted"]), .installFailed, "Missing definitions mean the plugin did not load as written")
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
