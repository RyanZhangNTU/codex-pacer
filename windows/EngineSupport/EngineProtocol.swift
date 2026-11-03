import Foundation
import PacerCore

enum EngineProtocol {
    static let version = 1
    static let maximumCommandBytes = 64 * 1024
    static let maximumSnapshotBytes = 1024 * 1024
}

struct EngineCommand: Decodable {
    let protocolVersion: Int
    let id: String
    let method: String
    let params: Parameters?

    struct Parameters: Decodable {
        var shell: EngineShellProjection.Request?
        var expanded: Bool?
        var discover: Bool?
        var demoStage: Int?
        var codexHome: String?
        var codexExecutable: String?
        var claudeHome: String?
        var claudeOrganization: String?
        var claudeSession: ClaudeWebSessionReply?
        var requestID: String?
        var context: String?
        var notificationAction: String?
        var navigationMessage: String?
        var deepseekHome: String?
        var sourceHome: String?
        var sourceID: String?
        var hideProjects: Bool?
        var showEmbeddedCodexSessions: Bool?
        var showEmbeddedClaudeSessions: Bool?
        var showClaudeCloudProjects: Bool?
        var monitorSSH: Bool?
        var deepseekSettings: EngineDeepSeekSettings?
        var reminderSettings: EngineReminderSettings?
        var retentionMinutes: Int?
        var enabledProviders: [String]?
        var providerModes: [String: String]?
        var provider: String?
        var activityID: String?
        var snapshotSequence: UInt64?
        var deepseekKey: String?
        var balanceContext: String?
        var webAvailable: Bool?
        var webRequestID: String?
        var webReply: DeepSeekWebReply?
        var webSuccess: Bool?
        var webNewSession: Bool?
    }

    static func correlationID(_ data: Data) -> String? {
        struct Envelope: Decodable { let id: String }
        guard data.count <= EngineProtocol.maximumCommandBytes,
              let id = try? JSONDecoder().decode(Envelope.self, from: data).id,
              !id.isEmpty, id.utf8.count <= 128,
              !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return id
    }

    static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= EngineProtocol.maximumCommandBytes else { throw Failure.tooLarge }
        let command = try JSONDecoder().decode(Self.self, from: bytes)
        guard command.protocolVersion == EngineProtocol.version else { throw Failure.version }
        guard !command.id.isEmpty, command.id.utf8.count <= 128,
              command.id.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              command.method.utf8.count <= 64 else { throw Failure.invalid }
        return command
    }
    enum Failure: Error { case tooLarge, version, invalid }
}

/// A split or oversized pipe write cannot create an unbounded line buffer.
struct EngineFramer {
    private var pending = Data()
    mutating func append(_ bytes: Data) throws -> [Data] {
        var frames: [Data] = []
        for byte in bytes {
            if byte == 10 {
                if pending.last == 13 { pending.removeLast() }
                if !pending.isEmpty { frames.append(pending) }
                pending.removeAll(keepingCapacity: true)
            } else {
                guard pending.count < EngineProtocol.maximumCommandBytes else { throw EngineCommand.Failure.tooLarge }
                pending.append(byte)
            }
        }
        return frames
    }
    mutating func finish() throws -> Data? {
        defer { pending.removeAll() }
        guard !pending.isEmpty else { return nil }
        return pending
    }
}

struct EngineTask: Codable, Equatable {
    let id: String
    let provider: String
    let sessionID: String?
    let turnID: String?
    let parentThreadID: String?
    let title: String
    let source: String
    let sourceID: String?
    let phase: String
    let stage: String
    let stageLabel: String
    let model: String?
    let effort: String?
    let tokensPerSecond: Double?
    let rateReportedAt: Double?
    let rateIsFresh: Bool
    let rateIsEstimated: Bool
    let firstTokenLatency: Double?
    let startedAt: Double?
    let unread: Bool
    let failed: Bool
    let turnCost: Double?
    let turnPeakCost: Double?

