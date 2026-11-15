import Foundation
import CryptoKit
import SQLite3

enum WorkBuddyHarness {
    /// The China build (WorkBuddy, workbuddy.cn) and the international build
    /// (WorkBuddy AI, workbuddy.ai) are separate apps with their own data
    /// folder, account, site and links, so each is a module of its own.
    enum Edition: Sendable { case china, international }

    static let china = makeDefinition(.china)
    static let international = makeDefinition(.international)
    static func id(_ edition: Edition) -> AgentProvider { edition == .china ? .workbuddy : .workbuddyAI }
    static func definition(for edition: Edition) -> LocalHarnessDefinition { edition == .china ? china : international }

    static func accountCredits(_ edition: Edition) -> HarnessAccountCreditsDefinition {
        let site = edition == .china ? "china" : "international"
        return HarnessAccountCreditsDefinition(
            sites: [.init(id: site, url: URL(string: edition == .china ? "https://www.workbuddy.cn/" : "https://www.workbuddy.ai/")!)],
            chineseSite: site, loginPath: "profile/plans-usage",
            billingPath: "/billing/meter/get-user-resource-summary", scriptResource: "workbuddy-account-credits")
    }

    private static func makeDefinition(_ edition: Edition) -> LocalHarnessDefinition {
        let china = edition == .china
        return LocalHarnessDefinition(
            descriptor: .init(id: id(edition), name: china ? "WorkBuddy" : "WorkBuddy AI", symbol: "briefcase",
                              brand: .init(dark: .init(0xC3ABF1), light: .init(0x6942A2), accentLift: 0.22, accentLuminance: 0.095),
                              website: URL(string: china ? "https://www.workbuddy.cn/" : "https://www.workbuddy.ai/"), balance: .accountCredits,
                              hasRateDisplay: true, hasTaskProgress: true, reportsSessionUsage: true,
                              usageGuide: URL(string: china ? "https://www.codebuddy.cn/docs/workbuddy/Usage" : "https://www.workbuddy.ai/docs/workbuddy/usage"),
                              progressConnector: true, accountCredits: accountCredits(edition)),
            platforms: [.windows, .macOS], home: china ? ".workbuddy" : ".workbuddy-ai", dataFile: "workbuddy.db",
            windowsExecutables: china ? ["WorkBuddy/WorkBuddy.exe", "Programs/WorkBuddy/WorkBuddy.exe"]
                : ["WorkBuddyAI/WorkBuddyAI.exe", "Programs/WorkBuddyAI/WorkBuddyAI.exe"],
            macApplicationNames: china ? ["WorkBuddy"] : ["WorkBuddy AI"],
            // Read from the installed apps: WorkBuddy 5.9.3 and WorkBuddy AI 5.9.4, both from team FN2V63AD2J.
            macBundleIdentifiers: china ? ["com.tencent.workbuddy.mac"] : ["com.workbuddy.workbuddy-ai"],
            macSigningOrganization: "Tencent Technology (Shenzhen) Company Limited",
            macTeamIdentifier: "FN2V63AD2J",
            conversationScheme: china ? "workbuddy" : "workbuddy-ai",
            connectorsPath: "connectors",
            progressConfigFile: "mcp.json",
            progressRuleDirectory: "rules",
            progressConnection: progressConnection,
            appLogFile: "logs/daemon.log",
            makeMonitor: { WorkBuddyMonitor(io: $0, edition: edition) })
    }

    /// The time in a UUIDv7, with or without hyphens.
    static func chargeTime(_ id: String) -> Date? {
        let hex = id.replacingOccurrences(of: "-", with: "")
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit), hex[hex.index(hex.startIndex, offsetBy: 12)] == "7",
              let milliseconds = UInt64(hex.prefix(12), radix: 16), milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }


    @Sendable static func progressConnection(home: URL, command: String, arguments: [String],
                                   storage: any ClaudeHookStorage) -> LocalHarnessProgressConnection {
        func readObject(_ name: String) throws -> JSONFieldView? {
            let file = home.appendingPathComponent(name)
            try storage.validate(file)
            guard storage.exists(file) else { return nil }
            let document = try JSONFieldView.document(storage.read(file), maximumBytes: 256 * 1024)
            guard document.isObject else { throw JSONFieldView.Failure.malformed }
            return document
        }
        do {
            guard let approvals = try readObject("mcp-approvals.json") else { return .needsTrust }
            // WorkBuddy 5.9.4 keys its approval to the current stdio command.
            // Pacer's entry has no environment overrides or working directory.
            let material = [command, arguments.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }.joined(separator: ","), ""].joined(separator: "|")
            let key = CompletionDismissalStore.hex(SHA256.hash(data: Data(material.utf8))) + "::" + CodexProgressEvidence.server
            guard let approval = try approvals.fields([key])[key] else {
                // An approval for an earlier command of the same server means
                // WorkBuddy trusted Pacer's tool before a Pacer update changed it.
                var earlier = false
                try approvals.forEachField(maximumCount: 4096) { name, _ in
                    if name != key, name.hasSuffix("::" + CodexProgressEvidence.server) { earlier = true }
                }
                return earlier ? .retrust : .needsTrust
            }
            guard approval.number() != nil else { return .unknown }
            if let policy = try readObject("mcp-tool-policy.json") {
                let fields = try policy.fields(["version", "disabledTools"])
                guard fields["version"]?.integer() == 1, let disabled = fields["disabledTools"], disabled.isObject else { return .unknown }
                if let tools = try disabled.fields([CodexProgressEvidence.server])[CodexProgressEvidence.server],
                   try tools.elements(maximumCount: 512).contains(where: { $0.matchesStringLiteral(CodexProgressEvidence.tool) }) { return .toolDisabled }
            }
            return .trusted
        } catch { return .unknown }
    }
}

