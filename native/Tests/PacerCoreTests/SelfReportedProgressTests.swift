import XCTest
@testable import PacerCore

final class SelfReportedProgressTests: XCTestCase {
    private let session = "a5a9fbea-c065-46d8-885c-d87413816c90"
    private let turn = "dc0520e2-1720-42a8-a1d1-d2031bf2b145"
    private let nextTurn = "4b1e9d0a-6f0c-4a52-9d39-0c7f2d1a8e55"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testMarkerMustOpenTheMessageAndStayWithinZeroToHundred() {
        XCTAssertEqual(ProgressMarker.percent(leading: "⟦62%⟧ Tests pass; updating the docs."), 62)
        XCTAssertEqual(ProgressMarker.percent(leading: " \n\t⟦100%⟧"), 100)
        XCTAssertEqual(ProgressMarker.percent(leading: "⟦ 7 % ⟧ starting"), 7)
        XCTAssertEqual(ProgressMarker.percent(leading: "⟦0%⟧"), 0)
        for text in ["Tests pass ⟦62%⟧", "⟦101%⟧", "⟦1000%⟧", "⟦62⟧", "[62%]", "⟦%⟧", "⟦６２%⟧", "⟦62％⟧", "⟦62%", "", "**⟦62%⟧**"] {
            XCTAssertNil(ProgressMarker.percent(leading: text), text)
        }
    }

