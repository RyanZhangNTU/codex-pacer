import Foundation

/// Bounded display metadata. The host never reconstructs provider lifecycle,
/// task families or rate estimates from strings or from raw event payloads.
struct EnginePresentation: Codable, Equatable {
    let rows: [EngineTaskRow]
    let pageSize: Int
    let rowCapacity: Int
    let pageCount: Int
    let header: EngineHeader

    init(activities: [SessionActivity], requests: [PendingAttentionRequest], inbox: CompletionInbox,
         hideProjects: Bool, at now: Date, showsDeepSeekTurnCost: Bool = true) {
        let groups = ActivityTaskGroup.make(activities)
        let known = Set(groups.flatMap { $0.members.map(\.id) })
        var displayed = groups.filter {
            $0.isRunning || $0.isWaiting || [.completed, .interrupted].contains($0.primary.phase) ||
                now.timeIntervalSince($0.primary.lastObserved ?? .distantPast) < 900
        }
        var ids = Set(displayed.map { $0.primary.id })
        for request in requests where !known.contains(request.activity.id) && ids.insert(request.activity.id).inserted {
            displayed += ActivityTaskGroup.make([request.activity])
        }
        func attention(_ group: ActivityTaskGroup) -> PendingAttentionRequest.Kind? {
            let members = Set(group.members.map(\.id))
            let matching = requests.filter { members.contains($0.activity.id) }
            if matching.contains(where: { $0.kind == .approval }) { return .approval }
            if matching.contains(where: { $0.kind == .decision }) { return .decision }
            if !matching.isEmpty { return .input }
            return group.members.first { $0.phase == .waitingForInput }.map { $0.waitingForApproval ? .approval : .input }
        }
        func priority(_ group: ActivityTaskGroup) -> Int {
            if attention(group) != nil { return 0 }
            switch group.primary.observedPhase(at: now) {
            case .waitingForInput: return 0
            case .running: return 1
            case .interrupted: return 2
            case .completed: return 3
            case .unknown: return 4
            }
        }
        displayed.sort {
            let left = priority($0), right = priority($1)
            if left != right { return left < right }
            let lhs = $0.primary.phaseChangedAt ?? .distantPast, rhs = $1.primary.phaseChangedAt ?? .distantPast
            return lhs == rhs ? $0.primary.id < $1.primary.id : lhs > rhs
        }
        rows = displayed.map { EngineTaskRow(group: $0, attention: attention($0), inbox: inbox, hideProjects: hideProjects, at: now, showsDeepSeekTurnCost: showsDeepSeekTurnCost) }
        let pagination = TaskPagination(itemCount: rows.count)
        pageSize = pagination.pageSize; rowCapacity = pagination.rowCapacity; pageCount = pagination.pageCount
        header = EngineHeader(groups: groups, requests: requests, inbox: inbox, at: now)
    }
}

struct EngineTaskRow: Codable, Equatable {
    let id: String
    let provider: String
    let title: String
    let status: String
    let source: String?
    let sourceLabel: String?
    let sourceKind: String?
    let phase: String
    let symbol: String
    let attention: String?
    let model: String
    let effort: String?
    let tokensPerSecond: Double?
    let rateIsFresh: Bool
    let ratePlaceholder: String?
    let turnTime: String?
    let subagents: Int
    let unread: Bool
    let failed: Bool
    let dimmed: Bool
    let cost: String?
    let peakCost: Bool

