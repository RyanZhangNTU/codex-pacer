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
        // A normal ending fills the ring even when no estimate ever arrived.
        let unreported = try XCTUnwrap(TaskProgressRing.make(activity, phase: .completed, enabled: true, at: now))
        XCTAssertEqual(unreported.mode, .done); XCTAssertEqual(unreported.fraction, 1); XCTAssertEqual(unreported.percent, 100)
        XCTAssertNil(TaskProgressRing.make(activity, phase: .interrupted, enabled: true, at: now), "An interruption without an estimate shows no ring")

        state.consume(ClaudeActivityRecord.encode(["kind": "response", "origin": "transcript", "sessionId": session, "promptId": turn,
            "itemId": "reply", "progress": 62, "at": start + 1])!, now: now.addingTimeInterval(100))
        activity = try XCTUnwrap(state.activities.first)
        let fresh = try XCTUnwrap(TaskProgressRing.make(activity, phase: .running, enabled: true, at: now.addingTimeInterval(30)))
        XCTAssertEqual(fresh.state, .reported); XCTAssertEqual(fresh.fraction, 0.62, accuracy: 0.0001); XCTAssertFalse(fresh.stale)
        XCTAssertEqual(fresh.accessibilityText, L10n.text("activity.progress_reported", 62))
        XCTAssertTrue(try XCTUnwrap(TaskProgressRing.make(activity, phase: .running, enabled: true, at: now.addingTimeInterval(122))).stale)
        // A normal ending is the request's end: the ring fills from the last estimate and never fades.
        let ended = try XCTUnwrap(TaskProgressRing.make(activity, phase: .completed, enabled: true, at: now.addingTimeInterval(600)))
        XCTAssertEqual(ended.mode, .done); XCTAssertEqual(ended.fraction, 1); XCTAssertFalse(ended.stale)
        XCTAssertEqual(ended.accessibilityText, L10n.text("activity.progress_done"))
        // An interrupted one keeps its own estimate.
        let stopped = try XCTUnwrap(TaskProgressRing.make(activity, phase: .interrupted, enabled: true, at: now.addingTimeInterval(600)))
        XCTAssertEqual(stopped.fraction, 0.62, accuracy: 0.0001); XCTAssertEqual(stopped.mode, .interrupted)

        let rows = ActivityTaskPresentation(activities: [activity], requests: [], inbox: CompletionInbox(),
            options: .init(progressRingProviders: [.claude]), at: now.addingTimeInterval(30)).rows
        XCTAssertEqual(rows.first?.progressRing?.percent, 62)
        XCTAssertNil(ActivityTaskPresentation(activities: [activity], requests: [], inbox: CompletionInbox(),
            options: .init(progressRingProviders: [.codex]), at: now).rows.first?.progressRing)
        // The collapsed badge draws the only task's estimate while it works.
        func badge(_ providers: Set<AgentProvider>) -> TaskProgressRing? {
            ActivityTaskPresentation(activities: [activity], requests: [], inbox: CompletionInbox(),
                options: .init(progressRingProviders: providers), at: now.addingTimeInterval(30)).header(symbol: { $0.rawValue }).progress
        }
        XCTAssertEqual(badge([.claude])?.percent, 62)
        XCTAssertNil(badge([.codex]), "No ring in the row, none in the badge")
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
        // Ending without background work completes the request: the ring fills from 70.
        send(["kind": "stopVerified", "origin": "transcript", "sessionId": session, "promptId": nextTurn, "itemId": "end-2", "at": start + 130])
        XCTAssertEqual(state.activities.first?.phase, .completed)
        let finished = try ring(at: 135)
        XCTAssertEqual(finished.mode, .done); XCTAssertEqual(finished.fraction, 1)
        // A prompt typed after the request ended starts the next one fresh.
        let third = "6a1d2c3b-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
        send(["kind": "prompt", "origin": "hook", "sessionId": session, "promptId": third, "at": start + 200])
        XCTAssertNil(state.activities.first?.currentProgress)
        XCTAssertEqual(try ring(at: 201).state, .pending)
    }

    func testUnownedTranscriptEstimateCannotBorrowTheCurrentTurn() throws {
        var state = ClaudeActivityState()
        let start = now.timeIntervalSince1970
        let records: [[String: Any]] = [
            ["kind": "prompt", "origin": "hook", "sessionId": session, "promptId": turn, "at": start],
            ["kind": "progress", "origin": "hook", "sessionId": session, "promptId": turn, "progress": 40, "at": start + 1]
        ]
        for record in records { state.consume(ClaudeActivityRecord.encode(record)!, now: now.addingTimeInterval(100)) }
        let raw: [String: Any] = ["type": "assistant", "sessionId": session, "uuid": "orphan-answer", "parentUuid": "missing-parent",
            "timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(2)),
            "message": ["role": "assistant", "content": [["type": "text", "text": "⟦90%⟧ PRIVATE_REPLY"]]]]
        let rows = ClaudeActivityRecord.transcript(ClaudeActivityRecord.encode(raw)!, sessionID: session)
        XCTAssertTrue(rows.contains { String(decoding: $0, as: UTF8.self).contains(#""unownedTurn":true"#) })
        for row in rows { state.consume(row, now: now.addingTimeInterval(100)) }
        XCTAssertEqual(state.activities.first?.currentProgress?.percent, 40)
        XCTAssertEqual(state.activities.first?.currentProgress?.turnID, turn)
        XCTAssertEqual(state.activities.first?.phase, .running)
    }

    func testWaitingEndsWhenTheSameTurnResumesOrReportsAnEmptyStopSnapshot() throws {
        let start = now.timeIntervalSince1970
        for resumed in ["thinking", "response", "toolStart", "emptyStop"] {
            var state = ClaudeActivityState()
            func send(_ kind: String, _ offset: Double, _ extra: [String: Any] = [:]) {
                var record: [String: Any] = ["kind": kind, "origin": "hook", "sessionId": session, "promptId": turn, "itemId": "item", "at": start + offset]
                record.merge(extra) { _, new in new }; state.consume(ClaudeActivityRecord.encode(record)!, now: now.addingTimeInterval(100))
            }
            send("prompt", 0); send("progress", 1, ["progress": 40])
            send("waiting", 10, ["background": ["shell"], "wakeups": 0])
            // A delayed model record from before the Stop cannot clear the wait.
            send("response", 9, ["origin": "transcript"])
            XCTAssertNotNil(state.activities.first?.currentBackgroundWait)
            if resumed == "emptyStop" { send("waiting", 11, ["background": [String](), "wakeups": 0]) }
            else { send(resumed, 11, ["origin": resumed == "toolStart" ? "hook" : "transcript", "attention": "none"]) }
            XCTAssertNil(state.activities.first?.currentBackgroundWait, resumed)
            send("waiting", 10, ["background": ["shell"], "wakeups": 0])
            XCTAssertNil(state.activities.first?.currentBackgroundWait, "An older Stop cannot replace resumed work or a newer empty snapshot")
            send("stopVerified", 12, ["origin": "transcript"])
            let ended = try XCTUnwrap(state.activities.first)
            XCTAssertEqual(ended.phase, .completed, resumed)
            XCTAssertEqual(TaskProgressRing.make(ended, phase: ended.phase, enabled: true, at: now.addingTimeInterval(15))?.fraction, 1)
        }
    }

    func testEmptyWaitingDoesNotHideTheFinalTranscriptResponse() throws {
        var state = ClaudeActivityState()
        let start = now.timeIntervalSince1970
        func send(_ kind: String, _ offset: Double, _ extra: [String: Any] = [:]) {
            var record: [String: Any] = ["kind": kind, "origin": "hook", "sessionId": session, "promptId": turn,
                "itemId": "item", "at": start + offset]
            record.merge(extra) { _, new in new }
            state.consume(ClaudeActivityRecord.encode(record)!, now: now.addingTimeInterval(100))
        }
        send("prompt", 0)
        send("waiting", 10, ["background": ["shell"], "wakeups": 0])
        send("waiting", 12, ["background": [String](), "wakeups": 0])
        XCTAssertEqual(state.activities.first?.lastObserved, now, "Waiting snapshots have their own ordering clock")
        // The spool is read first. The final reply predates its Stop, but its
        // transcript may be read only after that empty waiting snapshot.
        send("response", 11, ["origin": "transcript", "itemId": "final-reply"])
        XCTAssertEqual(state.activities.first?.stage, .responding)
        XCTAssertEqual(state.activities.first?.lastObserved, now.addingTimeInterval(11))
        XCTAssertNil(state.activities.first?.currentBackgroundWait)
        // Newer than the reply but older than the clear: lastObserved alone
        // cannot reject this stale nonempty waiting snapshot.
        send("waiting", 11.5, ["background": ["shell"], "wakeups": 0])
        XCTAssertNil(state.activities.first?.currentBackgroundWait)
        send("waiting", 13, ["background": ["subagent"], "wakeups": 0])
        XCTAssertEqual(state.activities.first?.currentBackgroundWait?.kinds, ["subagent"])
        send("waiting", 12.5, ["background": [String](), "wakeups": 0])
        XCTAssertNotNil(state.activities.first?.currentBackgroundWait, "An older clear cannot replace newer background work")
        send("waiting", 14, ["background": [String](), "wakeups": 0])
        send("stopVerified", 15, ["origin": "transcript"])
        XCTAssertEqual(state.activities.first?.phase, .completed)
    }

    func testInterruptedOrFailedBackgroundWaitCannotCarryProgressToANewRequest() throws {
        let start = now.timeIntervalSince1970
        for ending in ["interrupt", "failure"] {
            for wake in [false, true] {
                var state = ClaudeActivityState()
                let records: [[String: Any]] = [
                    ["kind": "prompt", "origin": "hook", "sessionId": session, "promptId": turn, "at": start],
                    ["kind": "progress", "origin": "hook", "sessionId": session, "promptId": turn, "progress": 40, "at": start + 1],
                    ["kind": "waiting", "origin": "hook", "sessionId": session, "promptId": turn, "background": [String](), "wakeups": 1, "at": start + 2],
                    ["kind": ending, "origin": "transcript", "sessionId": session, "promptId": turn, "at": start + 3]]
                for record in records { state.consume(ClaudeActivityRecord.encode(record)!, now: now.addingTimeInterval(100)) }
                XCTAssertEqual(state.activities.first?.phase, .interrupted)
                XCTAssertEqual(state.activities.first?.currentProgress?.percent, 40, "The ended request retains its own estimate")
                XCTAssertNil(state.activities.first?.currentBackgroundWait)
                state.consume(ClaudeActivityRecord.encode(["kind": "prompt", "origin": "hook", "sessionId": session,
                    "promptId": nextTurn, "wake": wake, "at": start + 4])!, now: now.addingTimeInterval(100))
                let next = try XCTUnwrap(state.activities.first)
                XCTAssertNil(next.currentProgress, "A new request after \(ending) starts without the old estimate")
                XCTAssertEqual(TaskProgressRing.make(next, phase: next.phase, enabled: true, at: now.addingTimeInterval(5))?.state, .pending)
            }
        }
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

    func testCloudRunsKeepTheDashedRingUntilTheyEnd() throws {
        let thread = "cloud-thread-1", source = ClaudeCloudProjectState.sourceID, start = now.timeIntervalSince1970
        func cloudActivity() -> SessionActivity {
            SessionActivity(id: AgentProvider.claude.activityID(sessionID: thread, sourceHostID: source), project: "Project",
                sourceHost: "Project", sourceHostID: source, provider: .claude, sessionID: thread)
        }
        func ring(_ activity: SessionActivity, at offset: Double = 0) -> TaskProgressRing? {
            TaskProgressRing.make(activity, phase: activity.phase, enabled: true, at: now.addingTimeInterval(offset))
        }
        XCTAssertNil(ring(cloudActivity()), "A cloud thread that was never seen running has no ring")
        var activity = cloudActivity()
        activity.applyRuntime(["method": "thread/observed", "threadId": thread, "status": "active", "at": start])
        XCTAssertNil(activity.turnID, "A cloud poll knows that a run is active, not its turn")
        // Plugins cannot run in the cloud: the dashes stay, however long the run.
        let running = try XCTUnwrap(ring(activity, at: 900))
        XCTAssertEqual(running.state, .pending); XCTAssertEqual(running.mode, .working); XCTAssertTrue(running.cloud); XCTAssertFalse(running.stale)
        XCTAssertEqual(running.accessibilityText, L10n.text("activity.progress_cloud"))
        XCTAssertNil(TaskProgressRing.make(activity, phase: activity.phase, enabled: false, at: now))
        let rows = ActivityTaskPresentation(activities: [activity], requests: [], inbox: CompletionInbox(),
            options: .init(progressRingProviders: [.claude]), at: now.addingTimeInterval(5)).rows
        XCTAssertEqual(rows.first?.progressRing?.state, .pending)
        XCTAssertNil(ActivityTaskPresentation(activities: [activity], requests: [], inbox: CompletionInbox(),
            options: .init(progressRingProviders: [.claude]), at: now.addingTimeInterval(5)).header(symbol: { $0.rawValue }).progress,
            "Without an estimate the badge keeps its orbit")
        activity.applyRuntime(["method": "thread/observed", "threadId": thread, "status": "active", "flags": ["waitingOnUserInput"], "at": start + 10])
        let asking = try XCTUnwrap(ring(activity, at: 10))
        XCTAssertEqual(asking.state, .pending); XCTAssertEqual(asking.mode, .attention)
        // The ending fills the dashed ring like any normal ending.
        var ended = activity
        ended.applyRuntime(["method": "turn/completed", "threadId": thread, "turnId": "cloud-1", "status": "completed", "at": start + 20])
        let done = try XCTUnwrap(ring(ended, at: 30))
        XCTAssertEqual(done.mode, .done); XCTAssertEqual(done.fraction, 1); XCTAssertEqual(done.accessibilityText, L10n.text("activity.progress_done"))
        // A failed run leaves no estimate behind, so its ring goes.
        var failed = activity
        failed.applyRuntime(["method": "turn/completed", "threadId": thread, "turnId": "cloud-1", "status": "failed", "at": start + 20])
        XCTAssertNil(ring(failed, at: 30))
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
