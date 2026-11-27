import Foundation
import SQLite3

struct AntigravityStore {
    enum RunState {
        case running, idle

        init?(_ value: String?, prefix: String) {
            guard let value, value.hasPrefix(prefix) else { return nil }
            switch value.dropFirst(prefix.count) {
            case "RUNNING", "CANCELLING", "CANCELING": self = .running
            case "IDLE": self = .idle
            default: return nil
            }
        }
    }

    struct Summary: Equatable {
        let id: String
        let title: String?
        let count: Int
        var updated: Date
        let status: String
        let parent: String?
        let depth: Int
        let background: Bool
        let inputTime: Date?
        let inputIndex: Int
        var runState: RunState? { RunState(status, prefix: "CASCADE_RUN_STATUS_") }
        var running: Bool { runState == .running }
    }

    struct Step: Equatable {
        let index: Int
        let type: Int
        let status: Int
    }

    struct Trajectory: Equatable {
        let id: String
        let anchor: Step?
        let firstPlanner: Int?
        let tail: [Step]
        let unresolved: [Step]
        var last: Step? { tail.last }
    }

    enum Failure: Error { case missing, unavailable, incompatible, retrySoon }
    let home: URL
    let files: any PlatformFileSystem

    init(home: URL, files: any PlatformFileSystem) {
        // Resolve the selected root once (including macOS /var → /private/var).
        // SQL opens below it still refuse symlinks in any component.
        self.home = files.resolvedDirectory(home)
        self.files = files
    }

    var summariesURL: URL { home.appendingPathComponent("conversation_summaries.db", isDirectory: false) }
    var conversationsDirectory: URL { home.appendingPathComponent("conversations", isDirectory: true) }
    func conversationURL(_ id: String) -> URL { conversationsDirectory.appendingPathComponent("\(id).db", isDirectory: false) }
    func transcriptURL(_ id: String) -> URL { home.appendingPathComponent("brain/\(id)/.system_generated/logs/transcript_full.jsonl", isDirectory: false) }

    static func uuid(_ value: String?) -> String? { value.flatMap(UUID.init(uuidString:))?.uuidString.lowercased() }
    static func date(_ value: String?) -> Date? {
        guard let value, value.count <= 48, !value.hasPrefix("0001-"),
              let date = SessionActivity.parseDate(value.replacingOccurrences(of: " ", with: "T")),
              date.timeIntervalSince1970 > 0 else { return nil }
        return date
    }

    func summaries(includeDatabaseDates: Bool = true) throws -> [Summary] {
        try snapshot(summariesURL) { db in
            try requireTables(["conversation_summaries"], db: db)
            let columns = try query(db, "SELECT name FROM pragma_table_info('conversation_summaries')") { text($0, 0) }
            // A missing family column must never silently promote a known child to a root.
            let optional = [("not_fully_idle", "0"), ("last_user_input_step_index", "-1")]
                .map { columns.contains($0.0) ? $0.0 : $0.1 }
            return try query(db, """
                SELECT conversation_id, substr(title,1,240), step_count, last_modified_time, status,
                       parent_conversation_id, nesting_depth, last_user_input_time, \(optional.joined(separator: ", "))
                FROM conversation_summaries ORDER BY status != 'CASCADE_RUN_STATUS_IDLE' DESC, last_modified_time DESC, conversation_id LIMIT 512
                """) { s in
                let count = Int(sqlite3_column_int64(s, 2))
                guard let id = Self.uuid(text(s, 0)),
                      let status = text(s, 4), (0...Int(Int32.max)).contains(count) else { return nil }
                let parent = text(s, 5)
                guard parent?.isEmpty != false || Self.uuid(parent) != nil else { return nil }
                let input = Self.date(text(s, 7))
                let modified = includeDatabaseDates ? files.metadata(conversationURL(id)).flatMap { $0.isRegularFile ? $0.modified : nil } : nil
                let updated = [Self.date(text(s, 3)), input, modified].compactMap { $0 }.max() ?? .distantPast
                return Summary(id: id, title: text(s, 1, limit: 960), count: count, updated: updated, status: status,
                    parent: Self.uuid(parent), depth: Int(sqlite3_column_int64(s, 6)), background: sqlite3_column_int(s, 8) != 0,
                    inputTime: input, inputIndex: Int(sqlite3_column_int64(s, 9)))
            }
        }
    }

    func trajectory(_ row: Summary) throws -> Trajectory {
        guard Self.uuid(row.id) == row.id else { throw Failure.incompatible }
        return try snapshot(conversationURL(row.id)) { db in
            try requireTables(["trajectory_meta", "steps"], db: db)
            let identities = try query(db, "SELECT trajectory_id, cascade_id FROM trajectory_meta LIMIT 2") {
                (Self.uuid(text($0, 0)), Self.uuid(text($0, 1)))
            }
            guard identities.count == 1, identities[0].1 == row.id, let trajectory = identities[0].0 else { throw Failure.incompatible }
            func steps(_ clause: String) throws -> [Step] {
                try query(db, "SELECT idx, step_type, status FROM steps " + clause) {
                    let index = Int(sqlite3_column_int64($0, 0))
                    guard (0..<Int(Int32.max)).contains(index) else { throw Failure.incompatible }
                    return Step(index: index, type: Int(sqlite3_column_int64($0, 1)), status: Int(sqlite3_column_int64($0, 2)))
                }
            }
            var anchor = try steps("WHERE step_type=14 ORDER BY idx DESC LIMIT 1").first
            if anchor == nil, row.parent != nil { anchor = try steps("WHERE idx=0 AND step_type=101").first }
            let start = anchor?.index ?? 0
            let first = try steps("WHERE idx>=\(start) AND step_type=15 ORDER BY idx LIMIT 1").first
            let open = try steps("WHERE idx>=\(start) AND status NOT IN (3,6,7) ORDER BY idx LIMIT 129")
            guard open.count <= 128 else { throw Failure.unavailable }
            guard let last = try steps("ORDER BY idx DESC LIMIT 1").first else { throw Failure.unavailable }
            let offset = max(start, last.index - 127, min(last.index - 15, open.first?.index ?? last.index))
            let tail = try steps("WHERE idx>=\(offset) ORDER BY idx LIMIT 128")
            return Trajectory(id: trajectory, anchor: anchor, firstPlanner: first?.index, tail: tail, unresolved: open)
        }
    }

