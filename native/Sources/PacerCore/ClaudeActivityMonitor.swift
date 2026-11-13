import Foundation

/// Claude's local collector stays native; only configured SSH hosts receive an
/// owned Python helper, whose lifetime is tied to this actor's input pipe.
public actor ClaudeActivityMonitor {
    private let processes: any HelperProcessLauncher
    private let fileEvents: any ActivityFileEvents
    private let telemetryTransport: any TelemetryTransport
    private let files: any PlatformFileSystem
    private let clock: @Sendable () -> Date
    private let remoteMirrorSessionIDs: @Sendable (URL) -> Set<String>
    public typealias Update = @Sendable ([SessionActivity], [String: RuntimeStreamStatus], [PendingAttentionRequest], [SessionPerformanceUpdate]) async -> Void
    private var callback: Update?
    private var home: URL?
    private var localReader: ClaudeActivityReader
    private var local = ClaudeActivityState()
    private var localMirrorRoots: Set<String> = []
    private var watcher: ActivityLogWatcher?
    private var telemetry: ClaudeActivityTelemetry?
    private var localGeneration = UUID()
    private var discovery: Task<Void, Never>?
    private var catchup: Task<Void, Never>?
    /// Records arrived since ended requests last settled.
    private var localReleasePending = false
    private var pendingPublish: Task<Void, Never>?
    private var urgency = ClaudeUrgency()
    private var lastPublication: Publication?
    private var policy: ActivityRefreshPolicy = .collapsed
    private let sshExecutable: URL
    private let makeSSHArguments: @Sendable (RemoteActivityTarget) -> [String]?
    private let remoteHome: @Sendable (RemoteActivityTarget) -> String
    private let maximumRemoteTargets: Int
    private struct Connection {
        let target: RemoteActivityTarget
        let identity: UUID
        let process: any ChildProcessConnection
        var buffer = Data()
        var state: ClaudeActivityState
        var lastFrame: Date
    }
    private var connections: [String: Connection] = [:]
    private var disconnected: [String: ClaudeActivityState] = [:]
    private var wanted: [String: RemoteActivityTarget] = [:]
    private var retry: [String: Date] = [:]
    /// Polled separately, published with everything else. It outlives this
    /// actor's shutdown because cloud work continues while the Mac sleeps.
    private var cloud: (activities: [SessionActivity], status: RuntimeStreamStatus?, attention: [PendingAttentionRequest]) = ([], nil, [])
    public init(sshExecutable: URL, processes: any HelperProcessLauncher,
                fileEvents: any ActivityFileEvents, telemetryTransport: any TelemetryTransport,
                remoteMirrorSessionIDs: @escaping @Sendable (URL) -> Set<String>,
                files: any PlatformFileSystem, clock: @escaping @Sendable () -> Date,
                sshArguments: @escaping @Sendable (RemoteActivityTarget) -> [String]?,
                remoteHome: @escaping @Sendable (RemoteActivityTarget) -> String = { _ in "~/.claude" }, maximumRemoteTargets: Int = 8) {
        self.sshExecutable = sshExecutable; self.processes = processes; self.fileEvents = fileEvents
        self.telemetryTransport = telemetryTransport; self.files = files; self.clock = clock
        self.remoteMirrorSessionIDs = remoteMirrorSessionIDs
        self.makeSSHArguments = sshArguments
        self.remoteHome = remoteHome
        self.maximumRemoteTargets = min(16, max(1, maximumRemoteTargets))
        localReader = ClaudeActivityReader(files: files, clock: clock)
    }
    public func start(home: URL, remoteTargets: [RemoteActivityTarget] = [], refreshPolicy: ActivityRefreshPolicy = .collapsed,
                      retryingRemoteSources: Set<String> = [], update: @escaping Update) async {
        // A (re)start always delivers: the host may have cleared its copy.
        callback = update; policy = refreshPolicy; lastPublication = nil
        if self.home != home {
            stopLocal(); self.home = home; localReader.reset(); local = ClaudeActivityState()
            let generation = localGeneration
            watcher = ActivityLogWatcher(files: files, events: fileEvents, interval: 0.1, maximumDirectoryWatches: ClaudeActivityReader.maximumDirectoryWatches) { [weak self] discover in Task { await self?.fileChanged(discover: discover, generation: generation) } }
            let receiver = ClaudeActivityTelemetry(transport: telemetryTransport) { [weak self] bytes in Task { await self?.receiveTelemetry(bytes, generation: generation) } }
            do { try receiver.start(); telemetry = receiver } catch { receiver.stop() }
            await readLocal(discover: true, attaching: true)
            guard localGeneration == generation, self.home == home else { return }
            discovery = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    guard !Task.isCancelled else { break }
                    await self?.maintain()
                }
            }
        }
        await updateRemoteTargets(remoteTargets, retrying: retryingRemoteSources)
        updateRefreshPolicy(refreshPolicy); await publish()
    }
    /// Reconcile discovery/settings without replacing healthy local/SSH state.
    public func updateRemoteTargets(_ remoteTargets: [RemoteActivityTarget], retrying: Set<String> = []) async {
        wanted = Dictionary(remoteTargets.prefix(maximumRemoteTargets).filter { target in
            makeSSHArguments(target) != nil
        }.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        let before = Set(connections.keys).union(disconnected.keys)
        for (id, connection) in connections where wanted[id] != connection.target { stopRemote(id); disconnected.removeValue(forKey: id) }
        for id in Array(disconnected.keys) where wanted[id] == nil { disconnected.removeValue(forKey: id); retry.removeValue(forKey: id) }
        for id in retrying where wanted[id] != nil && connections[id] == nil { retry.removeValue(forKey: id); failureCounts[id] = nil }
        let started = await connectWanted()
        // Periodic reconciliation is common; publish only an actual change.
        if started || before != Set(connections.keys).union(disconnected.keys) { await publish() }
    }
    /// Explicit refresh/setup bypasses backoff only for wanted inactive hosts;
    /// healthy helpers and retained completions keep their state.
    public func refresh(remoteTargetID: String? = nil) async {
        guard home != nil else { return }
        if let id = remoteTargetID {
            guard let target = wanted[id] else { return }
            if connections[id] == nil { retry.removeValue(forKey: id); failureCounts[id] = nil; connect(target) }
        } else {
            await readLocal(discover: true)
            for id in wanted.keys where connections[id] == nil { retry.removeValue(forKey: id); failureCounts[id] = nil }
            await connectWanted()
        }
        await publish()
    }
    public func activities() -> [SessionActivity] { local.activities + connections.values.flatMap { $0.state.activities } + disconnected.values.flatMap { $0.activities } + cloud.activities }
    public func updateCloud(activities: [SessionActivity], status: RuntimeStreamStatus?, attention: [PendingAttentionRequest]) async {
        cloud = (activities, status, attention)
        if home != nil { await publish() }
    }
    /// Cached source-scoped exclusions; reading these never scans metadata.
    public func excludedLocalActivityIDs() -> Set<String> { local.excludedActivityIDs }
    func localWatchCount() async -> Int { await watcher?.activeWatchCount() ?? 0 }
    public func statuses() -> [String: RuntimeStreamStatus] {
        var result = disconnected.mapValues { $0.status }; result.merge(connections.mapValues { $0.state.status }) { _, new in new }; result["local"] = local.status
        if let status = cloud.status { result[ClaudeCloudProjectState.sourceID] = status }
        return result
    }
    /// Numeric transport diagnostics only; no bodies, paths or identifiers.
    public func diagnostics() -> [String: Int] {
        let counters = telemetry?.counters ?? ClaudeActivityTelemetry.Counters(httpRequests: 0, projectedRequests: 0, missingCorrelations: 0, rejectedRequests: 0)
        return ["localTelemetryListening": telemetry?.listeningPort == 4319 ? 1 : 0,
                "localHTTPRequests": counters.httpRequests, "localProjectedRequests": counters.projectedRequests,
            "localMissingCorrelations": counters.missingCorrelations, "localRejectedRequests": counters.rejectedRequests,
            "localUnmatchedRequests": local.unmatchedRequests,
            "remoteUnmatchedRequests": connections.values.reduce(0) { partial, value in
                let (sum, overflow) = partial.addingReportingOverflow(value.state.unmatchedRequests); return overflow ? Int.max : sum
            }]
    }
    public func updateRefreshPolicy(_ value: ActivityRefreshPolicy, flushPending: Bool = false) {
        policy = value
        for connection in connections.values {
            if var data = try? JSONSerialization.data(withJSONObject: ["kind": "settings", "batchInterval": value.interval, "flushPending": flushPending]) {
                data.append(10); try? connection.process.write(data)
            }
        }
        if flushPending { Task { await readLocal(discover: false); await publish() } }
    }
    public func shutdown(deadline: ShutdownDeadline = ShutdownDeadline()) async {
        let children = connections.values.map(\.process)
        callback = nil; lastPublication = nil; stopLocal(); home = nil
        for id in Array(connections.keys) { stopRemote(id) }
        wanted.removeAll(); disconnected.removeAll(); retry.removeAll(); localReader.reset(); local = ClaudeActivityState()
        await deadline.finish(readers: [], children: children)
    }
    public func transcriptURL(for sessionID: String) -> URL? { localReader.transcriptURL(for: sessionID) }
    private func stopLocal() {
        localGeneration = UUID()
        localMirrorRoots.removeAll()
        discovery?.cancel(); discovery = nil; catchup?.cancel(); catchup = nil; pendingPublish?.cancel(); pendingPublish = nil
        watcher?.stop(); watcher = nil; telemetry?.stop(); telemetry = nil
    }
    private func maintain() async {
        await readLocal(discover: true)
        // Rechecking recent baseline tails rides this existing minute tick.
        local.expireUnconfirmedBaseline(now: clock())
        for id in Array(connections.keys) { connections[id]?.state.expireUnconfirmedBaseline(now: clock()) }
        for (id, connection) in connections where clock().timeIntervalSince(connection.lastFrame) > 45 { closed(id, identity: connection.identity) }
        await connectWanted(); await publish()
    }
    private func readLocal(discover: Bool, attaching: Bool = false) async {
        guard let home else { return }
        if discover { refreshLocalExclusions(home: home) }
        let result = localReader.read(home: home, discover: discover, excludingSessionIDs: localMirrorRoots)
        var watchURLs = result.watchURLs
        if !discover, !result.records.isEmpty {
            let known = local.knownStartedSessionIDs
            if result.records.contains(where: { Self.startsNewSession($0, known: known) }) {
                // A Desktop context can gain its CLI UUID just after file
                // creation. Recheck once on its first prompt, not each turn.
                refreshLocalExclusions(home: home)
                let removed = localReader.excludeSessionIDs(localMirrorRoots)
                watchURLs.removeAll { removed.contains($0) }
            }
        }
        for bytes in result.records { local.consume(bytes, now: clock()) }
        // A request's blocks can straddle a read budget, so ended requests
        // settle only once the reader has caught up.
        if !result.records.isEmpty { localReleasePending = true }
        if result.caughtUp, localReleasePending { local.releaseCompletedRequests(now: clock()); localReleasePending = false }
        if result.caughtUp { local.finalizeHistoricalBaseline(now: clock()) }
        if let status = ClaudeActivityRecord.encode(["kind": "status", "connected": result.available, "watchingLogs": !watchURLs.isEmpty, "scans": localReader.scans]) { local.consume(status, now: clock()) }
        if !result.available { local.unavailable() }
        watcher?.update(watchURLs, interval: 0.1)
        if !result.caughtUp, catchup == nil {
            catchup = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { return }
                await self?.continueRead()
            }
        }
        if result.caughtUp {
            let urgent = result.records.reduce(attaching) { urgency.isUrgent($1, source: "local") || $0 }
            await schedulePublish(immediate: urgent)
        }
    }
    private func fileChanged(discover: Bool, generation: UUID) async {
        guard localGeneration == generation else { return }
        await readLocal(discover: discover)
    }
    private func refreshLocalExclusions(home: URL) {
        localMirrorRoots = remoteMirrorSessionIDs(home)
        local.setExcludedSessionIDs(localMirrorRoots)
    }
    private func continueRead() async { catchup = nil; await readLocal(discover: false) }
    private func receiveTelemetry(_ bytes: Data, generation: UUID) async {
        guard localGeneration == generation, home != nil else { return }
        local.consume(bytes, now: clock()); await schedulePublish(immediate: false)
    }
    @discardableResult private func connectWanted() async -> Bool {
        let due = wanted.values.filter { connections[$0.id] == nil && clock() >= (retry[$0.id] ?? .distantPast) }
        for target in due { connect(target) }
        return !due.isEmpty
    }
    private func connect(_ target: RemoteActivityTarget) {
        let identity = UUID()
        let program = Data(ClaudeActivityProbe.script.utf8).base64EncodedString()
        let command = "python3 -u -c 'import base64;exec(base64.b64decode(\"\(program)\").decode())' \(Data(remoteHome(target).utf8).base64EncodedString()) \(policy.interval)"
        guard let arguments = makeSSHArguments(target) else { return }
        do {
            let process = try processes.launch(ChildProcessRequest(executable: sshExecutable, arguments: arguments + [command],
                environment: ProcessInfo.processInfo.environment), output: { [weak self] bytes in
                    await self?.receiveRemote(bytes, id: target.id, identity: identity)
                }, ended: { [weak self] in await self?.remoteEOF(target.id, identity: identity) })
            connections[target.id] = Connection(target: target, identity: identity, process: process,
                state: disconnected.removeValue(forKey: target.id) ?? ClaudeActivityState(sourceID: target.id, sourceName: target.name), lastFrame: clock())
        } catch {
            retry[target.id] = clock().addingTimeInterval(backoff(target.id))
            disconnected[target.id] = ClaudeActivityState(sourceID: target.id, sourceName: target.name)
        }
    }
    /// An unreachable host is a normal state: 30 s, doubling to 15 minutes.
    /// A frame from the helper or an explicit refresh resets it.
    private var failureCounts: [String: Int] = [:]
    private func backoff(_ id: String) -> TimeInterval {
        let count = failureCounts[id, default: 0] + 1
        failureCounts[id] = count
        return min(900, 30 * pow(2, Double(min(count - 1, 10))))
    }
    private func receiveRemote(_ bytes: Data, id: String, identity: UUID) async {
        guard var connection = connections[id], connection.identity == identity else { return }
        connection.buffer.append(bytes)
        guard connection.buffer.count <= 2 * 1024 * 1024 else { closed(id, identity: identity); await publish(); return }
        var urgent = false, received = false, missingHome = false
        let previousStatus = connection.state.status
        while let end = connection.buffer.firstIndex(of: 10) {
            let frame = Data(connection.buffer.prefix(upTo: end)); connection.buffer.removeSubrange(...end)
            guard let value = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else { continue }
            connection.state.consume(frame, now: clock()); connection.lastFrame = clock(); received = true; failureCounts[id] = nil
            if value["kind"] as? String == "status" { missingHome = value["claudeHome"] as? Bool == false }
            else { urgent = urgency.isUrgent(value, source: id) || urgent }
        }
        // Heartbeats bypass batching only when the visible state changed.
        if !connection.state.status.sameState(as: previousStatus) { urgent = true }
        connections[id] = connection
        if missingHome { park(id, identity: identity); await publish(); return }
        if received { await schedulePublish(immediate: urgent) }
    }
    /// SSH works but the host has no Claude home. That is not a connection
    /// failure: release the helper and look again much later.
    private func park(_ id: String, identity: UUID) {
        guard var connection = connections[id], connection.identity == identity else { return }
        // Invalidate at the final park boundary too: lifecycle records may
        // have followed the missing-home status in the same pipe chunk.
        connection.state.sourceMissing()
        disconnected[id] = connection.state; retry[id] = clock().addingTimeInterval(1800); stopRemote(id)
    }
    private func remoteEOF(_ id: String, identity: UUID) async {
        guard connections[id]?.identity == identity else { return }
        closed(id, identity: identity); await publish()
    }
    private func closed(_ id: String, identity: UUID) {
        guard var connection = connections[id], connection.identity == identity else { return }
        connection.state.unavailable(); disconnected[id] = connection.state; retry[id] = clock().addingTimeInterval(backoff(id)); stopRemote(id)
    }
    private func stopRemote(_ id: String) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        // The host owns stdin EOF, IO cancellation and termination escalation.
        connection.process.close()
    }
    private func publish() async {
        pendingPublish?.cancel(); pendingPublish = nil
        let attention = local.attention + connections.values.flatMap { $0.state.attention } + cloud.attention
        let performance = local.performanceUpdates + connections.values.flatMap { $0.state.performanceUpdates }
        let publication = Publication(activities: activities(), statuses: statuses(), attention: attention, performance: performance)
        // Heartbeats, minute maintenance and reads of unrelated files in a
        // watched folder repeat the last publication; the host already has it.
        if let lastPublication, lastPublication.matches(publication) { return }
        lastPublication = publication
        await callback?(publication.activities, publication.statuses, attention, performance)
    }
    private struct Publication {
        let activities: [SessionActivity]
        let statuses: [String: RuntimeStreamStatus]
        let attention: [PendingAttentionRequest]
        let performance: [SessionPerformanceUpdate]
        func matches(_ other: Publication) -> Bool {
            activities == other.activities && attention == other.attention && performance == other.performance &&
                statuses.count == other.statuses.count &&
                statuses.allSatisfy { key, value in other.statuses[key].map(value.sameState(as:)) == true }
        }
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
    private static func startsNewSession(_ bytes: Data, known: Set<String>) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return false }
        let rows = value["records"] as? [[String: Any]] ?? [value]
        return rows.contains {
            $0["kind"] as? String == "prompt" && ($0["sessionId"] as? String).map { !known.contains($0) && UUID(uuidString: $0) != nil } == true
        }
    }
}