    init(_ activity: SessionActivity, unread: Bool, hideProjects: Bool, at now: Date) {
        let rate = activity.displayedOutputEstimate(at: now)
        id = activity.id; provider = activity.provider.rawValue
        sessionID = activity.threadID; turnID = activity.turnID; parentThreadID = activity.parentThreadID
        title = hideProjects ? L10n.text("activity.local_task") : activity.title ?? activity.project
        source = hideProjects && activity.claudeCloud != nil ? L10n.text("connections.kind.claude_cloud")
            : activity.sourceHost ?? L10n.text("common.local")
        sourceID = activity.sourceHostID
        phase = activity.observedPhase(at: now).rawValue; stage = activity.stage.rawValue
        stageLabel = [.completed, .interrupted].contains(activity.phase) ? activity.endingLabel : activity.stage.label
        model = activity.modelName.map(ModelDisplay.name); effort = activity.reasoningEffort
        tokensPerSecond = rate?.value; rateReportedAt = rate?.reportedAt.timeIntervalSince1970
        rateIsFresh = rate?.isFresh == true; rateIsEstimated = activity.displayedRateIsEstimated(at: now)
        firstTokenLatency = activity.firstTokenLatency
        startedAt = activity.turnStartedAt?.timeIntervalSince1970
        self.unread = unread; failed = activity.turnFailed
        turnCost = activity.turnCost; turnPeakCost = activity.turnPeakCost
    }
}

struct EngineRequest: Codable, Equatable {
    let id: String
    let provider: String
    let activityID: String
    let kind: String
    let label: String
    let detectedAt: Double
    init(_ request: PendingAttentionRequest) {
        id = request.id; provider = request.provider.rawValue
        activityID = request.activity.id; kind = request.kind.rawValue
        label = request.kind.label; detectedAt = request.detectedAt.timeIntervalSince1970
    }
}

struct EngineSource: Codable, Equatable {
    let id: String
    let provider: String
    let available: Bool
    let transport: String
    let reason: String?
    var failure: CodexQuotaFailure? = nil
}

struct EngineModule: Codable, Equatable {
    let provider: String
    let mode: String
    let installed: Bool?
    let enabled: Bool
}

struct EngineQuota: Codable, Equatable {
    struct Window: Codable, Equatable {
        let id: String
        let label: String
        let remainingPercent: Double?
        let remainingTimePercent: Double?
        let pacePercent: Double?
        let durationMinutes: Int?
        let resetsAt: Double?
        let countdown: String?
        let verdict: String?
        let verdictText: String?
        let pressing: Bool
        let valueText: String
    }
    let provider: String
    let capturedAt: Double
    let stale: Bool
    let windows: [Window]
    init(_ value: QuotaSnapshot, provider: AgentProvider, at now: Date) {
        self.provider = provider.rawValue; capturedAt = value.capturedAt.timeIntervalSince1970
        let expired = value.isStale(at: now)
        stale = expired
        windows = value.windows.map { window in
            let pace = expired ? nil : window.pacePercent(at: now)
            let verdict = pace.map { $0 < 85 ? "fast" : $0 > 115 ? "spare" : "steady" }
            return .init(id: window.id, label: window.label, remainingPercent: window.remainingPercent,
                remainingTimePercent: window.remainingTimePercent(at: now), pacePercent: pace,
                durationMinutes: window.durationMinutes, resetsAt: window.resetsAt?.timeIntervalSince1970,
                countdown: window.remainingSeconds(at: now).map {
                    $0 <= 0 ? L10n.text("dashboard.countdown_waiting") : EngineTaskRow.duration($0)
                }, verdict: verdict, verdictText: verdict.map { L10n.text("quota.verdict." + $0) },
                pressing: !expired && (window.remainingPercent.map { $0 <= 15 } == true || verdict == "fast"),
                valueText: window.remainingPercent.map { String(Int($0.rounded())) } ?? "—")
        }
    }
}

struct EngineNotice: Codable, Equatable {
    struct Action: Codable, Equatable { let kind: String; let title: String; var reference: String? = nil }
    let id: String
    let kind: String
    let title: String
    let detail: String
    let category: String?
    let body: String?
    let privateBody: String?
    var actions: [Action]?
    var defaultAction: Action? = nil
    init(_ value: IslandNotice, hideProjects: Bool) {
        id = value.id; kind = value.kind.rawValue; title = value.title
        detail = hideProjects && value.kind != .lowQuota ? L10n.text("activity.local_task") : value.detail
        category = value.category
        let hidden = value.kind != .lowQuota ? L10n.text("activity.hidden_local_name") : value.detail
        body = L10n.text("notice.body", value.title, hideProjects ? hidden : value.detail)
        privateBody = L10n.text("notice.body", value.title, hidden)
        if value.category == DeepSeekNoticePolicy.spikeCategory {
            actions = [.init(kind: "openHarness", title: L10n.text("deepseek.notice.open_harness")), .init(kind: "snoozeSpike", title: L10n.text("deepseek.notice.snooze"))]
        } else if value.category == DeepSeekNoticePolicy.balanceCategory {
            actions = [.init(kind: "topUp", title: L10n.text("deepseek.notice.top_up"))]
        } else { actions = nil }
    }
}

