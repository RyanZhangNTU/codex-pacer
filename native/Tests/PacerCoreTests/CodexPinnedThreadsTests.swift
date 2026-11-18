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
    private func catalog(_ home: URL) -> [CodexPinnedThreads.Entry]? {
        CodexPinnedThreads.read(home: home, database: CodexPinnedThreads.database(home: home))
    }
    private func membership(_ home: URL) -> Set<String>? { catalog(home).map { Set($0.map(\.id)) } }
    private func titles(_ home: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (catalog(home) ?? []).compactMap { item in item.title.map { (item.id, $0) } })
    }
    func testPinnedTitlesDoNotRequireRolloutAndPreferRenamedTitle() throws {
        let home = try home(); try schema(home)
        try sql(home, "ALTER TABLE threads ADD COLUMN name TEXT; INSERT INTO threads (id,title,name,thread_section_id) VALUES ('\(id(1))','Old title','Renamed','\(CodexPinnedThreads.sectionID)')")
        XCTAssertEqual(titles(home), [id(1): "Renamed"])
        try sql(home, "UPDATE threads SET name='  '")
        XCTAssertEqual(titles(home), [id(1): "Old title"])
    }
    func testSectionIsAuthoritativeAndTracksPinUnpinArchive() throws {
        let home = try home(); try schema(home)
        try sql(home, "INSERT INTO threads (id, thread_section_id) VALUES ('\(id(1))','\(CodexPinnedThreads.sectionID)'); INSERT INTO threads (id,is_pinned) VALUES ('\(id(2))',1)")
        XCTAssertEqual(membership(home), [id(1)], "A legacy flag must not resurrect an unpinned conversation")
        try sql(home, "UPDATE threads SET thread_section_id=NULL WHERE id='\(id(1))'; UPDATE threads SET thread_section_id='\(CodexPinnedThreads.sectionID)' WHERE id='\(id(2))'")
        XCTAssertEqual(membership(home), [id(2)])
        try sql(home, "UPDATE threads SET archived=1")
        XCTAssertEqual(membership(home), [])
        try Data("broken".utf8).write(to: home.appendingPathComponent("state_6.sqlite"))
        XCTAssertNil(membership(home), "Do not fall back to an obsolete database on a read failure")
    }
    func testLegacyFallbackDoesNotReuseMigrationReceipts() throws {
        let home = try home(), file = home.appendingPathComponent(".codex-global-state.json")
        try JSONSerialization.data(withJSONObject: ["pinned-thread-ids": [id(1)]]).write(to: file)
        XCTAssertEqual(membership(home), [id(1)])
        try JSONSerialization.data(withJSONObject: ["pinned-thread-ids": [id(1)], "app-server-migrated-pinned-thread-ids-by-host": ["local": [id(1)]]]).write(to: file)
        XCTAssertNil(membership(home))
        try sql(home, "CREATE TABLE threads (id TEXT, is_pinned INTEGER); INSERT INTO threads VALUES ('\(id(2))',1)")
        XCTAssertEqual(membership(home), [id(2)])
    }
    func testPinnedSlotsLeaveRoomForAnUnpinnedChildAndOtherWork() async throws {
        let root = try home(), now = Date()
        var pins: [CodexPinnedThreads.Entry] = []
        for number in 1...20 {
            let file = try rollout(root, thread: id(number), at: now)
            pins.append(.init(id: id(number), title: nil, rolloutURL: file.standardizedFileURL))
        }
        let child = try rollout(root, thread: id(21), at: now)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(10)], ofItemAtPath: child.path)
        let reader = LocalActivityReader()
        let sample = await reader.read(home: root, now: now, pinned: pins)
        XCTAssertTrue(Set((1...21).map(id)).isSubset(of: Set(sample.activities.compactMap(\.threadID))))
        let resumed = try rollout(root, thread: id(1), suffix: "_" + id(99), at: now)
        pins[0] = .init(id: id(1), title: nil, rolloutURL: resumed.standardizedFileURL)
        let next = await reader.read(home: root, now: now, pinned: pins)
        XCTAssertEqual(next.activities.filter { $0.threadID == id(1) }.count, 1)
        XCTAssertTrue(next.watchURLs.contains(resumed.standardizedFileURL))
    }

    func testPinnedProjectionRespectsPrivacyAndLeavesLiveStateIntact() {
        let now = Date(), pins = [CodexPinnedThreads.Entry(id: id(1), title: "Fixture title")]
        var parent = SessionActivity(id: AgentProvider.codex.activityID(sessionID: id(1)), sessionID: id(1))
        var child = SessionActivity(id: AgentProvider.codex.activityID(sessionID: id(2)), sessionID: id(2))
        child.updateParent(id(1))
        child.consumeLive(["method": "turn/started", "threadId": id(2), "turnId": "fixture", "at": now.timeIntervalSince1970])
        func rows(_ entries: [CodexPinnedThreads.Entry], _ seen: [SessionActivity], hidden: Set<String> = [], embedded: Bool = true) -> [CodexPinnedThreads.Row] {
            CodexPinnedThreads.rows(entries, activities: seen, requests: [], excluding: hidden, showsEmbedded: embedded,
                inbox: .init(), options: .init(hideProjects: true), at: now)
        }
        let idle = rows(pins, [])
        XCTAssertEqual(idle.first?.title, L10n.text("activity.hidden_name"))
        XCTAssertNil(idle.first?.live)
        XCTAssertEqual(rows(pins, [child]).first?.live?.phase, .running)
        XCTAssertTrue(rows([], [child]).isEmpty)
        parent.setCodexOrigin(.init(embedded: true, ignored: false), at: now)
        XCTAssertTrue(rows(pins, [parent], embedded: false).isEmpty)
        XCTAssertTrue(rows(pins, [], hidden: [parent.id]).isEmpty)
        let both = rows(pins + [.init(id: id(2), title: "Child")], [parent, child])
        XCTAssertEqual(both.map { $0.live?.phase }, [.running, .running])
        XCTAssertEqual(both.last?.live?.title, L10n.text("activity.hidden_name"))
        var state = ActivityApplicationState()
        state.localActivities = [child]
        state.reconcile(at: now, retention: 300, visibility: .init())
        XCTAssertEqual(state.activities.map(\.threadID), [id(2)])
    }
}