private final class WorkBuddySessionStore {
    private var db: OpaquePointer?
    private static let required = Set(["id", "user_id", "status", "updated_at", "deleted_at", "transport",
        "visibility", "is_background_automation"])
    static let activityLifetime: TimeInterval = 15 * 60
    static let endingLifetime: TimeInterval = 24 * 60 * 60

    struct Row {
        let id: String
        let status: String
        let updated: Date
        let lastActivity: Date?
        let directory: String?
        let selectedModel: String?
        let thoughtLevel: String?
        /// The session's title as WorkBuddy shows it; a renamed session uses its new name.
        var title: String? = nil
        /// Started from WorkBuddy's home screen, in a folder it named by date and time.
        var playground = false
        var isRunning: Bool { ["planning", "working", "running"].contains(status) }
    }

    struct AutomationRun {
        let id: String
        let state: State
        let started: Date
        let updated: Date
        let session: Row?

        enum State: Equatable {
            case queued, running, completed, failed, interrupted

            init?(status: String, succeeded: Int?, reason: String?) {
                switch (status, succeeded) {
                case ("QUEUED", nil): self = .queued
                case ("IN_PROGRESS", nil): self = .running
                case ("ACCEPTED", 1): self = .completed
                case ("ACCEPTED", 0):
                    self = reason == "interrupted" || reason == "restart_interrupted" ? .interrupted : .failed
                default: return nil
                }
            }
        }
    }

    enum Read {
        case snapshot(sessions: [Row], runs: [AutomationRun])
        case unavailable
        case incompatible
    }

    struct UsageReading {
        var latest: HarnessUsage?
        var turnCredits: [String: Double] = [:]
    }

