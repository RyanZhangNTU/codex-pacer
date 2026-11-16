import Foundation

/// Only routing and request kind are retained. Questions, answers, commands and
/// permission details remain in Codex; an async question does not pause a turn.
public struct PendingAttentionRequest: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case input, approval, decision
        public var label: String {
            switch self {
            case .input: return L10n.text("attention.input")
            case .approval: return L10n.text("attention.approval")
            case .decision: return L10n.text("attention.decision")
            }
        }
    }
    public let id: String
    public let provider: AgentProvider
    public let threadID: String
    public let sourceHostID: String?
    public let sourceName: String?
    public let kind: Kind
    public let detectedAt: Date
    /// Hashed thread/turn/call identity shared by local Codex async-question sources.
    public let questionKey: String?
    /// Lets a waiting cloud Project task open before its row has been listed.
    public let claudeCloud: ClaudeCloudContext?
    /// A question recovered from an existing cloud snapshot can show without a new alert.
    public let suppressesNotice: Bool
    public init(id: String, threadID: String, sourceHostID: String?, sourceName: String?, kind: Kind, detectedAt: Date, provider: AgentProvider = .codex,
                questionKey: String? = nil, claudeCloud: ClaudeCloudContext? = nil, suppressesNotice: Bool = false) {
        self.id = id; self.threadID = threadID; self.sourceHostID = sourceHostID
        self.provider = provider
        self.sourceName = sourceName; self.kind = kind; self.detectedAt = detectedAt; self.questionKey = questionKey
        self.claudeCloud = claudeCloud; self.suppressesNotice = suppressesNotice
    }
    public var activity: SessionActivity {
        var value = SessionActivity(id: provider.activityID(sessionID: threadID, sourceHostID: sourceHostID),
            project: sourceName ?? L10n.text("activity.local_task"), sourceHost: sourceName,
            sourceHostID: sourceHostID, provider: provider, sessionID: threadID).canonicalized()
        if let claudeCloud { value.setClaudeCloud(claudeCloud) }
        return value
    }

    func suppressingNotice() -> Self {
        .init(id: id, threadID: threadID, sourceHostID: sourceHostID, sourceName: sourceName, kind: kind,
              detectedAt: detectedAt, provider: provider, questionKey: questionKey, claudeCloud: claudeCloud, suppressesNotice: true)
    }
}