    func testStringPrefixDecodesOnlyTheOpeningOfALongValue() throws {
        let tail = String(repeating: "SECRET_REPLY ", count: 400)
        for text in ["⟦62%⟧ " + tail, "\u{27E6}62%\u{27E7}" + tail] {
            let data = try JSONSerialization.data(withJSONObject: ["text": text])
            let field = try XCTUnwrap(try JSONFieldView.document(data).fields(["text"])["text"])
            let prefix = try XCTUnwrap(field.stringPrefix(maximumBytes: ProgressMarker.prefixBytes))
            XCTAssertTrue(prefix.hasPrefix("⟦62%⟧"))
            XCTAssertLessThanOrEqual(prefix.utf8.count, ProgressMarker.prefixBytes)
        }
        // ASCII-escaped markers and a cut through a multi-byte character or an
        // escape sequence still decode the whole characters before the cut.
        let escaped = Data(#"{"text":"⟦45%⟧ 进度进度进度进度"}"#.utf8)
        let field = try XCTUnwrap(try JSONFieldView.document(escaped).fields(["text"])["text"])
        XCTAssertEqual(field.stringPrefix(maximumBytes: ProgressMarker.prefixBytes).flatMap(ProgressMarker.percent(leading:)), 45)
        let wide = try JSONSerialization.data(withJSONObject: ["text": String(repeating: "进", count: 40)])
        let cut = try XCTUnwrap(try JSONFieldView.document(wide).fields(["text"])["text"]?.stringPrefix(maximumBytes: 17))
        XCTAssertFalse(cut.isEmpty); XCTAssertTrue(cut.allSatisfy { $0 == "进" })
    }

    func testTranscriptCarriesOnlyTheNumberFromAnAssistantReply() throws {
        func rows(_ type: String, _ content: [[String: Any]]) -> String {
            let raw: [String: Any] = ["type": type, "sessionId": session, "timestamp": "2027-01-15T08:00:02Z", "uuid": "answer-1",
                "promptId": turn, "message": ["role": type, "model": "claude-sonnet-4", "content": content, "usage": ["output_tokens": 10]]]
            return ClaudeActivityRecord.transcript(ClaudeActivityRecord.encode(raw)!, sessionID: session)
                .compactMap { String(data: $0, encoding: .utf8) }.joined()
        }
        let reply = rows("assistant", [["type": "text", "text": "⟦62%⟧ SECRET_PRIVATE_RESPONSE"]])
        XCTAssertTrue(reply.contains(#""progress":62"#)); XCTAssertFalse(reply.contains("SECRET")); XCTAssertFalse(reply.contains("⟦"))
        XCTAssertFalse(rows("assistant", [["type": "text", "text": "Done. ⟦62%⟧"]]).contains("progress"))
        XCTAssertFalse(rows("assistant", [["type": "thinking", "thinking": "⟦62%⟧"]]).contains("progress"))
        XCTAssertFalse(rows("user", [["type": "text", "text": "⟦62%⟧ please"]]).contains("progress"))
    }

    func testStateKeepsTheLatestEstimateOfTheCurrentTurnOnly() throws {
        var state = ClaudeActivityState()
        func consume(_ kind: String, _ offset: Double, prompt: String, _ extra: [String: Any] = [:]) {
            let record: [String: Any] = ["kind": kind, "origin": "transcript", "sessionId": session, "promptId": prompt,
                                         "itemId": "item-\(Int(offset * 10))", "at": now.timeIntervalSince1970 + offset]
            state.consume(ClaudeActivityRecord.encode(record.merging(extra) { _, newer in newer })!, now: now.addingTimeInterval(100))
        }
        consume("prompt", 0, prompt: turn)
        XCTAssertNil(try XCTUnwrap(state.activities.first).currentProgress)
        consume("response", 1, prompt: turn, ["progress": 40])
        XCTAssertEqual(state.activities.first?.currentProgress?.percent, 40)
        // A lower estimate replaces a higher one; nothing is only-up.
        consume("response", 2, prompt: turn, ["progress": 35])
        XCTAssertEqual(state.activities.first?.currentProgress?.percent, 35)
        consume("response", 3, prompt: turn, ["progress": 140])
        XCTAssertEqual(state.activities.first?.currentProgress?.percent, 35)
        consume("prompt", 4, prompt: nextTurn)
        XCTAssertNil(state.activities.first?.currentProgress)
        consume("response", 5, prompt: nextTurn, ["progress": 10])
        XCTAssertEqual(state.activities.first?.currentProgress?.percent, 10)
        XCTAssertEqual(state.activities.first?.currentProgress?.turnID, nextTurn)
    }

    func testLateEstimatesStillCountAfterNewerToolHooks() throws {
        var state = ClaudeActivityState()
        let start = now.timeIntervalSince1970
        func send(_ record: [String: Any]) { state.consume(ClaudeActivityRecord.encode(record)!, now: now.addingTimeInterval(100)) }
        send(["kind": "prompt", "origin": "hook", "sessionId": session, "promptId": turn, "at": start])
        send(["kind": "toolStart", "origin": "hook", "sessionId": session, "promptId": turn, "itemId": "tool-1", "attention": "none", "at": start + 20])
        // The background display observer reports text written before that tool started.
        send(["kind": "progress", "origin": "hook", "sessionId": session, "promptId": turn, "progress": 30, "at": start + 10])
        XCTAssertEqual(state.activities.first?.currentProgress?.percent, 30)
        // Transcript text is read after the hook spool and counts as well.
        send(["kind": "response", "origin": "transcript", "sessionId": session, "promptId": turn, "itemId": "reply", "progress": 45, "at": start + 15])
        XCTAssertEqual(state.activities.first?.currentProgress?.percent, 45)
        // Another turn's estimate and one older than the latest are ignored.
        send(["kind": "progress", "origin": "hook", "sessionId": session, "promptId": nextTurn, "progress": 90, "at": start + 21])
        send(["kind": "progress", "origin": "hook", "sessionId": session, "promptId": turn, "progress": 20, "at": start + 12])
        XCTAssertEqual(state.activities.first?.currentProgress?.percent, 45)
        XCTAssertEqual(state.activities.first?.phase, .running, "An estimate never changes the task's lifecycle")
    }

    func testRingShowsDashesUntilTheFirstEstimateAndNeverFillsByItself() throws {
        var state = ClaudeActivityState()
        let start = now.timeIntervalSince1970
        state.consume(ClaudeActivityRecord.encode(["kind": "prompt", "origin": "transcript", "sessionId": session, "promptId": turn, "at": start])!,
                      now: now.addingTimeInterval(100))
        var activity = try XCTUnwrap(state.activities.first)
        XCTAssertNil(TaskProgressRing.make(activity, phase: .running, enabled: false, at: now))
        XCTAssertEqual(TaskProgressRing.make(activity, phase: .running, enabled: true, at: now)?.state, .pending)
        XCTAssertEqual(TaskProgressRing.make(activity, phase: .waitingForInput, enabled: true, at: now)?.state, .pending)
        XCTAssertNil(TaskProgressRing.make(activity, phase: .completed, enabled: true, at: now))

        state.consume(ClaudeActivityRecord.encode(["kind": "response", "origin": "transcript", "sessionId": session, "promptId": turn,
            "itemId": "reply", "progress": 62, "at": start + 1])!, now: now.addingTimeInterval(100))
        activity = try XCTUnwrap(state.activities.first)
        let fresh = try XCTUnwrap(TaskProgressRing.make(activity, phase: .running, enabled: true, at: now.addingTimeInterval(30)))
        XCTAssertEqual(fresh.state, .reported); XCTAssertEqual(fresh.fraction, 0.62, accuracy: 0.0001); XCTAssertFalse(fresh.stale)
        XCTAssertEqual(fresh.accessibilityText, L10n.text("activity.progress_reported", 62))
        XCTAssertTrue(try XCTUnwrap(TaskProgressRing.make(activity, phase: .running, enabled: true, at: now.addingTimeInterval(122))).stale)
        // An ended turn keeps its own estimate and does not fade or fill.
        let ended = try XCTUnwrap(TaskProgressRing.make(activity, phase: .completed, enabled: true, at: now.addingTimeInterval(600)))
        XCTAssertEqual(ended.fraction, 0.62, accuracy: 0.0001); XCTAssertFalse(ended.stale)

        let rows = ActivityTaskPresentation(activities: [activity], requests: [], inbox: CompletionInbox(),
            options: .init(progressRingProviders: [.claude]), at: now.addingTimeInterval(30)).rows
        XCTAssertEqual(rows.first?.progressRing?.percent, 62)
        XCTAssertNil(ActivityTaskPresentation(activities: [activity], requests: [], inbox: CompletionInbox(),
            options: .init(progressRingProviders: [.codex]), at: now).rows.first?.progressRing)
    }

    func testATurnWaitingForBackgroundWorkStaysOpenAndItsWakeContinuesTheEstimate() throws {
        var state = ClaudeActivityState()
        let start = now.timeIntervalSince1970, later = now.addingTimeInterval(400)
        func send(_ record: [String: Any]) { state.consume(ClaudeActivityRecord.encode(record)!, now: later) }
        func ring(at offset: Double) throws -> TaskProgressRing {
            let activity = try XCTUnwrap(state.activities.first)
            return try XCTUnwrap(TaskProgressRing.make(activity, phase: activity.phase, enabled: true, at: now.addingTimeInterval(offset)))
        }
        send(["kind": "prompt", "origin": "hook", "sessionId": session, "promptId": turn, "at": start])
        send(["kind": "progress", "origin": "hook", "sessionId": session, "promptId": turn, "progress": 70, "at": start + 5])
        send(["kind": "waiting", "origin": "hook", "sessionId": session, "promptId": turn, "background": ["shell", "subagent"], "wakeups": 0, "at": start + 10])
        send(["kind": "stopVerified", "origin": "transcript", "sessionId": session, "promptId": turn, "itemId": "end", "at": start + 11])
        XCTAssertEqual(state.activities.first?.phase, .running, "A turn paused for background work is not finished")
        XCTAssertEqual(state.activities.first?.currentBackgroundWait?.kinds, ["shell", "subagent"])
        let waiting = try ring(at: 300)
        XCTAssertEqual(waiting.mode, .waiting); XCTAssertEqual(waiting.percent, 70); XCTAssertFalse(waiting.stale, "Expected silence never fades")
        XCTAssertEqual(waiting.accessibilityText, L10n.text("activity.progress_waiting", 70))
        func status(at offset: Double) throws -> String {
            ActivityTaskRowPresentation(activity: try XCTUnwrap(state.activities.first), unread: false, at: now.addingTimeInterval(offset)).status
        }
        // The final reply was the turn's last stage; the row now says what it waits for.
        send(["kind": "response", "origin": "transcript", "sessionId": session, "promptId": turn, "itemId": "reply", "at": start + 9])
        XCTAssertEqual(try status(at: 300), L10n.text("activity.background_wait"))
        XCTAssertEqual(TaskSymbol.symbol(for: try XCTUnwrap(state.activities.first)), .background, "A paused turn has its own glyph")
        // The completion notification wakes the same request in a new turn.
        send(["kind": "prompt", "origin": "hook", "sessionId": session, "promptId": nextTurn, "wake": true, "at": start + 120])
        XCTAssertEqual(state.activities.first?.turnID, nextTurn)
        XCTAssertEqual(state.activities.first?.currentProgress?.percent, 70)
        XCTAssertNil(state.activities.first?.currentBackgroundWait)
        XCTAssertEqual(try ring(at: 125).mode, .working)
        XCTAssertNotEqual(try status(at: 125), L10n.text("activity.background_wait"))
        XCTAssertNotEqual(TaskSymbol.symbol(for: try XCTUnwrap(state.activities.first)), .background)
        // Ending below 100 without background work keeps the estimate, dimmed.
        send(["kind": "stopVerified", "origin": "transcript", "sessionId": session, "promptId": nextTurn, "itemId": "end-2", "at": start + 130])
        XCTAssertEqual(state.activities.first?.phase, .completed)
        XCTAssertEqual(try ring(at: 135).mode, .short)
        // A prompt typed after the request ended starts the next one fresh.
        let third = "6a1d2c3b-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
        send(["kind": "prompt", "origin": "hook", "sessionId": session, "promptId": third, "at": start + 200])
        XCTAssertNil(state.activities.first?.currentProgress)
        XCTAssertEqual(try ring(at: 201).state, .pending)
    }

    func testRingModeFollowsLongStepsAttentionAndEndings() throws {
        func activity(_ records: [[String: Any]]) throws -> SessionActivity {
            var state = ClaudeActivityState()
            for record in records { state.consume(ClaudeActivityRecord.encode(record)!, now: now.addingTimeInterval(400)) }
            return try XCTUnwrap(state.activities.first)
        }
        let start = now.timeIntervalSince1970
        let prompt: [String: Any] = ["kind": "prompt", "origin": "hook", "sessionId": session, "promptId": turn, "at": start]
        let estimate: [String: Any] = ["kind": "progress", "origin": "hook", "sessionId": session, "promptId": turn, "progress": 40, "at": start + 1]
        func tool(_ attention: String) -> [String: Any] {
            ["kind": "toolStart", "origin": "hook", "sessionId": session, "promptId": turn, "itemId": "tool-1", "attention": attention, "at": start + 2]
        }
        let long = try activity([prompt, estimate, tool("none")])
        XCTAssertEqual(TaskProgressRing.make(long, phase: long.phase, enabled: true, at: now.addingTimeInterval(20))?.mode, .working)
        let step = try XCTUnwrap(TaskProgressRing.make(long, phase: long.phase, enabled: true, at: now.addingTimeInterval(200)))
        XCTAssertEqual(step.mode, .longStep); XCTAssertFalse(step.stale, "A long step is not silence")
        let asking = try activity([prompt, estimate, tool("approval")])
        XCTAssertEqual(TaskProgressRing.make(asking, phase: asking.phase, enabled: true, at: now.addingTimeInterval(5))?.mode, .attention)
        for (kind, mode) in [("failure", TaskProgressRing.Mode.failed), ("interrupt", .interrupted)] {
            let ended = try activity([prompt, estimate, ["kind": kind, "origin": "transcript", "sessionId": session, "promptId": turn, "itemId": "end", "at": start + 3]])
            XCTAssertEqual(TaskProgressRing.make(ended, phase: ended.phase, enabled: true, at: now.addingTimeInterval(5))?.mode, mode, kind)
        }
        let done = try activity([prompt, ["kind": "progress", "origin": "hook", "sessionId": session, "promptId": turn, "progress": 100, "at": start + 1],
            ["kind": "stopVerified", "origin": "transcript", "sessionId": session, "promptId": turn, "itemId": "end", "at": start + 3]])
        XCTAssertEqual(TaskProgressRing.make(done, phase: done.phase, enabled: true, at: now.addingTimeInterval(5))?.mode, .done)
    }

    func testSwitchFileWaitsForPacersHookFolderAndRemovesCleanly() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-progress-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let flag = ClaudeProgressRingSwitch.flagURL(home: home)
        XCTAssertFalse(ClaudeProgressRingSwitch.apply(enabled: true, home: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: flag.path))
        XCTAssertTrue(ClaudeProgressRingSwitch.apply(enabled: false, home: home))
        try FileManager.default.createDirectory(at: home.appendingPathComponent("pacer"), withIntermediateDirectories: false)
        XCTAssertTrue(ClaudeProgressRingSwitch.apply(enabled: true, home: home))
        XCTAssertEqual(FileManager.default.contents(atPath: flag.path), Data("tool\n".utf8), "Estimates come through Pacer's plugin tool")
        try Data("on\n".utf8).write(to: flag)
        XCTAssertTrue(ClaudeProgressRingSwitch.apply(enabled: true, home: home))
        XCTAssertEqual(FileManager.default.contents(atPath: flag.path), Data("tool\n".utf8), "An older marker switch moves to the tool")
        try Data("tool 15\n".utf8).write(to: flag)
        XCTAssertTrue(ClaudeProgressRingSwitch.apply(enabled: true, home: home))
        XCTAssertEqual(FileManager.default.contents(atPath: flag.path), Data("tool 15\n".utf8), "A hand-written mode is kept")
        XCTAssertTrue(ClaudeProgressRingSwitch.apply(enabled: false, home: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: flag.path))
    }
}