    init?(url: URL) {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; db = nil
            return nil
        }
        sqlite3_busy_timeout(db, 25)
        guard sqlite3_exec(db, "PRAGMA query_only=ON; PRAGMA trusted_schema=OFF", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db); db = nil; return nil
        }
    }

    deinit { if let db { sqlite3_close(db) } }

    func read(owner: String, now: Date, known: Set<String>) -> Read {
        guard let db else { return .unavailable }
        return withQueryBudget(db) {
            // Keep the owner check and row projection in the same SQLite snapshot.
            guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { return .unavailable }
            defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
            guard let schema = columns(db) else { return .unavailable }
            guard Self.required.isSubset(of: schema) else { return .incompatible }
            guard let sessions = rows(db, owner: owner, now: now, known: known, columns: schema) else { return .unavailable }
            return .snapshot(sessions: sessions, runs: automationRuns(db, owner: owner, now: now, columns: schema))
        }
    }

    private func withQueryBudget<T>(_ db: OpaquePointer, _ read: () -> T) -> T {
        var budget = QueryBudget(deadline: ProcessInfo.processInfo.systemUptime + 0.05)
        return withUnsafeMutablePointer(to: &budget) { limit in
            sqlite3_progress_handler(db, 1_000, { data in
                guard let data else { return 1 }
                let limit = data.assumingMemoryBound(to: QueryBudget.self)
                limit.pointee.steps += 1_000
                return limit.pointee.steps >= 250_000 || ProcessInfo.processInfo.systemUptime >= limit.pointee.deadline ? 1 : 0
            }, limit)
            defer { sqlite3_progress_handler(db, 0, nil, nil) }
            return read()
        }
    }

    private struct QueryBudget {
        let deadline: TimeInterval
        var steps = 0
    }

    private func columns(_ db: OpaquePointer) -> Set<String>? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(sessions)", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: if let name = Self.text(statement, 1) { names.insert(name) }
            case SQLITE_DONE: return names
            default: return nil
            }
        }
    }

    private func rows(_ db: OpaquePointer, owner: String, now: Date, known: Set<String>, columns: Set<String>) -> [Row]? {
        var statement: OpaquePointer?
        let known = known.sorted().prefix(64)
        let placeholders = (0..<known.count).map { "?\($0 + 5)" }.joined(separator: ",")
        let tracked = known.isEmpty ? "" : " UNION SELECT rowid FROM sessions WHERE id IN (" + placeholders + ")"
        let cwd = columns.contains("cwd") ? "cwd" : "NULL"
        let lastActivity = columns.contains("last_activity_at") ? "last_activity_at" : "NULL"
        let model = columns.contains("model") ? "model" : "NULL"
        let effort = columns.contains("thought_level") ? "thought_level" : "NULL"
        let title = ["custom_title", "title"].filter(columns.contains).map { "NULLIF(trim(\($0)),'')" }
        let titles = title.isEmpty ? "NULL" : title.count == 1 ? title[0] : "COALESCE(" + title.joined(separator: ",") + ")"
        let playground = columns.contains("is_playground") ? "is_playground" : "NULL"
        // WorkBuddy's recent-activity index is partial and covers cloud rows
        // only. Read a bounded set of local candidates without forcing it.
        // Already observed sessions are also looked up by primary key. The
        // desktop's New Task screen marks its default workspace as playground.
        let discovery = "SELECT rowid FROM (SELECT rowid FROM sessions ORDER BY rowid DESC LIMIT 512)"
        let sql = """
            WITH candidates AS (\(discovery)\(tracked))
            SELECT id,status,updated_at,\(cwd),\(lastActivity),\(model),\(effort),\(titles),\(playground)
            FROM candidates CROSS JOIN sessions ON sessions.rowid=candidates.rowid
            WHERE user_id=?1 AND transport='local' AND deleted_at IS NULL
              AND visibility IS NULL
              AND COALESCE(is_background_automation,0)=0
              AND updated_at<=?2 AND (
                (updated_at>=?3 AND lower(status) IN ('planning','working','running','pending'))
                OR (updated_at>=?4 AND lower(status) IN ('completed','failed','terminated'))
              )
            ORDER BY CASE lower(status) WHEN 'working' THEN 0 WHEN 'running' THEN 0 WHEN 'planning' THEN 0
                     WHEN 'pending' THEN 1 ELSE 2 END,updated_at DESC,id LIMIT 64
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let upper = Int64(now.timeIntervalSince1970 * 1000)
        guard sqlite3_bind_text(statement, 1, owner, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK,
              sqlite3_bind_int64(statement, 2, upper + 1000) == SQLITE_OK,
              sqlite3_bind_int64(statement, 3, upper - Int64(Self.activityLifetime * 1000)) == SQLITE_OK,
              sqlite3_bind_int64(statement, 4, upper - Int64(Self.endingLifetime * 1000)) == SQLITE_OK else { return nil }
        for (index, id) in known.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 5), id, -1,
                                   unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else { return nil }
        }
        var rows: [Row] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let id = Self.text(statement, 0), !id.isEmpty, let status = Self.text(statement, 1),
                      sqlite3_column_type(statement, 2) == SQLITE_INTEGER else { continue }
                let date = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 2)) / 1000)
                let activity = sqlite3_column_type(statement, 4) == SQLITE_INTEGER
                    ? Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 4)) / 1000) : nil
                rows.append(.init(id: id, status: status.lowercased(), updated: min(now, date), lastActivity: activity,
                                  directory: Self.text(statement, 3, limit: 16_384), selectedModel: Self.text(statement, 5),
                                  thoughtLevel: Self.text(statement, 6, limit: 32), title: Self.text(statement, 7, limit: 1_024),
                                  playground: sqlite3_column_int64(statement, 8) == 1))
            case SQLITE_DONE: return rows
            default: return nil
            }
        }
    }

    private func automationRuns(_ db: OpaquePointer, owner: String, now: Date, columns: Set<String>) -> [AutomationRun] {
        // WorkBuddy 5.9.4 stores execution results separately from chat state.
        // The installed app indexes status and creation date. Bound the
        // candidates before loading or decoding run metadata.
        let sql = """
            WITH recent AS (
                SELECT r.thread_id FROM automation_runs AS r JOIN automations AS a ON a.id=r.automation_id
                WHERE a.owner_user_id=?1 AND a.deleted_at IS NULL AND r.status IN ('QUEUED','IN_PROGRESS','ACCEPTED')
                  AND r.created_at>=?3 AND r.updated_at BETWEEN ?3 AND ?2
                ORDER BY CASE r.status WHEN 'IN_PROGRESS' THEN 0 WHEN 'QUEUED' THEN 1 ELSE 2 END,r.updated_at DESC,r.thread_id
                LIMIT 128
            )
            SELECT r.thread_id,r.status,r.created_at,r.updated_at,r.result_success,r.reason_code,
                   CASE WHEN length(r.metadata_json)<=16384 THEN r.metadata_json END
            FROM recent JOIN automation_runs AS r ON r.thread_id=recent.thread_id
            ORDER BY CASE r.status WHEN 'IN_PROGRESS' THEN 0 WHEN 'QUEUED' THEN 1 ELSE 2 END,r.updated_at DESC,r.thread_id
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        let upper = Int64(now.timeIntervalSince1970 * 1000)
        let copied = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, owner, -1, copied) == SQLITE_OK,
              sqlite3_bind_int64(statement, 2, upper + 1000) == SQLITE_OK,
              sqlite3_bind_int64(statement, 3, upper - Int64(Self.endingLifetime * 1000)) == SQLITE_OK else { return [] }

        // The metadata names a conversation, not the run's own ID. Recheck
        // the conversation's owner and background flag before using it.
        var sessionQuery: OpaquePointer?
        defer { sqlite3_finalize(sessionQuery) }
        var runs: [AutomationRun] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let id = Self.text(statement, 0), !id.isEmpty, let status = Self.text(statement, 1),
                      let start = Self.date(statement, 2), let end = Self.date(statement, 3),
                      start <= end else { continue }
                let resultType = sqlite3_column_type(statement, 4)
                guard resultType == SQLITE_INTEGER || resultType == SQLITE_NULL else { continue }
                let result = resultType == SQLITE_INTEGER ? Int(sqlite3_column_int64(statement, 4)) : nil
                guard let state = AutomationRun.State(status: status, succeeded: result, reason: Self.text(statement, 5)) else { continue }
                let session = automationSession(db, id: Self.automationSessionID(statement), owner: owner,
                                                columns: columns, query: &sessionQuery, now: now)
                if state == .running || state == .queued {
                    let observed = max(end, session?.updated ?? end)
                    guard now.timeIntervalSince(observed) < Self.activityLifetime else { continue }
                }
                runs.append(.init(id: id, state: state, started: min(start, now), updated: min(end, now), session: session))
                if runs.count == 64 { return runs }
            case SQLITE_DONE: return runs
            default: return []
            }
        }
    }

    private static func automationSessionID(_ statement: OpaquePointer?) -> String? {
        guard let raw = text(statement, 6, limit: 16_384),
              let metadata = try? JSONFieldView.document(Data(raw.utf8), maximumBytes: 16_384),
              let fields = try? metadata.fields(["sessionId", "conversationId"]),
              let id = fields["sessionId"]?.string(limit: 37),
              fields["conversationId"]?.string(limit: 37) == id, Foundation.UUID(uuidString: id) != nil else { return nil }
        return id
    }

    private func automationSession(_ db: OpaquePointer, id: String?, owner: String, columns: Set<String>,
                                   query: inout OpaquePointer?, now: Date) -> Row? {
        guard let id else { return nil }
        let copied = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if query == nil {
            let cwd = columns.contains("cwd") ? "cwd" : "NULL"
            let model = columns.contains("model") ? "model" : "NULL"
            let effort = columns.contains("thought_level") ? "thought_level" : "NULL"
            let sql = """
                SELECT status,updated_at,\(cwd),\(model),\(effort) FROM sessions
                WHERE id=?1 AND user_id=?2 AND transport='local' AND deleted_at IS NULL
                  AND is_background_automation=1 AND visibility IS NULL
                """
            guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK else { return nil }
        }
        defer { sqlite3_reset(query) }
        guard sqlite3_bind_text(query, 1, id, -1, copied) == SQLITE_OK,
              sqlite3_bind_text(query, 2, owner, -1, copied) == SQLITE_OK,
              sqlite3_step(query) == SQLITE_ROW, let status = Self.text(query, 0),
              let updated = Self.date(query, 1), updated <= now.addingTimeInterval(1) else { return nil }
        return .init(id: id, status: status.lowercased(), updated: min(now, updated), lastActivity: nil,
                     directory: Self.text(query, 2, limit: 16_384), selectedModel: Self.text(query, 3),
                     thoughtLevel: Self.text(query, 4, limit: 32))
    }

    private static func date(_ statement: OpaquePointer?, _ column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) == SQLITE_INTEGER else { return nil }
        let milliseconds = sqlite3_column_int64(statement, column)
        guard milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    /// Credits charged on each of the last seven local days. WorkBuddy keys each
    /// charge by its request ID, a UUIDv7 whose first 48 bits are the request
    /// time in milliseconds; a charge without one counts on its session's last update.
    /// Nil when the read failed or the query budget cut it short.
    func dailyCredits(owner: String, now: Date, calendar: Calendar = .current) -> [HarnessDailyAmount]? {
        guard let db else { return nil }
        let today = calendar.startOfDay(for: now)
        guard let first = calendar.date(byAdding: .day, value: -6, to: today) else { return nil }
        return withQueryBudget(db) {
            let sql = """
                SELECT u.updated_at,CASE WHEN length(u.credit_json)<=65536 THEN u.credit_json END
                FROM session_usage AS u JOIN sessions AS s ON s.id=u.session_id
                WHERE s.user_id=?1 AND u.updated_at>=?2
                ORDER BY u.updated_at DESC LIMIT 256
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            let copied = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard sqlite3_bind_text(statement, 1, owner, -1, copied) == SQLITE_OK,
                  sqlite3_bind_int64(statement, 2, Int64(first.timeIntervalSince1970 * 1000)) == SQLITE_OK else { return nil }
            var totals: [Date: Double] = [:]
            var step = sqlite3_step(statement)
            while step == SQLITE_ROW {
                defer { step = sqlite3_step(statement) }
                guard let updated = Self.date(statement, 0), let raw = Self.text(statement, 1, limit: 65_536),
                      let view = try? JSONFieldView.document(Data(raw.utf8), maximumBytes: 65_536) else { continue }
                try? view.forEachField(maximumCount: 2_048) { key, field in
                    guard let amount = field.number(), amount > 0, amount <= 1_000_000 else { return }
                    let at = WorkBuddyHarness.chargeTime(key) ?? updated
                    guard at >= first, at <= now.addingTimeInterval(60) else { return }
                    totals[calendar.startOfDay(for: at), default: 0] += amount
                }
            }
            guard step == SQLITE_DONE else { return nil }
            return totals.sorted { $0.key < $1.key }.map { HarnessDailyAmount(day: $0.key, amount: $0.value) }
        }
    }

    /// Read the latest session's overview and the charges for the bounded set
    /// of turns that the transcript reader could identify.
    func usage(owner: String, now: Date, latest: String?, requests: [String: String]) -> UsageReading {
        guard let db, let latest else { return UsageReading() }
        return withQueryBudget(db) {
            var result = UsageReading()
            let sql = """
                SELECT u.used,u.size,u.updated_at,CASE WHEN length(u.credit_json)<=16384 THEN u.credit_json END
                FROM session_usage AS u JOIN sessions AS s ON s.id=u.session_id
                WHERE u.session_id=?1 AND s.user_id=?2 AND s.deleted_at IS NULL
                LIMIT 1
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return result }
            defer { sqlite3_finalize(statement) }
            let copied = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard sqlite3_bind_text(statement, 2, owner, -1, copied) == SQLITE_OK else { return result }
            // Use the session primary key and reuse the statement for each lookup.
            let sessions = [latest] + requests.keys.filter { $0 != latest }
            guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { return result }
            defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
            for session in sessions {
                defer { sqlite3_reset(statement) }
                guard sqlite3_bind_text(statement, 1, session, -1, copied) == SQLITE_OK else { break }
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { continue }
                guard status == SQLITE_ROW else { break }
                guard let measured = Self.date(statement, 2), measured <= now.addingTimeInterval(1),
                      now.timeIntervalSince(measured) < Self.endingLifetime else { continue }
                let credits = Self.credits(Self.text(statement, 3, limit: 16_384), request: requests[session], includeTotal: session == latest)
                result.turnCredits[session] = credits.turn
                if session == latest {
                    let used = sqlite3_column_int64(statement, 0), capacity = sqlite3_column_int64(statement, 1)
                    let context = used > 0 && capacity > 0 && used <= capacity && capacity < 100_000_000
                        && sqlite3_column_type(statement, 0) == SQLITE_INTEGER && sqlite3_column_type(statement, 1) == SQLITE_INTEGER
                    if context || credits.total != nil {
                        result.latest = HarnessUsage(contextUsed: context ? Int(used) : nil, contextCapacity: context ? Int(capacity) : nil,
                                                     sessionCredits: credits.total, measuredAt: min(measured, now))
                    }
                }
            }
            return result
        }
    }

    private static func credits(_ raw: String?, request: String?, includeTotal: Bool) -> (turn: Double?, total: Double?) {
        guard let raw, let view = try? JSONFieldView.document(Data(raw.utf8), maximumBytes: 16_384) else { return (nil, nil) }
        // WorkBuddy accumulates charges in this object by conversation request ID.
        var total: Double? = includeTotal ? 0 : nil
        var turn: Double?
        do {
            try view.forEachField(maximumCount: 512) { key, field in
                guard total != nil || key == request else { return }
                guard let number = field.number(), (0...1_000_000).contains(number) else {
                    if key == request { turn = nil }
                    total = nil
                    return
                }
                if key == request { turn = number }
                if let subtotal = total { total = subtotal + number }
            }
        } catch { return (nil, nil) }
        return (turn, total)
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32, limit: Int = 256) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let bytes = sqlite3_column_text(statement, column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count <= limit else { return nil }
        let buffer = UnsafeBufferPointer(start: bytes, count: count)
        guard !buffer.contains(0) else { return nil }
        return String(bytes: buffer, encoding: .utf8)
    }
}