/// Which Claude records bypass the publication batch: the first reply of a
/// turn, turn and tool boundaries, self-reported progress and attention.
/// Later streaming text joins the 1 s (expanded) or 5 s (collapsed) batch.
struct ClaudeUrgency {
    private static let boundaries: Set<String> = ["prompt", "progress", "waiting", "toolStart", "toolEnd", "agentResult",
        "agentNotification", "approval", "input", "attentionCleared", "stop", "stopVerified", "failure", "interrupt",
        "subagentStart", "subagentStop", "unavailable"]
    private static let turnBoundaries: Set<String> = ["prompt", "stop", "stopVerified", "failure", "interrupt"]
    private var replying: Set<String> = []

    mutating func isUrgent(_ bytes: Data, source: String) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return false }
        return isUrgent(value, source: source)
    }
    mutating func isUrgent(_ value: [String: Any], source: String) -> Bool {
        var urgent = value["attaching"] as? Bool == true
        for row in value["records"] as? [[String: Any]] ?? [value] {
            let kind = row["kind"] as? String ?? ""
            let session = source + "\u{0}" + (row["sessionId"] as? String ?? "")
            if Self.turnBoundaries.contains(kind) { replying.remove(session) }
            if Self.boundaries.contains(kind) { urgent = true }
            else if kind == "responseDelta", replying.insert(session).inserted { urgent = true }
        }
        if replying.count > 1024 { replying.removeAll() }
        return urgent
    }
}

enum ClaudeActivityProbe {
    static var script: String { (try? String(contentsOf: Bundle.module.url(forResource: "claude_activity", withExtension: "py")!, encoding: .utf8)) ?? "" }
}