    private func snapshot<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        guard files.metadata(url.deletingLastPathComponent())?.isDirectory == true,
              let before = files.metadata(url), before.isRegularFile else { throw Failure.missing }
        let wal = URL(fileURLWithPath: url.path + "-wal"), shm = URL(fileURLWithPath: url.path + "-shm")
        switch (files.metadata(wal), files.metadata(shm)) {
        case (nil, nil):
            let journal = URL(fileURLWithPath: url.path + "-journal")
            guard files.metadata(journal) == nil else { throw Failure.retrySoon }
            let result = Result { try read(url.absoluteString + "?immutable=1", body) }
            guard files.metadata(url) == before, files.metadata(wal) == nil, files.metadata(shm) == nil,
                  files.metadata(journal) == nil else { throw Failure.retrySoon }
            return try result.get()
        case let (walStamp?, shmStamp?) where walStamp.isRegularFile && shmStamp.isRegularFile:
            let result = Result { try read(url.absoluteString + "?readonly_shm=1", body) }
            guard files.metadata(url)?.identity == before.identity, files.metadata(wal)?.identity == walStamp.identity,
                  files.metadata(shm)?.identity == shmStamp.identity else { throw Failure.retrySoon }
            return try result.get()
        default:
            throw Failure.retrySoon
        }
    }

    // SQLite opens the WAL with CREATE even for a read-only main database. Use the
    // platform VFS for normal locking, but forbid creating a WAL if the writer closes
    // between the metadata check and SQLite's open. readonly_shm covers its shared map.
    private static let platformVFS = sqlite3_vfs_find(nil)
    private static let readOnlyVFS: String? = {
        let name: StaticString = "pacer-antigravity-readonly"
        guard let platform = platformVFS else { return nil }
        let vfs = UnsafeMutablePointer<sqlite3_vfs>.allocate(capacity: 1)
        vfs.initialize(to: platform.pointee)
        vfs.pointee.zName = UnsafeRawPointer(name.utf8Start).assumingMemoryBound(to: CChar.self)
        vfs.pointee.xOpen = { _, path, file, flags, actual in
            guard let platform = AntigravityStore.platformVFS, let open = platform.pointee.xOpen else { return SQLITE_CANTOPEN }
            guard flags & (SQLITE_OPEN_MAIN_DB | SQLITE_OPEN_WAL) != 0 else { return SQLITE_READONLY }
            let readOnly = (flags & ~(SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE)) | SQLITE_OPEN_READONLY
            return open(platform, path, file, readOnly, actual)
        }
        vfs.pointee.xDelete = { _, _, _ in SQLITE_READONLY }
        guard sqlite3_vfs_register(vfs, 0) == SQLITE_OK else { vfs.deallocate(); return nil }
        return name.description
    }()

    private func read<T>(_ uri: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        guard let vfs = Self.readOnlyVFS else { throw Failure.unavailable }
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_URI
        let result = sqlite3_open_v2(uri, &connection, flags, vfs)
        defer { sqlite3_close(connection) }
        guard result == SQLITE_OK, let db = connection else { throw Failure.unavailable }
        sqlite3_busy_timeout(db, 25)
        guard sqlite3_exec(db, "PRAGMA query_only=ON; PRAGMA trusted_schema=OFF; BEGIN", nil, nil, nil) == SQLITE_OK else { throw Failure.unavailable }
        var budget = Budget()
        return try withUnsafeMutablePointer(to: &budget) { pointer in
            sqlite3_progress_handler(db, 1000, { context in
                guard let budget = context?.assumingMemoryBound(to: Budget.self) else { return 1 }
                budget.pointee.remaining -= 1
                return budget.pointee.remaining <= 0 || ProcessInfo.processInfo.systemUptime >= budget.pointee.deadline ? 1 : 0
            }, pointer)
            defer { sqlite3_progress_handler(db, 0, nil, nil) }
            return try body(db)
        }
    }

    private struct Budget { let deadline = ProcessInfo.processInfo.systemUptime + 0.05; var remaining = 250 }

    /// Reject views (which could read unrelated columns) and virtual/FTS tables.
    private func requireTables(_ tables: [String], db: OpaquePointer) throws {
        for table in tables {
            let types = try query(db, "SELECT type FROM pragma_table_list WHERE schema='main' AND name='\(table)'") { text($0, 0) }
            guard types == ["table"] else { throw Failure.incompatible }
        }
    }

    private func query<T>(_ db: OpaquePointer, _ sql: String, _ project: (OpaquePointer) throws -> T?) throws -> [T] {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard result == SQLITE_OK, let statement else { throw result == SQLITE_ERROR ? Failure.incompatible : Failure.unavailable }
        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: if let row = try project(statement) { rows.append(row) }
            case SQLITE_DONE: return rows
            default: throw Failure.unavailable
            }
        }
    }

    private func text(_ statement: OpaquePointer, _ column: Int32, limit: Int = 256) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT, sqlite3_column_bytes(statement, column) <= limit,
              let bytes = sqlite3_column_text(statement, column) else { return nil }
        return String(bytes: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), encoding: .utf8)
    }
}
