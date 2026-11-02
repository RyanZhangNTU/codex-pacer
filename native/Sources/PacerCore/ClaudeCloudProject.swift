import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A Claude Project is a cloud channel. Its threads run on cloud sessions, and
/// one coordinator session answers the project's main conversation and routes
/// work between threads. Only the fields below survive decoding: message
/// bodies, previews, attachments, members and tool input never leave the decoder.
public enum ClaudeCloudThreadStatus: String, Equatable, Sendable {
    case working, needsInput = "needs_input", failed, resolved, idle, archived
    /// Claude's web client reads an unknown value as idle, which ends no turn by itself.
    init(wire: Any?) {
        let name = (wire as? String)?.lowercased().replacingOccurrences(of: "thread_status_", with: "") ?? ""
        self = Self(rawValue: name) ?? .idle
    }
}

public struct ClaudeCloudProject: Equatable, Sendable {
    public let id: String
    public let name: String
    public let coordinatorSessionID: String?
    public let lastActivityAt: Date?
    public init(id: String, name: String, coordinatorSessionID: String? = nil, lastActivityAt: Date? = nil) {
        self.id = id; self.name = name; self.coordinatorSessionID = coordinatorSessionID; self.lastActivityAt = lastActivityAt
    }
}

public struct ClaudeCloudThread: Equatable, Sendable {
    public let id: String
    public let projectID: String
    public let status: ClaudeCloudThreadStatus
    public let isWorking: Bool
    public let hasUnread: Bool
    public let lastReplyAt: Date?
    public let title: String?
    public let sessionIDs: [String]
    public let openDecisions: Int
    /// Bound sessions the thread row itself reports as working.
    public let workingSessions: Int
    public let replyCount: Int
    public let createdAt: Date?
    public init(id: String, projectID: String, status: ClaudeCloudThreadStatus, isWorking: Bool = false, hasUnread: Bool = false,
                lastReplyAt: Date? = nil, title: String? = nil, sessionIDs: [String] = [], openDecisions: Int = 0, workingSessions: Int = 0,
                replyCount: Int = 0, createdAt: Date? = nil) {
        self.id = id; self.projectID = projectID; self.status = status; self.isWorking = isWorking; self.hasUnread = hasUnread
        self.lastReplyAt = lastReplyAt; self.title = title; self.sessionIDs = sessionIDs; self.openDecisions = openDecisions
        self.workingSessions = workingSessions; self.replyCount = replyCount; self.createdAt = createdAt
    }
    var isActive: Bool { isWorking || status == .working }
    /// Changes when the thread moves, not when it is read.
    var signature: String { "\(status.rawValue)|\(replyCount)|\(lastReplyAt?.timeIntervalSince1970 ?? 0)" }
}

public struct ClaudeCloudSession: Equatable, Sendable {
    public enum Worker: String, Equatable, Sendable { case running, idle, requiresAction = "requires_action", unknown }
    /// The server's word for a session's state and for how its last turn ended.
    public enum Category: String, Equatable, Sendable {
        case working, reviewReady = "review_ready", completed, failed, blocked, needInput = "need_input", waiting, other
        init?(wire: Any?) {
            guard let text = wire as? String else { return nil }
            self = Self(rawValue: text.lowercased()) ?? .other
        }
    }
    public let id: String
    public let worker: Worker
    /// `working` also covers a long tool call, during which the worker and the thread row both read idle.
    public let bucket: Category?
    /// How the last turn ended, when the server has summarized one.
    public let turnCategory: Category?
    public let isConnected: Bool
    public let isEnded: Bool
    public let isFailed: Bool
    public let hasUnread: Bool
    public let lastEventAt: Date?
    public let modelName: String?
    public let effort: String?
    /// Only whether Claude asked a question or wants approval; tool names and input are not kept.
    public let pending: PendingAttentionRequest.Kind?
    public init(id: String, worker: Worker, bucket: Category? = nil, turnCategory: Category? = nil, isConnected: Bool = true, isEnded: Bool = false,
                isFailed: Bool = false, hasUnread: Bool = false, lastEventAt: Date? = nil, modelName: String? = nil, effort: String? = nil,
                pending: PendingAttentionRequest.Kind? = nil) {
        self.id = id; self.worker = worker; self.bucket = bucket; self.turnCategory = turnCategory; self.isConnected = isConnected
        self.isEnded = isEnded; self.isFailed = isFailed; self.hasUnread = hasUnread; self.lastEventAt = lastEventAt
        self.modelName = modelName; self.effort = effort; self.pending = pending
    }
    /// A session reported as running on a dropped connection is not doing anything.
    var isRunning: Bool { (worker == .running || bucket == .working) && isConnected && !isEnded }
    /// Claude's web client reads a stopped turn the same way: without a summary, or with one of these, it asks for the user.
    var awaitsReply: Bool {
        guard let turnCategory else { return true }
        return [.blocked, .needInput, .waiting].contains(turnCategory)
    }
}

