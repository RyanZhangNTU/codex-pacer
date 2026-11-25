import Foundation

/// Follows Codex on SSH and WSL hosts: one owned helper per machine, started
/// over the user's own non-interactive SSH. No daemon is started, and only
/// these helpers and their SSH children are ever terminated. Local Codex is
/// read from Pacer's hook spool by `LocalActivityReader`.
public actor RealtimeActivityMonitor {
    private let services: RealtimeActivityServices
    private let retryInterval: TimeInterval
    private var retryTask: Task<Void, Never>?
    private struct Configuration { let home: URL; let includeSSH: Bool; let useSSHFallback: Bool }
    private var configuration: Configuration?
    private var discoveredTargets: [RemoteActivityTarget] = []
    private var sshMonitoring = SSHHostMonitoring()
    private struct Source: Equatable {
        let id: String
        let name: String?
        let alias: String
        let home: String
        var target: RemoteActivityTarget? = nil
        var refreshPolicy = ActivityRefreshPolicy.collapsed
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id && lhs.name == rhs.name && lhs.alias == rhs.alias && lhs.home == rhs.home && lhs.target == rhs.target
        }
    }
    private struct Connection {
        var source: Source
        let id: UUID
        let process: any ChildProcessConnection
        var buffer = Data()
        var lastFrame = Date()
        var state: RuntimeEventState
    }
    private var connections: [String: Connection] = [:]
    /// Consecutive failures per source. An unreachable host is a normal state:
    /// retries back off from the retry interval to thirty times it (30 s to 15 minutes).
    private var failureCounts: [String: Int] = [:]
    private func backoff(_ source: String) -> TimeInterval {
        let count = failureCounts[source, default: 0] + 1
        failureCounts[source] = count
        return min(retryInterval * 30, retryInterval * pow(2, Double(min(count - 1, 10))))
    }
    private var failed: [String: Source] = [:]
    private var retryAfter: [String: Date] = [:]
    private var callback: (@Sendable (RealtimeActivitySnapshot) async -> Void)?
    private var disconnected: [String: [SessionActivity]] = [:]
    private var refreshPolicy = ActivityRefreshPolicy.collapsed
    private var startGeneration = 0

    public init(services: RealtimeActivityServices, retryInterval: TimeInterval = 30) {
        self.services = services
        self.retryInterval = retryInterval.isFinite ? min(30, max(0.01, retryInterval)) : 30
    }

    public func start(home: URL, includeSSH: Bool = true, sshMonitoring: SSHHostMonitoring = .init(), useSSHFallback: Bool = true, refreshPolicy: ActivityRefreshPolicy = .collapsed,
                      update: @escaping @Sendable (RealtimeActivitySnapshot) -> Void) async {
        await startAsync(home: home, includeSSH: includeSSH, sshMonitoring: sshMonitoring, useSSHFallback: useSSHFallback, refreshPolicy: refreshPolicy) { update($0) }
    }

    public func startAsync(home: URL, includeSSH: Bool = true, sshMonitoring: SSHHostMonitoring = .init(), useSSHFallback: Bool = true, refreshPolicy: ActivityRefreshPolicy = .collapsed,
                           update: @escaping @Sendable (RealtimeActivitySnapshot) async -> Void) async {
        guard !Task.isCancelled else { return }
        self.sshMonitoring = sshMonitoring
        startGeneration += 1
        let generation = startGeneration
        if let previous = configuration, previous.home != home {
            callback = nil; configuration = nil; discoveredTargets = []; retryTask?.cancel(); retryTask = nil
            let children = connections.values.map(\.process)
            for id in Array(connections.keys) { stop(id) }
            failed = [:]; retryAfter = [:]; disconnected = [:]; failureCounts = [:]
            await ShutdownDeadline().finish(readers: [], children: children)
            for child in children where child.isRunning { child.terminateImmediately() }
            guard generation == startGeneration else { return }
        }
        configuration = Configuration(home: home, includeSSH: includeSSH, useSSHFallback: useSSHFallback)
        self.refreshPolicy = refreshPolicy
        callback = update
        guard !Task.isCancelled else { return }
        await reconcile(home: home, includeSSH: includeSSH, useSSHFallback: useSSHFallback, refreshPolicy: refreshPolicy)
    }

    private func reconcile(home: URL, includeSSH: Bool, useSSHFallback: Bool, refreshPolicy: ActivityRefreshPolicy) async {
        let generation = startGeneration
        let targets: [RemoteActivityTarget]
        if includeSSH, let discover = services.sshTargets { targets = await discover(home) }
        else { targets = includeSSH ? RemoteActivityTarget.readConfiguration(home: home) ?? [] : [] }
        guard generation == startGeneration else { return }
        discoveredTargets = targets
        await reconcileTargets(useSSHFallback: useSSHFallback, refreshPolicy: refreshPolicy)
    }

    /// A host switch uses the last discovery immediately, including while a new route lookup is suspended.
    public func updateSSHMonitoring(_ monitoring: SSHHostMonitoring, retrying: Set<String> = []) async {
        sshMonitoring = monitoring
        retryInactiveHelpers(sources: retrying)
        guard let configuration else { return }
        await reconcileTargets(useSSHFallback: configuration.useSSHFallback, refreshPolicy: refreshPolicy)
    }

    private func reconcileTargets(useSSHFallback: Bool, refreshPolicy: ActivityRefreshPolicy) async {
        let generation = startGeneration
        let monitoring = sshMonitoring
        let ssh = monitoring.monitored(discoveredTargets.filter { !$0.id.hasPrefix(ConnectionSource.wslPrefix) })
        let targets = ssh + discoveredTargets.filter { $0.id.hasPrefix(ConnectionSource.wslPrefix) }
        let sources = useSSHFallback ? targets.map {
            Source(id: $0.id, name: $0.name, alias: $0.alias, home: $0.home, target: $0, refreshPolicy: refreshPolicy)
        } : []
        let wanted = Set(sources.map(\.id))
        for (id, connection) in Array(connections) where !wanted.contains(id) || sources.first(where: { $0.id == id }) != connection.source {
            stop(id)
            disconnected.removeValue(forKey: id)
        }
        for id in Array(failed.keys) where !wanted.contains(id) { failed.removeValue(forKey: id); retryAfter.removeValue(forKey: id); disconnected.removeValue(forKey: id) }
        failureCounts = failureCounts.filter { wanted.contains($0.key) }
        disconnected = disconnected.filter { wanted.contains($0.key) }
        for (id, connection) in Array(connections) where Date().timeIntervalSince(connection.lastFrame) > 45 {
            await closed(id, identity: connection.id)
        }
        guard generation == startGeneration, monitoring == sshMonitoring else { return }
        for source in sources where connections[source.id] == nil && Date() >= (retryAfter[source.id] ?? .distantPast) { connect(source) }
        await updateRefreshPolicy(refreshPolicy)
        guard generation == startGeneration else { return }
        scheduleRetry()
        await publish()
    }

    /// Updates existing owned transports, without discovery or reconnecting.
    public func updateRefreshPolicy(_ policy: ActivityRefreshPolicy, flushPending: Bool = false) async {
        refreshPolicy = policy
        for (id, var connection) in connections where connection.source.refreshPolicy != policy || flushPending {
            if var bytes = try? JSONSerialization.data(withJSONObject: [
                "kind": "settings", "batchInterval": policy.interval, "flushPending": flushPending]) {
                bytes.append(10); try? connection.process.write(bytes)
            }
            connection.source.refreshPolicy = policy; connections[id] = connection
        }
        for id in Array(failed.keys) { failed[id]?.refreshPolicy = policy }
        if flushPending { await publish() }
    }

    public func activities() -> [SessionActivity] {
        connections.values.flatMap { $0.state.activities } + disconnected.values.flatMap { $0 }
    }

    public func statuses() -> [String: RuntimeStreamStatus] {
        var result = connections.mapValues { $0.state.status }
        for (host, connection) in connections where ConnectionSource.isManagedSSHSourceID(host) {
            result[host]?.sourceName = connection.source.name
        }
        for (host, source) in failed where result[host] == nil && ConnectionSource.isManagedSSHSourceID(host) {
            var status = RuntimeStreamStatus()
            status.sourceName = source.name
            result[host] = status
        }
        return result
    }

    public func shutdown(deadline: ShutdownDeadline = ShutdownDeadline()) async {
        let children = connections.values.map(\.process)
        startGeneration += 1; configuration = nil; discoveredTargets = []; retryTask?.cancel(); retryTask = nil
        callback = nil
        for id in Array(connections.keys) { stop(id) }
        failed = [:]; retryAfter = [:]; disconnected = [:]; failureCounts = [:]
        await deadline.finish(readers: [], children: children)
        for child in children where child.isRunning { child.terminateImmediately() }
    }

    /// A manual source retry clears only inactive helpers' backoff. Live
    /// transports and their unread/session state remain owned by this monitor.
    public func retryInactiveHelpers(sources: Set<String>? = nil) {
        for id in Array(retryAfter.keys) where connections[id] == nil && sources?.contains(id) != false {
            retryAfter.removeValue(forKey: id); failureCounts[id] = nil
        }
    }

    /// After a network change, reconnects SSH helpers that are waiting out a
    /// backoff. Live helpers and WSL keep their schedule.
    public func reconnectUnreachableSSH() async {
        guard configuration?.includeSSH == true else { return }
        let due = retryAfter.keys.filter { id in connections[id] == nil && failed[id] != nil && !id.hasPrefix(ConnectionSource.wslPrefix) }
        guard !due.isEmpty else { return }
        for id in due { retryAfter.removeValue(forKey: id); failureCounts[id] = nil }
        retryTask?.cancel(); retryTask = nil
        await retry(generation: startGeneration)
    }

    private func connect(_ source: Source) {
        let program = Data(RealtimeProbe.script.utf8).base64EncodedString()
        let encodedHome = Data(source.home.utf8).base64EncodedString()
        let command = "python3 -u -c 'import base64;exec(base64.b64decode(\"\(program)\").decode())' \(encodedHome) ssh-lifetime \(source.refreshPolicy.interval)"
        let arguments: [String]
        if let build = services.sshArguments, let target = source.target {
            guard let route = build(target) else { failed[source.id] = source; return }
            arguments = route + [command]
        } else {
            guard !ConnectionSource.isManagedSSHSourceID(source.id) else { failed[source.id] = source; return }
            arguments = ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ForwardAgent=no",
                "-o", "ClearAllForwardings=yes", "-o", "ConnectTimeout=6", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", "--", source.alias, command]
        }
        let id = UUID()
        do {
            let child = try services.processes.launch(.init(executable: services.ssh, arguments: arguments,
                environment: ProcessInfo.processInfo.environment), output: { [weak self] bytes in
                    await self?.receive(bytes, id: source.id, identity: id)
                }, ended: { [weak self] in await self?.closed(source.id, identity: id) })
            connections[source.id] = Connection(source: source, id: id, process: child,
                state: RuntimeEventState(sourceID: source.id, sourceName: source.name))
            retryAfter.removeValue(forKey: source.id)
        } catch {
            failed[source.id] = source; retryAfter[source.id] = Date().addingTimeInterval(backoff(source.id))
        }
    }

    private func receive(_ data: Data, id: String, identity: UUID) async {
        guard var connection = connections[id], connection.id == identity else { return }
        connection.buffer.append(data)
        guard connection.buffer.count <= 4 * 1024 * 1024 else { await closed(id, identity: identity); return }
        var publishFrame = false
        while let end = connection.buffer.firstIndex(of: 10) {
            let line = connection.buffer.prefix(upTo: end)
            connection.buffer.removeSubrange(...end)
            guard let frame = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            connection.lastFrame = Date()
            let kind = frame["kind"] as? String
            let recovered = failed[id] != nil || disconnected[id] != nil
            let previousStatus = connection.state.status
            let previousActivities = kind == "status" ? connection.state.activities : []
            connection.state.consume(frame)
            if services.diagnostics.enabled { services.diagnostics.record("remoteFrame", source: id, frame: frame,
                activities: connection.state.activities, status: connection.state.status) }
            failed.removeValue(forKey: id); failureCounts[id] = nil
            disconnected.removeValue(forKey: id)
            if kind == "status" {
                // Helper heartbeats carry CPU and loop counters every 15 seconds.
                if recovered || !connection.state.status.sameState(as: previousStatus) ||
                    connection.state.activities != previousActivities { publishFrame = true }
            } else if kind != "fallbackChunk" || frame["final"] as? Bool == true { publishFrame = true }
        }
        connections[id] = connection
        if publishFrame { await publish() }
    }

    private func closed(_ id: String, identity: UUID) async {
        guard let connection = connections[id], connection.id == identity else { return }
        disconnected[id] = connection.state.activities.map { value in
            var value = value
            if ![.completed, .interrupted].contains(value.phase) { value.markUnconfirmed() }
            return value
        }
        // A helper that delivered frames recovered; one that dies before its
        // first frame (an unreachable host) keeps backing off.
        failed[id] = connection.source; retryAfter[id] = Date().addingTimeInterval(backoff(id))
        stop(id); scheduleRetry(); await publish()
    }

    private func stop(_ id: String) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.process.close()
    }

    private func scheduleRetry() {
        retryTask?.cancel(); retryTask = nil
        guard configuration != nil else { return }
        let dates = retryAfter.filter { connections[$0.key] == nil }.map(\.value) + connections.values.map { $0.lastFrame.addingTimeInterval(45) }
        guard let next = dates.min() else { return }
        let generation = startGeneration
        let delay = max(0.01, min(45, next.timeIntervalSinceNow))
        retryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            await self?.retry(generation: generation)
        }
    }

    private func retry(generation: Int) async {
        guard generation == startGeneration, let config = configuration else { return }
        retryTask = nil
        await reconcile(home: config.home, includeSSH: config.includeSSH, useSSHFallback: config.useSSHFallback, refreshPolicy: refreshPolicy)
    }

    private func publish() async {
        let status = statuses()
        let down = failed.values.filter { status[$0.id]?.connected != true }
        let value = RealtimeActivitySnapshot(discoveredTargets: discoveredTargets, activities: activities(), statuses: status,
            unavailable: down.compactMap(\.name).sorted(), unavailableSources: down.map(\.id).sorted(),
            names: connections.values.flatMap { $0.state.nameUpdates },
            performance: connections.values.flatMap { $0.state.performanceUpdates })
        for id in Array(connections.keys) { connections[id]?.state.releasePublishedState() }
        // Release this captured publication before an async consumer reenters.
        await callback?(value)
    }
}

