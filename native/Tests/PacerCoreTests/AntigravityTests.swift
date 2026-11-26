import Foundation
import SQLite3
import XCTest
@testable import PacerCore

private let rootID = "11111111-1111-4111-8111-111111111111"
private let childID = "22222222-2222-4222-8222-222222222222"
private let trajectoryID = "33333333-3333-4333-8333-333333333333"
private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
private let sentinel = "0001-01-01 00:00:00+00:00"
private func timestamp(_ second: Int) -> String {
    ISO8601DateFormatter().string(from: epoch.addingTimeInterval(Double(second)))
}

private struct Step {
    let type: String, status: String
    let second: Int
    var arguments: [String: String]?
    var interaction: String?
    var code: Int { ["USER_INPUT": 14, "PLANNER_RESPONSE": 15, "SYSTEM_MESSAGE": 101][type] ?? 132 }
    // An arbitrary unmeasured integer exercises forward compatibility for PENDING.
    var state: Int { ["RUNNING": 2, "DONE": 3, "CANCELED": 6, "ERROR": 7, "GENERATING": 8, "WAITING": 9][status] ?? 47 }
    init(_ type: String, _ status: String, _ second: Int, _ interaction: String? = nil) {
        self.type = type; self.status = status; self.second = second; self.interaction = interaction
    }

    func object(at index: Int, id: String) -> [String: Any] {
        var meta: [String: Any] = ["sourceTrajectoryStepInfo": ["cascadeId": id, "trajectoryId": trajectoryID, "stepIndex": index] as [String: Any],
                                  "createdAt": timestamp(second), "executionId": "call-owner"]
        if type == "PLANNER_RESPONSE" {
            meta["viewableAt"] = timestamp(second + 1)
            if status == "DONE" { meta["finishedGeneratingAt"] = timestamp(second + 3) }
        }
        var object: [String: Any] = ["type": "CORTEX_STEP_TYPE_" + type, "status": "CORTEX_STEP_STATUS_" + status,
                                     "metadata": meta, "generic": ["args": ["secret": "private-tool-sentinel"]],
                                     "userInput": ["userResponse": "private-prompt-sentinel"]]
        if let arguments {
            object["generic"] = ["args": arguments]
            meta["completedAt"] = timestamp(second + 1)
            object["metadata"] = meta
        }
        if interaction == "pacer" {
            object["requestedInteraction"] = ["permission": ["resource": ["action": "mcp", "target": "codex-pacer_pacer_progress/report_progress"]]]
        } else if interaction == "mcp" {
            object["requestedInteraction"] = ["permission": ["resource": ["action": "mcp", "target": "private-tool-sentinel"]]]
        } else if let interaction { object["requestedInteraction"] = [interaction: ["text": "private-question-sentinel"]] }
        return object
    }
}

private final class FakeHost: AntigravityLocalHost, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: [String: Any]] = [:]
    private var seen: [AntigravityLocalRequest] = []
    var requests: [AntigravityLocalRequest] { lock.withLock { seen } }
    private var refused = false
    func disconnect() { lock.withLock { refused = true } }
    private var overrides: [String: Data] = [:]
    func respond(_ method: String, with data: Data) { lock.withLock { overrides[method] = data } }
    var intercept: (@Sendable (AntigravityLocalRequest) async -> Void)?
    func serverIdentity(hub: URL, pid: Int32, httpPort: UInt16) -> String? { pid == 42 ? "synthetic-server-start" : nil }
    func install(_ state: String, steps: [Step], id: String, parent: String?, updated: Int? = nil) {
        lock.withLock {
            var metadata: [String: Any] = ["rootConversationId": parent ?? id]
            if let parent {
                metadata["parentConversationId"] = parent
                metadata["subagentSpec"] = ["role": "Review tests", "typeName": "self", "initialPrompt": "private-child-sentinel"]
            }
            let calls: [[String: Any]] = steps.indices.filter { steps[$0].type == "PLANNER_RESPONSE" }.map { i in
                ["stepIndices": [i, i + 1], "executionId": "call-owner",
                 "chatModel": ["responseModel": "gemini-4-hydrogen-tiered-high", "timeToFirstToken": "1s", "streamingDuration": "2s",
                               "usage": ["outputTokens": "100", "thinkingOutputTokens": "40"]]]
            }
            var run = ["runState": "RUN_STATE_" + state]
            if let updated { run["updateTime"] = timestamp(updated) }
            answers[id] = ["GetConversation": ["conversation": ["id": id, "state": run]],
                           "GetConversationMetadata": ["metadata": metadata, "trajectoryId": trajectoryID],
                           "GetCascadeTrajectoryGeneratorMetadata": ["generatorMetadata": calls],
                           "GetCascadeTrajectorySteps": steps.indices.map { steps[$0].object(at: $0, id: id) }]
        }
    }

    func post(_ request: AntigravityLocalRequest) async throws -> (Int, Data) {
        if let intercept { await intercept(request) }
        return try lock.withLock {
            seen.append(request)
            if refused { throw URLError(.cannotConnectToHost) }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
            let method = String(request.path.split(separator: "/").last!)
            if let override = overrides[method] { return (200, override) }
            let id = (body["cascadeId"] ?? body["conversationId"]) as? String ?? ""
            var answer = answers[id]?[method]
            if method == "ListConversations" { answer = ["conversations": []] }
            if let steps = answer as? [[String: Any]], method == "GetCascadeTrajectorySteps" {
                answer = ["steps": Array(steps.dropFirst(body["stepOffset"] as? Int ?? 0))]
            }
            guard let answer else { return (404, Data()) }
            return (200, try JSONSerialization.data(withJSONObject: answer))
        }
    }
}

