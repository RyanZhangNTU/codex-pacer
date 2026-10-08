import Foundation
import SQLite3

/// Read-only lookup also finds sessions resumed from older date directories.
public enum SessionIndex {
    public struct Entry: Sendable {
        public let url: URL
        public let title: String?
        public let parentThreadID: String?
    }
    public static func files(home: URL, limit: Int = 256) -> [URL] { entries(home: home, limit: limit).map(\.url) }
    public static func entries(home: URL, limit: Int = 256) -> [Entry] {
        let manager = FileManager.default
        let databases = ((try? manager.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.range(of: #"^state_[0-9]+\.sqlite$"#, options: .regularExpression) != nil }
            .sorted { version($0) > version($1) }
        for file in databases {
            var db: OpaquePointer?
            guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
                if let db { sqlite3_close(db) }; continue
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 50)
            var info: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(threads)", -1, &info, nil) == SQLITE_OK else { continue }
            var columns: Set<String> = []
            while sqlite3_step(info) == SQLITE_ROW { if let name = sqlite3_column_text(info, 1) { columns.insert(String(cString: name)) } }
            sqlite3_finalize(info)
            guard columns.contains("rollout_path") else { continue }
            let order = ["recency_at_ms", "updated_at_ms", "updated_at", "created_at"].first { columns.contains($0) } ?? "rowid"
            var predicates = ["rollout_path IS NOT NULL"]
            if columns.contains("archived") { predicates.append("archived=0") }
            if columns.contains("thread_source") { predicates.append("COALESCE(thread_source,'') NOT IN ('guardian_review','auto_review','autoreview')") }
            if columns.contains("model") { predicates.append("COALESCE(model,'') NOT LIKE 'codex-auto-review%'") }
            let title: String
            if columns.contains("name"), columns.contains("title") { title = "COALESCE(NULLIF(TRIM(name),''),title)" }
            else { title = columns.contains("name") ? "name" : columns.contains("title") ? "title" : "NULL" }
            let source = columns.contains("source") ? "source" : "NULL"
            let query = "SELECT rollout_path, \(title), \(source) FROM threads WHERE \(predicates.joined(separator: " AND ")) ORDER BY \(order) DESC LIMIT \(min(1024, max(1, limit)))"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(statement) }
            let root = home.appendingPathComponent("sessions").standardizedFileURL.path + "/"
            var result: [Entry] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let raw = sqlite3_column_text(statement, 0) else { continue }
                let url = URL(fileURLWithPath: String(cString: raw)).standardizedFileURL
                if url.path.hasPrefix(root), url.pathExtension == "jsonl", manager.fileExists(atPath: url.path) {
                    let name = sqlite3_column_text(statement, 1).map { String(cString: $0) }
                    let raw = sqlite3_column_text(statement, 2).map { String(cString: $0) }
                    let source = raw.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) }
                    let parent = source.flatMap { SessionActivity.parentID(in: ["source": $0]) }
                    result.append(Entry(url: url, title: name, parentThreadID: parent))
                }
            }
            return result
        }
        return []
    }
    private static func version(_ url: URL) -> Int {
        Int(url.deletingPathExtension().lastPathComponent.dropFirst(6)) ?? 0
    }
}