/// What a finished turn reports about its own speed.
public struct ClaudeCloudTurnResult: Equatable, Sendable {
    public let id: String
    public let completedAt: Date
    public let outputTokens: Int
    /// Time spent generating, without tool calls or the wait for first output.
    public let streaming: TimeInterval
    public let firstOutput: TimeInterval?
    public init(id: String, completedAt: Date, outputTokens: Int, streaming: TimeInterval, firstOutput: TimeInterval? = nil) {
        self.id = id; self.completedAt = completedAt; self.outputTokens = outputTokens; self.streaming = streaming; self.firstOutput = firstOutput
    }
}

/// How a cloud task relates to its project; a row needs it to open and to word its state.
public struct ClaudeCloudContext: Equatable, Sendable {
    public enum Role: Equatable, Sendable { case thread, coordinator }
    public let projectID: String
    public let projectName: String
    public let role: Role
    public let status: ClaudeCloudThreadStatus?
    /// Sessions working in this thread beyond the first.
    public let additionalWorkers: Int
    /// The ending has been read in Claude, so Pacer has nothing left to remind about.
    public let readInClaude: Bool
    /// The turn stopped without finishing, so the next move is the user's.
    public let awaitsReply: Bool
    /// The server's latest reply marker for this ending. It can advance while
    /// an idle ending settles into resolved, without starting another turn.
    public let completionMark: Date?
    public init(projectID: String, projectName: String, role: Role, status: ClaudeCloudThreadStatus? = nil,
                additionalWorkers: Int = 0, readInClaude: Bool = false, awaitsReply: Bool = false, completionMark: Date? = nil) {
        self.projectID = projectID; self.projectName = projectName; self.role = role; self.status = status
        self.additionalWorkers = additionalWorkers; self.readInClaude = readInClaude; self.awaitsReply = awaitsReply
        self.completionMark = completionMark
    }

    /// Opens the project, and the thread when the row is one. A browser needs
    /// the same path on claude.ai.
    func url(session: String?, web: Bool) -> URL? {
        var url = URLComponents()
        url.scheme = web ? "https" : "claude"; url.host = web ? "claude.ai" : "code"
        url.path = (web ? "/code" : "") + "/project/" + projectID
        if role == .thread, let session { url.queryItems = [URLQueryItem(name: "thread", value: session)] }
        return url.url
    }
}

