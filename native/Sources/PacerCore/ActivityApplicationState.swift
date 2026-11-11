import Foundation

public struct ActivityVisibilityOptions: Equatable, Sendable {
    public var embeddedProviders: Set<AgentProvider>
    public var showsClaudeCloudProjects: Bool
    public var showsDurableActivities: Bool
    public init(embeddedProviders: Set<AgentProvider> = Set(AgentProvider.allCases), showsClaudeCloudProjects: Bool = true,
                showsDurableActivities: Bool = true) {
        self.embeddedProviders = embeddedProviders; self.showsClaudeCloudProjects = showsClaudeCloudProjects
        self.showsDurableActivities = showsDurableActivities
    }
}

public struct ActivityApplicationUpdate: Sendable {
    public let activities: [SessionActivity]
    public let requests: [PendingAttentionRequest]
    public let notices: [IslandNotice]
    public let latestFirstOutputLatency: TimeInterval?
}

/// One instance per application host. Collectors supply facts; this value owns
/// retention, visibility, acknowledgment, per-provider notices and display caches.
public struct ActivityApplicationState: Sendable {
    public var localActivities: [SessionActivity] = []
    public var remoteActivities: [SessionActivity] = []
    public var claudeActivities: [SessionActivity] = []
    public var deepseekActivities: [SessionActivity] = []
    public var codexReceivedRequests: [PendingAttentionRequest] = []
    public var codexLogRequests: [PendingAttentionRequest] = []
    public var claudeReceivedRequests: [PendingAttentionRequest] = []
    public var deepseekReceivedRequests: [PendingAttentionRequest] = []
    public var excludedCodexActivityIDs: Set<String> = []
    public var codexAttentionThreadIDs: Set<String> = []
    public var codexStreamConnected = false
    public var pendingCodexEndings: [String: SessionActivity] = [:]
    /// Demo source data is separate from observed data. Module switches only
    /// filter this snapshot; an I/O-isolated test can still supply observed facts.
    public var demoActivities: [SessionActivity] = []
    public var demoRequests: [PendingAttentionRequest] = []
    public var includesDemoMetadata = false
    public var codexAttention = AttentionPolicy()
    public var claudeAttention = AttentionPolicy()
    public var deepseekAttention = AttentionPolicy()
    public var inbox: CompletionInbox { didSet { cachedPresentation = nil } }
    public private(set) var activities: [SessionActivity] = []
    public private(set) var requests: [PendingAttentionRequest] = []
    public private(set) var latestFirstOutput: (at: Date, seconds: TimeInterval)?
    /// The last few first-output measurements for the collapsed bar's median.
    public private(set) var firstOutputHistory = CompactFirstOutputHistory()
    /// The total rate over the last minute while tasks run.
    public private(set) var taskGroupingComputations = 0
    private var cachedGroups: [ActivityTaskGroup]?
    private var cachedOverview: (at: Date, value: ActivityOverview)?
    private var cachedPresentation: (at: Date, options: TaskPresentationOptions, value: ActivityTaskPresentation)?
    public init(inbox: CompletionInbox = CompletionInbox()) { self.inbox = inbox }

