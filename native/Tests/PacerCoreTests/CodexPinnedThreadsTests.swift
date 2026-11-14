import XCTest
import SQLite3
@testable import PacerCore

final class CodexPinnedThreadsTests: XCTestCase {
    private func id(_ n: Int) -> String { String(format: "019a0000-0000-7000-8000-%012d", n) }
    private func home() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }
    private func sql(_ home: URL, _ query: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, query, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
    }
    private func schema(_ home: URL) throws {
        try sql(home, "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, title TEXT, archived INTEGER DEFAULT 0, updated_at INTEGER DEFAULT 0, is_pinned INTEGER DEFAULT 0, thread_section_id TEXT)")
    }
    private func rollout(_ home: URL, thread: String, suffix: String = "", at: Date = Date()) throws -> URL {
        let format = DateFormatter(); format.dateFormat = "yyyy/MM/dd"
        let folder = home.appendingPathComponent("sessions/" + format.string(from: at))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("rollout-" + thread + suffix + ".jsonl")
        let stamp = ISO8601DateFormatter().string(from: at)
        let rows: [[String: Any]] = [
            ["type": "session_meta", "timestamp": stamp, "payload": ["id": thread, "originator": "Codex Desktop", "cwd": "/fixture"]],
            ["type": "event_msg", "timestamp": stamp, "payload": ["type": "task_started", "turn_id": "synthetic"]]
        ]
        var data = Data()
        for row in rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }
        try data.write(to: file)
        return file
    }
    func testSectionIsAuthoritativeAndTracksPinUnpinArchive() throws {
        let home = try home(); try schema(home)
        try sql(home, "INSERT INTO threads (id, thread_section_id) VALUES ('\(id(1))','\(CodexPinnedThreads.sectionID)'); INSERT INTO threads (id,is_pinned) VALUES ('\(id(2))',1)")
        XCTAssertEqual(CodexPinnedThreads.read(home: home), [id(1)], "A legacy flag must not resurrect an unpinned conversation")
        try sql(home, "UPDATE threads SET thread_section_id=NULL WHERE id='\(id(1))'; UPDATE threads SET thread_section_id='\(CodexPinnedThreads.sectionID)' WHERE id='\(id(2))'")
        XCTAssertEqual(CodexPinnedThreads.read(home: home), [id(2)])
        try sql(home, "UPDATE threads SET archived=1")
        XCTAssertEqual(CodexPinnedThreads.read(home: home), [])
        try Data("broken".utf8).write(to: home.appendingPathComponent("state_6.sqlite"))
        XCTAssertNil(CodexPinnedThreads.read(home: home), "Do not fall back to an obsolete database on a read failure")
    }
    func testLegacyFallbackDoesNotReuseMigrationReceipts() throws {
        let home = try home(), file = home.appendingPathComponent(".codex-global-state.json")
        try JSONSerialization.data(withJSONObject: ["pinned-thread-ids": [id(1)]]).write(to: file)
        XCTAssertEqual(CodexPinnedThreads.read(home: home), [id(1)])
        try JSONSerialization.data(withJSONObject: ["pinned-thread-ids": [id(1)], "app-server-migrated-pinned-thread-ids-by-host": ["local": [id(1)]]]).write(to: file)
        XCTAssertNil(CodexPinnedThreads.read(home: home))
        try sql(home, "CREATE TABLE threads (id TEXT, is_pinned INTEGER); INSERT INTO threads VALUES ('\(id(2))',1)")
        XCTAssertEqual(CodexPinnedThreads.read(home: home), [id(2)])
    }
    func testResumedRolloutUsesIndexedPathAndVerifiedHeader() throws {
        let home = try home(); try schema(home)
        let old = try rollout(home, thread: id(1)), resumed = try rollout(home, thread: id(1), suffix: "_" + id(2))
        try sql(home, "INSERT INTO threads (id,rollout_path) VALUES ('\(id(1))','\(resumed.path.replacingOccurrences(of: "'", with: "''"))')")
        // Even if an old rollout's mtime is newer, the current indexed path wins.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: old.path)
        XCTAssertEqual(CodexOriginLookup(home: home).lookup(id(1))?.url, resumed)
        XCTAssertNil(CodexOriginLookup(home: home).lookup(id(2)), "A suffix UUID is not a thread identity")
        let foreign = try rollout(home, thread: id(3))
        try sql(home, "UPDATE threads SET rollout_path='\(foreign.path.replacingOccurrences(of: "'", with: "''"))'")
        XCTAssertNil(CodexOriginLookup(home: home).lookup(id(1)))
    }
    func testAllPinsReceiveReaderSlotsAndSupersededCursorIsRemoved() async throws {
        let home = try home(); try schema(home)
        let now = Date(), pins = Set((1...20).map(id))
        for number in 1...24 {
            let file = try rollout(home, thread: id(number), at: now)
            try sql(home, "INSERT INTO threads (id,rollout_path,updated_at) VALUES ('\(id(number))','\(file.path.replacingOccurrences(of: "'", with: "''"))',\(number))")
        }
        let reader = LocalActivityReader()
        let first = await reader.read(home: home, now: now, preferredThreads: pins)
        XCTAssertTrue(pins.isSubset(of: Set(first.activities.compactMap(\.threadID))))
        let resumed = try rollout(home, thread: id(1), suffix: "_" + id(50), at: now)
        try sql(home, "UPDATE threads SET rollout_path='\(resumed.path.replacingOccurrences(of: "'", with: "''"))' WHERE id='\(id(1))'")
        let next = await reader.read(home: home, now: now, preferredThreads: pins)
        XCTAssertEqual(next.activities.filter { $0.threadID == id(1) }.count, 1)
        XCTAssertTrue(next.watchURLs.contains(resumed))
        let covered = await LocalActivityReader().read(home: home, now: now, excludingThreads: [id(1)], preferredThreads: pins)
        XCTAssertFalse(covered.activities.contains { $0.threadID == id(1) }, "A resumed rollout uses its header identity when already covered by the live stream")
    }
    func testSelectionKeepsDescendantsAndOtherProvidersAndHidesUnpinnedAttention() {
        let now = Date()
        func task(_ n: Int, host: String? = nil, parent: String? = nil) -> SessionActivity {
            var row = SessionActivity(id: AgentProvider.codex.activityID(sessionID: id(n), sourceHostID: host), sourceHostID: host)
            row.consumeLive(["method": "turn/started", "threadId": id(n), "turnId": "synthetic", "at": now.timeIntervalSince1970])
            row.updateParent(parent)
            return row
        }
        var state = ActivityApplicationState()
        let parent = task(1), child = task(2, parent: id(1)), unpinned = task(3), remoteChild = task(4, host: "ssh:fixture", parent: id(1))
        state.localActivities = [child, parent, unpinned]; state.remoteActivities = [remoteChild]
        state.claudeActivities = [DemoScenario.claudeTask(stage: .thinking, at: now)]
        state.codexReceivedRequests = [.init(id: "question", threadID: id(3), sourceHostID: nil, sourceName: nil, kind: .input, detectedAt: now, provider: .codex)]
        let selected = ActivityVisibilityOptions(pinnedCodexThreadIDs: [id(1)])
        let hidden = state.hiddenActivityIDs(selected)
        XCTAssertFalse(hidden.contains(parent.canonicalized().id)); XCTAssertFalse(hidden.contains(child.canonicalized().id))
        XCTAssertTrue(hidden.contains(unpinned.canonicalized().id)); XCTAssertTrue(hidden.contains(remoteChild.canonicalized().id))
        state.reconcile(at: now, retention: 300, visibility: selected)
        XCTAssertTrue(state.requests.isEmpty)
        XCTAssertTrue(state.activities.contains { $0.provider == .claude })
        state.reconcile(at: now, retention: 300, visibility: .init(pinnedCodexThreadIDs: []))
        XCTAssertFalse(state.activities.contains { $0.provider == .codex })
    }
}
