import Foundation

public struct ActivityVisibilityOptions: Equatable, Sendable {
    public var embeddedProviders: Set<AgentProvider>
    public var showsClaudeCloudProjects: Bool
    public init(embeddedProviders: Set<AgentProvider> = Set(AgentProvider.allCases), showsClaudeCloudProjects: Bool = true) {
        self.embeddedProviders = embeddedProviders; self.showsClaudeCloudProjects = showsClaudeCloudProjects
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
    private var codex = CodexActivityInput()
    public var localActivities: [SessionActivity] {
        get { codex.logged }
        set { codex.logged = newValue }
    }
    public var remoteActivities: [SessionActivity] {
        get { codex.streamed }
        set { codex.streamed = newValue }
    }
    private var harnesses: [AgentProvider: HarnessActivity] = [:]
    public var claudeActivities: [SessionActivity] {
        get { harnesses[.claude]?.activities ?? [] }
        set { harnesses[.claude, default: HarnessActivity()].activities = newValue }
    }
    public var deepseekActivities: [SessionActivity] {
        get { harnesses[.deepseek]?.activities ?? [] }
        set { harnesses[.deepseek, default: HarnessActivity()].activities = newValue }
    }
    public var codexReceivedRequests: [PendingAttentionRequest] {
        get { codex.streamedRequests }
        set { codex.streamedRequests = newValue }
    }
    public var codexLogRequests: [PendingAttentionRequest] {
        get { codex.loggedRequests }
        set { codex.loggedRequests = newValue }
    }
    public var claudeReceivedRequests: [PendingAttentionRequest] {
        get { harnesses[.claude]?.requests ?? [] }
        set { harnesses[.claude, default: HarnessActivity()].requests = newValue }
    }
    public var deepseekReceivedRequests: [PendingAttentionRequest] {
        get { harnesses[.deepseek]?.requests ?? [] }
        set { harnesses[.deepseek, default: HarnessActivity()].requests = newValue }
    }
    public var excludedCodexActivityIDs: Set<String> {
        get { codex.excludedIDs }
        set { codex.excludedIDs = newValue }
    }
    public var codexAttentionThreadIDs: Set<String> {
        get { codex.attentionThreads }
        set { codex.attentionThreads = newValue }
    }
    public var codexStreamConnected: Bool {
        get { codex.connected }
        set { codex.connected = newValue }
    }
    public var pendingCodexEndings: [String: SessionActivity] {
        get { codex.endings }
        set { codex.endings = newValue }
    }
    /// Demo source data is separate from observed data. Module switches only
    /// filter this snapshot; an I/O-isolated test can still supply observed facts.
    public var demoActivities: [SessionActivity] = []
    public var demoRequests: [PendingAttentionRequest] = []
    public var includesDemoMetadata = false
    private var attention: [AgentProvider: AttentionPolicy] = [:]
    public var codexAttention: AttentionPolicy {
        get { attention[.codex] ?? .init() }
        set { attention[.codex] = newValue }
    }
    public var claudeAttention: AttentionPolicy {
        get { attention[.claude] ?? .init() }
        set { attention[.claude] = newValue }
    }
    public var deepseekAttention: AttentionPolicy {
        get { attention[.deepseek] ?? .init() }
        set { attention[.deepseek] = newValue }
    }
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

    public mutating func replaceHarness(_ provider: AgentProvider, with snapshot: HarnessActivity) {
        if provider == .codex {
            // Codex reconciles its logged and streamed views before the shared inbox.
            codex.logged = snapshot.activities
            codex.loggedRequests = snapshot.requests
        } else { harnesses[provider] = snapshot }
    }

    public mutating func removeHarness(_ provider: AgentProvider) {
        if provider == .codex { codex = CodexActivityInput() }
        harnesses.removeValue(forKey: provider)
        attention.removeValue(forKey: provider)
        inbox.remove(provider: provider)
    }

    public func knownActivities(for provider: AgentProvider) -> [SessionActivity] {
        let incoming: [SessionActivity]
        if provider == .codex { incoming = codex.knownActivities }
        else { incoming = harnesses[provider]?.activities ?? [] }
        var values: [String: SessionActivity] = [:]
        for item in inbox.activities where item.provider == provider {
            let value = item.canonicalized()
            values[value.id] = value
        }
        let samples = includesDemoMetadata ? demoActivities.filter { $0.provider == provider } : []
        for item in samples + incoming where inbox.isSourceVisible(item.sourceHostID) {
            var value = item.canonicalized()
            if let old = values[value.id] { value.mergeDisplayMetadata(from: old) }
            values[value.id] = value
        }
        let rows = Array(values.values)
        if provider == .codex, rows.contains(where: { $0.parentThreadID != nil }) { return CodexSessionOrigin.inheriting(rows) }
        return rows
    }
    public var ignoredCodexActivityIDs: Set<String> {
        excludedCodexActivityIDs.union(knownActivities(for: .codex).filter(\.isIgnoredCodexSession).map(\.id))
    }
    public func hiddenActivityIDs(_ visibility: ActivityVisibilityOptions) -> Set<String> {
        hiddenActivityIDs(visibility, ignoring: ignoredCodexActivityIDs)
    }
    private func hiddenActivityIDs(_ visibility: ActivityVisibilityOptions, ignoring ignored: Set<String>) -> Set<String> {
        var hidden = ignored
        if !visibility.showsClaudeCloudProjects {
            hidden.formUnion(knownActivities(for: .claude).filter { $0.claudeCloud != nil }.map(\.id))
            hidden.formUnion(claudeReceivedRequests.filter { $0.claudeCloud != nil }.map { $0.activity.id })
        }
        if !visibility.embeddedProviders.contains(.codex) {
            hidden.formUnion(EmbeddedSessionVisibility.embeddedActivityIDs(knownActivities(for: .codex)))
        }
        for provider in harnesses.keys where provider != .codex && !visibility.embeddedProviders.contains(provider) {
            hidden.formUnion(EmbeddedSessionVisibility.embeddedActivityIDs(knownActivities(for: provider)))
        }
        // A retained completion may still be present before its collector's first update.
        for provider in HarnessRegistry.legacyIDs where provider != .codex && harnesses[provider] == nil && !visibility.embeddedProviders.contains(provider) {
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
        observeAttentionRequests(values, hiding: values.isEmpty ? [] : hiddenActivityIDs(visibility))
    }
    private mutating func observeAttentionRequests(_ values: [PendingAttentionRequest], hiding hidden: Set<String>) -> [IslandNotice] {
        let shown = hidden.isEmpty ? values : values.filter { !hidden.contains($0.activity.id) }
        if requests != shown { requests = shown; cachedPresentation = nil }
        if shown.isEmpty {
            for provider in Array(attention.keys) { _ = attention[provider]?.requestNotices([]) }
            return []
        }
        let grouped = Dictionary(grouping: shown, by: \.provider)
        return Set(grouped.keys).union(attention.keys).sorted(by: HarnessRegistry.orderedBefore).flatMap { provider in
            attention[provider, default: AttentionPolicy()].requestNotices(grouped[provider] ?? [])
        }
    }
    @discardableResult public mutating func reconcile(at now: Date, retention: TimeInterval, visibility: ActivityVisibilityOptions) -> ActivityApplicationUpdate {
        let ignored = ignoredCodexActivityIDs
        if !ignored.isEmpty { inbox.remove(activityIDs: ignored) }
        let codexSnapshot = codex.snapshot(inbox: inbox)
        var sourceRows = codexSnapshot.activities, sourceRequests = codexSnapshot.requests
        for provider in harnesses.keys.sorted(by: HarnessRegistry.orderedBefore) {
            guard let source = harnesses[provider] else { continue }
            sourceRows.append(contentsOf: source.activities)
            sourceRequests.append(contentsOf: source.requests)
        }
        var notices = observeAttentionRequests(sourceRequests, hiding: sourceRequests.isEmpty ? [] : hiddenActivityIDs(visibility, ignoring: ignored))
        let previous = Dictionary(activities.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        let merged = sourceRows.compactMap { row -> SessionActivity? in
            guard !ignored.contains(row.id), !row.codexGoalExpired(at: now) else { return nil }
            guard let old = previous[row.id] else { return row }
            var row = row; row.mergeDisplayMetadata(from: old)
            return row
        }
        let observed = inbox.observe(ActivityTaskGroup.make(merged).flatMap(\.members), at: now, retention: retention)
        codex.releaseVisibleEndings(inbox: inbox)
        for ending in inbox.activities where ending.claudeCloud?.readInClaude == true { inbox.dismiss(ending) }
        let hidden = hiddenActivityIDs(visibility, ignoring: ignored)
        let shown = hidden.isEmpty ? observed : observed.filter { !hidden.contains($0.id) }
        observeFirstOutputs(shown, at: now)
        let activeRoots = Set(ActivityTaskGroup.make(shown).filter(\.isRunning).map { $0.primary.id })
        let combined = shown.filter {
            !$0.isInternalReview && (activeRoots.contains($0.id) || ![.completed, .interrupted].contains($0.phase)) &&
                (activeRoots.contains($0.id) || [.running, .waitingForInput].contains($0.phase) || now.timeIntervalSince($0.lastObserved ?? .distantPast) < 900)
        } + inbox.activities.filter { !activeRoots.contains($0.id) && !hidden.contains($0.id) }
        replaceActivities(combined, at: now)
        let tasks = taskGroups().filter { !($0.isRunning && [.completed, .interrupted].contains($0.primary.phase)) }.map(\.primary)
        let grouped = Dictionary(grouping: tasks, by: \.provider)
        let activityNotices = Set(grouped.keys).union(attention.keys).sorted(by: HarnessRegistry.orderedBefore).flatMap { provider in
            attention[provider, default: AttentionPolicy()].activityNotices(grouped[provider] ?? [], at: now)
        }
        notices += AttentionPolicy.excludingPendingReplies(activityNotices, activityIDs: Set(requests.map { $0.activity.id }))
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
        guard !notices.isEmpty else { return [] }
        let hidden = hiddenActivityIDs(visibility)
        guard !hidden.isEmpty else { return notices }
        let allRequests = codexReceivedRequests + codexLogRequests + harnesses.values.flatMap(\.requests) + demoRequests
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
