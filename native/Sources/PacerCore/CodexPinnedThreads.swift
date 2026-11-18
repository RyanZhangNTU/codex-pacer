import Foundation
import SQLite3

/// A read-only snapshot of the local Codex sidebar. A failed read is distinct from an empty section.
public enum CodexPinnedThreads {
    public static let sectionID = "01984de2-8f74-7c91-a3b2-5c5e937cf318"
    public static let limit = 256

    public struct Entry: Equatable, Sendable {
        public let id: String
        public let title: String?
        public let origin: CodexSessionOrigin?
        public let rolloutURL: URL?

        public init(id: String, title: String?, origin: CodexSessionOrigin? = nil, rolloutURL: URL? = nil) {
            self.id = id
            self.title = title
            self.origin = origin
            self.rolloutURL = rolloutURL
        }
    }

    public static func database(home: URL) -> URL? {
        let entries = (try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { url -> (Int, URL)? in
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "sqlite", name.hasPrefix("state_"),
                  let version = Int(name.dropFirst(6)), version >= 0 else { return nil }
            return (version, url)
        }.max { $0.0 < $1.0 }?.1
    }

    public static func watchURLs(home: URL, database: URL?) -> [URL] {
        var files = [home.appendingPathComponent(".codex-global-state.json")]
        if let database { files += [database, URL(fileURLWithPath: database.path + "-wal")] }
        return [home] + files.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func read(home: URL, database: URL?) -> [Entry]? {
        guard let database else { return legacy(home).map { $0.map { Entry(id: $0, title: nil) } } }
        var db: OpaquePointer?
        defer { if let db { sqlite3_close(db) } }
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { return nil }
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
        var predicates: [String]
        if columns.contains("thread_section_id") {
            predicates = ["thread_section_id='\(sectionID)'"]
        } else if columns.contains("is_pinned") {
            predicates = ["is_pinned=1"]
        } else {
            guard let ids = legacy(home) else { return nil }
            guard columns.contains("id"), !ids.isEmpty else { return ids.map { Entry(id: $0, title: nil) } }
            // legacy() returns canonical UUIDs only.
            predicates = ["id IN (" + ids.map { "'\($0)'" }.joined(separator: ",") + ")"]
        }
        guard columns.contains("id") else { return nil }
        if columns.contains("archived") { predicates.append("archived=0") }
        if columns.contains("thread_source") { predicates.append("COALESCE(thread_source,'') NOT IN ('guardian_review','auto_review','autoreview')") }
        if columns.contains("model") { predicates.append("COALESCE(model,'') NOT LIKE 'codex-auto-review%'") }
        let names = ["name", "title"].filter(columns.contains).map { "NULLIF(TRIM(\($0)), '')" }
        let title = !names.isEmpty ? "COALESCE(" + (names + ["NULL"]).joined(separator: ",") + ")" : "NULL"
        let originator = columns.contains("originator") ? "substr(originator,1,256)" : "NULL"
        let cwd = columns.contains("cwd") ? "substr(cwd,1,4096)" : "NULL"
        let path = columns.contains("rollout_path") ? "rollout_path" : "NULL"
        let sessions = home.appendingPathComponent("sessions", isDirectory: true).standardizedFileURL.path + "/"
        let sql = "SELECT id, substr(\(title),1,240), \(originator), \(cwd), \(path) FROM threads WHERE " +
            predicates.joined(separator: " AND ") + " ORDER BY id LIMIT \(limit + 1)"
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(query) }
        func string(_ column: Int32) -> String? {
            sqlite3_column_text(query, column).map { String(cString: $0) }
        }
        var result: [Entry] = []
        var seen: Set<String> = []
        step = sqlite3_step(query)
        while step == SQLITE_ROW {
            guard result.count < limit, let raw = string(0), let uuid = UUID(uuidString: raw) else { return nil }
            let id = uuid.uuidString.lowercased()
            guard seen.insert(id).inserted else { return nil }
            let url = string(4).map { URL(fileURLWithPath: $0).standardizedFileURL }
            let rollout = url.flatMap { $0.path.hasPrefix(sessions) && $0.pathExtension == "jsonl" ? $0 : nil }
            result.append(Entry(id: id, title: string(1), origin: CodexSessionOrigin.classify(originator: string(2), cwd: string(3)), rolloutURL: rollout))
            step = sqlite3_step(query)
        }
        return step == SQLITE_DONE ? result : nil
    }

    /// Only the pinned view uses these placeholders. They never enter activity, notice or rate state.
    public struct Row: Sendable {
        public let activity: SessionActivity
        public let live: ActivityTaskRowPresentation?
        public let title: String
    }

    public static func rows(_ entries: [Entry], activities: [SessionActivity], requests: [PendingAttentionRequest],
                            excluding hidden: Set<String>, origins: [String: CodexSessionOrigin] = [:],
                            showsEmbedded: Bool, inbox: CompletionInbox, options: TaskPresentationOptions, at date: Date) -> [Row] {
        let local = activities.filter { $0.provider == .codex && $0.sourceHostID == nil }
        let pending = requests.filter { $0.provider == .codex && $0.sourceHostID == nil }
        let observed = Dictionary((local + pending.map(\.activity)).map { ($0.canonicalized().id, $0.canonicalized()) },
                                  uniquingKeysWith: { first, _ in first })
        var candidates: [SessionActivity] = []
        for entry in entries {
            let key = AgentProvider.codex.activityID(sessionID: entry.id)
            let origin = observed[key]?.codexOrigin ?? origins[key] ?? entry.origin
            guard !hidden.contains(key), origin?.ignored != true, observed[key]?.isInternalReview != true,
                  showsEmbedded || origin?.embedded == false else { continue }
            var activity = observed[key] ?? SessionActivity(id: key, sessionID: entry.id)
            if let name = entry.title { activity.updateTitle(name) }
            if let origin, activity.codexOrigin == nil { activity.setCodexOrigin(origin) }
            candidates.append(activity)
        }
        let selected = Set(candidates.map(\.id))
        let groups = ActivityTaskGroup.make(candidates + local.filter { !selected.contains($0.canonicalized().id) })
        let roots = Dictionary(uniqueKeysWithValues: groups.map { ($0.primary.id, $0) })
        let members = Dictionary(uniqueKeysWithValues: groups.flatMap(\.members).map { ($0.id, $0) })
        return candidates.map { candidate in
            var activity = members[candidate.id] ?? candidate
            if let name = candidate.title { activity.updateTitle(name) }
            let group = roots[candidate.id]
            let attention = ActivityTaskPresentation.attentionKind(activity, groups: groups, requests: pending)
            let live = activity.phase != .unknown || group?.isRunning == true || group?.isWaiting == true || attention != nil
            let row = live ? ActivityTaskRowPresentation(activity: activity, group: group, attention: attention,
                unread: group?.isRunning != true && inbox.isUnread(activity), options: options, at: date) : nil
            return Row(activity: activity, live: row, title: ActivityTaskRowPresentation.title(activity, hideProjects: options.hideProjects))
        }
    }

    private static func legacy(_ home: URL) -> [String]? {
        guard let file = try? FileHandle(forReadingFrom: home.appendingPathComponent(".codex-global-state.json")) else { return nil }
        defer { try? file.close() }
        let maxBytes = 8 * 1024 * 1024
        guard let bytes = try? file.read(upToCount: maxBytes + 1), bytes.count <= maxBytes,
              let fields = try? JSONFieldView.document(bytes, maximumBytes: maxBytes).fields(["pinned-thread-ids", "app-server-migrated-pinned-thread-ids-by-host"]),
              let pins = fields["pinned-thread-ids"], pins.isArray else { return nil }
        // A migration receipt is not the current sidebar membership.
        if let receipt = fields["app-server-migrated-pinned-thread-ids-by-host"], receipt.isObject {
            var migrated = false
            guard (try? receipt.forEachField(maximumCount: 64) { _, _ in migrated = true }) != nil, !migrated else { return nil }
        }
        var ids: [String] = []
        var valid = true
        guard (try? pins.forEachElement(maximumCount: limit) { value in
            if let raw = value.string(limit: 36), let id = UUID(uuidString: raw) { ids.append(id.uuidString.lowercased()) }
            else { valid = false }
        }) != nil, valid, Set(ids).count == ids.count else { return nil }
        return ids
    }
}
