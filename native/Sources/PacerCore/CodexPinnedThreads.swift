import Foundation
import SQLite3

/// Read-only sidebar membership. A failed read is not an empty pinned list.
public enum CodexPinnedThreads {
    // Codex Desktop's reserved pinned section, also used by its sidebar API.
    public static let sectionID = "01984de2-8f74-7c91-a3b2-5c5e937cf318"
    public static let maximumThreads = 256

    public static func database(home: URL) -> URL? {
        ((try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.range(of: #"^state_[0-9]+\.sqlite$"#, options: .regularExpression) != nil }
            .max { version($0) < version($1) }
    }
    private static func version(_ file: URL) -> Int {
        Int(file.deletingPathExtension().lastPathComponent.dropFirst(6)) ?? 0
    }
    public static func watchURLs(home: URL) -> [URL] {
        var paths = [home, home.appendingPathComponent(".codex-global-state.json")]
        if let file = database(home: home) {
            paths += [file, URL(fileURLWithPath: file.path + "-wal")]
        }
        return paths.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    public static func read(home: URL) -> Set<String>? {
        guard let file = database(home: home) else { return legacy(home: home) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 50)
        var info: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(threads)", -1, &info, nil) == SQLITE_OK else { return nil }
        var columns: Set<String> = []
        var step = sqlite3_step(info)
        while step == SQLITE_ROW {
            if let name = sqlite3_column_text(info, 1) { columns.insert(String(cString: name)) }
            step = sqlite3_step(info)
        }
        sqlite3_finalize(info)
        guard step == SQLITE_DONE else { return nil }
        let predicate: String
        if columns.contains("thread_section_id") { predicate = "thread_section_id='\(sectionID)'" }
        else if columns.contains("is_pinned") { predicate = "is_pinned=1" }
        else { return legacy(home: home) }
        guard columns.contains("id") else { return nil }
        let archived = columns.contains("archived") ? " AND archived=0" : ""
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM threads WHERE \(predicate)\(archived) LIMIT \(maximumThreads + 1)", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var ids: Set<String> = []
        step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: raw)) else { return nil }
            ids.insert(id.uuidString.lowercased())
            guard ids.count <= maximumThreads else { return nil }
            step = sqlite3_step(statement)
        }
        return step == SQLITE_DONE ? ids : nil
    }
    /// Titles do not require a rollout: newly created and cold pinned chats remain visible.
    public static func titles(home: URL, ids: Set<String>) -> [String: String]? {
        guard let file = database(home: home) else { return [:] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 50)
        var info: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(threads)", -1, &info, nil) == SQLITE_OK else { return nil }
        var columns: Set<String> = []
        while sqlite3_step(info) == SQLITE_ROW { if let raw = sqlite3_column_text(info, 1) { columns.insert(String(cString: raw)) } }
        sqlite3_finalize(info)
        let title = columns.contains("name") && columns.contains("title") ? "COALESCE(NULLIF(TRIM(name),''),title)" : columns.contains("title") ? "title" : columns.contains("name") ? "name" : "NULL"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, \(title) FROM threads WHERE id=?", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var result: [String: String] = [:]
        for id in ids.sorted() {
            sqlite3_reset(statement)
            let code = id.withCString { raw -> Int32 in
                sqlite3_bind_text(statement, 1, raw, -1, nil)
                return sqlite3_step(statement)
            }
            if code == SQLITE_ROW, let text = sqlite3_column_text(statement, 1) {
                let value = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { result[id] = String(value.prefix(240)) }
            } else if code != SQLITE_DONE && code != SQLITE_ROW { return nil }
        }
        return result
    }
    private static func legacy(home: URL) -> Set<String>? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".codex-global-state.json")), data.count <= 8 * 1024 * 1024,
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // Migration receipts are not a live list. Never revive stale pins after migration.
        if let migrations = state["app-server-migrated-pinned-thread-ids-by-host"] as? [String: Any], !migrations.isEmpty { return nil }
        guard let raw = state["pinned-thread-ids"] as? [String], raw.count <= maximumThreads else { return nil }
        let ids = raw.compactMap { UUID(uuidString: $0)?.uuidString.lowercased() }
        guard ids.count == raw.count else { return nil }
        return Set(ids)
    }

    public static func visibleActivityIDs(pinned: Set<String>, activities: [SessionActivity]) -> Set<String> {
        let codex = activities.filter { $0.provider == .codex }
        var visible = Set(codex.filter { $0.threadID.map(pinned.contains) == true }.map { $0.canonicalized().id })
        for _ in 0..<64 {
            let before = visible.count
            for row in codex {
                guard let parent = row.parentThreadID else { continue }
                let parentID = AgentProvider.codex.activityID(sessionID: parent, sourceHostID: row.sourceHostID)
                if visible.contains(parentID) { visible.insert(row.canonicalized().id) }
            }
            if visible.count == before { break }
        }
        return visible
    }
}