    init(group: ActivityTaskGroup, attention: PendingAttentionRequest.Kind?, inbox: CompletionInbox,
         hideProjects: Bool, at now: Date, showsDeepSeekTurnCost: Bool = true) {
        let activity = group.primary
        let phase: ActivityPhase = group.isRunning ? .running : group.isWaiting ? .waitingForInput : activity.observedPhase(at: now)
        let unread = !group.isRunning && inbox.isUnread(activity)
        self.id = activity.id; provider = activity.provider.rawValue
        title = hideProjects ? L10n.text("activity.hidden_name") : activity.title ?? activity.project
        self.phase = phase.rawValue; self.attention = attention?.rawValue
        self.unread = unread; failed = activity.turnFailed
        dimmed = !unread && attention == nil && !activity.turnFailed && [.completed, .interrupted].contains(phase)
        let estimate = group.displayedRate(at: now)
        tokensPerSecond = estimate?.value; rateIsFresh = estimate?.isFresh == true
        subagents = group.runningSubagentCount + (phase == .running ? activity.claudeCloud?.additionalWorkers ?? 0 : 0)
        let name = activity.modelName.map(ModelDisplay.name) ?? activity.provider.displayName
        model = name.count > 22 ? String(name.prefix(21)) + "…" : name
        effort = activity.modelName == nil ? nil : activity.reasoningEffort.flatMap { ModelDisplay.effortLabel($0) }
        cost = activity.provider == .deepseek && showsDeepSeekTurnCost ? activity.turnCost.map(DeepSeekWallet.turnAmount) : nil
        peakCost = (activity.turnPeakCost ?? 0) >= 0.005
        if let cloud = activity.claudeCloud {
            source = hideProjects ? L10n.text("connections.kind.claude_cloud") : cloud.projectName
            sourceKind = "cloud"
        } else {
            source = activity.sourceHost; sourceKind = activity.sourceHostID == nil ? nil : "server"
        }
        sourceLabel = source.map { $0.count > 16 ? String($0.prefix(7)) + "…" + String($0.suffix(8)) : $0 }
        ratePlaceholder = activity.claudeCloud == nil ? L10n.text("performance.awaiting_usage") : nil
        var status = phase == .completed ? activity.endingLabel : activity.detail(at: now)
        if group.isRunning, activity.phase != .running, !activity.turnFailed { status = L10n.text("activity.running_long") }
        if let attention {
            if phase != .running { status = attention.label }
            else {
                switch activity.phase == .running ? activity.stage : nil {
                case .tool?: status = attention.label + " · " + L10n.text("activity.tool_compact")
                case .responding?: status = attention.label + " · " + L10n.text("activity.responding_compact")
                default: status = attention.label + " · " + status
                }
            }
        }
        self.status = status
        if let start = activity.turnStartedAt, phase == .running, start <= now {
            turnTime = Self.duration(now.timeIntervalSince(start))
        } else if let start = activity.turnStartedAt, let end = activity.phaseChangedAt,
                  [.completed, .interrupted].contains(phase), [.completed, .interrupted].contains(activity.phase), end >= start {
            turnTime = Self.duration(end.timeIntervalSince(start))
        } else { turnTime = nil }
        symbol = group.isRunning && activity.phase != .running && attention == nil ? "sparkle" : Self.symbol(activity, attention: attention)
    }

    static func symbol(_ activity: SessionActivity, attention: PendingAttentionRequest.Kind?) -> String {
        if let attention { return attention == .approval ? "hand.raised" : "ellipsis.bubble" }
        switch activity.phase {
        case .waitingForInput: return activity.waitingForApproval ? "hand.raised" : "ellipsis.bubble"
        case .completed: return "checkmark.circle"
        case .interrupted: return activity.turnFailed ? "xmark.circle" : "pause.circle"
        case .unknown: return "moon"
        case .running:
            switch activity.stage {
            case .thinking: return "sparkle"
            case .tool: return "terminal"
            case .responding: return "text.bubble"
            case .starting: return "hourglass"
            case .working: return "cloud"
            case .coordinating: return "arrow.triangle.branch"
            }
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else { return L10n.text("dashboard.countdown_soon") }
        let days = Int(seconds) / 86400, hours = Int(seconds) % 86400 / 3600, minutes = Int(seconds) % 3600 / 60
        if days > 0 { return L10n.text("dashboard.countdown_days", days, hours) }
        if hours > 0 { return L10n.text("dashboard.countdown_hours", hours, minutes) }
        return L10n.text("dashboard.countdown_minutes", minutes)
    }
}

struct EngineHeader: Codable, Equatable {
    let activeCount: Int
    let coreSymbol: String?
    let orbit: [String: Int]
    let attention: String?
    let ending: String?
    let endingProvider: String?
    let endingIsCore: Bool

    init(groups: [ActivityTaskGroup], requests: [PendingAttentionRequest], inbox: CompletionInbox, at now: Date) {
        let overview = ActivityOverview(groups: groups, at: now)
        activeCount = overview.running.count + overview.waiting.count
        let attention = requests.first?.kind ?? overview.waiting.first.map { $0.waitingForApproval ? .approval : .input }
        self.attention = attention?.rawValue
        var orbit: [String: Int] = [:]
        for activity in overview.running { orbit[activity.provider.rawValue, default: 0] += 1 }
        self.orbit = orbit
        let endedRoots = Set(groups.filter { !$0.isRunning }.map { $0.primary.id })
        let completion = inbox.unreadActivities.first { endedRoots.contains($0.id) }
        ending = completion.map { $0.turnFailed ? "xmark.circle" : $0.phase == .interrupted ? "pause.circle" : "checkmark.circle" }
        endingProvider = completion?.provider.rawValue
        endingIsCore = completion != nil && activeCount == 0 && attention == nil
        let prompt = attention.map { $0 == .approval ? "hand.raised" : "ellipsis.bubble" }
        if activeCount == 0 { coreSymbol = prompt ?? ending }
        else if activeCount == 1 {
            let latest = overview.running.max {
                let left = $0.lastObserved ?? .distantPast, right = $1.lastObserved ?? .distantPast
                return left == right ? $0.id < $1.id : left < right
            }
            coreSymbol = prompt ?? latest.map { activity in
                groups.first { $0.primary.id == activity.id }?.isRunning == true && activity.phase != .running
                    ? "sparkle" : EngineTaskRow.symbol(activity, attention: nil)
            }
        } else { coreSymbol = nil }
    }
}