public struct RealtimeActivitySnapshot: Sendable {
    public let discoveredTargets: [RemoteActivityTarget]
    public let activities: [SessionActivity]
    public let statuses: [String: RuntimeStreamStatus]
    /// Names of failed sources that have no connected stream.
    public let unavailable: [String]
    /// The source IDs behind `unavailable`. A failed helper process leaves
    /// `statuses`, so hosts that tell SSH from WSL read these IDs.
    public let unavailableSources: [String]
    public let names: [SessionNameUpdate]
    public let performance: [SessionPerformanceUpdate]
}

/// What the monitor needs from its host: SSH routes and owned helper processes.
public struct RealtimeActivityServices: Sendable {
    public let processes: any HelperProcessLauncher
    public let ssh: URL
    public let diagnostics: RuntimeDiagnosticObserver
    public let sshTargets: (@Sendable (URL) async -> [RemoteActivityTarget])?
    public let sshArguments: (@Sendable (RemoteActivityTarget) -> [String]?)?
    public init(processes: any HelperProcessLauncher, ssh: URL, diagnostics: RuntimeDiagnosticObserver = RuntimeDiagnosticObserver(),
                sshTargets: (@Sendable (URL) async -> [RemoteActivityTarget])? = nil,
                sshArguments: (@Sendable (RemoteActivityTarget) -> [String]?)? = nil) {
        self.processes = processes; self.ssh = ssh; self.diagnostics = diagnostics
        self.sshTargets = sshTargets; self.sshArguments = sshArguments
    }
}
