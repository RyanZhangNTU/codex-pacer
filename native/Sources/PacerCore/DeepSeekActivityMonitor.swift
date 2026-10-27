import Foundation

/// Local spend estimate and billing provider derived from the session logs.
public struct DeepSeekLocalUsage: Equatable, Sendable {
    public let ledger: DeepSeekSpendLedger
    /// The billing provider of the newest request, such as `deepseek-account`.
    public let provider: String?
    public init(ledger: DeepSeekSpendLedger = DeepSeekSpendLedger(), provider: String? = nil) {
        self.ledger = ledger; self.provider = provider
    }
}

/// Reads DeepSeek Harness session logs on this Mac. File events drive reads;
/// a minute tick rediscovers sessions and checks open turns for a live writer.
public actor DeepSeekActivityMonitor {
    public typealias Update = @Sendable ([SessionActivity], [String: RuntimeStreamStatus], [PendingAttentionRequest],
                                         [SessionPerformanceUpdate], DeepSeekLocalUsage) async -> Void
    private var callback: Update?
    private var home: URL?
    private var reader = DeepSeekSessionReader()
    private var state = DeepSeekActivityState()
    private var baselinePending = false
    private var watcher: ActivityLogWatcher?
    private var discovery: Task<Void, Never>?
    private var catchup: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var pendingPublish: Task<Void, Never>?
    private var policy: ActivityRefreshPolicy = .collapsed
    private let liveSessions: @Sendable ([String: URL]) -> Set<String>
    public init() { liveSessions = { DeepSeekSessionLocks.held($0) } }
    init(liveSessions: @escaping @Sendable ([String: URL]) -> Set<String>) { self.liveSessions = liveSessions }

    public func start(home: URL, refreshPolicy: ActivityRefreshPolicy = .collapsed, update: @escaping Update) async {
        callback = update; policy = refreshPolicy
        guard self.home != home else { await publish(); return }
        stop(); self.home = home; reader.reset(); state = DeepSeekActivityState(); baselinePending = true
        watcher = ActivityLogWatcher(interval: 0.1, maximumDirectoryWatches: 4) { [weak self] discover in Task { await self?.read(discover: discover) } }
        await read(discover: true)
        discovery = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.maintain()
            }
        }
        await publish()
    }
    public func refresh() async { guard home != nil else { return }; await read(discover: true); await publish() }
    public func updateRefreshPolicy(_ value: ActivityRefreshPolicy, flushPending: Bool = false) {
        policy = value
        if flushPending { Task { await read(discover: false); await publish() } }
    }
    public func shutdown() async {
        callback = nil; stop(); home = nil; reader.reset(); state = DeepSeekActivityState()
    }
    private func stop() {
        discovery?.cancel(); discovery = nil; catchup?.cancel(); catchup = nil; retry?.cancel(); retry = nil
        pendingPublish?.cancel(); pendingPublish = nil; watcher?.stop(); watcher = nil
    }
    private func maintain() async {
        await read(discover: true)
        state.pruneLedger()
        // A turn quiet for a minute is live only while Harness holds its lock.
        let quiet = state.openSessions(quietFor: 60)
        if !quiet.isEmpty { state.expire(candidates: quiet, live: liveSessions(reader.lockURLs(sessions: quiet))) }
        await publish()
    }
    private func read(discover: Bool) async {
        guard let home else { return }
        let result = reader.read(home: home, discover: discover)
        for line in result.lines { state.consume(line.record, session: line.session, attaching: line.attaching) }
        state.setAvailable(result.available, watching: !result.watchURLs.isEmpty)
        if baselinePending, result.caughtUp {
            baselinePending = false
            let open = state.openSessions()
            state.finalizeHistoricalBaseline(live: open.isEmpty ? [] : liveSessions(reader.lockURLs(sessions: open)))
        }
        watcher?.update(result.watchURLs, interval: 0.1)
        if !result.caughtUp, catchup == nil {
            catchup = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { return }
                await self?.continueRead()
            }
        }
        if result.awaitingLog, retry == nil {
            retry = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.retryDiscovery()
            }
        }
        if result.caughtUp { await schedulePublish(immediate: result.lines.contains { Self.urgent($0.record.event) }) }
    }
    private func continueRead() async { catchup = nil; await read(discover: false) }
    private func retryDiscovery() async { retry = nil; await read(discover: true) }
    private func publish() async {
        pendingPublish?.cancel(); pendingPublish = nil
        let statuses = home == nil ? [:] : ["local": state.status]
        await callback?(state.activities, statuses, state.attention, state.performanceUpdates,
            DeepSeekLocalUsage(ledger: state.ledger, provider: state.latestProvider?.name))
    }
    private func schedulePublish(immediate: Bool) async {
        if immediate { await publish(); return }
        guard pendingPublish == nil else { return }
        let delay = UInt64(policy.interval * 1_000_000_000)
        pendingPublish = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.publish()
        }
    }
    private static func urgent(_ event: DeepSeekLogEvent) -> Bool {
        switch event {
        case .turnStart, .turnEnd, .toolCall, .toolResult, .approvalAsked, .approvalDecided: true
        default: false
        }
    }
}