struct EngineNavigationFailure: Codable, Equatable {
    let id: String
    let message: String
    init(_ failure: ActivityNavigationState.Failure) { id = failure.id.uuidString; message = failure.message }
}

struct EngineSnapshot: Codable, Equatable {
    let protocolVersion: Int
    let type: String
    let sequence: UInt64
    let demo: Bool
    let capturedAt: Double
    let tasks: [EngineTask]
    let requests: [EngineRequest]
    let sources: [EngineSource]
    let quota: [EngineQuota]
    let notices: [EngineNotice]
    let runningCount: Int
    let waitingCount: Int
    let totalTokensPerSecond: Double?
    let rateIsFresh: Bool
    let presentation: EnginePresentation
    let wallet: EngineWallet?
    let modules: [EngineModule]?
    let quotaDashboard: EngineQuotaDashboard?
    let compactWarnings: [CompactWarningPresentation.Item]?
    let compactContext: CompactBarContext?
    let deepseekConnection: EngineDeepSeekConnection?
    let claudeConnection: EngineClaudeConnection?
    let claudeCloudConnection: EngineClaudeCloudConnection?
    let activityLinks: [EngineActivityLink]?
    let claudeSetup: EngineClaudeHookSetup?
    let claudeRemoteSetups: [EngineClaudeRemoteSetup]?
    let navigationError: EngineNavigationFailure?
    let openingActivityIDs: [String]?

    init(sequence: UInt64, demo: Bool, activities: [SessionActivity], requests: [PendingAttentionRequest],
         sources: [EngineSource], quota: [EngineQuota], notices: [IslandNotice], inbox: CompletionInbox,
         hideProjects: Bool, now: Date, wallet: EngineWallet? = nil, modules: [EngineModule]? = nil, quotaDashboard: EngineQuotaDashboard? = nil,
         showsDeepSeekTurnCost: Bool = true, compactWarnings: [CompactWarningPresentation.Item]? = nil, compactContext: CompactBarContext? = nil,
         taskPresentation: ActivityTaskPresentation? = nil,
         deepseekConnection: EngineDeepSeekConnection? = nil, claudeConnection: EngineClaudeConnection? = nil,
         claudeCloudConnection: EngineClaudeCloudConnection? = nil, activityLinks: [EngineActivityLink]? = nil,
         notificationProjections: [EngineNotice]? = nil,
         navigationError: EngineNavigationFailure? = nil, openingActivityIDs: [String]? = nil, claudeSetup: EngineClaudeHookSetup? = nil,
         claudeRemoteSetups: [EngineClaudeRemoteSetup]? = nil) {
        protocolVersion = EngineProtocol.version; type = "snapshot"; self.sequence = sequence
        self.demo = demo; capturedAt = now.timeIntervalSince1970
        tasks = activities.sorted { $0.id < $1.id }.map { EngineTask($0, unread: inbox.isUnread($0), hideProjects: hideProjects, at: now) }
        self.requests = requests.map(EngineRequest.init); self.sources = sources; self.quota = quota
        self.notices = notificationProjections ?? notices.map { EngineNotice($0, hideProjects: hideProjects) }
        let overview = taskPresentation?.overview ?? ActivityOverview(activities: activities, at: now)
        runningCount = overview.running.count; waitingCount = overview.waiting.count
        totalTokensPerSecond = overview.displayedRate; rateIsFresh = overview.rateIsFresh
        presentation = taskPresentation.map(EnginePresentation.init) ?? EnginePresentation(activities: activities, requests: requests, inbox: inbox, hideProjects: hideProjects, at: now, showsDeepSeekTurnCost: showsDeepSeekTurnCost)
        self.wallet = wallet
        self.modules = modules
        self.quotaDashboard = quotaDashboard
        self.compactWarnings = compactWarnings
        self.compactContext = compactContext
        self.deepseekConnection = deepseekConnection
        self.claudeConnection = claudeConnection
        self.claudeCloudConnection = claudeCloudConnection
        self.activityLinks = activityLinks
        self.claudeSetup = claudeSetup
        self.claudeRemoteSetups = claudeRemoteSetups
        self.navigationError = navigationError; self.openingActivityIDs = openingActivityIDs
    }
}