    public func knownActivities(for provider: AgentProvider) -> [SessionActivity] {
        let incoming: [SessionActivity]
        switch provider { case .codex: incoming = localActivities + remoteActivities + Array(pendingCodexEndings.values); case .claude: incoming = claudeActivities; case .deepseek: incoming = deepseekActivities }
        var values = Dictionary(inbox.activities.filter { $0.provider == provider }.map { ($0.canonicalized().id, $0.canonicalized()) }, uniquingKeysWith: { _, latest in latest })
        let samples = includesDemoMetadata ? demoActivities.filter { $0.provider == provider } : []
        for item in samples + incoming {
            var value = item.canonicalized()
            if let old = values[value.id] { value.mergeDisplayMetadata(from: old) }
            values[value.id] = value
        }
        return CodexSessionOrigin.inheriting(Array(values.values))
    }
    public var ignoredCodexActivityIDs: Set<String> {
        excludedCodexActivityIDs.union(knownActivities(for: .codex).filter(\.isIgnoredCodexSession).map(\.id))
    }
    public func hiddenActivityIDs(_ visibility: ActivityVisibilityOptions) -> Set<String> {
        var hidden = ignoredCodexActivityIDs
        if !visibility.showsDurableActivities {
            hidden.formUnion(knownActivities(for: .codex).filter { $0.sourceHostID == DurableActivityCatalog.hostID }.map(\.id))
            hidden.formUnion(codexReceivedRequests.filter { $0.sourceHostID == DurableActivityCatalog.hostID }.map { $0.activity.id })
        }
        if !visibility.showsClaudeCloudProjects {
            hidden.formUnion(knownActivities(for: .claude).filter { $0.claudeCloud != nil }.map(\.id))
            hidden.formUnion(claudeReceivedRequests.filter { $0.claudeCloud != nil }.map { $0.activity.id })
        }
        for provider in AgentProvider.allCases where !visibility.embeddedProviders.contains(provider) {
            hidden.formUnion(EmbeddedSessionVisibility.embeddedActivityIDs(knownActivities(for: provider)))
        }
        return hidden
    }
    public mutating func replaceActivities(_ values: [SessionActivity], at now: Date) {
        if values != activities { activities = values; cachedGroups = nil; cachedOverview = nil; cachedPresentation = nil }
        observeFirstOutputs(values, at: now)
    }
    public mutating func taskGroups() -> [ActivityTaskGroup] {
        if let cachedGroups { return cachedGroups }
        let groups = ActivityTaskGroup.make(activities)
        cachedGroups = groups; taskGroupingComputations += 1; return groups
    }
    public mutating func overview(at now: Date) -> ActivityOverview {
        if let cachedOverview, cachedOverview.at == now { return cachedOverview.value }
        let value = ActivityOverview(groups: taskGroups(), at: now)
        cachedOverview = (now, value); return value
    }
    public mutating func presentation(at now: Date, options: TaskPresentationOptions = .init()) -> ActivityTaskPresentation {
        if let cachedPresentation, cachedPresentation.at == now, cachedPresentation.options == options { return cachedPresentation.value }
        let groups = taskGroups(), overview = overview(at: now)
        let value = ActivityTaskPresentation(activities: activities, requests: requests, inbox: inbox,
            groups: groups, overview: overview, options: options, at: now)
        cachedPresentation = (now, options, value); return value
    }
    /// The latest value takes only a newer measurement; the history of recent
    /// ones also keeps those that arrive after a newer one.
    public mutating func rememberFirstOutput(_ latency: TimeInterval?, reportedAt: Date?, at now: Date) {
        guard let latency, latency.isFinite, (0...3600).contains(latency), let reportedAt, reportedAt <= now else { return }
        firstOutputHistory.record(latency, measuredAt: reportedAt)
        if latestFirstOutput.map({ reportedAt > $0.at }) ?? true { latestFirstOutput = (reportedAt, latency) }
    }
    public mutating func clearFirstOutput() { latestFirstOutput = nil; firstOutputHistory = CompactFirstOutputHistory() }
    public mutating func replacePendingRequests(for provider: AgentProvider, with values: [PendingAttentionRequest]) {
        requests = requests.filter { $0.provider != provider } + values; cachedPresentation = nil
    }
    public mutating func replacePendingRequests(_ values: [PendingAttentionRequest]) { requests = values; cachedPresentation = nil }
    public mutating func rememberCodexEndings(_ values: [SessionActivity]) {
        for value in values where [.completed, .interrupted].contains(value.phase) { pendingCodexEndings[value.id] = value }
        if pendingCodexEndings.count > 256 {
            for id in pendingCodexEndings.keys.sorted(by: {
                (pendingCodexEndings[$0]?.phaseChangedAt ?? .distantPast) > (pendingCodexEndings[$1]?.phaseChangedAt ?? .distantPast)
            }).dropFirst(256) { pendingCodexEndings.removeValue(forKey: id) }
        }
    }
    public mutating func discardPendingDurableEndings() {
        pendingCodexEndings = pendingCodexEndings.filter { $0.value.sourceHostID != DurableActivityCatalog.hostID }
    }
    public mutating func applyCodexMetadata(names: [SessionNameUpdate], performance: [SessionPerformanceUpdate],
                                           at now: Date, visibility: ActivityVisibilityOptions) {
        inbox.updateNames(names); inbox.updatePerformance(performance)
        for index in localActivities.indices {
            for name in names where name.id == localActivities[index].id { name.apply(to: &localActivities[index]) }
            for sample in performance where sample.id == localActivities[index].id { sample.apply(to: &localActivities[index]) }
        }
        for index in remoteActivities.indices {
            for name in names where name.id == remoteActivities[index].id { name.apply(to: &remoteActivities[index]) }
            for sample in performance where sample.id == remoteActivities[index].id { sample.apply(to: &remoteActivities[index]) }
        }
        let hidden = hiddenActivityIDs(visibility)
        for sample in performance where !hidden.contains(sample.id) {
            rememberFirstOutput(sample.firstTokenLatency, reportedAt: sample.firstTokenReportedAt, at: now)
        }
    }
    private mutating func observeFirstOutputs(_ values: [SessionActivity], at now: Date) {
        for activity in values where !activity.isInternalReview {
            rememberFirstOutput(activity.firstTokenLatency, reportedAt: activity.firstTokenReportedAt, at: now)
        }
    }
    public mutating func observeAttentionRequests(_ values: [PendingAttentionRequest], visibility: ActivityVisibilityOptions) -> [IslandNotice] {
        let hidden = hiddenActivityIDs(visibility), shown = values.filter { !hidden.contains($0.activity.id) }
        if requests != shown { requests = shown; cachedPresentation = nil }
        return codexAttention.requestNotices(shown.filter { $0.provider == .codex }) +
            claudeAttention.requestNotices(shown.filter { $0.provider == .claude }) +
            deepseekAttention.requestNotices(shown.filter { $0.provider == .deepseek })
    }
    private var reconciledCodexRequests: [PendingAttentionRequest] {
        let liveInputs = Set(codexReceivedRequests.filter { $0.sourceHostID == nil && $0.kind == .input }.map(\.threadID))
        let authoritative = codexAttentionThreadIDs.filter { thread in
            if codexReceivedRequests.contains(where: { $0.threadID == thread }) { return true }
            guard codexStreamConnected, let live = remoteActivities.first(where: { $0.sourceHostID == nil && $0.threadID == thread && $0.hasLiveEvidence }) else { return false }
            let logged = localActivities.first { $0.threadID == thread }
            return logged?.turnID == nil || logged?.turnID == live.turnID
        }
        let logged = codexLogRequests.filter { request in
            guard !liveInputs.contains(request.threadID), !authoritative.contains(request.threadID) else { return false }
            if let live = remoteActivities.first(where: { $0.sourceHostID == nil && $0.threadID == request.threadID && $0.hasLiveEvidence }) {
                if let start = live.turnStartedAt, start > request.detectedAt { return false }
                if [.completed, .interrupted].contains(live.phase), (live.phaseChangedAt ?? .distantPast) >= request.detectedAt { return false }
            }
            return true
        }
        return codexReceivedRequests + logged
    }
    @discardableResult public mutating func reconcile(at now: Date, retention: TimeInterval, visibility: ActivityVisibilityOptions) -> ActivityApplicationUpdate {
        var notices = observeAttentionRequests(reconciledCodexRequests + claudeReceivedRequests + deepseekReceivedRequests, visibility: visibility)
        let ignored = ignoredCodexActivityIDs
        inbox.remove(activityIDs: ignored)
        let previous = Dictionary(activities.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        // A temporary verification gap must not consume an ending before
        // it can produce an unread card and notice for the same account.
        // Don't turn a long outage into a batch of newly unread old endings.
        let durableCutoff = now.addingTimeInterval(-min(retention > 0 ? retention : .infinity, 900))
        for (id, ending) in pendingCodexEndings where ending.sourceHostID == DurableActivityCatalog.hostID &&
            (ending.phaseChangedAt ?? .distantPast) <= durableCutoff {
            pendingCodexEndings.removeValue(forKey: id)
        }
        let ready = pendingCodexEndings.values.filter { visibility.showsDurableActivities || $0.sourceHostID != DurableActivityCatalog.hostID }
        let streamed = ready.isEmpty ? remoteActivities : ActivitySourceMerger.merge(logged: ready, streamed: remoteActivities)
        let merged = (ActivitySourceMerger.merge(logged: localActivities, streamed: streamed) + claudeActivities + deepseekActivities)
            .filter { !ignored.contains($0.id) && !$0.codexGoalExpired(at: now) }.map { value in
                var value = value
                if let old = previous[value.id] { value.mergeDisplayMetadata(from: old) }
                return value
            }
        let observed = inbox.observe(ActivityTaskGroup.make(merged).flatMap(\.members), at: now, retention: retention)
        for ending in ready { pendingCodexEndings.removeValue(forKey: ending.id) }
        for ending in inbox.activities where ending.claudeCloud?.readInClaude == true { inbox.dismiss(ending) }
        let hidden = hiddenActivityIDs(visibility), shown = observed.filter { !hidden.contains($0.id) }
        observeFirstOutputs(shown, at: now)
        let activeRoots = Set(ActivityTaskGroup.make(shown).filter(\.isRunning).map { $0.primary.id })
        let combined = shown.filter {
            !$0.isInternalReview && (activeRoots.contains($0.id) || ![.completed, .interrupted].contains($0.phase)) &&
                (activeRoots.contains($0.id) || [.running, .waitingForInput].contains($0.phase) || now.timeIntervalSince($0.lastObserved ?? .distantPast) < 900)
        } + inbox.activities.filter { !activeRoots.contains($0.id) && !hidden.contains($0.id) }
        replaceActivities(combined, at: now)
        let tasks = taskGroups().filter { !($0.isRunning && [.completed, .interrupted].contains($0.primary.phase)) }.map(\.primary)
        notices += AttentionPolicy.excludingPendingReplies(codexAttention.activityNotices(tasks.filter { $0.provider == .codex }, at: now) +
            claudeAttention.activityNotices(tasks.filter { $0.provider == .claude }, at: now) +
            deepseekAttention.activityNotices(tasks.filter { $0.provider == .deepseek }, at: now), activityIDs: Set(requests.map { $0.activity.id }))
        return update(notices: notices)
    }
    @discardableResult public mutating func applyDemoSnapshot(enabled: Set<AgentProvider>, at now: Date,
                                                             visibility: ActivityVisibilityOptions) -> ActivityApplicationUpdate {
        let hidden = hiddenActivityIDs(visibility)
        replaceActivities(demoActivities.filter { enabled.contains($0.provider) && !hidden.contains($0.id) }, at: now)
        let notices = observeAttentionRequests(demoRequests.filter { enabled.contains($0.provider) && !hidden.contains($0.activity.id) }, visibility: visibility)
        return update(notices: notices)
    }
    public func update(notices: [IslandNotice] = []) -> ActivityApplicationUpdate {
        .init(activities: activities, requests: requests, notices: notices, latestFirstOutputLatency: latestFirstOutput?.seconds)
    }
    public func visibleNotices(_ notices: [IslandNotice], visibility: ActivityVisibilityOptions) -> [IslandNotice] {
        let hidden = hiddenActivityIDs(visibility)
        let allRequests = codexReceivedRequests + codexLogRequests + claudeReceivedRequests + deepseekReceivedRequests + demoRequests
        let hiddenRequests = Set(allRequests.filter { hidden.contains($0.activity.canonicalized().id) }.map { "request:" + $0.id })
        return notices.filter { notice in
            !hiddenRequests.contains(notice.id) && (notice.kind == .lowQuota || !hidden.contains { notice.id.hasPrefix($0 + ":") })
        }
    }
    public mutating func removeActivities(_ ids: Set<String>, at now: Date) { replaceActivities(activities.filter { !ids.contains($0.id) }, at: now) }
    @discardableResult public mutating func markAllRead(at now: Date) -> Bool {
        markRead(activityID: nil, at: now)
    }
    @discardableResult public mutating func markRead(activityID: String?, at now: Date) -> Bool {
        let value = presentation(at: now)
        let family = activityID.flatMap { id in value.groups.first { $0.primary.id == id } }.map { Set($0.members.map(\.id)) }
        let readable = value.readableCompletions.filter { activityID == nil || family?.contains($0.id) == true }
        let removed = Set(readable.filter { inbox.dismiss($0) }.map(\.id))
        guard !removed.isEmpty else { return false }
        removeActivities(removed, at: now); return true
    }
    public mutating func prune(at now: Date, retention: TimeInterval) {
        inbox.prune(at: now, retention: retention)
        let retained = Set(inbox.activities.map(\.id)).union(taskGroups().filter(\.isRunning).map { $0.primary.id })
        replaceActivities(activities.filter {
            !$0.codexGoalExpired(at: now) && (![.completed, .interrupted].contains($0.phase) || retained.contains($0.id))
        }, at: now)
    }
    /// Display-only wake-ups never request collection or reset a notice baseline.
    public func nextDisplayDeadline(at now: Date, retention: TimeInterval, progressRingProviders: Set<AgentProvider> = []) -> Date? {
        var dates = activities.compactMap(\.rateExpiresAt) + activities.compactMap(\.codexGoalDeadline)
        dates += activities.filter { ![.running, .waitingForInput, .completed, .interrupted].contains($0.phase) }
            .compactMap { $0.lastObserved?.addingTimeInterval(900) }
        if retention > 0 { dates += inbox.activities.compactMap { $0.phaseChangedAt?.addingTimeInterval(retention) } }
        for value in activities where value.phase == .running {
            if let start = value.turnStartedAt, start <= now {
                dates.append(start.addingTimeInterval((floor(now.timeIntervalSince(start) / 60) + 1) * 60))
            }
            if progressRingProviders.contains(value.provider) {
                if let start = value.toolWaitStartedAt { dates.append(start.addingTimeInterval(TaskProgressRing.longStepInterval)) }
                if let report = value.currentProgress { dates.append(report.reportedAt.addingTimeInterval(TaskProgressRing.staleInterval)) }
            }
        }
        return dates.filter { $0 > now && $0.timeIntervalSince1970.isFinite }.min()
    }
}