enum ClaudeCloudDecoder {
    private static func identifier(_ value: Any?, _ pattern: String) -> String? {
        guard let text = value as? String, text.utf8.count <= 128,
              text.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return text
    }
    static func projectID(_ value: Any?) -> String? { identifier(value, #"^chan_\w{6,120}\z"#) }
    /// Pending client-side messages are not threads yet.
    static func threadID(_ value: Any?) -> String? {
        guard let id = identifier(value, #"^(?:cmsg|session|ses|cse)_\w{6,120}\z"#), !id.hasPrefix("cmsg_pending_") else { return nil }
        return id
    }
    static func sessionID(_ value: Any?) -> String? { identifier(value, #"^(?:cse|session)_\w{6,120}\z"#) }

    private static func label(_ value: Any?, limit: Int) -> String? {
        guard let text = value as? String else { return nil }
        let cleaned = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(limit))
    }
    private static func date(_ value: Any?) -> Date? { (value as? String).flatMap(SessionActivity.parseDate) }
    /// Counts arrive as strings.
    private static func count(_ value: Any?) -> Int { (value as? Int) ?? (value as? String).flatMap { Int($0) } ?? 0 }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClaudeCloudFailure.invalidReply }
        return value
    }

    /// Archived and plan-disabled projects cannot run anything.
    static func projects(_ data: Data) throws -> [ClaudeCloudProject] {
        let reply = try object(data)
        guard let rows = (reply["channels"] ?? reply["data"]) as? [[String: Any]] else { throw ClaudeCloudFailure.invalidReply }
        return rows.compactMap { row in
            guard let id = projectID(row["id"]), !(row["archived_at"] is String), !(row["disabled_at"] is String),
                  row["disabled_by_plan"] as? Bool != true else { return nil }
            let activity = [date(row["last_message_at"]), date(row["updated_at"])].compactMap { $0 }.max()
            return ClaudeCloudProject(id: id, name: label(row["name"], limit: 80) ?? L10n.text("claude.cloud.project"),
                coordinatorSessionID: sessionID(row["overview_session_id"]) ?? sessionID(row["channel_session_id"]), lastActivityAt: activity)
        }
    }

    static func threads(_ data: Data, projectID: String) throws -> [ClaudeCloudThread] {
        guard let sections = try object(data)["sections"] as? [[String: Any]] else { throw ClaudeCloudFailure.invalidReply }
        var seen = Set<String>()
        return sections.flatMap { section -> [ClaudeCloudThread] in
            ((section["data"] as? [[String: Any]]) ?? []).compactMap { row in
                guard let id = threadID(row["thread_root_id"] ?? row["id"]), seen.insert(id).inserted else { return nil }
                let bound = (row["bound_sessions"] as? [[String: Any]]) ?? []
                return ClaudeCloudThread(id: id, projectID: projectID, status: ClaudeCloudThreadStatus(wire: row["thread_status"] ?? section["status"]),
                    isWorking: row["thread_any_session_working"] as? Bool == true, hasUnread: row["has_unread"] as? Bool == true,
                    lastReplyAt: date(row["last_reply_at"]) ?? date(row["created_at"]),
                    title: bound.lazy.compactMap { label($0["title"], limit: 120) }.first,
                    sessionIDs: bound.compactMap { sessionID($0["id"]) }, openDecisions: (row["open_decisions"] as? [Any])?.count ?? 0,
                    workingSessions: bound.filter { $0["status_bucket"] as? String == "working" }.count,
                    replyCount: count(row["reply_count"]), createdAt: date(row["created_at"]))
            }
        }
    }

    /// The newest turn's numbers, from a page of events that also holds message
    /// text. `duration_api_ms` adds up across a session's turns, so it says
    /// nothing about this one. A coordinator's result has no streaming time.
    static func turnResult(_ data: Data) throws -> ClaudeCloudTurnResult? {
        guard let rows = try object(data)["data"] as? [[String: Any]] else { throw ClaudeCloudFailure.invalidReply }
        guard let row = rows.filter({ $0["event_type"] as? String == "result" }).max(by: { count($0["sequence_num"]) < count($1["sequence_num"]) }),
              let payload = row["payload"] as? [String: Any], let at = date(row["created_at"]),
              let id = label(row["event_id"], limit: 128) ?? label(payload["uuid"], limit: 128),
              let streaming = (payload["process_wall_ms_streaming"] as? Double).map({ $0 / 1000 }), streaming.isFinite, streaming > 0 else { return nil }
        let tokens = count((payload["usage"] as? [String: Any])?["output_tokens"])
        guard tokens > 0, Double(tokens) / streaming <= maximumRate else { return nil }
        let first = (payload["ttft_ms"] as? Double).map { $0 / 1000 }
        return ClaudeCloudTurnResult(id: id, completedAt: at, outputTokens: tokens, streaming: streaming,
            firstOutput: first.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
    }
    /// Faster than any model runs, so the numbers cannot belong together.
    static let maximumRate = 5000.0

    static func session(_ data: Data) throws -> ClaudeCloudSession {
        let reply = try object(data)
        let row = (reply["session"] as? [String: Any]) ?? (reply["response_shape"] as? [String: Any]) ?? reply
        guard let id = sessionID(row["id"]) else { throw ClaudeCloudFailure.invalidReply }
        let metadata = row["external_metadata"] as? [String: Any], config = row["config"] as? [String: Any]
        let worker = ClaudeCloudSession.Worker(rawValue: ((row["worker_status"] as? String) ?? "").lowercased()
            .replacingOccurrences(of: "worker_status_", with: "")) ?? .unknown
        let status = (row["status"] as? String)?.lowercased().replacingOccurrences(of: "session_status_", with: "")
        var requests = (row["requires_action_details_list"] as? [[String: Any]]) ?? []
        for value in [row["requires_action_details"], metadata?["pending_action"]] { if let value = value as? [String: Any] { requests.append(value) } }
        let pending: PendingAttentionRequest.Kind?
        if requests.contains(where: { $0["tool_name"] as? String == "AskUserQuestion" }) { pending = .input }
        else { pending = requests.isEmpty && worker != .requiresAction ? nil : .approval }
        let bucket = ClaudeCloudSession.Category(wire: row["status_bucket"])
        let summary = metadata?["post_turn_summary"] as? [String: Any]
        return ClaudeCloudSession(id: id, worker: worker, bucket: bucket, turnCategory: ClaudeCloudSession.Category(wire: summary?["status_category"]),
            isConnected: row["connection_status"] as? String != "disconnected", isEnded: status == "archived" || status == "failed",
            isFailed: status == "failed" || bucket == .failed, hasUnread: row["unread"] as? Bool == true,
            lastEventAt: date(row["last_event_at"]),
            modelName: ModelDisplay.sanitizedModel(metadata?["last_served_model"] ?? metadata?["model"] ?? config?["model"]),
            effort: ModelDisplay.sanitizedEffort(metadata?["effort_level"] ?? config?["effort_level"]), pending: pending)
    }
}

public enum ClaudeCloudFailure: Error, Equatable {
    case signedOut, denied, challenge, notEnabled, throttled(Date?), connection, invalidReply

    /// Nil when the reply can be read.
    public init?(response: HTTPURLResponse, at date: Date) {
        guard response.url?.scheme == "https", response.url?.host == "claude.ai" else { self = .invalidReply; return }
        switch response.statusCode {
        case 200: return nil
        case 401: self = .signedOut
        case 403: self = .denied
        case 404, 501: self = .notEnabled
        case 429: self = .throttled(ClaudeQuotaClient.retryDate(response.value(forHTTPHeaderField: "Retry-After"), now: date))
        case 400: self = .invalidReply
        default: self = .connection
        }
    }
    /// A stream's body cannot be read for a challenge page, but its type gives one away.
    public init?(streamResponse response: HTTPURLResponse, at date: Date) {
        if let failure = Self(response: response, at: date) { self = failure; return }
        guard response.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/event-stream") != true else { return nil }
        self = .challenge
    }
}
