import Foundation

/// Only routing and request kind are retained. Questions, answers, commands and
/// permission details remain in Codex; an async question does not pause a turn.
public struct PendingAttentionRequest: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case input, approval }
    public let id: String
    public let provider: AgentProvider
    public let threadID: String
    public let sourceHostID: String?
    public let sourceName: String?
    public let kind: Kind
    public let detectedAt: Date
    /// Hashed thread/turn/call identity shared by local Codex async-question sources.
    public let questionKey: String?
    public init(id: String, threadID: String, sourceHostID: String?, sourceName: String?, kind: Kind, detectedAt: Date, provider: AgentProvider = .codex,
                questionKey: String? = nil) {
        self.id = id; self.threadID = threadID; self.sourceHostID = sourceHostID
        self.provider = provider
        self.sourceName = sourceName; self.kind = kind; self.detectedAt = detectedAt; self.questionKey = questionKey
    }
    public var activity: SessionActivity {
        SessionActivity(id: provider.activityID(sessionID: threadID, sourceHostID: sourceHostID),
            project: sourceName ?? L10n.text("activity.local_task"), sourceHost: sourceName,
            sourceHostID: sourceHostID, provider: provider, sessionID: threadID).canonicalized()
    }
}
