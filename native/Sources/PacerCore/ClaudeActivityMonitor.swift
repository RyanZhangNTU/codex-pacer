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
    private var pendingPublish: Task<Void, Never>?
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
    public func start(home: URL, remoteTargets: [RemoteActivityTarget] = [], refreshPolicy: ActivityRefreshPolicy = .collapsed, update: @escaping Update) async {
        callback = update; policy = refreshPolicy
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
        await updateRemoteTargets(remoteTargets)
        updateRefreshPolicy(refreshPolicy); await publish()
    }
    /// Reconcile discovery/settings without replacing healthy local/SSH state.
    public func updateRemoteTargets(_ remoteTargets: [RemoteActivityTarget]) async {
        wanted = Dictionary(remoteTargets.prefix(maximumRemoteTargets).filter { target in
            makeSSHArguments(target) != nil
        }.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        let before = Set(connections.keys).union(disconnected.keys)
        for (id, connection) in connections where wanted[id] != connection.target { stopRemote(id); disconnected.removeValue(forKey: id) }
        for id in Array(disconnected.keys) where wanted[id] == nil { disconnected.removeValue(forKey: id); retry.removeValue(forKey: id) }
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
            if connections[id] == nil { retry.removeValue(forKey: id); connect(target) }
        } else {
            await readLocal(discover: true)
            for id in wanted.keys where connections[id] == nil { retry.removeValue(forKey: id) }
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
        callback = nil; stopLocal(); home = nil
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
        if result.caughtUp { await schedulePublish(immediate: attaching || result.records.contains(where: Self.urgent)) }
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
            retry[target.id] = clock().addingTimeInterval(30)
            disconnected[target.id] = ClaudeActivityState(sourceID: target.id, sourceName: target.name)
        }
    }
    private func receiveRemote(_ bytes: Data, id: String, identity: UUID) async {
        guard var connection = connections[id], connection.identity == identity else { return }
        connection.buffer.append(bytes)
        guard connection.buffer.count <= 2 * 1024 * 1024 else { closed(id, identity: identity); await publish(); return }
        var urgent = false, received = false, missingHome = false
        while let end = connection.buffer.firstIndex(of: 10) {
            let frame = Data(connection.buffer.prefix(upTo: end)); connection.buffer.removeSubrange(...end)
            guard let value = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else { continue }
            connection.state.consume(frame, now: clock()); connection.lastFrame = clock(); received = true
            urgent = urgent || Self.urgent(value)
            if value["kind"] as? String == "status" { missingHome = value["claudeHome"] as? Bool == false }
        }
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
        connection.state.unavailable(); disconnected[id] = connection.state; retry[id] = clock().addingTimeInterval(30); stopRemote(id)
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
        await callback?(activities(), statuses(), attention, performance)
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
    private static func urgent(_ bytes: Data) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return false }
        return urgent(value)
    }
    private static func urgent(_ value: [String: Any]) -> Bool {
        if value["kind"] as? String == "status" { return true }
        if value["attaching"] as? Bool == true { return true }
        let rows = value["records"] as? [[String: Any]] ?? [value]
        return rows.contains { ["prompt", "responseDelta", "toolStart", "toolEnd", "agentResult", "agentNotification", "approval", "input", "attentionCleared", "stop", "stopVerified", "failure", "interrupt", "subagentStart", "subagentStop", "unavailable"].contains($0["kind"] as? String ?? "") }
    }
    private static func startsNewSession(_ bytes: Data, known: Set<String>) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return false }
        let rows = value["records"] as? [[String: Any]] ?? [value]
        return rows.contains {
            $0["kind"] as? String == "prompt" && ($0["sessionId"] as? String).map { !known.contains($0) && UUID(uuidString: $0) != nil } == true
        }
    }
}

enum ClaudeActivityProbe {
    static var script: String { (try? String(contentsOf: Bundle.module.url(forResource: "claude_activity", withExtension: "py")!, encoding: .utf8)) ?? "" }
}