actor WorkBuddyMonitor: LocalHarnessMonitor {
    private let io: LocalHarnessIO
    private var home: URL?
    private var generation: UInt64 = 0
    private var readRevision: UInt64 = 0
    private var policy = ActivityRefreshPolicy.collapsed
    private var watcher: ActivityLogWatcher?
    private var watchURLs: [URL] = []
    private var retry: Task<Void, Never>?
    private var retryDeadline: TimeInterval?
    private var retryRevision: UInt64 = 0
    // WorkBuddy appends to a running task's transcript through a stream it
    // keeps open, and Windows reports no change for such writes until the file
    // closes (seen 11/15: none within 8 s; 0.06 s for open, append, close). While
    // a task runs, the monitor compares its files' sizes and times every second
    // instead, which costs a few metadata reads, and reads them when they change.
    private var probe: Task<Void, Never>?
    private var probedFiles: [String] = []
    // What each task does now, from WorkBuddy's agent logs; see WorkBuddyRunLog.
    private var runLog = WorkBuddyRunLog()
    private var publish: (@Sendable (HarnessActivity) async -> Void)?
    private var lastObservation: HarnessActivity?
    private var owner: String?
    private var transcripts: [String: WorkBuddyTranscript] = [:]
    private var witnessed: [String: String] = [:]
    private var witnessedRuns: Set<String> = []
    private var started: Date?
    private var lastSuccess: Date?
    private var catchUpUntil: Date?
    private var failureCount = 0
    private var accountRetries = 0
    private var dailyCredits: [HarnessDailyAmount]?
    private var dailyCharged: Date?
    private var dailyReadAt: Date?

    private let edition: WorkBuddyHarness.Edition
    private nonisolated var id: AgentProvider { WorkBuddyHarness.id(edition) }
    private nonisolated var definition: LocalHarnessDefinition { WorkBuddyHarness.definition(for: edition) }

    init(io: LocalHarnessIO, edition: WorkBuddyHarness.Edition) { self.io = io; self.edition = edition }

    func start(home: URL, policy: ActivityRefreshPolicy, publish: @escaping @Sendable (HarnessActivity) async -> Void) async {
        _ = reset()
        self.home = home; self.policy = policy; self.publish = publish; started = io.now()
        let current = generation
        watcher = ActivityLogWatcher(files: io.files, events: io.events, interval: policy.interval,
            maximumDirectoryWatches: 4, fileExtensions: nil) { [weak self] _ in
            Task { await self?.refresh(ifCurrent: current) }
        }
        await refresh()
    }

    func updatePolicy(_ policy: ActivityRefreshPolicy) {
        self.policy = policy
        watcher?.update(watchURLs, interval: policy.interval, flushPending: policy == .expanded)
    }

    func stop() async {
        let oldWatcher = reset()
        _ = await oldWatcher?.activeWatchCount()
    }

    private func reset() -> ActivityLogWatcher? {
        generation &+= 1; home = nil; publish = nil
        cancelRetry()
        probe?.cancel(); probe = nil; probedFiles = []
        let oldWatcher = watcher
        oldWatcher?.stop(); watcher = nil; watchURLs = []
        lastObservation = nil; lastSuccess = nil; failureCount = 0; accountRetries = 0
        dailyCredits = nil; dailyCharged = nil; dailyReadAt = nil
        catchUpUntil = nil
        owner = nil; transcripts.removeAll(); witnessed.removeAll(); witnessedRuns.removeAll(); started = nil
        runLog = WorkBuddyRunLog()
        return oldWatcher
    }

    func refresh() async {
        guard let home, let publish, let watcher else { return }
        readRevision &+= 1
        let current = generation, revision = readRevision
        let db = home.appendingPathComponent(definition.dataFile)
        let wal = home.appendingPathComponent(db.lastPathComponent + "-wal")
        let shm = home.appendingPathComponent(db.lastPathComponent + "-shm")
        let accountDirectory = home.appendingPathComponent("storage/skeleton", isDirectory: true)
        let account = accountDirectory.appendingPathComponent("account-snapshot.json")
        let baseWatches = io.files.metadata(home)?.isDirectory == true
            ? [home, db, wal, accountDirectory, account] : [home.deletingLastPathComponent()]
        // Keep existing transcript watches during the read. Removing and
        // reopening them here loses writes in the gap and allocates new handles.
        if watchURLs.isEmpty { watcher.update(baseWatches, interval: policy.interval) }
        let watchCount = await watcher.activeWatchCount()
        guard current == generation, revision == readRevision else { return }
        watchURLs = baseWatches
        let now = io.now()
        var observation = HarnessActivity(status: .missing)
        let selectedOwner = verifiedOwner(in: home, account: account)
        // WorkBuddy rewrites its account file in place. While the file is still
        // there, an unreadable copy is a write in progress, not a sign-out.
        if selectedOwner == nil, owner != nil, accountRetries < 4, io.files.metadata(account)?.isRegularFile == true {
            accountRetries += 1
            scheduleRetry(after: 1)
            return
        }
        accountRetries = 0
        if owner != selectedOwner {
            owner = selectedOwner
            transcripts.removeAll()
            witnessed.removeAll()
            witnessedRuns.removeAll()
            lastSuccess = nil
            catchUpUntil = nil
            dailyCredits = nil; dailyCharged = nil
            started = now
        }
        if let owner {
            observation.scope = CompletionDismissalStore.digest(["workbuddy-owner", owner])
        }
        if io.files.metadata(home)?.isDirectory == true, io.files.metadata(db)?.isRegularFile == true {
            observation.status = .unavailable
            // Require WorkBuddy's sidecars; don't open a live WAL as immutable.
            let sidecarsExist = io.files.metadata(wal)?.isRegularFile == true && io.files.metadata(shm)?.isRegularFile == true
            if sidecarsExist, let owner, let store = WorkBuddySessionStore(url: db) {
                runLog.read(home: home, files: io.files, now: now, within: WorkBuddySessionStore.activityLifetime)
                switch store.read(owner: owner, now: now, known: Set(witnessed.keys)) {
                case .snapshot(let sessions, let runs):
                    if verifiedOwner(in: home, account: account) == owner {
                        project(sessions, runs: runs, store: store, owner: owner, home: home, now: now, into: &observation)
                        observation.status = .ready
                        lastSuccess = now
                    }
                case .unavailable:
                    // A busy database misses one read; tasks waiting on the user
                    // and their requests stay too, or they vanish and come back
                    // with a second alert (11/16 review).
                    if let lastSuccess, now.timeIntervalSince(lastSuccess) < 15,
                       let old = lastObservation, old.scope == observation.scope {
                        observation.activities = old.activities.filter {
                            [.running, .waitingForInput].contains($0.phase)
                                && now.timeIntervalSince($0.lastObserved ?? .distantPast) < WorkBuddySessionStore.activityLifetime
                        }
                        let kept = Set(observation.activities.compactMap(\.threadID))
                        observation.requests = old.requests.filter { kept.contains($0.threadID) }
                    }
                case .incompatible: observation.status = .incompatible
                }
            }
        }
        watcher.update(watchURLs, interval: policy.interval)
        probedFiles = fileStamps()
        if observation.status == .ready, observation.activities.contains(where: { $0.phase == .running || $0.phase == .waitingForInput }) {
            startProbe()
        } else { probe?.cancel(); probe = nil }
        if observation.status == .ready { failureCount = 0 }
        else { failureCount = min(4, failureCount + 1) }
        if observation.status == .ready {
            if catchUpUntil.map({ $0 > now }) == true {
                scheduleRetry(after: policy == .expanded ? 1 : 3)
            } else if observation.activities.contains(where: { $0.phase == .running || $0.phase == .waitingForInput }) || watchCount < 5 {
                scheduleRetry(after: 15)
            } else { cancelRetry() }
        } else {
            scheduleRetry(after: observation.activities.isEmpty ? min(300, 15 << failureCount) : 5)
        }
        guard lastObservation != observation else { return }
        lastObservation = observation
        await publish(observation)
    }

    private func verifiedOwner(in home: URL, account: URL) -> String? {
        guard io.files.metadata(home)?.isDirectory == true,
              io.files.metadata(home.appendingPathComponent("storage"))?.isDirectory == true,
              io.files.metadata(account.deletingLastPathComponent())?.isDirectory == true,
              let info = io.files.metadata(account), info.isRegularFile, info.size <= 16_384,
              let bytes = try? io.files.read(account, offset: 0, maximumBytes: 16_385),
              let document = try? JSONFieldView.document(bytes, maximumBytes: 16_384),
              let fields = try? document.fields(["primary"]),
              let primary = try? fields["primary"]?.fields(["uid", "version"]),
              primary["version"]?.integer() == 1,
              let id = primary["uid"]?.string(limit: 37),
              Foundation.UUID(uuidString: id) != nil else { return nil }
        return id
    }

    private func project(_ rows: [WorkBuddySessionStore.Row], runs: [WorkBuddySessionStore.AutomationRun], store: WorkBuddySessionStore,
                         owner: String, home: URL, now: Date, into observation: inout HarnessActivity) {
        let linkedRows = runs.compactMap(\.session)
        let currentIDs = Set(rows.map(\.id) + linkedRows.map(\.id))
        transcripts = transcripts.filter { currentIDs.contains($0.key) }
        witnessed = witnessed.filter { currentIDs.contains($0.key) }
        witnessedRuns.formIntersection(runs.map(\.id))
        let canNavigate = home.standardizedFileURL == definition.defaultHome().standardizedFileURL
        let allRows = rows + linkedRows
        let candidates = linkedRows.isEmpty ? rows : allRows.sorted {
            let left = $0.isRunning || $0.status == "pending", right = $1.isRunning || $1.status == "pending"
            return left == right ? $0.updated > $1.updated : left
        }
        let turns = readTurns(candidates, home: home, now: now)
        let latest = allRows.max { $0.updated < $1.updated }?.id
        let usage = store.usage(owner: owner, now: now, latest: latest, requests: turns.mapValues(\.id))
        observation.usage = usage.latest
        // The week's credits change only when a charge lands; read them at most every five minutes otherwise.
        let charged = usage.latest?.measuredAt
        if dailyCredits == nil || charged != dailyCharged || now.timeIntervalSince(dailyReadAt ?? .distantPast) >= 300 {
            // A read the query budget cut short is tried again next time, not kept empty for five minutes.
            if let daily = store.dailyCredits(owner: owner, now: now) { dailyCredits = daily; dailyCharged = charged; dailyReadAt = now }
        }
        if let daily = dailyCredits, !daily.isEmpty {
            var value = observation.usage ?? HarnessUsage(contextUsed: nil, contextCapacity: nil, sessionCredits: nil, measuredAt: dailyReadAt ?? now)
            value.daily = daily
            observation.usage = value
        }
        for row in rows {
            let age = now.timeIntervalSince(row.updated)
            let running = row.isRunning && age < WorkBuddySessionStore.activityLifetime
            let current = turns[row.id].flatMap { $0.started <= row.updated.addingTimeInterval(1) ? $0 : nil }
            let stage = liveStage(row.id, turn: current, since: current?.started ?? now.addingTimeInterval(-WorkBuddySessionStore.activityLifetime),
                                  planning: row.status == "planning")
            let session = CompletionDismissalStore.digest(["workbuddy-session", owner, row.id])
            var task = SessionActivity.observedSession(provider: id, session: session, stage: stage, at: row.updated)
            // A task from WorkBuddy's home screen sits in a folder named by date and
            // time; its notices name the module, not "2026-11-15-22-05-19".
            task.applyObservedTitle(row.title, project: row.playground ? nil : row.directory.map { URL(fileURLWithPath: $0).lastPathComponent })
            if let turn = current {
                let turnID = CompletionDismissalStore.digest(["workbuddy-turn", session, turn.id])
                let live = turn.started >= (started ?? now) || witnessed[row.id] == turn.id
                let state: SessionActivity.ObservedTurnState
                let changedAt: Date
                if running {
                    witnessed[row.id] = turn.id
                    state = .working(stage)
                    changedAt = row.updated
                } else if row.status == "pending", age < WorkBuddySessionStore.activityLifetime,
                          let awaiting = turn.awaiting, awaiting.call.time <= row.updated.addingTimeInterval(1) {
                    // A question, or a tool waiting on the user's go-ahead.
                    witnessed[row.id] = turn.id
                    state = .waiting(awaiting.kind)
                    changedAt = awaiting.call.time
                    observation.requests.append(request(awaiting, session: session, turn: turnID))
                } else if let ending = turn.ending, let ended = turn.ended,
                          [row.updated, row.lastActivity].compactMap({ $0 }).contains(where: { abs($0.timeIntervalSince(ended)) <= 3 }),
                          let terminal = terminalState(status: row.status, ending: ending) {
                    state = terminal
                    changedAt = min(now, ended)
                } else {
                    if age < 5 { catchUpUntil = max(catchUpUntil ?? .distantPast, row.updated.addingTimeInterval(5)) }
                    continue
                }
                task.applyObservedTurn(state, id: turnID, started: turn.started, at: changedAt, live: live,
                                       model: turn.model?.displayName, effort: turn.effort)
                turn.applyMeasurements(to: &task, turnID: turnID, credits: usage.turnCredits[row.id])
            } else if !running {
                if age < 5 { catchUpUntil = max(catchUpUntil ?? .distantPast, row.updated.addingTimeInterval(5)) }
                continue
            }
            observation.activities.append(task)
            if canNavigate, age < WorkBuddySessionStore.endingLifetime, let url = conversationURL(row.id) {
                observation.conversationURLs[task.id] = url
            }
        }
        for run in runs {
            let session = CompletionDismissalStore.digest(["workbuddy-automation-run", owner, run.id])
            let turnID = session
            let live = run.started >= (started ?? now) || witnessedRuns.contains(run.id)
            let linked = run.session
            let observedAt = max(run.updated, linked?.updated ?? run.updated)
            let turn = linked.flatMap { turns[$0.id] }.flatMap { turn in
                (run.started.addingTimeInterval(-1)...observedAt.addingTimeInterval(1)).contains(turn.started) ? turn : nil
            }
            let state: SessionActivity.ObservedTurnState
            let changedAt: Date
            switch run.state {
            case .queued:
                witnessedRuns.insert(run.id)
                state = .working(.starting); changedAt = run.updated
            case .running:
                witnessedRuns.insert(run.id)
                if linked?.status == "pending", let awaiting = turn?.awaiting, awaiting.call.time <= observedAt.addingTimeInterval(1) {
                    state = .waiting(awaiting.kind); changedAt = awaiting.call.time
                    observation.requests.append(request(awaiting, session: session, turn: turnID))
                } else {
                    state = .working(liveStage(linked?.id, turn: turn, since: run.started, planning: false))
                    changedAt = observedAt
                }
            case .completed:
                state = .finished; changedAt = run.updated
            case .failed, .interrupted:
                state = .interrupted(failed: run.state == .failed); changedAt = run.updated
            }
            var task = SessionActivity.observedSession(provider: id, session: session, stage: .starting, at: changedAt)
            task.applyObservedTurn(state, id: turnID, started: run.started, at: min(now, changedAt), live: live,
                                   model: turn?.model?.displayName, effort: turn?.effort)
            turn?.applyMeasurements(to: &task, turnID: turnID, credits: linked.flatMap { usage.turnCredits[$0.id] }, notBefore: run.started)
            observation.activities.append(task)
            if canNavigate, let url = linked.flatMap({ conversationURL($0.id) }) { observation.conversationURLs[task.id] = url }
        }
    }

    private func readTurns(_ rows: [WorkBuddySessionStore.Row], home: URL, now: Date) -> [String: WorkBuddyTranscript.Turn] {
        var turns: [String: WorkBuddyTranscript.Turn] = [:]
        var watched = Set<String>()
        for row in rows {
            if watched.count == 32 { break }
            guard !watched.contains(row.id), let transcript = transcriptURL(row, home: home) else { continue }
            watched.insert(row.id)
            watchURLs.append(transcript)
            do {
                try transcripts[row.id, default: WorkBuddyTranscript()].read(transcript, session: row.id, files: io.files, now: now)
                transcripts[row.id]?.observeThoughtLevel(row.thoughtLevel, selectedModel: row.selectedModel, updated: row.updated)
                turns[row.id] = transcripts[row.id]?.turn
            } catch {
                transcripts.removeValue(forKey: row.id)
                witnessed.removeValue(forKey: row.id)
            }
        }
        return turns
    }

    private nonisolated func request(_ awaiting: (kind: PendingAttentionRequest.Kind, call: WorkBuddyTranscript.Question),
                                     session: String, turn: String) -> PendingAttentionRequest {
        .init(id: CompletionDismissalStore.digest([awaiting.kind == .input ? "workbuddy-question" : "workbuddy-approval", turn, awaiting.call.call]),
              threadID: session, sourceHostID: nil, sourceName: id.displayName, kind: awaiting.kind, detectedAt: awaiting.call.time, provider: id)
    }

    private nonisolated func conversationURL(_ id: String) -> URL? {
        guard let uuid = Foundation.UUID(uuidString: id), let scheme = definition.conversationScheme else { return nil }
        return URL(string: scheme + "://chat/" + uuid.uuidString.lowercased())
    }

    /// What a running task does now, like other modules' tasks: starting,
    /// thinking or running a tool. WorkBuddy's agent log says so as it
    /// happens. Without it, an open tool call in the transcript means a tool,
    /// and otherwise the request is with the model, which may think for
    /// minutes before its first step. A local task is never shown as a cloud
    /// poll's "working".
    private func liveStage(_ session: String?, turn: WorkBuddyTranscript.Turn?, since: Date, planning: Bool) -> ActivityStage {
        if let session, let live = runLog.sessions[session.lowercased()], live.at >= since.addingTimeInterval(-2) {
            switch live.stage {
            case .starting: return .starting
            case .model: return .thinking
            case .tool, .permission: return .tool
            case .ended: break
            }
        }
        if turn?.calls.isEmpty == false { return .tool }
        return planning && turn?.response == nil ? .starting : .thinking
    }

    private func terminalState(status: String, ending: WorkBuddyTranscript.Turn.Ending) -> SessionActivity.ObservedTurnState? {
        switch (status, ending) {
        case ("completed", .reply): .finished
        case ("completed", .cancelled), ("terminated", .cancelled): .interrupted(failed: false)
        case ("failed", .failed): .interrupted(failed: true)
        default: nil
        }
    }

    private func transcriptURL(_ row: WorkBuddySessionStore.Row, home: URL) -> URL? {
        guard let directory = row.directory, Foundation.UUID(uuidString: row.id) != nil else { return nil }
        let segment = directory.replacingOccurrences(of: #"[/\\:]+"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !segment.isEmpty, segment != ".", segment != "..",
              !segment.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let workspace: String
        if segment.utf8.count <= 255 { workspace = segment }
        else {
            var prefix = "", count = 0
            for scalar in segment.unicodeScalars {
                let text = String(scalar)
                count += text.utf8.count
                if count > 180 { break }
                prefix += text
            }
            let hash = segment.utf8.reduce(UInt32(5381)) { ($0 &* 33) ^ UInt32($1) }
            workspace = prefix + "-" + String(hash, radix: 36)
        }
        let projects = home.appendingPathComponent("projects", isDirectory: true)
        let parent = projects.appendingPathComponent(workspace, isDirectory: true)
        guard io.files.metadata(projects)?.isDirectory == true, io.files.metadata(parent)?.isDirectory == true else { return nil }
        return parent.appendingPathComponent(row.id + ".jsonl")
    }

    /// The size and time of each watched file, in order.
    private func fileStamps() -> [String] {
        watchURLs.compactMap { url in
            guard let metadata = io.files.metadata(url), metadata.isRegularFile else { return nil }
            return "\(metadata.size):\(metadata.modified.timeIntervalSince1970)"
        }
    }

    private func startProbe() {
        guard probe == nil else { return }
        let current = generation
        probe = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self, await self.probeChanged(current) else { continue }
                await self.refresh(ifCurrent: current)
            }
        }
    }

    private func probeChanged(_ current: UInt64) -> Bool {
        guard current == generation, probe != nil else { return false }
        // The agent logs grow all the time; only a new stage asks for a read.
        let staged = home.map { runLog.read(home: $0, files: io.files, now: io.now(), within: WorkBuddySessionStore.activityLifetime) } ?? false
        let stamps = fileStamps()
        guard stamps != probedFiles else { return staged }
        probedFiles = stamps
        return true
    }

    private func scheduleRetry(after seconds: UInt64) {
        let deadline = ProcessInfo.processInfo.systemUptime + Double(seconds)
        if let retryDeadline, retryDeadline <= deadline { return }
        cancelRetry(); retryDeadline = deadline
        let current = generation, revision = retryRevision
        retry = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
            await self?.retryIfCurrent(current, revision: revision)
        }
    }

    private func cancelRetry() {
        retry?.cancel(); retry = nil; retryDeadline = nil; retryRevision &+= 1
    }

    private func retryIfCurrent(_ generation: UInt64, revision: UInt64) async {
        guard generation == self.generation, revision == retryRevision, !Task.isCancelled else { return }
        retry = nil; retryDeadline = nil
        await refresh()
    }

    private func refresh(ifCurrent generation: UInt64) async {
        guard generation == self.generation else { return }
        await refresh()
    }
}
