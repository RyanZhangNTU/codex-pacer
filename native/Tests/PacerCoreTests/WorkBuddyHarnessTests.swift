import Foundation
import SQLite3
import XCTest
@testable import PacerCore

final class WorkBuddyHarnessTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_800_000_000)
    private let updated: Int64 = 1_800_000_000_000

    private struct NoEvents: ActivityFileEvents {
        func watch(_ url: URL, isDirectory: Bool,
                   changed: @escaping @Sendable (ActivityFileEvent) -> Void) -> (any ActivityFileWatch)? { nil }
    }

    private actor Updates {
        var history: [HarnessActivity] = []
        func append(_ value: HarnessActivity) { history.append(value) }
    }

    private final class Fixture {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(Foundation.UUID().uuidString)
        static let owner = "11111111-1111-1111-1111-111111111111"
        static let otherOwner = "22222222-2222-2222-2222-222222222222"
        static let session = "33333333-3333-3333-3333-333333333333"
        private var db: OpaquePointer?

        init() throws {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let url = home.appendingPathComponent("workbuddy.db")
            guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
            try exec("PRAGMA journal_mode=WAL")
            try selectAccount(Self.owner)
        }

        deinit {
            if let db { sqlite3_close(db) }
            try? FileManager.default.removeItem(at: home)
        }

        func exec(_ sql: String) throws {
            let query = sql.replacingOccurrences(of: "'account-a'", with: "'\(Self.owner)'")
                .replacingOccurrences(of: "'account-b'", with: "'\(Self.otherOwner)'")
                .replacingOccurrences(of: "'account'", with: "'\(Self.owner)'")
            guard sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        }

        func selectAccount(_ owner: String?) throws {
            let directory = home.appendingPathComponent("storage/skeleton", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("account-snapshot.json")
            if let owner {
                try Data("{\"primary\":{\"version\":1,\"uid\":\"\(owner)\"}}".utf8).write(to: file)
            } else { try FileManager.default.removeItem(at: file) }
        }

        func createSessions() throws {
            try exec("""
                CREATE TABLE sessions(id TEXT PRIMARY KEY, user_id TEXT, status TEXT, updated_at INTEGER, deleted_at INTEGER,
                transport TEXT, visibility TEXT, is_playground INTEGER, is_background_automation INTEGER, title TEXT)
                """)
        }
    }

    private func monitor() throws -> any LocalHarnessMonitor {
        var modules = LocalHarnessMonitors(platform: .windows, io: .init(files: TestFileSystem(), events: NoEvents(), now: { [at] in at }))
        let definition = try XCTUnwrap(modules.definition(for: WorkBuddyHarness.id))
        return modules.monitor(for: definition)
    }

    func testPublishedWorkHasStableIdentityAndNoNotificationOnStop() async throws {
        let fixture = try Fixture(), monitor = try monitor(), updates = Updates()
        try fixture.createSessions()
        try fixture.exec("""
            INSERT INTO sessions VALUES
            ('test-active','account','working',\(updated),NULL,'local',NULL,0,NULL,'fixture title'),
            ('test-planning','account','planning',\(updated - 1),NULL,'local',NULL,0,0,NULL),
            ('test-pending','account','pending',\(updated),NULL,'local',NULL,0,0,NULL),
            ('test-cloud','cloud-account','working',\(updated),NULL,'cloud',NULL,0,0,NULL),
            ('test-deleted','account','working',\(updated),\(updated),'local',NULL,0,0,NULL),
            ('test-hidden','account','working',\(updated),NULL,'local','hidden',0,0,NULL),
            ('test-playground','account','working',\(updated - 2),NULL,'local',NULL,1,0,NULL),
            ('test-job','account','working',\(updated),NULL,'local',NULL,0,1,NULL),
            ('test-old','account','working',\(updated - 901_000),NULL,'local',NULL,0,0,NULL),
            ('test-future','account','working',\(updated + 60_000),NULL,'local',NULL,0,0,NULL)
            """)
        await monitor.start(home: fixture.home, policy: .expanded) { await updates.append($0) }
        await monitor.refresh()
        let initial = await updates.history
        XCTAssertEqual(initial.count, 1, "An unchanged refresh should not publish twice")
        let start = try XCTUnwrap(initial.first)
        XCTAssertEqual(start.status, .ready)
        XCTAssertEqual(start.activities.map(\.stage), [.working, .starting, .working])
        let active = try XCTUnwrap(start.activities.first)
        XCTAssertFalse(active.id.contains("test-active"))
        XCTAssertEqual(active.project, "WorkBuddy")
        XCTAssertEqual(ActivityTaskRowPresentation.title(active, hideProjects: true), "WorkBuddy")
        XCTAssertNil(active.title)
        XCTAssertNil(active.turnID)
        XCTAssertNil(active.threadURL)

        let provider = WorkBuddyHarness.id
        var state = ActivityApplicationState()
        state.replaceHarness(provider, with: start)
        let running = state.reconcile(at: at, retention: 1800, visibility: .init())
        XCTAssertEqual(running.activities.count, 3, "WorkBuddy flags ordinary tasks from its home screen as playground sessions")
        XCTAssertTrue(running.requests.isEmpty)
        XCTAssertTrue(running.notices.isEmpty)
        XCTAssertTrue(state.presentation(at: at).rows.allSatisfy { $0.rate == nil && $0.ratePlaceholder != nil })

        try fixture.exec("UPDATE sessions SET updated_at=\(updated + 1) WHERE id='test-active'")
        await monitor.refresh()
        let touched = await updates.history.last
        XCTAssertEqual(touched?.activities.first?.id, active.id)
        try fixture.exec("UPDATE sessions SET status='completed' WHERE id IN ('test-active','test-planning','test-playground')")
        await monitor.refresh()
        let history = await updates.history
        state.replaceHarness(provider, with: try XCTUnwrap(history.last))
        let settled = state.reconcile(at: at, retention: 1800, visibility: .init())
        XCTAssertTrue(settled.activities.isEmpty)
        XCTAssertTrue(settled.notices.isEmpty)
        XCTAssertTrue(state.inbox.activities.isEmpty)
        await monitor.stop()
        await monitor.refresh()
        let afterStop = await updates.history
        XCTAssertEqual(afterStop.count, history.count)
    }

    func testVerifiedOwnerChangeClearsRowsAndIncompatibleSchemaIsReported() async throws {
        let fixture = try Fixture(), monitor = try monitor(), updates = Updates()
        try fixture.createSessions()
        try fixture.exec("INSERT INTO sessions VALUES ('task-a','account-a','working',\(updated),NULL,'local',NULL,0,0,NULL)")
        await monitor.start(home: fixture.home, policy: .collapsed) { await updates.append($0) }
        let initial = await updates.history
        XCTAssertEqual(initial.last?.activities.count, 1)
        try fixture.exec("INSERT INTO sessions VALUES ('task-b','account-b','completed',\(updated),NULL,'local',NULL,0,0,NULL)")
        await monitor.refresh()
        let multiple = await updates.history
        XCTAssertEqual(multiple.last?.status, .ready)
        XCTAssertEqual(multiple.last?.activities.count, 1, "Other signed-out accounts must not affect the selected one")
        try fixture.selectAccount(nil)
        await monitor.refresh()
        let signedOut = await updates.history
        XCTAssertEqual(signedOut.last?.status, .unavailable)
        XCTAssertEqual(signedOut.last?.activities.count, 0)
        try fixture.selectAccount(Fixture.otherOwner)
        try fixture.exec("DROP TABLE sessions; CREATE TABLE sessions(id TEXT)")
        await monitor.refresh()
        let incompatible = await updates.history
        XCTAssertEqual(incompatible.last?.status, .incompatible)
        XCTAssertEqual(incompatible.last?.activities.count, 0)
        await monitor.stop()
    }

    func testAutomationRunsKeepOneIdentityThroughQueueQuestionProgressAndCompletion() async throws {
        let fixture = try Fixture(), monitor = try monitor(), updates = Updates()
        try fixture.createSessions()
        let session = Fixture.session
        try fixture.exec("""
            ALTER TABLE sessions ADD COLUMN cwd TEXT;
            CREATE TABLE automations(id TEXT PRIMARY KEY,owner_user_id TEXT,deleted_at INTEGER);
            CREATE TABLE automation_runs(thread_id TEXT PRIMARY KEY,automation_id TEXT,status TEXT,created_at INTEGER,
                updated_at INTEGER,result_success INTEGER,reason_code TEXT,metadata_json TEXT);
            CREATE INDEX idx_automation_runs_status_created_at ON automation_runs(status,created_at);
            CREATE TABLE session_usage(session_id TEXT PRIMARY KEY,used INTEGER,size INTEGER,updated_at INTEGER,credit_json TEXT);
            INSERT INTO automations VALUES ('local-job','account',NULL),('other-job','account-b',NULL),('deleted-job','account',1);
            INSERT INTO automation_runs VALUES
            ('run-1','local-job','QUEUED',\(updated - 10000),\(updated - 10000),NULL,NULL,NULL),
            ('foreign','other-job','IN_PROGRESS',\(updated),\(updated),NULL,NULL,NULL),
            ('deleted','deleted-job','IN_PROGRESS',\(updated),\(updated),NULL,NULL,NULL),
            ('archived','local-job','ARCHIVED',\(updated),\(updated),1,NULL,NULL),
            ('contradictory','local-job','IN_PROGRESS',\(updated),\(updated),1,NULL,NULL),
            ('stale','local-job','IN_PROGRESS',\(updated - 901000),\(updated - 901000),NULL,NULL,NULL);
            """)
        await monitor.start(home: fixture.home, policy: .expanded) { await updates.append($0) }
        let queued = await updates.history.last
        let initial = try XCTUnwrap(queued?.activities.first)
        XCTAssertEqual(queued?.activities.count, 1)
        XCTAssertEqual(initial.stage, .starting)
        XCTAssertEqual(initial.phase, .running)

        try fixture.exec("""
            INSERT INTO sessions VALUES ('\(session)','account','pending',\(updated - 1000),NULL,'local',NULL,0,1,
                'PRIVATE SESSION TITLE','C:/fixture');
            INSERT INTO session_usage VALUES ('\(session)',120,200, \(updated - 500),'{"r1":2.5}');
            UPDATE automation_runs SET status='IN_PROGRESS',created_at=\(updated - 9000),updated_at=\(updated - 8000),
                metadata_json='{"conversationId":"\(session)","sessionId":"\(session)","resultTitle":"PRIVATE RESULT"}' WHERE thread_id='run-1';
            """)
        let workspace = fixture.home.appendingPathComponent("projects/C-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let transcript = workspace.appendingPathComponent(session + ".jsonl")
        let lines = """
            {"type":"message","role":"user","sessionId":"\(session)","id":"u1","timestamp":\(updated - 7000),"providerData":{"conversationRequestId":"r1","startsNewUserRequest":true}}
            {"type":"function_call","sessionId":"\(session)","id":"p1","parentId":"u1","callId":"pacer1","timestamp":\(updated - 6000),"name":"mcp__pacer_progress__report_progress","arguments":{"percent":43},"providerData":{"conversationRequestId":"r1"}}
            {"type":"function_call_result","status":"completed","sessionId":"\(session)","id":"p2","parentId":"p1","callId":"pacer1","timestamp":\(updated - 5000),"output":{"type":"text","text":"pacer-progress:accepted"},"providerData":{"conversationRequestId":"r1"}}
            {"type":"function_call","sessionId":"\(session)","id":"q1","parentId":"p2","callId":"ask1","timestamp":\(updated - 2000),"name":"AskUserQuestion","providerData":{"conversationRequestId":"r1"}}

            """
        try Data(lines.utf8).write(to: transcript)
        await monitor.refresh()
        let waiting = await updates.history.last
        XCTAssertEqual(waiting?.activities.map(\.id), [initial.id])
        XCTAssertEqual(waiting?.activities.first?.turnID, initial.turnID)
        XCTAssertEqual(waiting?.activities.first?.phase, .waitingForInput)
        XCTAssertEqual(waiting?.activities.first?.currentProgress?.percent, 43)
        XCTAssertEqual(waiting?.requests.first?.threadID, initial.threadID)
        XCTAssertEqual(waiting?.usage?.sessionCredits, 2.5)
        XCTAssertEqual(waiting?.activities.first?.turnCharge, .credits(2.5))
        XCTAssertFalse(String(describing: waiting).contains("PRIVATE"))

        try fixture.exec("""
            UPDATE automation_runs SET status='ACCEPTED',updated_at=\(updated),result_success=1 WHERE thread_id='run-1';
            INSERT INTO automation_runs VALUES
            ('restart','local-job','ACCEPTED',\(updated - 2000),\(updated),0,'restart_interrupted',NULL),
            ('failure','local-job','ACCEPTED',\(updated - 1500),\(updated),0,NULL,NULL);
            """)
        await monitor.refresh()
        let ending = await updates.history.last
        let tasks = try XCTUnwrap(ending?.activities)
        XCTAssertEqual(tasks.count, 3)
        XCTAssertTrue(ending?.requests.isEmpty == true)
        let complete = try XCTUnwrap(tasks.first { $0.id == initial.id })
        XCTAssertEqual(complete.phase, .completed)
        XCTAssertTrue(complete.hasLiveEvidence)
        XCTAssertEqual(tasks.filter { $0.phase == .interrupted && $0.turnFailed }.count, 1)
        XCTAssertEqual(tasks.filter { $0.phase == .interrupted && !$0.turnFailed }.count, 1)
        await monitor.stop()

        let reopened = try self.monitor(), reopenedUpdates = Updates()
        await reopened.start(home: fixture.home, policy: .expanded) { await reopenedUpdates.append($0) }
        let historical = await reopenedUpdates.history.last
        XCTAssertEqual(historical?.activities.map(\.id), tasks.map(\.id))
        XCTAssertTrue(historical?.activities.allSatisfy(\.isHistoricalCompletion) == true)
        await reopened.stop()
    }

    func testTranscriptWaitingCompletionCancellationAndPrivateFields() throws {
        var transcript = WorkBuddyTranscript()
        let session = Fixture.session
        let prompt = "{\"type\":\"message\",\"role\":\"user\",\"sessionId\":\"\(session)\",\"id\":\"u1\",\"timestamp\":\(updated - 4000),\"providerData\":{\"conversationRequestId\":\"r1\",\"startsNewUserRequest\":true},\"content\":[{\"type\":\"input_text\",\"text\":\"PRIVATE PROMPT\"}]}"
        let call = "{\"type\":\"function_call\",\"sessionId\":\"\(session)\",\"id\":\"f1\",\"parentId\":\"u1\",\"callId\":\"ask1\",\"timestamp\":\(updated - 3000),\"name\":\"AskUserQuestion\",\"providerData\":{\"conversationRequestId\":\"r1\"}}"
        let result = "{\"type\":\"function_call_result\",\"sessionId\":\"\(session)\",\"id\":\"f2\",\"parentId\":\"f1\",\"callId\":\"ask1\",\"timestamp\":\(updated - 2000),\"providerData\":{\"conversationRequestId\":\"r1\"}}"
        let final = "{\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\",\"sessionId\":\"\(session)\",\"id\":\"a1\",\"parentId\":\"f2\",\"timestamp\":\(updated - 1000),\"providerData\":{\"conversationRequestId\":\"r1\",\"model\":\"default-model\",\"requestModelName\":\"Auto\"},\"content\":[{\"type\":\"output_text\",\"text\":\"PRIVATE REPLY\"}]}"
        let stop = "{\"type\":\"message\",\"role\":\"assistant\",\"status\":\"incomplete\",\"sessionId\":\"\(session)\",\"id\":\"stop\",\"parentId\":\"a1\",\"timestamp\":\(updated),\"providerData\":{\"conversationRequestId\":\"r1\",\"isPartialAborted\":true}}"
        func consume(_ value: String) { XCTAssertTrue(transcript.consume(Data(value.utf8), session: session, now: at)) }
        consume(prompt)
        consume(call)
        XCTAssertEqual(transcript.turn?.question?.call, "ask1")
        consume(final)
        XCTAssertNil(transcript.turn?.ending, "An unreturned tool cannot prove completion")
        consume(result)
        XCTAssertNil(transcript.turn?.question)
        consume(final)
        XCTAssertEqual(transcript.turn?.ending, .reply)
        XCTAssertEqual(transcript.turn?.model?.displayName, L10n.text("provider.automatic"))
        XCTAssertNil(transcript.turn?.rate)
        consume(stop)
        XCTAssertEqual(transcript.turn?.ending, .cancelled)
        XCTAssertFalse(String(describing: transcript.turn).contains("PRIVATE"))
    }

    func testOnlyAnAcknowledgedProgressToolCanSupplyAnEstimate() throws {
        var transcript = WorkBuddyTranscript()
        let session = Fixture.session
        func write(_ fields: [String: Any], milliseconds: Int64 = 0) throws {
            var row = fields
            row["sessionId"] = session; row["timestamp"] = updated + milliseconds
            var metadata: [String: Any] = ["conversationRequestId": "request"]
            if fields["role"] as? String == "user" { metadata["startsNewUserRequest"] = true }
            row["providerData"] = metadata
            XCTAssertTrue(transcript.consume(try JSONSerialization.data(withJSONObject: row), session: session, now: at))
        }
        try write(["type": "message", "role": "user", "id": "start"], milliseconds: -2000)
        try write(["type": "function_call", "name": "TodoWrite", "id": "todo", "parentId": "start", "callId": "todo-call",
                   "arguments": ["todos": [["status": "completed"]]]])
        try write(["type": "function_call_result", "status": "completed", "id": "todo-result", "parentId": "todo",
                   "callId": "todo-call", "output": ["type": "text", "text": "pacer-progress:accepted"]])
        XCTAssertNil(transcript.turn?.progress)
        try write(["type": "function_call", "name": "DeferExecuteTool", "id": "progress", "parentId": "todo-result", "callId": "report-call",
                   "arguments": #"{"toolName":"mcp__pacer_progress__report_progress","params":{"percent":37}}"#])
        XCTAssertNil(transcript.turn?.progress)
        try write(["type": "function_call_result", "status": "completed", "id": "report-result", "parentId": "progress", "callId": "report-call",
                   "output": ["type": "text", "text": "pacer-progress:accepted"]], milliseconds: -20)
        XCTAssertEqual(transcript.turn?.progress?.percent, 37)
        XCTAssertEqual(transcript.turn?.progress?.at, at)
        try write(["type": "function_call", "name": "mcp__pacer_progress__report_progress", "id": "bad", "parentId": "report-result",
                   "callId": "report-bad", "arguments": ["percent": 99]])
        try write(["type": "function_call_result", "status": "failed", "id": "bad-result", "parentId": "bad",
                   "callId": "report-bad", "output": ["type": "text", "text": "pacer-progress:accepted"]])
        XCTAssertEqual(transcript.turn?.progress?.percent, 37)
    }

    func testProjectsTurnModelThoughtLevelAndThroughputFromLocalRecords() async throws {
        let fixture = try Fixture(), monitor = try monitor(), updates = Updates()
        let session = Fixture.session
        try fixture.createSessions()
        try fixture.exec("""
            ALTER TABLE sessions ADD COLUMN cwd TEXT;
            ALTER TABLE sessions ADD COLUMN model TEXT;
            ALTER TABLE sessions ADD COLUMN thought_level TEXT;
            INSERT INTO sessions VALUES ('\(session)','account','working',\(updated),NULL,'local',NULL,1,0,
                'PRIVATE TITLE','C:/fixture','deepseek-v4.1-flash-sg','high');
            """)
        let workspace = fixture.home.appendingPathComponent("projects/C-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let file = workspace.appendingPathComponent(session + ".jsonl")
        func event(_ type: String, _ id: String, _ parent: String?, _ milliseconds: Int64, _ fields: [String: Any] = [:],
                   metadata: [String: Any] = [:]) throws -> Data {
            var row = fields
            row["type"] = type; row["id"] = id; row["parentId"] = parent
            row["timestamp"] = updated + milliseconds; row["sessionId"] = session
            row["providerData"] = ["conversationRequestId": "r1"].merging(metadata) { _, new in new }
            return try JSONSerialization.data(withJSONObject: row) + Data([10])
        }
        let first: [String: Any] = ["stepSeq": 1, "messageId": "request1", "model": "deepseek-v4.1-flash-sg",
            "requestModelId": "deepseek-v4.1-flash-sg", "requestModelName": "Deepseek-V4.1-Flash"]
        let second: [String: Any] = ["stepSeq": 2, "messageId": "request2", "model": "deepseek-v4.1-flash-sg",
            "usage": ["requests": 1, "outputTokens": 80]]
        let start = try event("message", "user", nil, -17_000, ["role": "user"], metadata: ["startsNewUserRequest": true])
        let reasoning = try event("reasoning", "reasoning", "user", -15_000, ["rawContent": "PRIVATE REASONING"], metadata: first)
        let call = try event("function_call", "call", "reasoning", -13_000, ["callId": "tool"],
            metadata: first.merging(["usage": ["requests": 1, "outputTokens": 200]]) { _, new in new })
        let result = try event("function_call_result", "result", "call", -3000, ["callId": "tool"],
            metadata: first.merging(["usage": ["requests": 1, "outputTokens": 999]]) { _, new in new })
        try (start + reasoning + call + result).write(to: file)
        await monitor.start(home: fixture.home, policy: .expanded) { await updates.append($0) }
        let running = await updates.history.last?.activities.first
        XCTAssertEqual(running?.modelName, "Deepseek-V4.1-Flash")
        XCTAssertEqual(running?.reasoningEffort, "high")
        XCTAssertEqual(running?.responsePerformance?.tokensPerSecond, 50)

        // The following response took two seconds. The preceding ten-second
        // tool run and its repeated usage do not enter this measurement.
        let reply = try event("message", "reply", "result", -1000, ["role": "assistant", "status": "completed",
            "content": [["type": "output_text", "text": "PRIVATE REPLY"]]], metadata: second)
        try (start + reasoning + call + result + reply).write(to: file)
        try fixture.exec("UPDATE sessions SET status='completed',thought_level='low' WHERE id='\(session)'")
        await monitor.refresh()
        let snapshot = await updates.history.last
        let completed = try XCTUnwrap(snapshot?.activities.first)
        XCTAssertEqual(completed.phase, .completed)
        XCTAssertEqual(completed.modelName, "Deepseek-V4.1-Flash")
        XCTAssertEqual(completed.reasoningEffort, "high")
        let row = ActivityTaskRowPresentation(activity: completed, unread: true, at: at)
        XCTAssertEqual(row.model, "Deepseek-V4.1-Flash")
        XCTAssertEqual(row.effort, L10n.text("model.effort.high"))
        XCTAssertEqual(row.rate?.value, 40)
        XCTAssertFalse(String(describing: completed).contains("PRIVATE"))
        await monitor.stop()
    }

    func testBilledCreditsFollowEachRequestAndCanArriveAfterCompletion() async throws {
        let fixture = try Fixture(), monitor = try monitor(), updates = Updates()
        let session = Fixture.session, secondSession = "44444444-4444-4444-4444-444444444444"
        try fixture.createSessions()
        try fixture.exec("""
            ALTER TABLE sessions ADD COLUMN cwd TEXT;
            CREATE TABLE session_usage(session_id TEXT PRIMARY KEY,used INTEGER,size INTEGER,updated_at INTEGER,credit_json TEXT);
            INSERT INTO sessions VALUES
            ('\(session)','account','working',\(updated - 1000),NULL,'local',NULL,0,0,NULL,'C:/fixture'),
            ('\(secondSession)','account','completed',\(updated - 5000),NULL,'local',NULL,0,0,NULL,'C:/fixture');
            INSERT INTO session_usage VALUES
            ('\(session)',200,500,\(updated - 2000),'{"r1":0.53,"earlier":12}'),
            ('\(secondSession)',100,500,\(updated - 5000),'{"r1":1}');
            """)
        let workspace = fixture.home.appendingPathComponent("projects/C-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        func turn(_ request: String, session: String, start: Int64, end: Int64? = nil) -> Data {
            let anchor = """
                {"type":"message","role":"user","id":"u-\(request)","sessionId":"\(session)","timestamp":\(updated + start),"providerData":{"conversationRequestId":"\(request)","startsNewUserRequest":true}}
                """
            guard let end else { return Data((anchor + "\n").utf8) }
            let reply = """
                {"type":"message","role":"assistant","status":"completed","id":"a-\(request)","parentId":"u-\(request)","sessionId":"\(session)","timestamp":\(updated + end),"content":[{"type":"output_text","text":"test"}],"providerData":{"conversationRequestId":"\(request)"}}
                """
            return Data((anchor + "\n" + reply + "\n").utf8)
        }
        let transcript = workspace.appendingPathComponent(session + ".jsonl")
        try turn("r1", session: session, start: -9000).write(to: transcript)
        try turn("r1", session: secondSession, start: -8000, end: -5000)
            .write(to: workspace.appendingPathComponent(secondSession + ".jsonl"))
        await monitor.start(home: fixture.home, policy: .expanded) { await updates.append($0) }
        let running = await updates.history.last
        let first = try XCTUnwrap(running?.activities.first { $0.phase == .running })
        XCTAssertEqual(first.turnCharge, .credits(0.53))
        XCTAssertEqual(running?.activities.first { $0.phase == .completed }?.turnCharge, .credits(1))
        XCTAssertEqual(running?.usage?.sessionCredits, 12.53)

        let oldTurn = turn("r1", session: session, start: -9000, end: -800)
        try oldTurn.write(to: transcript)
        try fixture.exec("UPDATE sessions SET status='completed',updated_at=\(updated - 800) WHERE id='\(session)'")
        await monitor.refresh()
        let ended = await updates.history.last?.activities.first { $0.id == first.id }
        XCTAssertEqual(ended?.phase, .completed)
        XCTAssertEqual(ended?.turnCharge, .credits(0.53))

        try fixture.exec("UPDATE session_usage SET credit_json='{\"r1\":0.57,\"earlier\":12}',updated_at=\(updated - 750) WHERE session_id='\(session)'")
        await monitor.refresh()
        let settled = await updates.history.last?.activities.first { $0.id == first.id }
        let charged = try XCTUnwrap(settled)
        XCTAssertEqual(charged.turnID, ended?.turnID)
        XCTAssertEqual(charged.phaseChangedAt, ended?.phaseChangedAt)
        XCTAssertEqual(charged.turnCharge, .credits(0.57))
        XCTAssertNil(charged.turnCost, "Credits never enter the CNY accounting")
        let row = ActivityTaskRowPresentation(activity: charged, unread: true, at: at)
        XCTAssertEqual(row.cost, "0.57 " + L10n.text("harness.credit_unit"))
        XCTAssertFalse(row.peakCost)

        try (oldTurn + turn("r2", session: session, start: -200)).write(to: transcript)
        try fixture.exec("UPDATE sessions SET status='working',updated_at=\(updated) WHERE id='\(session)'")
        await monitor.refresh()
        let next = await updates.history.last?.activities.first { $0.id == first.id }
        var newTurn = try XCTUnwrap(next)
        newTurn.mergeDisplayMetadata(from: charged)
        XCTAssertNotEqual(newTurn.turnID, charged.turnID)
        XCTAssertNil(newTurn.turnCharge, "A new request cannot inherit the previous request's charge")

        try fixture.exec("UPDATE session_usage SET credit_json='{\"r1\":0.57,\"r2\":0}',updated_at=\(updated) WHERE session_id='\(session)'")
        await monitor.refresh()
        let free = await updates.history.last?.activities.first { $0.id == first.id }
        XCTAssertEqual(free?.turnCharge, .credits(0), "A recorded zero differs from a missing charge")
        await monitor.stop()
    }
}
