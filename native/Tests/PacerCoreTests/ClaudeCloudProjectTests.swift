#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation
import XCTest
@testable import PacerCore

final class ClaudeCloudProjectTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let project = ClaudeCloudProject(id: "chan_project1", name: "Launch plan", coordinatorSessionID: "cse_coordinator1")

    private func thread(_ status: ClaudeCloudThreadStatus, working: Bool = false, unread: Bool = false, reply: TimeInterval = 0,
                        decisions: Int = 0, sessions: [String] = ["cse_worker1"], workers: Int = 0, id: String = "cmsg_thread1",
                        replies: Int = 0) -> ClaudeCloudThread {
        ClaudeCloudThread(id: id, projectID: project.id, status: status, isWorking: working, hasUnread: unread,
            lastReplyAt: base.addingTimeInterval(reply), title: "Draft the outline", sessionIDs: sessions, openDecisions: decisions, workingSessions: workers,
            replyCount: replies)
    }
    private func snapshot(_ threads: [ClaudeCloudThread], sessions: [ClaudeCloudSession] = [], local: Set<String> = []) -> ClaudeCloudSnapshot {
        ClaudeCloudSnapshot(projects: [project], threads: [project.id: threads],
            sessions: Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) }), localSessionIDs: local)
    }
    private func row(_ state: ClaudeCloudProjectState, _ id: String = "cmsg_thread1") -> SessionActivity? {
        state.activities.first { $0.threadID == id }
    }
    private func at(_ offset: TimeInterval) -> Date { base.addingTimeInterval(offset) }

    // MARK: Decoding

    func testThreadDecodingKeepsLifecycleAndDropsMessageContent() throws {
        let reply: [String: Any] = ["sections": [["status": "working", "count": 1, "data": [[
            "id": "cmsg_thread1", "thread_status": "thread_status_needs_input", "thread_any_session_working": false, "has_unread": true,
            "last_reply_at": "2027-01-15T08:00:00Z", "reply_count": "2", "open_decisions": [["id": "d1", "question": "Private question"]],
            "body": "Private message body", "thread_preview": "Private preview",
            "bound_sessions": [["id": "cse_worker1", "title": "  Draft\nthe outline ", "status_bucket": "working"],
                               ["id": "not a session", "title": "ignored"]]
        ], ["id": "cmsg_pending_abcdef"], ["id": "cmsg_thread1"]]]]]
        let threads = try ClaudeCloudDecoder.threads(JSONSerialization.data(withJSONObject: reply), projectID: "chan_project1")
        XCTAssertEqual(threads.count, 1)
        let first = try XCTUnwrap(threads.first)
        XCTAssertEqual(first.status, .needsInput)
        XCTAssertEqual(first.title, "Draftthe outline")
        XCTAssertEqual(first.sessionIDs, ["cse_worker1"])
        XCTAssertEqual(first.openDecisions, 1)
        XCTAssertEqual(first.workingSessions, 1)
        XCTAssertEqual(first.replyCount, 2, "counts arrive as strings")
        XCTAssertFalse(String(describing: first).contains("Private"))
    }

    func testUnknownThreadStatusReadsAsIdleLikeClaudesOwnClient() {
        XCTAssertEqual(ClaudeCloudThreadStatus(wire: "thread_status_something_new"), .idle)
        XCTAssertEqual(ClaudeCloudThreadStatus(wire: nil), .idle)
        XCTAssertEqual(ClaudeCloudThreadStatus(wire: "THREAD_STATUS_FAILED"), .failed)
    }

    func testProjectDecodingSkipsArchivedAndDisabledProjects() throws {
        let reply: [String: Any] = ["channels": [
            ["id": "chan_active1", "name": "Active", "overview_session_id": "cse_lead000", "last_message_at": "2027-01-15T08:00:00Z"],
            ["id": "chan_archive", "name": "Old", "archived_at": "2027-01-01T00:00:00Z"],
            ["id": "chan_planoff", "name": "Plan", "disabled_by_plan": true],
            ["id": "bad"]
        ]]
        let projects = try ClaudeCloudDecoder.projects(JSONSerialization.data(withJSONObject: reply))
        XCTAssertEqual(projects.map(\.id), ["chan_active1"])
        XCTAssertEqual(projects.first?.coordinatorSessionID, "cse_lead000")
        XCTAssertNotNil(projects.first?.lastActivityAt)
    }

    func testSessionDecodingOnlyKeepsWhatKindOfRequestIsPending() throws {
        func decode(_ fields: [String: Any]) throws -> ClaudeCloudSession {
            var row: [String: Any] = ["id": "cse_worker1", "worker_status": "requires_action", "connection_status": "connected"]
            row.merge(fields) { _, new in new }
            return try ClaudeCloudDecoder.session(JSONSerialization.data(withJSONObject: ["response_shape": row]))
        }
        let question = try decode(["requires_action_details_list": [["tool_name": "AskUserQuestion", "input": ["secret": "Private"]]]])
        XCTAssertEqual(question.pending, .input)
        XCTAssertFalse(String(describing: question).contains("Private"))
        XCTAssertEqual(try decode(["external_metadata": ["pending_action": ["tool_name": "Bash"]]]).pending, .approval)
        XCTAssertEqual(try decode([:]).pending, .approval)
        XCTAssertNil(try decode(["worker_status": "idle"]).pending)
        let oldQuestion = ["pending_action": ["tool_name": "AskUserQuestion"]]
        XCTAssertNil(try decode(["worker_status": "idle", "external_metadata": oldQuestion]).pending, "metadata alone can describe an old action")
        XCTAssertNil(try decode(["status": "archived", "external_metadata": oldQuestion]).pending)
        XCTAssertNil(try decode(["connection_status": "disconnected", "external_metadata": oldQuestion]).pending)
        XCTAssertFalse(try decode(["worker_status": "running", "connection_status": "disconnected"]).isRunning)
        XCTAssertTrue(try decode(["status": "failed"]).isFailed)
        XCTAssertEqual(try decode(["external_metadata": ["model": "claude-opus-5-5", "effort_level": "high"]]).modelName, "claude-opus-5-5")
    }

    func testSessionBucketShowsARunTheWorkerDoesNot() throws {
        func decode(_ fields: [String: Any]) throws -> ClaudeCloudSession {
            var row: [String: Any] = ["id": "cse_worker1", "worker_status": "idle", "connection_status": "connected"]
            row.merge(fields) { _, new in new }
            return try ClaudeCloudDecoder.session(JSONSerialization.data(withJSONObject: ["session": row]))
        }
        let tool = try decode(["status_bucket": "working", "external_metadata": ["post_turn_summary": ["status_category": "review_ready", "text": "Private"]]])
        XCTAssertTrue(tool.isRunning, "a long tool call leaves the worker idle")
        XCTAssertEqual(tool.turnCategory, .reviewReady)
        XCTAssertFalse(String(describing: tool).contains("Private"))
        XCTAssertTrue(try decode(["worker_status": "WORKER_STATUS_UNSPECIFIED", "status_bucket": "working"]).isRunning)
        XCTAssertFalse(try decode(["status_bucket": "working", "connection_status": "disconnected"]).isRunning)
        XCTAssertFalse(try decode(["status_bucket": "review_ready"]).isRunning)
        XCTAssertEqual(try decode(["status_bucket": "something_new"]).bucket, .other)
        XCTAssertTrue(try decode(["status_bucket": "failed"]).isFailed)

        XCTAssertTrue(try decode(["status_bucket": "review_ready"]).awaitsReply, "no summary reads as waiting, as in Claude's web client")
        for category in ["blocked", "need_input", "waiting"] {
            XCTAssertTrue(try decode(["external_metadata": ["post_turn_summary": ["status_category": category]]]).awaitsReply, category)
        }
        for category in ["completed", "review_ready", "failed", "something_new"] {
            XCTAssertFalse(try decode(["external_metadata": ["post_turn_summary": ["status_category": category]]]).awaitsReply, category)
        }
    }

    func testTurnResultKeepsOnlyTheNewestTurnsNumbers() throws {
        func event(_ sequence: Int, _ type: String, _ payload: [String: Any]) -> [String: Any] {
            ["sequence_num": sequence, "event_id": "event\(sequence)", "event_type": type, "created_at": "2027-01-15T08:00:\(10 + sequence)Z", "payload": payload]
        }
        func decode(_ payload: [String: Any]) throws -> ClaudeCloudTurnResult? {
            try ClaudeCloudDecoder.turnResult(JSONSerialization.data(withJSONObject: ["data": [event(1, "result", payload)]]))
        }
        let timed: [String: Any] = ["usage": ["output_tokens": 1860], "process_wall_ms_streaming": 27853, "ttft_ms": 2001, "duration_api_ms": 30588, "result": "Private answer"]
        let page: [String: Any] = ["data": [
            event(9, "control_request", ["request": "Private"]), event(8, "result", timed),
            event(7, "assistant", ["message": ["usage": ["output_tokens": 25], "content": "Private text"]]),
            event(2, "result", ["usage": ["output_tokens": 5], "process_wall_ms_streaming": 100])
        ]]
        let result = try XCTUnwrap(try ClaudeCloudDecoder.turnResult(JSONSerialization.data(withJSONObject: page)))
        XCTAssertEqual(result.id, "event8")
        XCTAssertEqual(result.outputTokens, 1860)
        XCTAssertEqual(result.streaming, 27.853, accuracy: 0.001, "the cumulative API time is not this turn's")
        XCTAssertEqual(result.firstOutput ?? 0, 2.001, accuracy: 0.001)
        XCTAssertFalse(String(describing: result).contains("Private"))

        XCTAssertNil(try decode(["usage": ["output_tokens": 353], "duration_api_ms": 70591, "ttft_ms": 1499]), "a coordinator's result has no streaming time")
        XCTAssertNil(try decode(["usage": ["output_tokens": 0], "process_wall_ms_streaming": 1000]))
        XCTAssertNil(try decode(["usage": ["output_tokens": 500], "process_wall_ms_streaming": 0]))
        XCTAssertNil(try decode(["usage": ["output_tokens": 50000], "process_wall_ms_streaming": 1000]), "faster than any model")
        XCTAssertNil(try decode(["process_wall_ms_streaming": 1000]))
        XCTAssertNil(try decode(["usage": ["output_tokens": 500], "process_wall_ms_streaming": 1000])?.firstOutput)
        XCTAssertNil(try ClaudeCloudDecoder.turnResult(JSONSerialization.data(withJSONObject: ["data": [event(1, "assistant", [:])]])))
        XCTAssertThrowsError(try ClaudeCloudDecoder.turnResult(Data(#"{"sections":[]}"#.utf8)))
    }

    func testRepliesWithoutTheExpectedShapeAreRejected() {
        XCTAssertThrowsError(try ClaudeCloudDecoder.projects(Data("{}".utf8)))
        XCTAssertThrowsError(try ClaudeCloudDecoder.threads(Data("[]".utf8), projectID: "chan_project1"))
        XCTAssertThrowsError(try ClaudeCloudDecoder.session(Data(#"{"id":"not valid"}"#.utf8)))
    }

    // MARK: Thread lifecycle

    private func worker(_ bucket: ClaudeCloudSession.Category, category: ClaudeCloudSession.Category? = nil, worker: ClaudeCloudSession.Worker = .idle,
                        connected: Bool = true) -> ClaudeCloudSession {
        ClaudeCloudSession(id: "cse_worker1", worker: worker, bucket: bucket, turnCategory: category, isConnected: connected, hasUnread: true)
    }

    func testALongToolCallStaysRunningThroughAnIdleThreadRow() throws {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([thread(.working, working: true)]), at: at(0))
        state.apply(snapshot([thread(.idle)], sessions: [worker(.working, category: .reviewReady)]), at: at(20))
        XCTAssertEqual(row(state)?.phase, .running, "the row reads idle within seconds of a run starting")
        XCTAssertTrue(state.hasRunningWork)
        state.apply(snapshot([thread(.resolved, working: true, reply: 120)], sessions: [worker(.working)]), at: at(125))
        XCTAssertEqual(row(state)?.phase, .running, "still reporting")
        state.apply(snapshot([thread(.resolved, unread: true, reply: 120)], sessions: [worker(.completed, category: .completed)]), at: at(145))
        let ended = try XCTUnwrap(row(state))
        XCTAssertEqual(ended.phase, .completed)
        XCTAssertEqual(ended.endingLabel, L10n.text("activity.resolved"))
    }

    func testARunFoundOnlyThroughItsSessionStillGetsARow() throws {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([thread(.idle, reply: -60)], sessions: [worker(.working)]), at: at(0))
        XCTAssertEqual(row(state)?.phase, .running, "the baseline can catch a run in a long tool call")
    }

    func testAPassThatCannotReadTheSessionHoldsTheRunForAWhile() throws {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([thread(.working, working: true)]), at: at(0))
        state.apply(snapshot([thread(.idle)]), at: at(20))
        XCTAssertEqual(row(state)?.phase, .running)
        state.apply(snapshot([thread(.idle)]), at: at(299))
        XCTAssertEqual(row(state)?.phase, .running)
        state.apply(snapshot([thread(.idle)]), at: at(301))
        XCTAssertEqual(row(state)?.phase, .unknown, "missing evidence cannot prove an ending")
        XCTAssertTrue(state.turnResultsToRead().isEmpty)
        state.apply(snapshot([thread(.idle)]), at: at(340))
        XCTAssertEqual(row(state)?.phase, .unknown)
        state.apply(snapshot([thread(.idle)], sessions: [worker(.working)]), at: at(360))
        XCTAssertEqual(row(state)?.phase, .running, "fresh evidence recovers the run")
        state.apply(snapshot([thread(.resolved, unread: true, reply: 380)]), at: at(400))
        XCTAssertEqual(row(state)?.phase, .completed)
    }

    func testAnUnreadBoundSessionCannotBeReplacedByAnotherSessionsIdleState() {
        var state = ClaudeCloudProjectState()
        let ids = ["cse_worker1", "cse_worker2"]
        state.apply(snapshot([thread(.working, working: true, sessions: ids)]), at: at(0))
        state.apply(snapshot([thread(.idle, sessions: ids)], sessions: [worker(.completed)]), at: at(301))
        XCTAssertEqual(row(state)?.phase, .unknown)
        state.apply(snapshot([thread(.idle, sessions: ids)], sessions: [worker(.completed),
            ClaudeCloudSession(id: "cse_worker2", worker: .idle, bucket: .working)]), at: at(320))
        XCTAssertEqual(row(state)?.phase, .running)
    }

    func testAStoppedTurnCanContinueWithoutShowingAWaitingRequest() throws {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([thread(.working, working: true)]), at: at(0))
        state.apply(snapshot([thread(.idle)], sessions: [worker(.reviewReady)]), at: at(20))
        let ended = try XCTUnwrap(row(state))
        XCTAssertEqual(ended.phase, .completed)
        let card = ActivityTaskRowPresentation(activity: ended, unread: true, at: at(20))
        XCTAssertEqual(card.status, L10n.text("claude.cloud.turn_can_continue"))
        XCTAssertEqual(card.symbol, .completed)
        XCTAssertTrue(state.attention.isEmpty)
        state.apply(snapshot([thread(.idle)], sessions: [worker(.reviewReady)]), at: at(20 + ClaudeCloudProjectState.readGrace + 1))
        XCTAssertEqual(row(state)?.claudeCloud?.readInClaude, false, "an idle thread never turns unread, so silence is not reading")

        state.apply(snapshot([thread(.idle)], sessions: [worker(.reviewReady, category: .completed)]), at: at(200))
        XCTAssertEqual(row(state)?.endingLabel, L10n.text("activity.turn_finished"), "the summary arrives after the turn stops")
    }

    func testAnsweringAnIdleThreadRunsItAgainThenResolves() throws {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([thread(.working, working: true)]), at: at(0))
        state.apply(snapshot([thread(.idle)], sessions: [worker(.reviewReady)]), at: at(20))
        let first = try XCTUnwrap(row(state)?.turnID)
        state.apply(snapshot([thread(.idle)], sessions: [worker(.working, worker: .unknown)]), at: at(600))
        XCTAssertEqual(row(state)?.phase, .running, "the row has not moved yet")
        state.apply(snapshot([thread(.resolved, unread: true, reply: 610)], sessions: [worker(.completed, category: .completed)]), at: at(620))
        XCTAssertEqual(row(state)?.phase, .completed)
        XCTAssertNotEqual(row(state)?.turnID, first)
    }

    func testAStoppedRunBetweenPollsIsRecognizedThroughItsSessionNotItsUnreadFlag() throws {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([thread(.idle, reply: -3600)], sessions: [worker(.reviewReady)]), at: at(0))
        XCTAssertNil(row(state), "an idle thread at baseline says nothing about being unread")
        state.apply(snapshot([thread(.idle, reply: -3600)], sessions: [worker(.reviewReady)]), at: at(200))
        XCTAssertNil(row(state), "looking again at an unchanged thread is not news")
        state.apply(snapshot([thread(.idle, reply: 300)], sessions: [worker(.reviewReady)]), at: at(310))
        XCTAssertEqual(row(state)?.phase, .completed)
        XCTAssertEqual(row(state)?.endingLabel, L10n.text("claude.cloud.turn_can_continue"))
    }

    func testAWatchedRunEndsOnceAndIdleSettlingIntoResolvedOnlyChangesTheLabel() throws {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([thread(.working, working: true, reply: -600, workers: 2)]), at: at(0))
        let running = try XCTUnwrap(row(state))
        XCTAssertEqual(running.phase, .running)
        XCTAssertEqual(running.stage, .working)
        XCTAssertEqual(running.title, "Draft the outline")
        XCTAssertEqual(running.claudeCloud?.additionalWorkers, 1)
        XCTAssertEqual(running.detail(at: at(0)), L10n.text("activity.working"))
        XCTAssertTrue(state.hasRunningWork)

        state.apply(snapshot([thread(.idle, reply: 160)], sessions: [worker(.reviewReady, category: .reviewReady)]), at: at(164))
        let ended = try XCTUnwrap(row(state))
        XCTAssertEqual(ended.phase, .completed)
        XCTAssertFalse(ended.isHistoricalCompletion)
        XCTAssertTrue(ended.hasLiveEvidence && ended.liveTurnStarted)
        XCTAssertEqual(ended.endingLabel, L10n.text("activity.turn_finished"))

        state.apply(snapshot([thread(.resolved, unread: true, reply: 184)]), at: at(188))
        let settled = try XCTUnwrap(row(state))
        XCTAssertEqual(settled.turnID, ended.turnID, "the same run must not remind twice")
        XCTAssertEqual(settled.phaseChangedAt, ended.phaseChangedAt)
        XCTAssertEqual(settled.endingLabel, L10n.text("activity.resolved"))
        XCTAssertFalse(state.hasRunningWork)
    }

    func testARunBetweenPollsIsRecognizedFromANewerUnreadReply() throws {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([thread(.resolved, reply: -3600)]), at: at(0))
        XCTAssertNil(row(state), "a read thread at baseline is not a task")

        state.apply(snapshot([thread(.resolved, reply: -3600)]), at: at(20))
        XCTAssertNil(row(state))

        state.apply(snapshot([thread(.resolved, unread: true, reply: 30)]), at: at(40))
        let ended = try XCTUnwrap(row(state))
        XCTAssertEqual(ended.phase, .completed)
        XCTAssertTrue(ended.liveTurnStarted)
        XCTAssertEqual(ended.phaseChangedAt, at(30))

        state.apply(snapshot([thread(.resolved, unread: true, reply: 30)]), at: at(60))
        XCTAssertEqual(row(state)?.turnID, ended.turnID, "an unchanged reply is not another run")
    }

    func testANewThreadCountsOnlyWhenItsReplyIsNews() throws {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([]), at: at(0))
        state.apply(snapshot([thread(.resolved, unread: true, reply: -86_400, id: "cmsg_olderone")]), at: at(20))
        XCTAssertNil(row(state, "cmsg_olderone"), "an old thread entering the bounded list is not a new ending")
        state.apply(snapshot([thread(.resolved, unread: true, reply: 30, id: "cmsg_freshone")]), at: at(40))
        XCTAssertEqual(row(state, "cmsg_freshone")?.phase, .completed)
    }

    func testUnreadEndingsAtBaselineStayQuiet() throws {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([thread(.resolved, unread: true, reply: -600),
                              thread(.resolved, unread: true, reply: -30 * 86_400, id: "cmsg_ancient1")]), at: at(0))
        let historical = try XCTUnwrap(row(state))
        XCTAssertTrue(historical.isHistoricalCompletion)
        XCTAssertFalse(historical.liveTurnStarted)
        XCTAssertEqual(historical.phaseChangedAt, at(-600))
        XCTAssertNil(row(state, "cmsg_ancient1"))

        var first = AttentionPolicy()
        XCTAssertTrue(first.activityNotices(state.activities, at: at(0)).isEmpty)
    }

    func testAnEndingIdentitySurvivesARelaunchSoADismissalHolds() throws {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([thread(.working, working: true, reply: -10)]), at: at(0))
        state.apply(snapshot([thread(.resolved, unread: true, reply: 15)]), at: at(20))
        var relaunched = ClaudeCloudProjectState()
        relaunched.apply(snapshot([thread(.resolved, unread: true, reply: 15)]), at: at(600))
        XCTAssertEqual(row(state)?.turnID, row(relaunched)?.turnID)
    }

    func testFailureAndArchiveAreReported() throws {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([thread(.working, working: true)]), at: at(0))
        state.apply(snapshot([thread(.failed, reply: 18)]), at: at(20))
        let failed = try XCTUnwrap(row(state))
        XCTAssertEqual(failed.phase, .interrupted)
        XCTAssertTrue(failed.turnFailed)
        state.apply(snapshot([thread(.archived, reply: 18)]), at: at(40))
        XCTAssertNil(row(state))
    }

    func testALateLookReportsWhenTheEndingWasNoticedSoItStillReminds() throws {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([thread(.working, working: true)]), at: at(0))
        state.apply(snapshot([thread(.resolved, unread: true, reply: 60)]), at: at(4000))
        let ended = try XCTUnwrap(row(state))
        XCTAssertEqual(ended.phaseChangedAt, at(4000))
        var attention = AttentionPolicy()
        XCTAssertEqual(attention.activityNotices(state.activities, at: at(4000)).map(\.kind), [.completed])
    }

    func testAnotherRunOnAThreadStartsAFreshTurn() throws {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([thread(.working, working: true)]), at: at(0))
        state.apply(snapshot([thread(.resolved, unread: true, reply: 15)]), at: at(20))
        let first = try XCTUnwrap(row(state)?.turnID)
        state.apply(snapshot([thread(.working, working: true, reply: 15)]), at: at(400))
        XCTAssertEqual(row(state)?.phase, .running)
        XCTAssertEqual(row(state)?.stage, .working)
        state.apply(snapshot([thread(.resolved, unread: true, reply: 415)]), at: at(420))
        XCTAssertEqual(row(state)?.phase, .completed)
        XCTAssertNotEqual(row(state)?.turnID, first)
    }

    func testASessionDesktopRunsHereStaysALocalTask() {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([thread(.working, working: true, sessions: ["cse_abcdef1"], id: "cmsg_onthismac"),
                              thread(.working, working: true, sessions: ["cse_abcdef1", "cse_other01"], id: "cmsg_mixedsess"),
                              thread(.working, working: true, sessions: [], id: "cmsg_nosession")], local: ["abcdef1"]), at: at(0))
        XCTAssertNil(row(state, "cmsg_onthismac"))
        XCTAssertNotNil(row(state, "cmsg_mixedsess"))
        XCTAssertNotNil(row(state, "cmsg_nosession"))
    }

    // MARK: Attention

    func testWaitingStatesRaiseTheirOwnRequestAndClearWhenWorkResumes() throws {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([thread(.working, working: true)]), at: at(0))
        state.apply(snapshot([thread(.needsInput)], sessions: [ClaudeCloudSession(id: "cse_worker1", worker: .requiresAction, pending: .input)]), at: at(20))
        XCTAssertEqual(state.attention.map(\.kind), [.input])
        XCTAssertEqual(row(state)?.phase, .waitingForInput)
        XCTAssertFalse(row(state)?.waitingForApproval ?? true)

        state.apply(snapshot([thread(.needsInput)], sessions: [ClaudeCloudSession(id: "cse_worker1", worker: .requiresAction, pending: .approval)]), at: at(40))
        XCTAssertEqual(state.attention.map(\.kind), [.approval])
        XCTAssertTrue(row(state)?.waitingForApproval ?? false)

        state.apply(snapshot([thread(.working, decisions: 1)]), at: at(60))
        XCTAssertEqual(state.attention.map(\.kind), [.decision])
        XCTAssertEqual(state.attention.first?.activity.claudeCloud?.projectID, project.id)

        state.apply(snapshot([thread(.working, working: true)]), at: at(80))
        XCTAssertTrue(state.attention.isEmpty)
        XCTAssertEqual(row(state)?.phase, .running)
    }

    func testAQuestionReadAndLeftUnansweredStopsAskingUntilWorkResumes() throws {
        let asking = ClaudeCloudSession(id: "cse_worker1", worker: .idle, bucket: .blocked, turnCategory: .needInput, hasUnread: true)
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([thread(.working, working: true)]), at: at(0))
        state.apply(snapshot([thread(.needsInput, unread: true, reply: 18)], sessions: [asking]), at: at(20))
        XCTAssertEqual(row(state)?.phase, .waitingForInput)
        XCTAssertEqual(state.attention.map(\.kind), [.input])
        state.apply(snapshot([thread(.needsInput, reply: 18)], sessions: [asking]), at: at(40))
        XCTAssertNil(row(state), "opening it in Claude settles it")
        XCTAssertTrue(state.attention.isEmpty)
        state.apply(snapshot([thread(.needsInput, reply: 18)], sessions: [asking]), at: at(60))
        XCTAssertNil(row(state), "and it stays settled")
        state.apply(snapshot([thread(.needsInput, reply: 18)], sessions: [worker(.working)]), at: at(80))
        XCTAssertEqual(row(state)?.phase, .running, "the worker can resume before the thread status changes")
        XCTAssertTrue(state.attention.isEmpty)
        state.apply(snapshot([thread(.needsInput, reply: 90)], sessions: [asking]), at: at(100))
        XCTAssertEqual(row(state)?.phase, .waitingForInput, "a new question is not settled by the last one's read")
    }

    func testAQuestionAskedAsTheUserWatchedSettlesWithoutEverTurningUnread() {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([thread(.working, working: true)]), at: at(0))
        state.apply(snapshot([thread(.needsInput, reply: 18)]), at: at(20))
        XCTAssertEqual(row(state)?.phase, .waitingForInput)
        state.apply(snapshot([thread(.needsInput, reply: 18)]), at: at(80))
        XCTAssertEqual(row(state)?.phase, .waitingForInput)
        state.apply(snapshot([thread(.needsInput, reply: 18)]), at: at(20 + ClaudeCloudProjectState.readGrace))
        XCTAssertNil(row(state))
    }

    func testBaselineShowsOnlyRecentUnreadPlainQuestionsAndDoesNotAlert() throws {
        var state = ClaudeCloudProjectState()
        var policy = AttentionPolicy()
        state.apply(snapshot([thread(.needsInput, unread: true, reply: -600), thread(.needsInput, reply: -600, sessions: ["cse_readone1"], id: "cmsg_readthread"),
                              thread(.needsInput, unread: true, reply: -30 * 86_400, sessions: ["cse_oldone1"], id: "cmsg_oldthread")]), at: at(0))
        XCTAssertEqual(row(state)?.phase, .waitingForInput)
        XCTAssertNil(row(state, "cmsg_readthread"))
        XCTAssertNil(row(state, "cmsg_oldthread"))
        XCTAssertTrue(policy.requestNotices(state.attention).isEmpty)
        let request = try XCTUnwrap(state.attention.first), activity = try XCTUnwrap(row(state))
        let task = ActivityTaskRowPresentation(activity: activity, attention: request.kind, unread: false, at: at(0))
        XCTAssertEqual(task.status, L10n.text("attention.input"))
        XCTAssertEqual(task.symbol, .input)
    }

    func testAQuestionSettledInClaudeStaysSettledAfterItFallsOffThePage() {
        var state = ClaudeCloudProjectState(), policy = AttentionPolicy()
        state.apply(snapshot([thread(.working, working: true)]), at: at(0))
        state.apply(snapshot([thread(.needsInput, unread: true, reply: 18)]), at: at(20))
        XCTAssertEqual(policy.requestNotices(state.attention).count, 1)
        state.apply(snapshot([thread(.needsInput, reply: 18)]), at: at(40))
        XCTAssertNil(row(state))
        XCTAssertTrue(policy.requestNotices(state.attention).isEmpty)
        state.apply(snapshot([]), at: at(60))
        state.apply(snapshot([thread(.needsInput, unread: true, reply: 18, replies: 2)]), at: at(80))
        XCTAssertNil(row(state), "a new unread flag or changed count does not make the same reply new")
        XCTAssertTrue(policy.requestNotices(state.attention).isEmpty)
        state.apply(snapshot([thread(.needsInput, unread: true, reply: 98)]), at: at(100))
        XCTAssertEqual(row(state)?.phase, .waitingForInput)
        XCTAssertEqual(policy.requestNotices(state.attention).count, 1, "a new reply can still ask")
    }

    func testAWaitingThreadIsReadAgainAfterAFailedSessionReadSoItsApprovalAppears() {
        var state = ClaudeCloudProjectState()
        let waiting = thread(.needsInput, reply: -2 * 86_400)
        func reads(_ seconds: TimeInterval) -> [String] {
            state.sessionsToRead(projects: [project], threads: [project.id: [waiting]], at: at(seconds))
        }
        XCTAssertTrue(reads(0).contains("cse_worker1"))
        state.apply(snapshot([waiting]), at: at(0))
        XCTAssertTrue(state.attention.isEmpty, "the session read failed")
        XCTAssertTrue(reads(600).contains("cse_worker1"), "a failed read is tried again")
        state.apply(snapshot([waiting], sessions: [ClaudeCloudSession(id: "cse_worker1", worker: .requiresAction)]), at: at(600))
        XCTAssertEqual(state.attention.map(\.kind), [.approval])

        var quiet = ClaudeCloudProjectState()
        _ = quiet.sessionsToRead(projects: [project], threads: [project.id: [waiting]], at: at(0))
        quiet.apply(snapshot([waiting], sessions: [worker(.blocked, category: .needInput)]), at: at(0))
        XCTAssertFalse(quiet.sessionsToRead(projects: [project], threads: [project.id: [waiting]], at: at(600)).contains("cse_worker1"),
                       "once read, an old unchanged question is not read every pass")
    }

    func testAQuestionThatArrivesJustAfterTheTurnEndedStillAsks() {
        var state = ClaudeCloudProjectState(), policy = AttentionPolicy()
        state.apply(snapshot([thread(.working, working: true, reply: -60)]), at: at(0))
        _ = policy.requestNotices(state.attention)
        state.apply(snapshot([thread(.idle, reply: 18)], sessions: [worker(.reviewReady)]), at: at(20))
        XCTAssertEqual(row(state)?.phase, .completed)
        state.apply(snapshot([thread(.needsInput, reply: 18)]), at: at(40))
        XCTAssertEqual(row(state)?.phase, .waitingForInput, "idle can come before needs_input for the same run")
        XCTAssertEqual(policy.requestNotices(state.attention).count, 1)
        state.apply(snapshot([thread(.needsInput, unread: true, reply: 18)]), at: at(70))
        XCTAssertEqual(row(state)?.phase, .waitingForInput, "the unread flag arrives later")
        XCTAssertEqual(state.attention.map(\.kind), [.input])
    }

    func testEachSessionOfAWaitingThreadIsReadOnceWhenAddedAndAcrossPasses() {
        var state = ClaudeCloudProjectState()
        let old = -2 * 86_400.0
        let one = thread(.needsInput, reply: old, sessions: ["cse_worker1"])
        _ = state.sessionsToRead(projects: [project], threads: [project.id: [one]], at: at(0))
        state.apply(snapshot([one], sessions: [worker(.blocked, category: .needInput)]), at: at(0))
        let two = thread(.needsInput, reply: old, sessions: ["cse_worker1", "cse_worker2"])
        let reads = state.sessionsToRead(projects: [project], threads: [project.id: [two]], at: at(600))
        XCTAssertTrue(reads.contains("cse_worker2"), "a newly bound session is read on an otherwise unchanged thread")
        XCTAssertFalse(reads.contains("cse_worker1"))
        state.apply(snapshot([two], sessions: [ClaudeCloudSession(id: "cse_worker2", worker: .requiresAction)]), at: at(600))
        XCTAssertEqual(state.attention.map(\.kind), [.approval])

        var crowded = ClaudeCloudProjectState(), read: Set<String> = []
        let ids = (1...17).map { String(format: "cse_many%02d", $0) }
        let many = thread(.needsInput, reply: old, sessions: ids)
        for pass in 0..<3 {
            let selected = crowded.sessionsToRead(projects: [project], threads: [project.id: [many]], at: at(Double(pass) * 600)).filter(ids.contains)
            if pass == 2 { XCTAssertTrue(selected.isEmpty, "every session was read once, over two passes") }
            read.formUnion(selected)
            crowded.apply(snapshot([many], sessions: selected.map { ClaudeCloudSession(id: $0, worker: .idle) }), at: at(Double(pass) * 600))
        }
        XCTAssertEqual(read.count, 17)
    }

    func testAnOlderSnapshotAfterAnEndingNeitherAsksNorClearsTheEnding() {
        var state = ClaudeCloudProjectState(), policy = AttentionPolicy()
        state.apply(snapshot([thread(.working, working: true, reply: -60)]), at: at(0))
        _ = policy.requestNotices(state.attention)
        state.apply(snapshot([thread(.idle, reply: 18)], sessions: [worker(.reviewReady)]), at: at(20))
        XCTAssertEqual(row(state)?.phase, .completed)
        state.apply(snapshot([thread(.needsInput, unread: true, reply: -30 * 86_400)]), at: at(40))
        XCTAssertEqual(row(state)?.phase, .completed, "an older reply is not the run that just ended")
        XCTAssertTrue(state.attention.isEmpty)
        XCTAssertTrue(policy.requestNotices(state.attention).isEmpty)
    }

    func testAQuestionWithoutAReplyTimeYetWaitsForIt() {
        var state = ClaudeCloudProjectState(), policy = AttentionPolicy()
        state.apply(snapshot([thread(.working, working: true, reply: -60)]), at: at(0))
        _ = policy.requestNotices(state.attention)
        state.apply(snapshot([thread(.idle, reply: 18)], sessions: [worker(.reviewReady)]), at: at(20))
        let undated = ClaudeCloudThread(id: "cmsg_thread1", projectID: project.id, status: .needsInput, sessionIDs: ["cse_worker1"])
        state.apply(snapshot([undated]), at: at(40))
        XCTAssertEqual(row(state)?.phase, .completed, "the ending stands until the question's reply time arrives")
        state.apply(snapshot([thread(.needsInput, unread: true, reply: 18)]), at: at(60))
        XCTAssertEqual(row(state)?.phase, .waitingForInput)
        XCTAssertEqual(policy.requestNotices(state.attention).count, 1)

        // Its read flag waits as well, or the ending would leave the inbox for good.
        var seen = ClaudeCloudProjectState()
        seen.apply(snapshot([thread(.working, working: true, reply: -60)]), at: at(0))
        seen.apply(snapshot([thread(.idle, reply: 18)], sessions: [worker(.reviewReady)]), at: at(20))
        seen.apply(snapshot([thread(.idle, unread: true, reply: 18)]), at: at(40))
        seen.apply(snapshot([undated]), at: at(60))
        XCTAssertEqual(row(seen)?.phase, .completed)
        XCTAssertNotEqual(row(seen)?.claudeCloud?.readInClaude, true, "an undated question cannot mark the ending read")
        seen.apply(snapshot([thread(.needsInput, unread: true, reply: 18)]), at: at(80))
        XCTAssertEqual(row(seen)?.phase, .waitingForInput)
    }

    func testAStaleRowStillShowsARunOrRequestItsSessionsReport() {
        func ended() -> ClaudeCloudProjectState {
            var state = ClaudeCloudProjectState()
            state.apply(snapshot([thread(.working, working: true, reply: -60)]), at: at(0))
            state.apply(snapshot([thread(.resolved, unread: true, reply: 18)], sessions: [worker(.reviewReady)]), at: at(20))
            return state
        }
        var running = ended()
        running.apply(snapshot([thread(.idle, reply: -60)], sessions: [worker(.working, worker: .running)]), at: at(40))
        XCTAssertEqual(row(running)?.phase, .running, "the session read with an older row is current")

        var asking = ended()
        let approval = ClaudeCloudSession(id: "cse_worker1", worker: .requiresAction, pending: .approval)
        asking.apply(snapshot([thread(.needsInput, reply: -60)], sessions: [approval]), at: at(40))
        XCTAssertEqual(row(asking)?.phase, .waitingForInput)
        XCTAssertEqual(asking.attention.map(\.kind), [.approval])

        // The older row's own state still changes nothing.
        var decided = ended()
        decided.apply(snapshot([thread(.working, working: true, reply: -60, decisions: 1)], sessions: [worker(.reviewReady)]), at: at(40))
        XCTAssertEqual(row(decided)?.phase, .completed)
        XCTAssertTrue(decided.attention.isEmpty)
    }

    func testAStaleRowChangesNeitherANewerEndingNorANewerQuestion() {
        var ending = ClaudeCloudProjectState()
        ending.apply(snapshot([thread(.working, working: true, reply: -60)]), at: at(0))
        ending.apply(snapshot([thread(.resolved, unread: true, reply: 18)], sessions: [worker(.reviewReady)]), at: at(20))
        XCTAssertEqual(row(ending)?.phase, .completed)
        ending.apply(snapshot([thread(.needsInput, reply: -30 * 86_400)]), at: at(40))
        XCTAssertNotEqual(row(ending)?.claudeCloud?.readInClaude, true, "an older row cannot mark the new ending read")
        ending.apply(snapshot([thread(.resolved, unread: true, reply: 18)]), at: at(60))
        XCTAssertEqual(row(ending)?.phase, .completed)
        XCTAssertNotEqual(row(ending)?.claudeCloud?.readInClaude, true)

        var asking = ClaudeCloudProjectState()
        asking.apply(snapshot([thread(.working, working: true, reply: -60)]), at: at(0))
        asking.apply(snapshot([thread(.needsInput, unread: true, reply: 18)]), at: at(20))
        XCTAssertEqual(row(asking)?.phase, .waitingForInput)
        asking.apply(snapshot([thread(.idle, reply: -60)], sessions: [worker(.reviewReady)]), at: at(40))
        XCTAssertEqual(row(asking)?.phase, .waitingForInput, "an older idle row cannot clear a newer question")
        XCTAssertEqual(asking.attention.map(\.kind), [.input])
        asking.apply(snapshot([thread(.idle, reply: -60)], sessions: [worker(.reviewReady)]), at: at(400))
        XCTAssertNotEqual(row(asking)?.phase, .waitingForInput, "after five minutes the older reply is the thread's state")
    }

    func testFirstLookAfterStartupDoesNotRaiseAnOldOrUndatedQuestion() {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([]), at: at(0))
        let noReply = ClaudeCloudThread(id: "cmsg_undated1", projectID: project.id, status: .needsInput, hasUnread: true,
            sessionIDs: [], createdAt: at(1))
        state.apply(snapshot([thread(.needsInput, unread: true, reply: -30 * 86_400), noReply]), at: at(20))
        XCTAssertTrue(state.activities.isEmpty)
        XCTAssertTrue(state.attention.isEmpty)
    }

    func testMissingSessionPreservesAWaitAndAnUnchangedReplyCannotFinishIt() {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([thread(.working, working: true)]), at: at(-20))
        state.apply(snapshot([thread(.needsInput, unread: true)]), at: at(0))
        state.apply(snapshot([thread(.idle)]), at: at(30))
        XCTAssertEqual(row(state)?.phase, .waitingForInput)
        XCTAssertEqual(state.attention.first?.detectedAt, at(0))
        state.apply(snapshot([thread(.idle)]), at: at(301))
        XCTAssertEqual(row(state)?.phase, .unknown)
        XCTAssertTrue(state.attention.isEmpty)
        state.apply(snapshot([thread(.idle)], sessions: [worker(.reviewReady)]), at: at(320))
        XCTAssertNil(row(state), "the old reply did not finish a new turn")
    }

    func testAThreadCanClearItsDecisionWhileTheSessionIsUnavailable() {
        for status in [ClaudeCloudThreadStatus.idle, .needsInput] {
            var state = ClaudeCloudProjectState()
            state.apply(snapshot([thread(.working, decisions: 1)]), at: at(0))
            XCTAssertEqual(state.attention.map(\.kind), [.decision])
            state.apply(snapshot([thread(status)]), at: at(20))
            XCTAssertTrue(state.attention.isEmpty)
            XCTAssertEqual(row(state)?.phase, status == .idle ? .unknown : nil)
        }
    }

    func testAnExplicitRequestCanEndWithTheSameReplyTimestamp() {
        let approval = ClaudeCloudSession(id: "cse_worker1", worker: .requiresAction)
        for (status, phase) in [(ClaudeCloudThreadStatus.resolved, ActivityPhase.completed), (.failed, .interrupted)] {
            var state = ClaudeCloudProjectState()
            state.apply(snapshot([thread(.needsInput)], sessions: [approval]), at: at(0))
            XCTAssertEqual(state.attention.map(\.kind), [.approval])
            state.apply(snapshot([thread(status)]), at: at(20))
            XCTAssertTrue(state.attention.isEmpty)
            XCTAssertEqual(row(state)?.phase, phase)
            XCTAssertEqual(row(state)?.turnFailed, status == .failed)
        }
    }

    func testAnUnreadPlainQuestionAgesOutWhileItIsTracked() {
        var state = ClaudeCloudProjectState()
        let oldQuestion = thread(.needsInput, unread: true, reply: -7 * 86_400 + 1)
        state.apply(snapshot([oldQuestion]), at: at(0))
        XCTAssertEqual(row(state)?.phase, .waitingForInput)
        state.apply(snapshot([oldQuestion]), at: at(2))
        XCTAssertNil(row(state))
        XCTAssertTrue(state.attention.isEmpty)
    }

    func testAnApprovalStaysUntilAnsweredEvenAfterItWasRead() {
        var state = ClaudeCloudProjectState()
        let approval = ClaudeCloudSession(id: "cse_worker1", worker: .requiresAction, pending: .approval)
        state.apply(snapshot([thread(.needsInput, unread: true)], sessions: [approval]), at: at(0))
        state.apply(snapshot([thread(.needsInput)], sessions: [approval]), at: at(20))
        XCTAssertEqual(state.attention.map(\.kind), [.approval])
        state.apply(snapshot([thread(.working, decisions: 1)]), at: at(40))
        XCTAssertEqual(state.attention.map(\.kind), [.decision])
    }

    func testRequestKeepsItsDetectionTimeWhileUnchanged() {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([thread(.needsInput, unread: true)]), at: at(0))
        state.apply(snapshot([thread(.needsInput, unread: true)]), at: at(20))
        XCTAssertEqual(state.attention.first?.detectedAt, at(0))
    }

    // MARK: Coordinator

    private func coordinator(_ worker: ClaudeCloudSession.Worker, unread: Bool = false, event: TimeInterval = 0, failed: Bool = false) -> ClaudeCloudSession {
        ClaudeCloudSession(id: "cse_coordinator1", worker: worker, isEnded: failed, isFailed: failed, hasUnread: unread, lastEventAt: at(event))
    }

    func testCoordinatorRunsAndEndsAsItsOwnRow() throws {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([], sessions: [coordinator(.idle, event: -600)]), at: at(0))
        XCTAssertNil(row(state, "cse_coordinator1"))
        state.apply(snapshot([], sessions: [coordinator(.running, event: 18)]), at: at(20))
        let running = try XCTUnwrap(row(state, "cse_coordinator1"))
        XCTAssertEqual(running.stage, .coordinating)
        XCTAssertEqual(running.title, L10n.text("claude.cloud.coordinator"))
        XCTAssertEqual(running.claudeCloud?.role, .coordinator)
        state.apply(snapshot([], sessions: [coordinator(.idle, unread: true, event: 38)]), at: at(40))
        XCTAssertEqual(row(state, "cse_coordinator1")?.phase, .completed)
    }

    func testCoordinatorHandingWorkToAThreadDoesNotReportAnEnding() {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([], sessions: [coordinator(.idle)]), at: at(0))
        state.apply(snapshot([], sessions: [coordinator(.running, event: 18)]), at: at(20))
        state.apply(snapshot([thread(.working, working: true)], sessions: [coordinator(.idle, unread: true, event: 38)]), at: at(40))
        XCTAssertNil(row(state, "cse_coordinator1"), "delegating is not an answer")
        XCTAssertEqual(row(state)?.phase, .running)
    }

    func testACoordinatorAsksOnlyWhileItsWorkerWaits() {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([], sessions: [coordinator(.idle)]), at: at(0))
        let listed = ClaudeCloudSession(id: "cse_coordinator1", worker: .running, lastEventAt: at(18), pending: .approval)
        state.apply(snapshot([], sessions: [listed]), at: at(20))
        XCTAssertTrue(state.attention.isEmpty, "a request list alone can outlive the action")
        XCTAssertEqual(row(state, "cse_coordinator1")?.phase, .running)
        let asking = ClaudeCloudSession(id: "cse_coordinator1", worker: .requiresAction, lastEventAt: at(38), pending: .input)
        state.apply(snapshot([], sessions: [asking]), at: at(40))
        XCTAssertEqual(state.attention.map(\.kind), [.input])
    }

    func testACoordinatorAskingForItsThreadStaysQuietButAskingItselfDoesNot() throws {
        let asking = ClaudeCloudSession(id: "cse_coordinator1", worker: .idle, bucket: .blocked, turnCategory: .needInput, hasUnread: true, lastEventAt: at(38))
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([thread(.resolved, reply: -3600), thread(.needsInput, unread: true, reply: -3000, sessions: ["cse_other01"], id: "cmsg_waitingtd")],
                             sessions: [coordinator(.idle)]), at: at(0))
        state.apply(snapshot([thread(.resolved, reply: -3600), thread(.needsInput, unread: true, reply: -3000, sessions: ["cse_other01"], id: "cmsg_waitingtd")],
                             sessions: [coordinator(.running, event: 18)]), at: at(20))
        state.apply(snapshot([thread(.resolved, reply: -3600), thread(.needsInput, unread: true, reply: -3000, sessions: ["cse_other01"], id: "cmsg_waitingtd")],
                             sessions: [asking]), at: at(40))
        XCTAssertNil(row(state, "cse_coordinator1"), "the waiting thread already asks")

        var direct = ClaudeCloudProjectState()
        direct.apply(snapshot([thread(.resolved, reply: -3600)], sessions: [coordinator(.idle)]), at: at(0))
        direct.apply(snapshot([thread(.resolved, reply: -3600)], sessions: [coordinator(.running, event: 18)]), at: at(20))
        direct.apply(snapshot([thread(.resolved, reply: -3600)], sessions: [asking]), at: at(40))
        let ended = try XCTUnwrap(row(direct, "cse_coordinator1"))
        XCTAssertEqual(ended.phase, .completed)
        XCTAssertEqual(ended.endingLabel, L10n.text("claude.cloud.turn_can_continue"))
    }

    func testACoordinatorWhoseThreadOutlivedThePollStaysQuiet() {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([], sessions: [coordinator(.idle)]), at: at(0))
        state.apply(snapshot([], sessions: [coordinator(.running, event: 18)]), at: at(20))
        let created = ClaudeCloudThread(id: "cmsg_thread1", projectID: project.id, status: .idle, lastReplyAt: at(25),
            sessionIDs: ["cse_worker1"], createdAt: at(25))
        state.apply(snapshot([created], sessions: [coordinator(.idle, unread: true, event: 38), worker(.working)]), at: at(40))
        XCTAssertNil(row(state, "cse_coordinator1"), "the thread it started runs in a long tool call")
        XCTAssertEqual(row(state)?.phase, .running)
    }

    func testACoordinatorReportingOnAThreadThatJustEndedDoesNotRepeatItsCard() throws {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([thread(.working, working: true)], sessions: [coordinator(.idle)]), at: at(0))
        state.apply(snapshot([thread(.resolved, unread: true, reply: 18)], sessions: [coordinator(.running, event: 18)]), at: at(20))
        XCTAssertEqual(row(state)?.phase, .completed)
        XCTAssertEqual(row(state, "cse_coordinator1")?.phase, .running)
        state.apply(snapshot([thread(.resolved, unread: true, reply: 18)], sessions: [coordinator(.idle, unread: true, event: 38)]), at: at(40))
        XCTAssertNil(row(state, "cse_coordinator1"), "the thread's own card already says it")
        XCTAssertEqual(row(state)?.phase, .completed)
    }

    func testACoordinatorAnsweringOnItsOwnStillEndsWithACard() throws {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([thread(.resolved, reply: -3600)], sessions: [coordinator(.idle)]), at: at(0))
        state.apply(snapshot([thread(.resolved, reply: -3600)], sessions: [coordinator(.running, event: 18)]), at: at(20))
        let answered = ClaudeCloudSession(id: "cse_coordinator1", worker: .idle, bucket: .reviewReady, turnCategory: .completed, hasUnread: true, lastEventAt: at(38))
        state.apply(snapshot([thread(.resolved, reply: -3600)], sessions: [answered]), at: at(40))
        let ended = try XCTUnwrap(row(state, "cse_coordinator1"))
        XCTAssertEqual(ended.phase, .completed)
        XCTAssertEqual(ended.endingLabel, L10n.text("activity.turn_finished"))
    }

    func testCoordinatorRunBetweenPollsShowsAsUnreadRisingOnce() throws {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([], sessions: [coordinator(.idle, event: -600)]), at: at(0))
        state.apply(snapshot([], sessions: [coordinator(.idle, unread: true, event: 18)]), at: at(20))
        let ended = try XCTUnwrap(row(state, "cse_coordinator1"))
        XCTAssertEqual(ended.phase, .completed)
        // Later events on a session still unread do not separate another run.
        state.apply(snapshot([], sessions: [coordinator(.idle, unread: true, event: 38)]), at: at(40))
        XCTAssertEqual(row(state, "cse_coordinator1")?.turnID, ended.turnID)
    }

    func testAnUnreadCoordinatorAtBaselineStaysQuiet() {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([], sessions: [coordinator(.idle, unread: true, event: -600)]), at: at(0))
        XCTAssertNil(row(state, "cse_coordinator1"))
        state.apply(snapshot([], sessions: [coordinator(.idle, unread: true, event: -600)]), at: at(20))
        XCTAssertNil(row(state, "cse_coordinator1"))
    }

    func testAnUnreadSessionNotReadThisPassKeepsItsCard() throws {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([], sessions: [coordinator(.idle)]), at: at(0))
        state.apply(snapshot([], sessions: [coordinator(.idle, unread: true, event: 18)]), at: at(20))
        state.apply(snapshot([]), at: at(600))
        XCTAssertEqual(row(state, "cse_coordinator1")?.claudeCloud?.readInClaude, false)
    }

    // MARK: Read state

    func testEndingReadInClaudeIsReportedOnlyAfterUnreadCouldHaveArrived() throws {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([thread(.working, working: true)]), at: at(0))
        state.apply(snapshot([thread(.resolved, reply: 18)]), at: at(20))
        XCTAssertEqual(row(state)?.claudeCloud?.readInClaude, false, "unread arrives after the ending")
        state.apply(snapshot([thread(.resolved, unread: true, reply: 18)]), at: at(44))
        XCTAssertEqual(row(state)?.claudeCloud?.readInClaude, false)
        state.apply(snapshot([thread(.resolved, reply: 18)]), at: at(64))
        XCTAssertEqual(row(state)?.claudeCloud?.readInClaude, true, "unread seen, then cleared in Claude")
    }

    func testEndingThatNeverTurnsUnreadWasReadAsItHappened() {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([thread(.working, working: true)]), at: at(0))
        state.apply(snapshot([thread(.resolved, reply: 18)]), at: at(20))
        state.apply(snapshot([thread(.resolved, reply: 18)]), at: at(80))
        XCTAssertEqual(row(state)?.claudeCloud?.readInClaude, false)
        state.apply(snapshot([thread(.resolved, reply: 18)]), at: at(20 + ClaudeCloudProjectState.readGrace))
        XCTAssertEqual(row(state)?.claudeCloud?.readInClaude, true)
    }

    // MARK: Source availability

    func testUnavailableSourceStopsVouchingThenRecoversTheEnding() throws {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([thread(.needsInput, unread: true)]), at: at(0))
        state.markUnavailable()
        XCTAssertEqual(row(state)?.phase, .unknown)
        XCTAssertTrue(state.attention.isEmpty)
        state.apply(snapshot([thread(.resolved, unread: true, reply: 300)]), at: at(320))
        let ended = try XCTUnwrap(row(state))
        XCTAssertEqual(ended.phase, .completed)
        XCTAssertTrue(ended.liveTurnStarted)
    }

    func testAProjectNotReadThisPassKeepsItsRowsAndAVanishedProjectDoesNot() {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([thread(.working, working: true)]), at: at(0))
        state.apply(ClaudeCloudSnapshot(projects: [project], threads: [:]), at: at(20))
        XCTAssertEqual(row(state)?.phase, .running)
        state.apply(ClaudeCloudSnapshot(projects: [], threads: [:]), at: at(40))
        XCTAssertNil(row(state))
    }

    // MARK: What to read

    func testSessionReadsAreBoundedAndFollowWhatCanChange() {
        var state = ClaudeCloudProjectState()
        let running = [thread(.working, working: true)]
        let first = state.sessionsToRead(projects: [project], threads: [project.id: running], at: at(0))
        XCTAssertEqual(first, ["cse_worker1", "cse_coordinator1"], "first look: the worker and the coordinator")
        state.apply(snapshot(running, sessions: [worker(.working), coordinator(.idle)]), at: at(0))
        XCTAssertEqual(state.sessionsToRead(projects: [project], threads: [project.id: [thread(.idle)]], at: at(20)), ["cse_worker1"],
                       "only its session can say a run with an idle row has ended")
        XCTAssertEqual(state.sessionsToRead(projects: [project], threads: [project.id: [thread(.needsInput)]], at: at(40)), ["cse_worker1"])

        let moved = ClaudeCloudProject(id: project.id, name: project.name, coordinatorSessionID: project.coordinatorSessionID, lastActivityAt: at(50))
        XCTAssertEqual(state.sessionsToRead(projects: [moved], threads: [:], at: at(60)), ["cse_coordinator1"])
        let many = (0..<40).map { ClaudeCloudThread(id: "cmsg_thread\($0)x", projectID: project.id, status: .needsInput, sessionIDs: ["cse_worker\($0)x"]) }
        XCTAssertEqual(state.sessionsToRead(projects: [project], threads: [project.id: many], at: at(60)).count, 16)
    }

    func testAQuietThreadCostsNothingUntilItMovesOrMayHaveBeenAnswered() {
        var state = ClaudeCloudProjectState()
        let done = thread(.resolved, reply: -60), old = thread(.idle, reply: -90_000, sessions: ["cse_oldone1"], id: "cmsg_oldthread")
        let idle = thread(.idle, reply: -120, sessions: ["cse_idle001"], id: "cmsg_idlethrd")
        XCTAssertEqual(state.sessionsToRead(projects: [project], threads: [project.id: [done, old, idle]], at: at(0)),
                       ["cse_coordinator1", "cse_worker1", "cse_idle001"], "recent threads get a first look and an old one does not")
        state.apply(snapshot([done, old, idle], sessions: [worker(.completed, category: .completed), coordinator(.idle),
            ClaudeCloudSession(id: "cse_idle001", worker: .idle, bucket: .reviewReady)]), at: at(0))
        XCTAssertEqual(state.sessionsToRead(projects: [project], threads: [project.id: [done, old, idle]], at: at(30)), [])
        XCTAssertEqual(state.sessionsToRead(projects: [project], threads: [project.id: [done, old, idle]], at: at(120)), ["cse_idle001"],
                       "answering an idle thread moves nothing on its row")
        let replied = thread(.resolved, unread: true, reply: 100)
        XCTAssertEqual(state.sessionsToRead(projects: [project], threads: [project.id: [replied, old, idle]], at: at(110)), ["cse_worker1"])
        XCTAssertEqual(state.sessionsToRead(projects: [project], threads: [project.id: [thread(.working, working: true, sessions: ["cse_abcdef1"])]], at: at(110), local: ["abcdef1"]), [],
                       "a session Desktop runs here is not read")
    }

    func testSessionReadBudgetRotatesWithoutInventingAnEnding() {
        var state = ClaudeCloudProjectState()
        let active = (0..<17).map { index in
            thread(.working, working: true, sessions: ["cse_worker\(index)x"], id: "cmsg_thread\(index)x")
        }
        state.apply(snapshot(active), at: at(0))
        let idle = (0..<17).map { index in
            thread(.idle, sessions: ["cse_worker\(index)x"], id: "cmsg_thread\(index)x")
        }
        var read = Set<String>()
        for offset in stride(from: 20, through: 320, by: 20) {
            let wanted = state.sessionsToRead(projects: [project], threads: [project.id: idle], at: at(Double(offset)))
            XCTAssertLessThanOrEqual(wanted.count, 16)
            read.formUnion(wanted)
            state.apply(snapshot(idle, sessions: wanted.map { ClaudeCloudSession(id: $0, worker: .idle, bucket: .working) }), at: at(Double(offset)))
            XCTAssertTrue(state.activities.filter { $0.claudeCloud?.role == .thread }.allSatisfy { $0.phase == .running })
        }
        XCTAssertTrue(Set(idle.flatMap(\.sessionIDs)).isSubset(of: read))

        let bound = (0..<5).map { "cse_bound\($0)x" }
        let shared = thread(.working, working: true, sessions: bound)
        var sharedRead = Set<String>()
        for step in 0..<3 {
            sharedRead.formUnion(state.sessionsToRead(projects: [project], threads: [project.id: [shared]], at: at(Double(step)), limit: 2))
        }
        XCTAssertTrue(Set(bound).isSubset(of: sharedRead), "the fourth bound session must get a turn too")
    }

    func testPollingFollowsWhatIsHappening() {
        XCTAssertEqual(ClaudeCloudPolling.delay(running: true, waiting: false, recentlyActive: false, expanded: false, failures: 0), 20)
        XCTAssertEqual(ClaudeCloudPolling.delay(running: false, waiting: false, recentlyActive: false, expanded: true, failures: 0), 30)
        XCTAssertEqual(ClaudeCloudPolling.delay(running: false, waiting: true, recentlyActive: false, expanded: false, failures: 0), 60)
        XCTAssertEqual(ClaudeCloudPolling.delay(running: false, waiting: false, recentlyActive: false, expanded: false, failures: 0), 120)
        XCTAssertEqual(ClaudeCloudPolling.delay(running: true, waiting: false, recentlyActive: false, expanded: false, failures: 1), 30)
        XCTAssertEqual(ClaudeCloudPolling.delay(running: true, waiting: false, recentlyActive: false, expanded: false, failures: 20), 900)
    }

    // MARK: Opening

    func testURLsOpenTheThreadOrTheProject() throws {
        let thread = ClaudeCloudContext(projectID: "chan_project1", projectName: "Launch plan", role: .thread)
        XCTAssertEqual(thread.url(session: "cmsg_thread1", web: false)?.absoluteString, "claude://code/project/chan_project1?thread=cmsg_thread1")
        XCTAssertEqual(thread.url(session: "cmsg_thread1", web: true)?.absoluteString, "https://claude.ai/code/project/chan_project1?thread=cmsg_thread1")
        let lead = ClaudeCloudContext(projectID: "chan_project1", projectName: "Launch plan", role: .coordinator)
        XCTAssertEqual(lead.url(session: "cse_coordinator1", web: false)?.absoluteString, "claude://code/project/chan_project1")

        var state = ClaudeCloudProjectState()
        state.apply(snapshot([self.thread(.working, working: true)]), at: at(0))
        let activity = try XCTUnwrap(row(state))
        XCTAssertEqual(activity.threadURL?.scheme, "claude")
        XCTAssertEqual(activity.claudeCloudWebURL?.host, "claude.ai")
        XCTAssertEqual(activity.id, "claude:claude-cloud:cmsg_thread1")
    }

    // MARK: Speed

    private func result(_ id: String = "event1", at offset: TimeInterval, tokens: Int = 1200, streaming: TimeInterval = 20, first: TimeInterval? = 2) -> ClaudeCloudTurnResult {
        ClaudeCloudTurnResult(id: id, completedAt: at(offset), outputTokens: tokens, streaming: streaming, firstOutput: first)
    }

    func testAnEndedThreadGetsItsTurnsSpeedAndFirstOutput() throws {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([thread(.working, working: true)]), at: at(0))
        XCTAssertTrue(state.turnResultsToRead().isEmpty, "a run has nothing to report yet")
        XCTAssertNil(row(state)?.displayedOutputEstimate(at: at(0)))
        state.apply(snapshot([thread(.resolved, unread: true, reply: 60)], sessions: [worker(.completed, category: .completed)]), at: at(80))
        let wanted = try XCTUnwrap(state.turnResultsToRead().first)
        XCTAssertEqual(wanted.thread, "cmsg_thread1")
        XCTAssertEqual(wanted.session, "cse_worker1")

        state.applyTurnResult(result(at: 65), thread: wanted.thread, at: at(80))
        let ended = try XCTUnwrap(row(state))
        XCTAssertEqual(ended.displayedOutputEstimate(at: at(80))?.value ?? 0, 60, accuracy: 0.01)
        XCTAssertEqual(ended.firstTokenLatency ?? 0, 2, accuracy: 0.01)
        XCTAssertEqual(ended.phase, .completed)
        XCTAssertTrue(state.turnResultsToRead().isEmpty, "one look per ending that found its result")

        state.apply(snapshot([thread(.resolved, unread: true, reply: 60)], sessions: []), at: at(120))
        XCTAssertEqual(row(state)?.displayedOutputEstimate(at: at(120))?.value ?? 0, 60, accuracy: 0.01, "later passes keep it")
    }

    func testAResultFromAnEarlierTurnIsLeftOutThenTheLookGivesUp() throws {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([thread(.working, working: true)]), at: at(0))
        state.apply(snapshot([thread(.resolved, unread: true, reply: 60)], sessions: [worker(.completed)]), at: at(80))
        state.applyTurnResult(result(at: 65), thread: "cmsg_thread1", at: at(80))

        state.apply(snapshot([thread(.working, working: true, reply: 60)]), at: at(100))
        XCTAssertTrue(state.turnResultsToRead().isEmpty)
        state.apply(snapshot([thread(.resolved, unread: true, reply: 130)], sessions: [worker(.completed)]), at: at(140))
        state.applyTurnResult(result(at: 65), thread: "cmsg_thread1", at: at(140))
        XCTAssertEqual(row(state)?.responsePerformance, nil, "the same result already belongs to the last turn")
        XCTAssertEqual(state.turnResultsToRead().count, 1, "it can land after the ending")
        state.applyTurnResult(result("older", at: 20), thread: "cmsg_thread1", at: at(160))
        XCTAssertEqual(row(state)?.responsePerformance, nil, "from before this run began")
        XCTAssertEqual(state.turnResultsToRead().count, 1)
        state.applyTurnResult(nil, thread: "cmsg_thread1", at: at(180))
        XCTAssertTrue(state.turnResultsToRead().isEmpty, "a card without a speed is fine")
        state.applyTurnResult(result("late", at: 135), thread: "cmsg_thread1", at: at(200))
        XCTAssertEqual(row(state)?.responsePerformance, nil, "no one asked anymore")
    }

    func testARerunShowsNoSpeedAndStaysOutOfTheTotal() throws {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([thread(.working, working: true)]), at: at(0))
        state.apply(snapshot([thread(.resolved, unread: true, reply: 60)], sessions: [worker(.completed)]), at: at(80))
        state.applyTurnResult(result(at: 65), thread: "cmsg_thread1", at: at(80))
        var overview = ActivityOverview(activities: state.activities, at: at(80))
        XCTAssertNil(overview.tokensPerSecond, "an ended card is not current throughput")
        XCTAssertNil(overview.displayedRate)

        state.apply(snapshot([thread(.working, working: true, reply: 60)]), at: at(90))
        XCTAssertEqual(row(state)?.phase, .running)
        XCTAssertNil(row(state)?.displayedOutputEstimate(at: at(90)), "the last turn's speed would read as live")
        overview = ActivityOverview(activities: state.activities, at: at(90))
        XCTAssertNil(overview.tokensPerSecond)
        XCTAssertNil(overview.displayedRate)
    }

    func testOnlyThreadsLookForASpeedAndLiveEndingsGoFirst() throws {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot([thread(.resolved, unread: true, reply: -600, sessions: ["cse_quiet001"], id: "cmsg_quietone"),
                              thread(.working, working: true)], sessions: [coordinator(.running)]), at: at(0))
        state.apply(snapshot([thread(.resolved, unread: true, reply: -600, sessions: ["cse_quiet001"], id: "cmsg_quietone"),
                              thread(.resolved, unread: true, reply: 18)],
                             sessions: [worker(.completed), coordinator(.idle, unread: true, event: 18)]), at: at(20))
        XCTAssertEqual(state.turnResultsToRead().map(\.thread), ["cmsg_thread1", "cmsg_quietone"], "never the coordinator")
        XCTAssertEqual(state.turnResultsToRead(limit: 1).map(\.session), ["cse_worker1"])
    }

    func testAThreadWithSeveralSessionsLooksAtTheLatestOne() throws {
        var state = ClaudeCloudProjectState()
        let sessions = ["cse_worker1", "cse_worker2"]
        state.apply(snapshot([thread(.working, working: true, sessions: sessions)]), at: at(0))
        state.apply(snapshot([thread(.resolved, unread: true, reply: 18, sessions: sessions)], sessions: [
            ClaudeCloudSession(id: "cse_worker1", worker: .idle, lastEventAt: at(5)), ClaudeCloudSession(id: "cse_worker2", worker: .idle, lastEventAt: at(18))]), at: at(20))
        XCTAssertEqual(state.turnResultsToRead().first?.session, "cse_worker2")
    }

    // MARK: Completion inbox

    func testInboxKeepsOneUnreadCardAcrossIdleAndResolved() throws {
        var state = ClaudeCloudProjectState(), inbox = CompletionInbox()
        state.apply(snapshot([thread(.working, working: true)]), at: at(0))
        inbox.observe(state.activities, at: at(0), retention: 1800)
        state.apply(snapshot([thread(.idle, reply: 18)], sessions: [worker(.reviewReady)]), at: at(20))
        inbox.observe(state.activities, at: at(20), retention: 1800)
        XCTAssertEqual(inbox.unreadActivities.count, 1)
        state.apply(snapshot([thread(.resolved, unread: true, reply: 40)]), at: at(44))
        inbox.observe(state.activities, at: at(44), retention: 1800)
        let card = try XCTUnwrap(inbox.unreadActivities.first)
        XCTAssertEqual(inbox.unreadActivities.count, 1)
        XCTAssertEqual(card.endingLabel, L10n.text("activity.resolved"))
    }

    func testBaselineCardIsNotUnreadButNewRunIs() {
        var state = ClaudeCloudProjectState(), inbox = CompletionInbox()
        state.apply(snapshot([thread(.resolved, unread: true, reply: -60)]), at: at(0))
        inbox.observe(state.activities, at: at(0), retention: 1800)
        XCTAssertTrue(inbox.unreadActivities.isEmpty)
        state.apply(snapshot([thread(.working, working: true, reply: -60)]), at: at(20))
        inbox.observe(state.activities, at: at(20), retention: 1800)
        state.apply(snapshot([thread(.resolved, unread: true, reply: 38)]), at: at(40))
        inbox.observe(state.activities, at: at(40), retention: 1800)
        XCTAssertEqual(inbox.unreadActivities.count, 1)
    }

    // MARK: Monitor

    private actor Requests {
        var paths: [String] = []
        func add(_ path: String) { paths.append(path) }
    }
    private actor ReplyGate {
        private var reached = false
        private var released = false
        private var ready: CheckedContinuation<Void, Never>?
        private var reply: CheckedContinuation<Void, Never>?
        func pause() async {
            reached = true; ready?.resume(); ready = nil
            if !released { await withCheckedContinuation { reply = $0 } }
        }
        func waitUntilReached() async {
            if !reached { await withCheckedContinuation { ready = $0 } }
        }
        func release() { released = true; reply?.resume(); reply = nil }
    }
    private final class Box: @unchecked Sendable {
        private let lock = NSLock(); private var value: Date
        init(_ value: Date) { self.value = value }
        var date: Date { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    }
    private static func cookies() -> ClaudeWebSession {
        ClaudeWebSession(cookieHeader: "sessionKey=sk-ant-sid01-abcdefghijklmnop", sessionHash: ClaudeQuotaDecoder.digest("sk-ant-sid01-abcdefghijklmnop"),
            organizationID: "00000000-0000-4000-8000-000000000001", userAgent: "Pacer-Test")
    }
    private func response(_ url: URL?, _ code: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url!, statusCode: code, httpVersion: nil, headerFields: headers)!
    }

    func testAnUnchangedOldQuestionDoesNotReturnAfterAQuietProjectSkipsItsRead() async throws {
        let clock = Box(base), requests = Requests()
        let stamp = ISO8601DateFormatter().string(from: at(-30 * 86_400))
        let monitor = ClaudeCloudProjectMonitor(cookieProvider: { Self.cookies() }, transport: { [self] request in
            let path = request.url!.path
            await requests.add(path)
            let body: [String: Any]
            if path == "/v1/code/channels" {
                body = ["channels": [["id": "chan_project1", "name": "Synthetic project", "last_message_at": stamp]]]
            } else if path.hasSuffix("/threads") {
                body = ["sections": [["data": [
                    ["id": "cmsg_thread1", "thread_status": "needs_input", "last_reply_at": stamp, "has_unread": false],
                    ["id": "cmsg_thread2", "thread_status": "needs_input", "last_reply_at": stamp, "has_unread": true]
                ]]]]
            } else {
                throw ClaudeCloudFailure.invalidReply
            }
            return (try JSONSerialization.data(withJSONObject: body), response(request.url, 200))
        }, now: { clock.date })
        await monitor.observe { activities, status, attention in
            XCTAssertEqual(status?.connected, true)
            XCTAssertTrue(activities.isEmpty, "an unchanged old question is not a task")
            XCTAssertTrue(attention.isEmpty)
        }
        for (seconds, reads) in [(0.0, 1), (120.0, 1), (600.0, 2), (720.0, 2), (1200.0, 3)] {
            clock.date = at(seconds)
            _ = await monitor.pollOnce()
            let paths = await requests.paths
            XCTAssertEqual(paths.filter { $0.hasSuffix("/threads") }.count, reads)
        }
        await monitor.shutdown()
    }

    func testMonitorSendsOnlyReadsWithTheExpectedHeadersAndPublishes() async throws {
        let seen = Requests()
        let monitor = ClaudeCloudProjectMonitor(cookieProvider: { Self.cookies() }, transport: { [self] request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-organization-uuid"), "00000000-0000-4000-8000-000000000001")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-client-feature"), "ccr")
            XCTAssertFalse(request.httpShouldHandleCookies)
            let path = request.url!.path
            await seen.add(path)
            let body: [String: Any]
            if path == "/v1/code/channels" {
                body = ["channels": [["id": "chan_project1", "name": "Launch plan", "overview_session_id": "cse_coordinator1"]]]
            } else if path.hasSuffix("/threads") {
                body = ["sections": [["data": [["id": "cmsg_thread1", "thread_status": "working", "thread_any_session_working": true,
                                                 "bound_sessions": [["id": "cse_worker1", "title": "Draft"]]]]]]]
            } else {
                body = ["response_shape": ["id": path.hasSuffix("cse_worker1") ? "cse_worker1" : "cse_coordinator1", "worker_status": "idle"]]
            }
            return (try JSONSerialization.data(withJSONObject: body), self.response(request.url, 200))
        }, now: { [base] in base })
        final class Sink: @unchecked Sendable { var activities: [SessionActivity] = []; var status: RuntimeStreamStatus? }
        let sink = Sink()
        await monitor.observe { values, status, _ in sink.activities = values; sink.status = status }
        let delay = await monitor.pollOnce()
        XCTAssertEqual(delay, 20)
        XCTAssertEqual(sink.status?.connected, true)
        XCTAssertEqual(sink.activities.first?.threadID, "cmsg_thread1")
        let paths = await seen.paths
        XCTAssertTrue(paths.allSatisfy { $0.hasPrefix("/v1/code/") })
        XCTAssertTrue(paths.contains("/v1/code/sessions/cse_worker1"))
    }

    func testMonitorReadsAnEndingsSpeedInTheSamePassAndOnlyOnce() async throws {
        final class Reply: @unchecked Sendable { var status = "working" }
        final class Sink: @unchecked Sendable { var activities: [SessionActivity] = [] }
        let reply = Reply(), sink = Sink(), clock = Box(base), seen = Requests()
        let stamp = ISO8601DateFormatter().string(from: base.addingTimeInterval(100))
        let monitor = ClaudeCloudProjectMonitor(cookieProvider: { Self.cookies() }, transport: { [self] request in
            let path = request.url!.path
            await seen.add(path)
            let body: [String: Any]
            if path == "/v1/code/channels" {
                body = ["channels": [["id": "chan_project1", "name": "Launch plan"]]]
            } else if path.hasSuffix("/threads") {
                body = ["sections": [["data": [["id": "cmsg_thread1", "thread_status": reply.status, "thread_any_session_working": reply.status == "working",
                    "has_unread": reply.status != "working", "last_reply_at": stamp, "bound_sessions": [["id": "cse_worker1"]]]]]]]
            } else if path.hasSuffix("/events") {
                XCTAssertEqual(request.url?.query, "limit=8")
                body = ["data": [["event_type": "result", "sequence_num": 3, "event_id": "event3", "created_at": stamp,
                                  "payload": ["usage": ["output_tokens": 1200], "process_wall_ms_streaming": 20000, "ttft_ms": 1500]]]]
            } else {
                body = ["session": ["id": "cse_worker1", "worker_status": reply.status == "working" ? "running" : "idle"]]
            }
            return (try JSONSerialization.data(withJSONObject: body), self.response(request.url, 200))
        }, now: { clock.date })
        await monitor.observe { values, _, _ in sink.activities = values }
        _ = await monitor.pollOnce()
        var events = await seen.paths.filter { $0.hasSuffix("/events") }
        XCTAssertTrue(events.isEmpty, "a run has no result to read")

        reply.status = "resolved"; clock.date = at(120)
        _ = await monitor.pollOnce()
        let ended = try XCTUnwrap(sink.activities.first)
        XCTAssertEqual(ended.phase, .completed)
        XCTAssertEqual(ended.displayedOutputEstimate(at: at(120))?.value ?? 0, 60, accuracy: 0.01)
        XCTAssertEqual(ended.firstTokenLatency ?? 0, 1.5, accuracy: 0.01)

        clock.date = at(150)
        _ = await monitor.pollOnce()
        events = await seen.paths.filter { $0.hasSuffix("/events") }
        XCTAssertEqual(events, ["/v1/code/sessions/cse_worker1/events"])
    }

    func testMonitorBacksOffAndReportsEachFailureItsOwnWay() async throws {
        final class Reply: @unchecked Sendable { var code = 500; var headers: [String: String] = [:] }
        final class Sink: @unchecked Sendable { var status: RuntimeStreamStatus?; var published = 0 }
        let reply = Reply(), sink = Sink(), clock = Box(base)
        let monitor = ClaudeCloudProjectMonitor(cookieProvider: { Self.cookies() }, transport: { [self] request in
            (Data("{}".utf8), self.response(request.url, reply.code, headers: reply.headers))
        }, now: { clock.date })
        await monitor.observe { _, status, _ in sink.status = status; sink.published += 1 }

        var delay = await monitor.pollOnce()
        XCTAssertEqual(delay, 30)
        XCTAssertEqual(sink.status?.hasConnectionFailure, true)
        delay = await monitor.pollOnce()
        XCTAssertEqual(delay, 60)

        reply.code = 429; reply.headers = ["Retry-After": "300"]
        delay = await monitor.pollOnce()
        XCTAssertEqual(delay, 300)

        reply.code = 401; reply.headers = [:]
        delay = await monitor.pollOnce()
        XCTAssertEqual(delay, 60)
        XCTAssertEqual(sink.status?.sourceAvailable, false)
        XCTAssertEqual(sink.status?.hasConnectionFailure, false)
        let rejected = sink.published
        reply.code = 200
        _ = await monitor.pollOnce()
        XCTAssertEqual(sink.published, rejected + 1)
        XCTAssertEqual(sink.status?.sourceAvailable, false, "a rejected session stays rejected until a new sign-in")
    }

    func testAccountWithoutProjectsShowsNothing() async {
        final class Sink: @unchecked Sendable { var status: RuntimeStreamStatus? = RuntimeStreamStatus() }
        let sink = Sink(), clock = Box(base)
        let monitor = ClaudeCloudProjectMonitor(cookieProvider: { Self.cookies() }, transport: { [self] request in
            (Data(), self.response(request.url, 404))
        }, now: { clock.date })
        await monitor.observe { _, status, _ in sink.status = status }
        let delay = await monitor.pollOnce()
        XCTAssertEqual(delay, 1800)
        XCTAssertNil(sink.status)
    }

    func testSuspendingKeepsWhatWasRunningToReportHowItEnded() async throws {
        final class Sink: @unchecked Sendable { var activities: [SessionActivity] = [] }
        final class Reply: @unchecked Sendable { var status = "working"; var reply = "2027-01-15T08:00:00Z" }
        let sink = Sink(), reply = Reply(), clock = Box(base)
        let monitor = ClaudeCloudProjectMonitor(cookieProvider: { Self.cookies() }, transport: { [self] request in
            let path = request.url!.path
            let body: [String: Any] = path == "/v1/code/channels" ? ["channels": [["id": "chan_project1", "name": "Launch plan"]]]
                : ["sections": [["data": [["id": "cmsg_thread1", "thread_status": reply.status, "thread_any_session_working": reply.status == "working",
                                           "has_unread": reply.status != "working", "last_reply_at": reply.reply]]]]]
            return (try JSONSerialization.data(withJSONObject: body), self.response(request.url, 200))
        }, now: { clock.date })
        await monitor.observe { values, _, _ in sink.activities = values }
        _ = await monitor.pollOnce()
        XCTAssertEqual(sink.activities.first?.phase, .running)
        reply.status = "resolved"
        clock.date = at(8 * 3600)
        await monitor.suspend()
        _ = await monitor.pollOnce()
        let ended = try XCTUnwrap(sink.activities.first)
        XCTAssertEqual(ended.phase, .completed)
        XCTAssertTrue(ended.liveTurnStarted, "an ending found on wake still reminds")
    }

    func testSigningOutClearsWhatWasBeingFollowed() async {
        final class Sink: @unchecked Sendable { var activities: [SessionActivity] = [] }
        final class Session: @unchecked Sendable { var value: ClaudeWebSession? }
        let sink = Sink(), session = Session()
        session.value = Self.cookies()
        let monitor = ClaudeCloudProjectMonitor(cookieProvider: { session.value }, transport: { [self] request in
            let path = request.url!.path
            let body: [String: Any] = path == "/v1/code/channels" ? ["channels": [["id": "chan_project1", "name": "Launch plan"]]]
                : ["sections": [["data": [["id": "cmsg_thread1", "thread_status": "working", "thread_any_session_working": true]]]]]
            return (try JSONSerialization.data(withJSONObject: body), self.response(request.url, 200))
        }, now: { [base] in base })
        await monitor.observe { values, _, _ in sink.activities = values }
        _ = await monitor.pollOnce()
        XCTAssertEqual(sink.activities.count, 1)
        session.value = nil
        _ = await monitor.pollOnce()
        XCTAssertTrue(sink.activities.isEmpty)
    }

    func testSessionAndOrganizationChangesDiscardInFlightRepliesAndResults() async throws {
        final class Binding: @unchecked Sendable {
            var cookies: ClaudeWebSession? = ClaudeCloudProjectTests.cookies()
            var organization: String?
            var ended = false
            var changed = false
        }
        final class Sink: @unchecked Sendable { var activities: [SessionActivity] = [] }
        for path in ["/threads", "/events"] {
            for change in 0..<3 {
                let binding = Binding(), sink = Sink(), clock = Box(base)
                let monitor = ClaudeCloudProjectMonitor(cookieProvider: { binding.cookies }, selectedOrganization: { binding.organization }, transport: { [self] request in
                    let target = request.url!.path
                    let stamp = ISO8601DateFormatter().string(from: clock.date)
                    if binding.ended, target.hasSuffix(path), !binding.changed {
                        binding.changed = true
                        switch change {
                        case 0: binding.cookies = nil
                        case 1:
                            let token = "sk-ant-sid01-abcdefghijklmnop2"
                            binding.cookies = ClaudeWebSession(cookieHeader: "sessionKey=" + token, sessionHash: ClaudeQuotaDecoder.digest(token), organizationID: Self.cookies().organizationID)
                        default: binding.organization = "00000000-0000-4000-8000-000000000002"
                        }
                    }
                    let body: [String: Any]
                    if target == "/v1/code/channels" { body = ["channels": [["id": "chan_project1", "name": "Launch plan"]]] }
                    else if target.hasSuffix("/threads") {
                        body = ["sections": [["data": [["id": "cmsg_thread1", "thread_status": binding.ended ? "resolved" : "working",
                            "has_unread": binding.ended, "last_reply_at": stamp, "bound_sessions": [["id": "cse_worker1"]]]]]]]
                    } else if target.hasSuffix("/events") {
                        body = ["data": [["event_type": "result", "sequence_num": 3, "event_id": "event3", "created_at": stamp,
                            "payload": ["usage": ["output_tokens": 1200], "process_wall_ms_streaming": 20000]]]]
                    } else { body = ["session": ["id": "cse_worker1", "worker_status": binding.ended ? "idle" : "running"]] }
                    return (try JSONSerialization.data(withJSONObject: body), self.response(request.url, 200))
                }, now: { clock.date })
                await monitor.observe { values, _, _ in sink.activities = values }
                _ = await monitor.pollOnce()
                XCTAssertEqual(sink.activities.first?.phase, .running)
                binding.ended = true; clock.date = at(20)
                _ = await monitor.pollOnce()
                XCTAssertTrue(binding.changed)
                XCTAssertTrue(sink.activities.isEmpty, "a changed binding discards \(path), including an already projected ending")
                await monitor.shutdown()
            }
        }
    }

    func testChangingAccountsDoesNotInheritThePreviousAccountsNotEnabledBackoff() async throws {
        final class Binding: @unchecked Sendable {
            var cookies = ClaudeCloudProjectTests.cookies()
            var enabled = false
        }
        final class Sink: @unchecked Sendable { var status: RuntimeStreamStatus? }
        let binding = Binding(), sink = Sink()
        let monitor = ClaudeCloudProjectMonitor(cookieProvider: { binding.cookies }, transport: { [self] request in
            let data = try JSONSerialization.data(withJSONObject: ["channels": []])
            return (data, self.response(request.url, binding.enabled ? 200 : 404))
        }, now: { [base] in base })
        await monitor.observe { _, status, _ in sink.status = status }
        let first = await monitor.pollOnce()
        XCTAssertEqual(first, 1800)
        let token = "sk-ant-sid01-abcdefghijklmnop2"
        binding.cookies = ClaudeWebSession(cookieHeader: "sessionKey=" + token, sessionHash: ClaudeQuotaDecoder.digest(token), organizationID: Self.cookies().organizationID)
        binding.enabled = true
        _ = await monitor.pollOnce()
        XCTAssertEqual(sink.status?.connected, true)
        await monitor.shutdown()
    }

    func testRefreshAndSuspendInvalidateAnOutstandingPoll() async throws {
        final class Sink: @unchecked Sendable { var publications = 0 }
        for suspend in [false, true] {
            let gate = ReplyGate(), sink = Sink()
            let monitor = ClaudeCloudProjectMonitor(cookieProvider: { Self.cookies() }, transport: { [self] request in
                let body: [String: Any]
                if request.url!.path == "/v1/code/channels" { body = ["channels": [["id": "chan_project1", "name": "Launch plan"]]] }
                else {
                    await gate.pause()
                    body = ["sections": [["data": [["id": "cmsg_thread1", "thread_status": "working"]]]]]
                }
                return (try JSONSerialization.data(withJSONObject: body), self.response(request.url, 200))
            }, now: { [base] in base })
            await monitor.observe { _, _, _ in sink.publications += 1 }
            let poll = Task { await monitor.pollOnce() }
            await gate.waitUntilReached()
            if suspend { await monitor.suspend() } else { await monitor.refresh() }
            await gate.release()
            _ = await poll.value
            XCTAssertEqual(sink.publications, 0, "a replaced poll must not publish or report a connection failure")
            await monitor.shutdown()
        }
    }
}