private final class Fixture {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let host = FakeHost()
    let files = TestFileSystem()
    private var connections: [String: OpaquePointer] = [:]
    struct NoEvents: ActivityFileEvents {
        func watch(_ url: URL, isDirectory: Bool, changed: @escaping @Sendable (ActivityFileEvent) -> Void) -> (any ActivityFileWatch)? { nil }
    }
    var io: LocalHarnessIO { .init(files: files, events: NoEvents(), antigravity: host, now: { epoch }) }
    var store: AntigravityStore { .init(home: home, files: files) }
    init() throws {
        for directory in ["daemon", "conversations"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try sql("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE conversation_summaries(conversation_id TEXT PRIMARY KEY, title TEXT, step_count INTEGER, last_modified_time TEXT,
                status TEXT, parent_conversation_id TEXT, nesting_depth INTEGER, last_user_input_time TEXT,
                not_fully_idle INTEGER, last_user_input_step_index INTEGER, preview TEXT, raw_summary BLOB)
            """)
        try hub()
    }
    deinit {
        closeDatabases()
        try? FileManager.default.removeItem(at: home)
    }
    func closeDatabases() {
        for db in connections.values { sqlite3_close(db) }
        connections.removeAll()
    }
    func checkpointAndClose() throws {
        try sql("PRAGMA wal_checkpoint(TRUNCATE)")
        try sql("PRAGMA wal_checkpoint(TRUNCATE)", db: "conversations/\(rootID).db")
        closeDatabases()
        // Apple SQLite can persist empty sidecars after the last writer closes.
        for db in [store.summariesURL, store.conversationURL(rootID)] {
            for suffix in ["-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: db.path + suffix)
                if files.metadata(sidecar) != nil { try FileManager.default.removeItem(at: sidecar) }
            }
        }
    }
    @discardableResult func hub(_ port: Int = 34001, pid: Int = 42, token: String = "synthetic-token") throws -> URL {
        let file = home.appendingPathComponent("daemon/hub_\(port).json")
        try JSONSerialization.data(withJSONObject: ["httpPort": port, "pid": pid, "csrfToken": token]).write(to: file, options: .atomic)
        return file
    }
    func sql(_ query: String, db name: String = "conversation_summaries.db") throws {
        if connections[name] == nil {
            var connection: OpaquePointer?
            guard sqlite3_open(home.appendingPathComponent(name).path, &connection) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
            connections[name] = connection
        }
        guard sqlite3_exec(connections[name], query, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }
    func write(_ steps: [Step], state: String, at: Int, id: String = rootID, parent: String? = nil,
               hold: Bool = false, wal: Bool = true) throws {
        let db = "conversations/\(id).db"
        try sql("""
            PRAGMA journal_mode=\(wal ? "WAL" : "DELETE");
            CREATE TABLE IF NOT EXISTS trajectory_meta(trajectory_id TEXT, cascade_id TEXT);
            CREATE TABLE IF NOT EXISTS steps(idx INTEGER PRIMARY KEY, step_type INTEGER, status INTEGER, step_payload BLOB);
            DELETE FROM trajectory_meta; INSERT INTO trajectory_meta VALUES('\(trajectoryID)','\(id)'); DELETE FROM steps;
            """, db: db)
        var lines = Data()
        for (i, step) in steps.enumerated() {
            try sql("INSERT INTO steps VALUES(\(i),\(step.code),\(step.state),x'ffff')", db: db)
            if step.status == "DONE" {
                var record: [String: Any] = ["step_index": i, "type": step.type, "status": step.status, "created_at": timestamp(step.second),
                                              "content": "private-response-sentinel"]
                if step.type == "PLANNER_RESPONSE" { record["model"] = "gemini-4-hydrogen-tiered-high"; record["output_tokens"] = 100 }
                lines.append(try JSONSerialization.data(withJSONObject: record)); lines.append(10)
            }
        }
        let log = store.transcriptURL(id)
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.write(to: log, options: .atomic)
        let input = steps.last(where: { $0.type == "USER_INPUT" }).map { timestamp($0.second) } ?? "0001-01-01 00:00:00+00:00"
        try sql("""
            INSERT OR REPLACE INTO conversation_summaries VALUES('\(id)','Synthetic task',\(steps.count),'\(timestamp(at))',
                 'CASCADE_RUN_STATUS_\(state)','\(parent ?? "")',\(parent == nil ? 0 : 1),'\(input)',\(hold ? 1 : 0),-1,'private-preview-sentinel',x'ffff')
            """)
        host.install(state, steps: steps, id: id, parent: parent)
    }
    func monitor() throws -> any LocalHarnessMonitor {
        var modules = LocalHarnessMonitors(platform: .macOS, io: io)
        return modules.monitor(for: try XCTUnwrap(modules.definition(for: .antigravity)))
    }
}

private actor Updates {
    private(set) var last = HarnessActivity()
    func receive(_ value: HarnessActivity) { last = value }
}

/// Simulate a writer changing files immediately after the initial sidecar lookup.
private final class SnapshotRace: PlatformFileSystem, @unchecked Sendable {
    let files = TestFileSystem()
    let shm: URL
    var change: (() throws -> Void)?
    init(db: URL, change: @escaping () throws -> Void) {
        shm = URL(fileURLWithPath: db.path + "-shm")
        self.change = change
    }
    func metadata(_ url: URL, followingSymbolicLinks: Bool) -> PlatformFileMetadata? {
        let result = files.metadata(url, followingSymbolicLinks: followingSymbolicLinks)
        if url == shm, let change {
            self.change = nil
            do { try change() } catch { XCTFail("Synthetic writer failed: \(error)") }
        }
        return result
    }
    func entries(in directory: URL) throws -> [URL] { try files.entries(in: directory) }
    func read(_ url: URL, offset: UInt64, maximumBytes: Int) throws -> Data {
        try files.read(url, offset: offset, maximumBytes: maximumBytes)
    }
    func replace(_ url: URL, with data: Data) -> Bool { XCTFail("Unexpected monitor write"); return false }
}

final class AntigravityTests: XCTestCase {
    private let input = Step("USER_INPUT", "DONE", 1)
    private let planner = Step("PLANNER_RESPONSE", "DONE", 2)

    private func report(_ percent: String, at second: Int, status: String = "DONE", server: String = "codex-pacer_pacer_progress",
                        tool: String = "report_progress", type: String = "GENERIC") -> Step {
        var step = Step(type, status, second)
        step.arguments = ["ServerName": server, "ToolName": tool, "Arguments": percent]
        return step
    }

    func testProgressFollowsOnlyItsOwnRowAndCurrentInput() async throws {
        let f = try Fixture(), m = try f.monitor(), updates = Updates()
        try f.write([Step("USER_INPUT", "DONE", -10), report(#"{"percent":70}"#, at: -9)], state: "RUNNING", at: -7)
        await m.start(home: f.home, policy: .collapsed) { await updates.receive($0) }
        await m.refresh()
        var snapshot = await updates.last
        XCTAssertNil(snapshot.activities.first?.currentProgress)
        let parent = [input, report(#"{"percent":100}"#, at: 2)]
        let child = [Step("SYSTEM_MESSAGE", "DONE", 1), report(#"{"percent":49}"#, at: 3)]
        try f.write(parent, state: "RUNNING", at: 3)
        try f.write(child, state: "RUNNING", at: 4, id: childID, parent: rootID)
        await m.refresh(); snapshot = await updates.last
        var root = try XCTUnwrap(snapshot.activities.first { $0.threadID == rootID })
        XCTAssertEqual(root.currentProgress?.percent, 100); XCTAssertEqual(root.phase, .running)
        XCTAssertEqual(root.currentProgress?.reportedAt, epoch.addingTimeInterval(3))
        XCTAssertEqual(snapshot.activities.first { $0.threadID == childID }?.currentProgress?.percent, 49)
        let updated = parent + [report(#"{"percent":18}"#, at: 5), report("not-json", at: 6, server: "other"),
            report(#"{"percent":90}"#, at: 7, tool: "other"), report(#"{"percent":80}"#, at: 8, status: "ERROR"),
            report(#"{"percent":true}"#, at: 9), report(#"{"percent":1.5}"#, at: 10), report(#"{"percent":101}"#, at: 11),
            report(#"{"percent":66}"#, at: 12, type: "RUN_COMMAND")]
        try f.write(updated, state: "RUNNING", at: 14)
        await m.refresh(); snapshot = await updates.last
        root = try XCTUnwrap(snapshot.activities.first { $0.threadID == rootID })
        XCTAssertEqual(root.currentProgress?.percent, 18)
        XCTAssertEqual(root.currentProgress?.reportedAt, epoch.addingTimeInterval(6))
        try f.write(updated + [Step("USER_INPUT", "DONE", 15)], state: "RUNNING", at: 15)
        await m.refresh(); snapshot = await updates.last
        XCTAssertNil(snapshot.activities.first { $0.threadID == rootID }?.currentProgress)
        XCTAssertEqual(snapshot.activities.first { $0.threadID == childID }?.currentProgress?.percent, 49)
        await m.stop()
    }

    func testProgressApprovalRemainsAnApprovalAndAdvancesGuide() async throws {
        let f = try Fixture(), m = try f.monitor(), updates = Updates()
        await m.start(home: f.home, policy: .collapsed) { await updates.receive($0) }
        for interaction in ["mcp", "pacer"] {
            try f.write([input, Step("GENERIC", "WAITING", 2, interaction)], state: "RUNNING", at: 3)
            await m.refresh()
            let snapshot = await updates.last
            XCTAssertEqual(snapshot.requests.first?.kind, .approval); XCTAssertEqual(snapshot.requests.first?.threadID, rootID)
            XCTAssertEqual(snapshot.activities.first?.phase, .waitingForInput)
            XCTAssertEqual(snapshot.requestsProgressApproval, interaction == "pacer")
            let guide = HarnessProgressGuide(setup: .configured, connection: nil, reported: false, ringOn: true, name: "Antigravity",
                                            pluginPlatform: .macOS, requestsApproval: snapshot.requestsProgressApproval)
            XCTAssertEqual(guide?.stage, interaction == "pacer" ? .allowTool : .newConversation)
            XCTAssertEqual(guide?.steps[2].copyText, "codex-pacer_pacer_progress")
        }
        await m.stop()
    }

    func testProgressGuideUsesPlatformLoadBehaviorAndOnlyAReportConfirmsSetup() {
        func guide(_ setup: LocalHarnessProgressStatus, _ platform: HarnessPlatform, app: HarnessProgressGuide.AppPresence? = nil,
                   reported: Bool = false, connection: LocalHarnessProgressConnection? = nil, on: Bool = true) -> HarnessProgressGuide? {
            HarnessProgressGuide(setup: setup, connection: connection, reported: reported, ringOn: on, name: "Antigravity",
                                 addedAt: epoch, app: app, pluginPlatform: platform)
        }
        XCTAssertEqual(guide(.settingUp, .macOS)?.steps.first?.state, .current)
        XCTAssertEqual(guide(.configured, .macOS, app: .running(since: .distantPast))?.stage, .newConversation)
        XCTAssertEqual(guide(.configured, .windows, app: .running(since: .distantPast))?.action, .restartApp)
        XCTAssertEqual(guide(.configured, .windows, app: .running(since: epoch))?.stage, .allowTool)
        XCTAssertEqual(guide(.configured, .macOS, reported: true)?.stage, .ready)
        XCTAssertEqual(guide(.configured, .macOS, reported: true, connection: .disabled)?.stage, .turnedOff)
        for status in [LocalHarnessProgressStatus.conflict, .failed] { XCTAssertEqual(guide(status, .macOS)?.action, .retry) }
        XCTAssertNil(guide(.configured, .macOS, on: false))
        XCTAssertEqual(guide(.removalPending, .windows, on: false)?.waiting, true)
    }

    func testFirstResponseBeforeSummaryAndTranscriptCatchUp() async throws {
        let f = try Fixture(), m = try f.monitor(), updates = Updates()
        let steps = [Step("USER_INPUT", "DONE", 10), Step("PLANNER_RESPONSE", "GENERATING", 11)]
        try f.write(steps, state: "RUNNING", at: -100)
        try f.sql("""
            UPDATE conversation_summaries SET last_modified_time='\(sentinel)', last_user_input_time='\(sentinel)',
                   step_count=0, last_user_input_step_index=-1
            """)
        try FileManager.default.setAttributes([.modificationDate: epoch], ofItemAtPath: f.store.conversationURL(rootID).path)
        try FileManager.default.removeItem(at: f.store.transcriptURL(rootID))
        try FileManager.default.removeItem(at: f.home.appendingPathComponent("daemon/hub_34001.json"))
        let row = try XCTUnwrap(f.store.summaries().first)
        XCTAssertEqual(row.updated, epoch)
        XCTAssertEqual(try f.store.trajectory(row).anchor?.index, 0)
        await m.start(home: f.home, policy: .collapsed) { await updates.receive($0) }
        var snapshot = await updates.last
        XCTAssertEqual(snapshot.activities.first?.phase, .running)
        XCTAssertEqual(snapshot.activities.first?.stage, .thinking)
        let turn = try XCTUnwrap(snapshot.activities.first?.turnID)
        try f.hub()
        await m.refresh(); snapshot = await updates.last
        XCTAssertEqual(snapshot.activities.first?.phase, .running)
        XCTAssertEqual(snapshot.activities.first?.turnStartedAt, epoch.addingTimeInterval(10))
        XCTAssertEqual(snapshot.activities.first?.turnID, turn)
        XCTAssertEqual(snapshot.activities.first?.firstTokenLatency, 2)
        try f.write(steps + [Step("USER_INPUT", "DONE", 20)], state: "RUNNING", at: -100)
        try f.sql("UPDATE conversation_summaries SET last_user_input_time='\(timestamp(1))', last_user_input_step_index=0, step_count=2")
        await m.refresh(); snapshot = await updates.last
        XCTAssertNotEqual(snapshot.activities.first?.turnID, turn)
        XCTAssertEqual(snapshot.activities.first?.turnStartedAt, epoch.addingTimeInterval(20))
        XCTAssertEqual(snapshot.activities.first?.stage, .starting)
        XCTAssertEqual(try f.store.summaries().first?.updated, epoch.addingTimeInterval(1))
        await m.stop()
    }

    func testToolTypeClassesPendingAndUnknownStatuses() async throws {
        let f = try Fixture(), m = try f.monitor(), updates = Updates()
        let steps = [input, Step("VIEW_FILE", "DONE", 2), Step("WRITE_FILE", "FUTURE_STATUS", 3),
                     Step("FUTURE_TOOL", "PENDING", 4)]
        try f.write(steps, state: "RUNNING", at: 4)
        let db = "conversations/\(rootID).db"
        try f.sql("UPDATE steps SET status=47 WHERE idx=1; UPDATE steps SET status=3 WHERE idx=2", db: db)
        await m.start(home: f.home, policy: .collapsed) { await updates.receive($0) }
        var snapshot = await updates.last
        XCTAssertEqual(snapshot.activities.first?.phase, .running)
        XCTAssertEqual(snapshot.activities.first?.stage, .tool)
        XCTAssertEqual(snapshot.activities.first?.toolWaitStartedAt, epoch.addingTimeInterval(4))
        XCTAssertTrue(snapshot.requests.isEmpty)
        f.host.install("RUNNING", steps: Array(steps.dropLast()) + [Step("FUTURE_TOOL", "DONE", 4)], id: rootID, parent: nil)
        await m.refresh(); snapshot = await updates.last
        XCTAssertEqual(snapshot.activities.first?.stage, .thinking)
        await m.stop()
    }

    func testAPIRunStateAndUpdateTimeLeadSummaryThroughCompletion() async throws {
        let f = try Fixture(), m = try f.monitor(), updates = Updates()
        let steps = [input, Step("PLANNER_RESPONSE", "GENERATING", 2)]
        try f.write(steps, state: "IDLE", at: 1)
        f.host.install("RUNNING", steps: steps, id: rootID, parent: nil, updated: 5)
        await m.start(home: f.home, policy: .collapsed) { await updates.receive($0) }
        var snapshot = await updates.last
        let turn = try XCTUnwrap(snapshot.activities.first?.turnID)
        XCTAssertEqual(snapshot.activities.first?.stage, .thinking)
        XCTAssertEqual(snapshot.activities.first?.lastObserved, epoch.addingTimeInterval(5))
        try f.sql("UPDATE conversation_summaries SET status='CASCADE_RUN_STATUS_RUNNING', not_fully_idle=1")
        f.host.install("IDLE", steps: [input, planner], id: rootID, parent: nil, updated: 8)
        await m.refresh(); snapshot = await updates.last
        XCTAssertEqual(snapshot.activities.first?.phase, .completed)
        XCTAssertEqual(snapshot.activities.first?.phaseChangedAt, epoch.addingTimeInterval(8))
        XCTAssertEqual(snapshot.activities.first?.turnID, turn)
        XCTAssertTrue(snapshot.requests.isEmpty)
        try f.write([input, planner], state: "IDLE", at: 9)
        await m.refresh(); snapshot = await updates.last
        XCTAssertEqual(snapshot.activities.first?.phase, .completed)
        XCTAssertEqual(snapshot.activities.first?.phaseChangedAt, epoch.addingTimeInterval(8))
        XCTAssertEqual(snapshot.activities.first?.turnID, turn)
        await m.stop()
    }

    func testBaselineSilenceThenSettledPlannerAndNewInput() async throws {
        let f = try Fixture(), m = try f.monitor(), updates = Updates()
        try f.write([Step("USER_INPUT", "DONE", -20), Step("PLANNER_RESPONSE", "DONE", -18)], state: "IDLE", at: -14)
        await m.start(home: f.home, policy: .collapsed) { await updates.receive($0) }
        var snapshot = await updates.last
        XCTAssertEqual(snapshot.activities.first?.phase, .completed)
        XCTAssertEqual(snapshot.activities.first?.isHistoricalCompletion, true)
        XCTAssertEqual(f.host.requests.map { $0.path.components(separatedBy: "/").last }, ["GetUserStatus"],
                       "A baseline model can read the catalog without polling old conversations")
        var app = ActivityApplicationState()
        app.replaceHarness(.antigravity, with: snapshot)
        XCTAssertTrue(app.reconcile(at: epoch, retention: 1800, visibility: .init()).notices.isEmpty)
        XCTAssertTrue(app.inbox.unreadActivities.isEmpty)
        let old = snapshot.activities.first?.turnID
        try f.write([input, Step("PLANNER_RESPONSE", "GENERATING", 2)], state: "RUNNING", at: 4)
        await m.refresh()
        snapshot = await updates.last
        let turn = try XCTUnwrap(snapshot.activities.first?.turnID)
        XCTAssertNotEqual(turn, old)
        app.replaceHarness(.antigravity, with: snapshot)
        _ = app.reconcile(at: epoch.addingTimeInterval(4), retention: 1800, visibility: .init())
        XCTAssertEqual(snapshot.activities.first?.stage, .thinking)
        XCTAssertEqual(snapshot.activities.first?.firstTokenLatency, 2)
        XCTAssertNil(snapshot.activities.first?.responsePerformance)
        try f.write([input, planner, Step("RUN_COMMAND", "RUNNING", 6)], state: "RUNNING", at: 7)
        await m.refresh()
        snapshot = await updates.last
        var task = try XCTUnwrap(snapshot.activities.first)
        XCTAssertEqual(task.turnID, turn); XCTAssertEqual(task.stage, .tool)
        XCTAssertEqual(task.toolWaitStartedAt, epoch.addingTimeInterval(6))
        XCTAssertEqual(task.modelName, "Gemini 4 Hydrogen"); XCTAssertEqual(task.reasoningEffort, "high")
        XCTAssertEqual(task.responsePerformance?.tokensPerSecond, 100.0 / 3)
        await m.refresh()
        XCTAssertEqual(f.host.requests.filter { $0.path.hasSuffix("GeneratorMetadata") }.count, 1)
        try f.write([input, planner, Step("RUN_COMMAND", "DONE", 6), Step("PLANNER_RESPONSE", "DONE", 8)], state: "IDLE", at: 12)
        await m.refresh()
        snapshot = await updates.last
        task = try XCTUnwrap(snapshot.activities.first)
        XCTAssertEqual(task.phase, .completed); XCTAssertFalse(task.isHistoricalCompletion)
        XCTAssertEqual(task.turnID, turn); XCTAssertEqual(task.responsePerformance?.responseID, "3")
        XCTAssertEqual(task.firstTokenReportedAt, epoch.addingTimeInterval(3))
        app.replaceHarness(.antigravity, with: snapshot)
        let ended = app.reconcile(at: epoch.addingTimeInterval(12), retention: 1800, visibility: .init())
        XCTAssertEqual(ended.notices.count, 1)
        XCTAssertEqual(app.inbox.unreadActivities.map(\.id), [task.id])
        XCTAssertTrue(app.reconcile(at: epoch.addingTimeInterval(13), retention: 1800, visibility: .init()).notices.isEmpty)
        XCTAssertFalse(String(describing: task).contains("-sentinel"))
        try f.write([input, planner, Step("USER_INPUT", "DONE", 13)], state: "RUNNING", at: 13)
        await m.refresh(); snapshot = await updates.last
        XCTAssertNotEqual(snapshot.activities.first?.turnID, turn)
        XCTAssertNil(snapshot.activities.first?.responsePerformance)
        XCTAssertNil(snapshot.activities.first?.firstTokenLatency)
        await m.stop()
    }

    func testWaitUnionRecoverableErrorAndCancel() async throws {
        let f = try Fixture(), m = try f.monitor(), updates = Updates()
        let baseline = [Step("USER_INPUT", "DONE", -10), Step("RUN_COMMAND", "WAITING", -5, "permission")]
        try f.write(baseline, state: "RUNNING", at: -5)
        await m.start(home: f.home, policy: .collapsed) { await updates.receive($0) }
        var snapshot = await updates.last
        XCTAssertEqual(snapshot.requests.first?.kind, .approval); XCTAssertEqual(snapshot.requests.first?.suppressesNotice, true)
        let denied = [input, planner, Step("RUN_COMMAND", "ERROR", 6)]
        try f.write(denied, state: "RUNNING", at: 7)
        await m.refresh(); snapshot = await updates.last
        XCTAssertEqual(snapshot.activities.first?.phase, .running); XCTAssertTrue(snapshot.requests.isEmpty)
        for (type, key, expected) in [("GENERIC", nil, nil), ("RUN_COMMAND", "permission", PendingAttentionRequest.Kind.approval),
                                      ("ASK_QUESTION", "askQuestion", .input), ("GENERIC", "mcp", .approval)] {
            try f.write(denied + [Step(type, "WAITING", 8, key)], state: "RUNNING", at: 8)
            try f.sql("UPDATE steps SET status=2 WHERE idx=3", db: "conversations/\(rootID).db")
            await m.refresh(); snapshot = await updates.last
            XCTAssertEqual(snapshot.requests.count, expected == nil ? 0 : 1)
            XCTAssertEqual(snapshot.requests.first?.kind, expected)
            XCTAssertEqual(snapshot.activities.first?.phase, key == nil ? .running : .waitingForInput)
            if key != nil { XCTAssertEqual(snapshot.requests.first?.suppressesNotice, false) }
            let requests = snapshot.requests
            await m.refresh(); snapshot = await updates.last
            XCTAssertEqual(snapshot.requests, requests)
            XCTAssertFalse(String(describing: snapshot).contains("-sentinel"))
        }
        let turn = snapshot.activities.first?.turnID
        try f.write(denied + [Step("ASK_QUESTION", "CANCELED", 8)], state: "IDLE", at: 10)
        await m.refresh(); snapshot = await updates.last
        XCTAssertTrue(snapshot.requests.isEmpty); XCTAssertEqual(snapshot.activities.first?.phase, .interrupted)
        XCTAssertEqual(snapshot.activities.first?.turnFailed, false); XCTAssertEqual(snapshot.activities.first?.turnID, turn)
        await m.stop()
    }

    func testFamilyHoldsUntilChildAndBackgroundFinish() async throws {
        let f = try Fixture(), m = try f.monitor(), updates = Updates()
        try f.write([input, planner], state: "IDLE", at: 5)
        let system = Step("SYSTEM_MESSAGE", "DONE", 2)
        try f.write([system, Step("PLANNER_RESPONSE", "GENERATING", 3)], state: "RUNNING", at: 5, id: childID, parent: rootID)
        await m.start(home: f.home, policy: .collapsed) { await updates.receive($0) }
        var snapshot = await updates.last
        var group = try XCTUnwrap(ActivityTaskGroup.make(snapshot.activities).first)
        XCTAssertEqual(group.members.count, 2); XCTAssertEqual(group.primary.threadID, rootID)
        XCTAssertEqual(group.primary.currentBackgroundWait?.kinds, ["subagent"])
        let child = try XCTUnwrap(group.members.first { $0.threadID == childID })
        XCTAssertEqual(child.subagentDisplay?.title, "Review tests"); XCTAssertNil(child.subagentDisplay?.typeTag)
        XCTAssertNotEqual(group.primary.turnID, child.turnID)
        try f.write([system, Step("PLANNER_RESPONSE", "DONE", 3)], state: "IDLE", at: 7, id: childID, parent: rootID)
        try f.write([input, planner], state: "IDLE", at: 7, hold: true)
        await m.refresh(); snapshot = await updates.last
        group = try XCTUnwrap(ActivityTaskGroup.make(snapshot.activities).first)
        XCTAssertEqual(group.primary.currentBackgroundWait?.kinds, ["background"])
        XCTAssertEqual(group.members.first { $0.threadID == childID }?.phase, .completed)
        try f.write([input, planner], state: "IDLE", at: 10)
        await m.refresh(); snapshot = await updates.last
        group = try XCTUnwrap(ActivityTaskGroup.make(snapshot.activities).first)
        XCTAssertEqual(group.primary.phase, .completed); XCTAssertNil(group.primary.currentBackgroundWait)
        try f.sql("UPDATE conversation_summaries SET parent_conversation_id='\(childID)' WHERE conversation_id='\(rootID)'")
        await m.refresh(); snapshot = await updates.last
        XCTAssertTrue(snapshot.activities.isEmpty, "A cycle cannot escape as a top-level family")
        await m.stop()
    }

    func testFilesOnlyAndUnavailableServerClearAttention() async throws {
        let f = try Fixture(), m = try f.monitor(), updates = Updates()
        try f.write([input, Step("RUN_COMMAND", "WAITING", 2, "permission")], state: "RUNNING", at: 3)
        await m.start(home: f.home, policy: .collapsed) { await updates.receive($0) }
        var snapshot = await updates.last; XCTAssertEqual(snapshot.requests.count, 1)
        f.host.disconnect()
        await m.refresh(); snapshot = await updates.last
        XCTAssertTrue(snapshot.requests.isEmpty); XCTAssertEqual(snapshot.activities.first?.phase, .running)
        XCTAssertEqual(snapshot.activities.first?.stage, .tool)
        try f.write([input, planner], state: "IDLE", at: 6)
        await m.refresh(); snapshot = await updates.last
        XCTAssertEqual(snapshot.status, .ready); XCTAssertEqual(snapshot.activities.first?.phase, .completed)
        XCTAssertEqual(snapshot.activities.first?.reasoningEffort, "high"); XCTAssertNil(snapshot.activities.first?.responsePerformance)
        try f.write([Step("SYSTEM_MESSAGE", "DONE", 2), Step("PLANNER_RESPONSE", "GENERATING", 3)],
                    state: "RUNNING", at: 5, id: childID, parent: rootID)
        await m.refresh(); snapshot = await updates.last
        XCTAssertEqual(snapshot.activities.first { $0.threadID == childID }?.stage, .thinking)
        XCTAssertEqual(snapshot.activities.first { $0.threadID == rootID }?.currentBackgroundWait?.kinds, ["subagent"])
        try f.sql("DROP TABLE steps", db: "conversations/\(childID).db")
        await m.refresh(); snapshot = await updates.last
        XCTAssertEqual(snapshot.activities.first { $0.threadID == rootID }?.phase, .unknown,
                       "Losing the child’s step tail cannot settle its family")
        await m.stop()
    }

    func testMissingSchemaAndMismatchedTrajectory() async throws {
        let f = try Fixture(), m = try f.monitor(), updates = Updates()
        try f.write([input, planner], state: "IDLE", at: 6)
        try f.sql("UPDATE trajectory_meta SET cascade_id='\(childID)'", db: "conversations/\(rootID).db")
        await m.start(home: f.home, policy: .collapsed) { await updates.receive($0) }
        var snapshot = await updates.last; XCTAssertEqual(snapshot.activities.first?.phase, .unknown)
        try f.sql("DROP TABLE conversation_summaries")
        await m.refresh(); snapshot = await updates.last
        XCTAssertEqual(snapshot.status, .incompatible); XCTAssertEqual(snapshot.activities.first?.phase, .unknown)
        XCTAssertTrue(snapshot.requests.isEmpty)
        await m.stop()
        await m.start(home: f.home.appendingPathComponent("absent"), policy: .expanded) { await updates.receive($0) }
        snapshot = await updates.last; XCTAssertEqual(snapshot.status, .missing)
        await m.stop()
    }

    func testPartialOversizedTranscriptRotationAndModelFallback() throws {
        let f = try Fixture(), url = f.home.appendingPathComponent("synthetic.jsonl")
        let line = #"{"step_index":2,"type":"PLANNER_RESPONSE","created_at":"2027-01-01T00:00:00Z","model":"gemini-4-hydrogen-tiered-high","output_tokens":"37","status":"DONE"}"#
        var transcript = AntigravityTranscript()
        try Data(line.utf8).write(to: url); transcript.read(url, files: f.files); XCTAssertTrue(transcript.records.isEmpty)
        var data = Data(repeating: 65, count: AntigravityTranscript.maximumBytes + 100)
        data.append(contentsOf: ("\n" + line + "\n" + line).utf8)
        try data.write(to: url); transcript.read(url, files: f.files)
        XCTAssertEqual(transcript.records[2]?.outputTokens, 37); XCTAssertEqual(transcript.records.count, 1)
        try Data("invalid\n".utf8).write(to: url, options: .atomic); transcript.read(url, files: f.files)
        XCTAssertTrue(transcript.records.isEmpty)
        XCTAssertEqual(AntigravityModel(id: "new-family-high")?.name, "new-family-high")
        XCTAssertNil(AntigravityModel(id: "new-family-high")?.effort)
        XCTAssertEqual(AntigravityModel(id: "MODEL_PLACEHOLDER_4", displayName: "Custom Model")?.name, "Custom Model")
        XCTAssertNil(AntigravityModel(id: "MODEL_PLACEHOLDER_4"))
    }

    func testReadOnlyWALAndMissingSidecars() throws {
        let f = try Fixture()
        try f.write([input, planner], state: "IDLE", at: 6)
        let databases = [f.store.summariesURL, f.store.conversationURL(rootID)]
        let paths = databases.flatMap { [$0, URL(fileURLWithPath: $0.path + "-wal")] }
        let before = try paths.map { try Data(contentsOf: $0) }
        let row = try XCTUnwrap(f.store.summaries().first)
        XCTAssertEqual(try f.store.trajectory(row).anchor?.index, 0)
        XCTAssertEqual(try paths.map { try Data(contentsOf: $0) }, before)
        try f.checkpointAndClose()
        func listing() throws -> [String] { try FileManager.default.subpathsOfDirectory(atPath: f.home.path).sorted() }
        let checkpointed = try listing()
        for db in databases {
            XCTAssertEqual(try f.files.read(db, offset: 18, maximumBytes: 2), Data([2, 2]))
        }
        XCTAssertFalse(checkpointed.contains { $0.hasSuffix("-wal") || $0.hasSuffix("-shm") })
        let closedRow = try XCTUnwrap(f.store.summaries().first)
        XCTAssertEqual(closedRow.id, rootID)
        XCTAssertEqual(try f.store.trajectory(closedRow).tail.map(\.index), [0, 1])
        XCTAssertEqual(try listing(), checkpointed)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: databases[0].path + suffix)
            try Data().write(to: sidecar)
            XCTAssertThrowsError(try f.store.summaries()) { XCTAssertEqual($0 as? AntigravityStore.Failure, .retrySoon) }
            try FileManager.default.removeItem(at: sidecar)
            XCTAssertEqual(try listing(), checkpointed)
        }
    }

    func testSnapshotDiscardsFileChangesAndNeverRecreatesDisappearingSidecars() throws {
        let f = try Fixture()
        try f.write([input, planner], state: "IDLE", at: 6)
        try f.checkpointAndClose()
        let db = f.store.summariesURL
        let wal = URL(fileURLWithPath: db.path + "-wal"), shm = URL(fileURLWithPath: db.path + "-shm")
        func race(_ change: @escaping () throws -> Void) {
            let fs = SnapshotRace(db: db, change: change)
            XCTAssertThrowsError(try AntigravityStore(home: f.home, files: fs).summaries()) {
                XCTAssertEqual($0 as? AntigravityStore.Failure, .retrySoon)
            }
        }
        race { try FileManager.default.setAttributes([.modificationDate: epoch], ofItemAtPath: db.path) }
        race { try Data(contentsOf: db).write(to: db, options: .atomic) }
        race { try Data().write(to: wal) }
        XCTAssertNil(f.files.metadata(shm))
        try Data().write(to: shm)
        // Both sidecars passed the preflight, then the writer removed them before SQLite opened.
        race { try FileManager.default.removeItem(at: wal); try FileManager.default.removeItem(at: shm) }
        XCTAssertNil(f.files.metadata(wal)); XCTAssertNil(f.files.metadata(shm))
        XCTAssertEqual(try f.store.summaries().map(\.id), [rootID])
    }

    func testHubDiscoveryCapsHeadersAndRotation() async throws {
        let f = try Fixture(), client = AntigravityLocalClient(home: f.home, io: f.io)
        _ = try f.hub(34002, pid: 99)
        let discovered = await client.discover(), generation = try XCTUnwrap(discovered)
        _ = try await client.call(.list, generation: generation)
        let request = try XCTUnwrap(f.host.requests.last)
        XCTAssertEqual(request.port, 34001); XCTAssertEqual(request.path, "/product.v1.ConversationService/ListConversations")
        XCTAssertEqual(request.headers["Connect-Protocol-Version"], "1"); XCTAssertEqual(request.headers["x-codeium-csrf-token"], "synthetic-token")
        XCTAssertEqual(request.maximumBytes, 256 * 1024)
        try f.hub(34002, token: "next-token")
        let duplicate = await client.discover(); XCTAssertNil(duplicate)
        try FileManager.default.removeItem(at: f.home.appendingPathComponent("daemon/hub_34001.json"))
        let rotated = await client.discover(), next = try XCTUnwrap(rotated)
        XCTAssertNotEqual(next, generation)
        do { _ = try await client.call(.list, generation: generation); XCTFail("A stale generation sent a request") } catch { }
        _ = try await client.call(.list, generation: next)
        XCTAssertEqual(f.host.requests.last?.headers["x-antigravity-csrf-token"], "next-token")
        XCTAssertEqual(f.host.requests.last?.port, 34002)
        try Data(repeating: 65, count: 4097).write(to: f.home.appendingPathComponent("daemon/hub_34002.json"))
        let oversized = await client.discover(); XCTAssertNil(oversized)
    }
    func testOwnedTailOffsetMissingFirstPlannerAndAmbiguousUsage() async throws {
        let f = try Fixture(), m = try f.monitor(), updates = Updates()
        var steps = [input, planner]
        steps += (0..<20).map { Step("RUN_COMMAND", "DONE", 7 + $0) }
        steps += [Step("PLANNER_RESPONSE", "DONE", 29), Step("RUN_COMMAND", "RUNNING", 33)]
        try f.write(steps, state: "RUNNING", at: 34)
        let call = ["stepIndices": [22], "executionId": "other-execution", "chatModel":
            ["timeToFirstToken": "1s", "streamingDuration": "2s", "usage": ["outputTokens": 900]]] as [String: Any]
        f.host.respond("GetCascadeTrajectoryGeneratorMetadata", with: try JSONSerialization.data(withJSONObject: ["generatorMetadata": [call]]))
        await m.start(home: f.home, policy: .collapsed) { await updates.receive($0) }
        let snapshot = await updates.last
        let task = try XCTUnwrap(snapshot.activities.first)
        XCTAssertEqual(task.phase, .running); XCTAssertEqual(task.stage, .tool)
        XCTAssertNil(task.firstTokenLatency, "A later planner cannot stand in for the first one")
        XCTAssertNil(task.responsePerformance, "A matching index on a different execution cannot supply a rate")
        let request = try XCTUnwrap(f.host.requests.first { $0.path.hasSuffix("TrajectorySteps") })
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(body["stepOffset"] as? Int, 8)
        await m.stop()
    }

    func testDisagreementDoesNotSettleOldTail() async throws {
        let f = try Fixture(), m = try f.monitor(), updates = Updates()
        try f.write([input, Step("PLANNER_RESPONSE", "GENERATING", 2)], state: "RUNNING", at: 4)
        await m.start(home: f.home, policy: .collapsed) { await updates.receive($0) }
        try f.write([input, planner], state: "IDLE", at: 6)
        f.host.install("RUNNING", steps: [input, planner, Step("USER_INPUT", "DONE", 7)], id: rootID, parent: nil)
        let before = f.host.requests.filter { $0.path.hasSuffix("TrajectorySteps") }.count
        await m.refresh()
        var snapshot = await updates.last
        XCTAssertEqual(f.host.requests.filter { $0.path.hasSuffix("TrajectorySteps") }.count, before + 2)
        XCTAssertEqual(snapshot.activities.first?.phase, .unknown)
        f.host.install("IDLE", steps: [input, planner], id: rootID, parent: nil)
        await m.refresh(); snapshot = await updates.last
        XCTAssertEqual(snapshot.activities.first?.phase, .completed)
        await m.stop()
    }

    func testTypeDisagreementClearsOnAutomaticRecheck() async throws {
        let f = try Fixture(), m = try f.monitor(), updates = Updates()
        let steps = [input, Step("PLANNER_RESPONSE", "GENERATING", 2)]
        try f.write(steps, state: "RUNNING", at: 3)
        let host = f.host
        host.install("RUNNING", steps: [input, Step("VIEW_FILE", "RUNNING", 2)], id: rootID, parent: nil)
        host.intercept = { request in
            if request.path.hasSuffix("TrajectorySteps"), host.requests.contains(where: { $0.path.hasSuffix("TrajectorySteps") }) {
                host.install("RUNNING", steps: steps, id: rootID, parent: nil)
            }
        }
        await m.start(home: f.home, policy: .collapsed) { await updates.receive($0) }
        let snapshot = await updates.last
        XCTAssertEqual(snapshot.activities.first?.phase, .running)
        XCTAssertEqual(snapshot.activities.first?.stage, .thinking)
        XCTAssertEqual(host.requests.filter { $0.path.hasSuffix("TrajectorySteps") }.count, 2)
        host.intercept = nil
        await m.stop()
    }

    func testResponseSizeAndInFlightRevocation() async throws {
        let f = try Fixture(), client = AntigravityLocalClient(home: f.home, io: f.io)
        let initial = await client.discover(), generation = try XCTUnwrap(initial)
        f.host.respond("ListConversations", with: Data(repeating: 32, count: 256 * 1024 + 1))
        do { _ = try await client.call(.list, generation: generation); XCTFail("An oversized response escaped") }
        catch AntigravityLocalClient.Failure.oversized { }
        let (began, started) = AsyncStream<Void>.makeStream()
        let (resume, release) = AsyncStream<Void>.makeStream()
        f.host.intercept = { _ in
            started.yield(); started.finish()
            for await _ in resume { break }
        }
        let pending = Task { try await client.call(.list, generation: generation) }
        for await _ in began { break }
        try f.hub(token: "rotated-synthetic-token")
        let next = await client.discover()
        XCTAssertNotEqual(next, generation)
        release.finish()
        do { _ = try await pending.value; XCTFail("Old hub response escaped") }
        catch AntigravityLocalClient.Failure.revoked { }
        XCTAssertEqual(f.host.requests.last?.headers["x-antigravity-csrf-token"], "synthetic-token")
        await client.revoke()
    }
    func testNewUserInputRacingAnInspectionDropsOldWait() async throws {
        let f = try Fixture(), m = try f.monitor(), updates = Updates()
        try f.write([input, Step("ASK_QUESTION", "WAITING", 3, "askQuestion")], state: "RUNNING", at: 4)
        let (began, started) = AsyncStream<Void>.makeStream()
        let (resume, release) = AsyncStream<Void>.makeStream()
        f.host.intercept = { request in
            guard request.path.hasSuffix("GetCascadeTrajectorySteps") else { return }
            started.yield(); started.finish()
            for await _ in resume { break }
        }
        let reading = Task { await m.start(home: f.home, policy: .collapsed) { await updates.receive($0) } }
        for await _ in began { break }
        try f.write([input, Step("ASK_QUESTION", "DONE", 3), Step("USER_INPUT", "DONE", 8)], state: "RUNNING", at: 8)
        release.finish()
        await reading.value
        let current = await updates.last
        XCTAssertTrue(current.requests.isEmpty)
        XCTAssertEqual(current.activities.first?.turnStartedAt, epoch.addingTimeInterval(8))
        XCTAssertEqual(current.activities.first?.stage, .starting)
        await m.stop()
    }

    func testViewAndBusyStepDatabaseDegradeWithoutReadingPayload() throws {
        let f = try Fixture()
        try f.write([input, planner], state: "IDLE", at: 7, wal: false)
        let row = try XCTUnwrap(f.store.summaries().first), db = "conversations/\(rootID).db"
        try f.sql("BEGIN EXCLUSIVE; UPDATE steps SET status=8", db: db)
        XCTAssertThrowsError(try f.store.trajectory(row)) { XCTAssertEqual($0 as? AntigravityStore.Failure, .retrySoon) }
        try f.sql("ROLLBACK", db: db)
        XCTAssertEqual(try f.store.trajectory(row).last?.status, 3)
        try f.sql("ALTER TABLE steps RENAME TO original; CREATE VIEW steps AS SELECT idx,step_type,step_payload AS status FROM original", db: db)
        XCTAssertThrowsError(try f.store.trajectory(row)) { XCTAssertEqual($0 as? AntigravityStore.Failure, .incompatible) }
    }

    func testOptionalColumnsAndSignedAppOnlyRegistration() throws {
        let f = try Fixture()
        try f.write([input, planner], state: "IDLE", at: 7)
        try f.sql("ALTER TABLE conversation_summaries DROP COLUMN not_fully_idle; ALTER TABLE conversation_summaries DROP COLUMN last_user_input_step_index")
        let row = try XCTUnwrap(f.store.summaries().first)
        XCTAssertFalse(row.background); XCTAssertEqual(row.inputIndex, -1)
        let definition = AntigravityHarness.definition
        XCTAssertEqual(definition.platforms, [.macOS]); XCTAssertEqual(definition.homeEnvironmentKey, "ANTIGRAVITY_CONFIG_DIR")
        XCTAssertEqual(definition.macBundleIdentifiers, ["com.google.antigravity"]); XCTAssertEqual(definition.macTeamIdentifier, "EQHXZ8M8AV")
        XCTAssertEqual(definition.descriptor.balance, .quotaWindows); XCTAssertTrue(definition.descriptor.hasTaskProgress); XCTAssertTrue(definition.descriptor.progressConnector)
        XCTAssertNil(definition.conversationScheme); XCTAssertNil(definition.progressConfigFile)
    }
}

private actor QuotaUpdates {
    private(set) var state = LocalHarnessQuotaState()
    private(set) var notices: [IslandNotice] = []
    func receive(_ state: LocalHarnessQuotaState, _ notices: [IslandNotice]) {
        self.state = state
        self.notices += notices
    }
}

extension AntigravityTests {
    func testWholeCallRatesIncludeThinkingAndRejectMismatchedSpans() throws {
        func rate(tokens: Int, thinking: Int, first: Double, streaming: Double, span: Double) throws -> Double? {
            let step = AntigravityProjection.TypedStep(index: 2, type: 15, status: .done, created: epoch,
                transition: nil, viewable: epoch.addingTimeInterval(first), finished: epoch.addingTimeInterval(span),
                execution: nil, wait: nil)
            let chat: [String: Any] = ["timeToFirstToken": "\(first)s", "streamingDuration": "\(streaming)s",
                                       "usage": ["outputTokens": String(tokens), "thinkingOutputTokens": String(thinking)]]
            let data = try JSONSerialization.data(withJSONObject: ["generatorMetadata": [["stepIndices": [2, 3], "chatModel": chat]]])
            return try AntigravityProjection.calls(data, planners: [step])[step.index]?.performance(planner: step, turn: "turn", started: epoch)?.tokensPerSecond
        }
        for (tokens, thinking, first, stream, expected) in [(184, 116, 3.03, 0.07, 59.0), (120, 52, 7.10, 0.12, 17),
            (268, 211, 3.42, 0.50, 68), (10468, 9735, 3.42, 47.27, 207)] {
            XCTAssertEqual(try XCTUnwrap(rate(tokens: tokens, thinking: thinking, first: first, streaming: stream,
                span: first + stream + 0.01)).rounded(), expected)
        }
        XCTAssertNil(try rate(tokens: 200, thinking: 120, first: 0.8, streaming: 0.19, span: 0.99))
        XCTAssertNil(try rate(tokens: 200, thinking: 120, first: 2, streaming: 0.1, span: 3.11))
        XCTAssertEqual(try rate(tokens: 100, thinking: 50, first: 0.9, streaming: 0.1, span: 1), 100)
    }

    func testMissedEndingsKeepMeasurementsButHideEndedChildLineRate() async throws {
        let f = try Fixture(), monitor = try f.monitor(), updates = Updates()
        await monitor.start(home: f.home, policy: .collapsed) { await updates.receive($0) }
        try f.write([input, planner, Step("GENERIC", "CANCELED", 7)], state: "IDLE", at: 8)
        try f.write([Step("SYSTEM_MESSAGE", "DONE", 2), Step("PLANNER_RESPONSE", "DONE", 3)], state: "IDLE",
                    at: 7, id: childID, parent: rootID)
        await monitor.refresh()
        await monitor.refresh()
        let ended = await updates.last.activities
        XCTAssertEqual(ended.first { $0.threadID == rootID }?.phase, .interrupted)
        XCTAssertEqual(ended.first { $0.threadID == childID }?.phase, .completed)
        XCTAssertEqual(ended.count, 2)
        let child = try XCTUnwrap(ended.first { $0.threadID == childID })
        let line = ActivityTaskRowPresentation.subagentLine(child, options: .init(), at: epoch.addingTimeInterval(100))
        XCTAssertNil(line.rateText); XCTAssertFalse(line.rateIsFresh)
        let root = try XCTUnwrap(ended.first { $0.threadID == rootID })
        XCTAssertEqual(ActivityTaskRowPresentation(activity: root, unread: true, at: epoch.addingTimeInterval(100)).rateText, "33.3")
        for task in ended {
            XCTAssertEqual(task.displayedOutputEstimate(at: epoch.addingTimeInterval(100))?.value, 100.0 / 3)
        }
        XCTAssertEqual(f.host.requests.filter { $0.path.hasSuffix("GeneratorMetadata") }.count, 2)
        await monitor.stop()
    }

    func testCatalogMatchingSessionCacheAndOfflineNames() async throws {
        let f = try Fixture(), client = AntigravityLocalClient(home: f.home, io: f.io)
        let generation = await client.discover()
        let session = try XCTUnwrap(generation)
        func object(_ name: String, _ levels: [String]) -> [String: Any] {
            ["displayName": name, "supportedThinkingLevels": levels.map { ["thinkingSuffix": $0] }]
        }
        let groups = ["gemini-4-hydrogen": object("Catalog Hydrogen", ["high", "xhigh"]),
                      "gemini-3.8-flash": object("Gemini 3.8 Flash", ["medium"]),
                      "claude-opus-5-5": object("Claude Opus 5.5", ["high"]),
                      "gpt-6.2-sol": object("GPT Sol", ["high"]),
                      "future": object("Future", ["high"]), "future-tiered": object("Longer base", ["high"])]
        let data = try JSONSerialization.data(withJSONObject: ["userStatus": ["cascadeModelConfigData": ["groupedModels": groups],
            "email": "synthetic@example.invalid", "name": "forbidden-sentinel", "profilePictureUrl": "forbidden-sentinel"]])
        f.host.respond("GetUserStatus", with: data)
        let catalog = await client.modelCatalog(for: "gemini-4-hydrogen-tiered-high", session: session)
        for (id, name, effort) in [("gemini-4-hydrogen-tiered-high", "Catalog Hydrogen", "high"),
            ("claude-opus-5-5-high", "Claude Opus 5.5", "high"), ("gemini-3.8-flash-medium", "Gemini 3.8 Flash", "medium"),
            ("gpt-6.2-sol-high", "Sol 6.2", "high"), ("future-tiered-high", "Longer base", "high")] {
            XCTAssertEqual(catalog.resolve(id), AntigravityModel(name: name, effort: effort))
        }
        XCTAssertNil(catalog.resolve("gemini-3.8-flash-medium-high"))
        XCTAssertNil(catalog.resolve("gemini-3.8-flash")?.effort)
        XCTAssertNil(catalog.resolve("future-tiered-unsupported"))
        _ = await client.modelCatalog(for: "unknown", session: session)
        XCTAssertEqual(f.host.requests.filter { $0.path.hasSuffix("GetUserStatus") }.count, 1)
        XCTAssertFalse(String(describing: catalog).contains("sentinel"))
        _ = try f.hub(token: "rotated")
        let next = await client.discover()
        f.host.respond("GetUserStatus", with: Data("{}".utf8))
        let missing = await client.modelCatalog(for: "gemini-4-hydrogen-tiered-high", session: try XCTUnwrap(next))
        XCTAssertNil(missing.resolve("gemini-4-hydrogen-tiered-high"))
        XCTAssertEqual(AntigravityModel(id: "gemini-4-hydrogen-tiered-high")?.name, "Gemini 4 Hydrogen")
        XCTAssertEqual(f.host.requests.filter { $0.path.hasSuffix("GetUserStatus") }.count, 2)
    }

    private func quotaData(gemini: Double, third: Double, reset: Bool = true) throws -> Data {
        func bucket(_ id: String, _ period: String, _ fraction: Double, _ dated: Bool) -> [String: Any] {
            var result: [String: Any] = ["bucketId": id + "-" + period, "window": period, "remainingFraction": fraction]
            if dated { result["resetTime"] = timestamp(300) }
            return result
        }
        return try JSONSerialization.data(withJSONObject: ["response": ["groups": [
            ["buckets": [bucket("3p", "weekly", 0.8, reset), bucket("3p", "5h", third, reset)]],
            ["buckets": [bucket("gemini", "5h", gemini, true), bucket("gemini", "weekly", 0.9, true)]]]]])
    }

    func testQuotaGroupsWindowSelectionAndFreshness() throws {
        let value = try AntigravityQuotaCoordinator.decode(quotaData(gemini: 0.2, third: 0.15, reset: false), scope: nil, at: epoch)
        XCTAssertEqual(value.buckets.map(\.id), ["gemini", "3p"])
        XCTAssertEqual(value.windows.map(\.durationMinutes), [300, 10080, 300, 10080])
        XCTAssertEqual(Set(value.windows.map(\.id)).count, 4)
        let gemini = AntigravityQuotaGroup.selected(value, saved: nil), third = AntigravityQuotaGroup.selected(value, saved: "3p")
        XCTAssertEqual(CompactBarPresentation.quotaValue(provider: .antigravity, snapshot: gemini, failed: false, metric: .remaining,
            selection: nil, now: epoch), 90)
        XCTAssertEqual(CompactBarPresentation.quotaValue(provider: .antigravity, snapshot: third, failed: false, metric: .remaining,
            selection: "5h", now: epoch), 15)
        let week = QuotaDashboardPresentation.Reading(provider: .antigravity, period: .weekly, snapshot: third, now: epoch)
        XCTAssertEqual(week.remainingPercent, 80); XCTAssertEqual(week.availability, .available)
        XCTAssertNil(week.remainingTimePercent); XCTAssertNil(week.verdict); XCTAssertNil(week.projection)
        XCTAssertNil(week.resetMoment)
        XCTAssertEqual(QuotaDashboardPresentation.Reading(provider: .antigravity, period: .weekly, snapshot: gemini,
            now: epoch.addingTimeInterval(300)).availability, .stale)
        XCTAssertEqual(QuotaDashboardPresentation.Reading(provider: .antigravity, period: .weekly, snapshot: third,
            now: epoch.addingTimeInterval(601)).availability, .stale)
        func warnings(_ date: Date) -> [CompactWarningPresentation.Item] {
            CompactWarningPresentation.items(enabled: [.antigravity], warnings: [.fiveHour], snapshots: [.antigravity: value], now: date)
        }
        let mark = try XCTUnwrap(warnings(epoch).first)
        XCTAssertTrue(mark.help.contains(AntigravityQuotaGroup.thirdParty.name))
        XCTAssertFalse(mark.help.contains(AntigravityQuotaGroup.gemini.name))
        XCTAssertTrue(warnings(epoch.addingTimeInterval(601)).isEmpty)

        let partial = Data(#"{"response":{"groups":[{"buckets":[{"bucketId":"gemini-weekly","window":"5h","remainingFraction":0.5},{"bucketId":"3p-5h","window":"5h","remainingFraction":0},{"bucketId":"future-5h","window":"5h","remainingFraction":1},{"bucketId":"3p-weekly","window":"weekly","remainingFraction":1.01},{"bucketId":"gemini-5h","window":"5h","remainingFraction":"0.5"}]}]}}"#.utf8)
        let onlyThird = try AntigravityQuotaCoordinator.decode(partial, scope: nil, at: epoch)
        XCTAssertEqual(onlyThird.windows.map(\.usedPercent), [100])
        XCTAssertEqual(AntigravityQuotaGroup.selected(onlyThird, saved: nil)?.buckets.first?.id, "3p")
        XCTAssertNil(AntigravityQuotaGroup.selected(onlyThird, saved: "gemini"))
        XCTAssertEqual(QuotaDashboardPresentation.selectedWindow(provider: .antigravity, snapshot: onlyThird, selection: nil)?.durationMinutes, 300)
    }

    func testQuotaScopeSwitchHistoryAndNoticeBoundaries() async throws {
        let f = try Fixture(), client = AntigravityLocalClient(home: f.home, io: f.io), output = QuotaUpdates()
        let generation = await client.discover()
        let directory = f.home.appendingPathComponent("pacer-history")
        let store = QuotaHistoryStore(directory: directory)
        let credential = DeepSeekHistoryCredential(loadSalt: { Data(repeating: 7, count: 32) }, saveSalt: { _ in })
        let coordinator = AntigravityQuotaCoordinator(client: client, session: try XCTUnwrap(generation), home: f.home,
            credential: credential, history: store, now: { epoch }) { await output.receive($0, $1) }
        func status(_ local: String) -> Data { Data("{\"userStatus\":{\"email\":\"\(local)@example.invalid\"}}".utf8) }
        func read(_ remaining: Double) async throws -> LocalHarnessQuotaState {
            f.host.respond("RetrieveUserQuotaSummary", with: try quotaData(gemini: remaining, third: remaining))
            await coordinator.refresh(expanded: true, force: true)
            return await output.state
        }
        f.host.respond("GetUserStatus", with: status("account-a"))
        var state = try await read(0.1)
        let scopeA = try XCTUnwrap(state.snapshot?.accountScope)
        XCTAssertEqual(scopeA.count, 64); XCTAssertEqual(state.history.cycles.count, 2)
        let cachedA = await store.restore(home: f.home, accountScope: scopeA, now: epoch)
        XCTAssertEqual(cachedA?.1.cycles.count, 2)
        var notices = await output.notices
        XCTAssertTrue(notices.isEmpty, "First low reading establishes a silent baseline")
        _ = try await read(0.20); _ = try await read(0.15)
        notices = await output.notices; XCTAssertTrue(notices.isEmpty)
        _ = try await read(0.21); _ = try await read(0.151); _ = try await read(0.15); _ = try await read(0)
        notices = await output.notices
        XCTAssertEqual(notices.count, 2); XCTAssertEqual(Set(notices.map(\.id)).count, 2)
        for group in AntigravityQuotaGroup.allCases { XCTAssertTrue(notices.contains { $0.detail.contains(group.name) }) }

        let b = status("account-b")
        f.host.intercept = { [host = f.host] request in
            if request.path.hasSuffix("RetrieveUserQuotaSummary") { host.respond("GetUserStatus", with: b) }
        }
        state = try await read(0.5)
        XCTAssertNil(state.snapshot); XCTAssertTrue(state.history.cycles.isEmpty)
        f.host.intercept = nil
        state = try await read(0.3)
        let scopeB = try XCTUnwrap(state.snapshot?.accountScope)
        XCTAssertNotEqual(scopeB, scopeA); XCTAssertEqual(state.history.accountScope, scopeB)
        XCTAssertTrue(state.history.cycles.allSatisfy { $0.points.count == 1 })
        f.host.respond("GetUserStatus", with: Data(#"{"userStatus":{"name":"forbidden-sentinel"}}"#.utf8))
        state = try await read(0.01)
        XCTAssertNotNil(state.snapshot); XCTAssertNil(state.snapshot?.accountScope); XCTAssertTrue(state.history.cycles.isEmpty)
        XCTAssertNotNil(state.warning)
        let persisted = await store.restore(home: f.home, accountScope: scopeB, now: epoch)
        XCTAssertEqual(persisted?.0.buckets.first?.windows.first?.remainingPercent, 30)
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("example.invalid"))
        }
        let count = f.host.requests.count
        await coordinator.refresh(expanded: false)
        XCTAssertEqual(f.host.requests.count, count, "Scheduled refresh honors its cadence")
        f.host.respond("RetrieveUserQuotaSummary", with: Data("{}".utf8))
        await coordinator.refresh(expanded: true, force: true)
        state = await output.state; XCTAssertNil(state.snapshot); XCTAssertNotNil(state.error)
        f.host.disconnect()
        await coordinator.refresh(expanded: true, force: true)
        state = await output.state; XCTAssertNil(state.snapshot); XCTAssertNil(state.error)
    }
}

extension AntigravityTests {
    func testConcurrentQuotaRefreshCoalescesAndRetiredSourceCannotSave() async throws {
        let f = try Fixture(), client = AntigravityLocalClient(home: f.home, io: f.io)
        let generation = await client.discover(), output = QuotaUpdates()
        let directory = f.home.appendingPathComponent("history")
        let coordinator = AntigravityQuotaCoordinator(client: client, session: try XCTUnwrap(generation), home: f.home,
            credential: DeepSeekHistoryCredential(loadSalt: { Data(repeating: 1, count: 32) }, saveSalt: { _ in }),
            history: QuotaHistoryStore(directory: directory), now: { epoch }) { await output.receive($0, $1) }
        f.host.respond("GetUserStatus", with: Data(#"{"userStatus":{"email":"test@example.invalid"}}"#.utf8))
        f.host.respond("RetrieveUserQuotaSummary", with: try quotaData(gemini: 1, third: 1))
        let (started, start) = AsyncStream<Void>.makeStream(), (blocked, resume) = AsyncStream<Void>.makeStream()
        f.host.intercept = { request in
            guard request.path.hasSuffix("RetrieveUserQuotaSummary") else { return }
            start.finish()
            for await _ in blocked { break }
        }
        let first = Task { await coordinator.refresh(expanded: false) }
        for await _ in started { break }
        await coordinator.refresh(expanded: true, force: true)
        coordinator.invalidateSource()
        resume.finish()
        await first.value
        XCTAssertEqual(f.host.requests.filter { $0.path.hasSuffix("RetrieveUserQuotaSummary") }.count, 1)
        let state = await output.state
        XCTAssertNil(state.snapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
