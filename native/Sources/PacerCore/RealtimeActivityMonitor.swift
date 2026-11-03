import Foundation

/// Each source gets one persistent helper connection; no
/// daemon is started and only our own helper/SSH children are terminated.
public actor RealtimeActivityMonitor {
    private let services: RealtimeActivityServices
    private let retryInterval: TimeInterval
    private var retryTask: Task<Void, Never>?
    private struct Configuration { let home: URL; let includeSSH: Bool; let includeRemoteControl: Bool; let useSSHFallback: Bool }
    private var configuration: Configuration?
    public typealias Update = @Sendable ([SessionActivity], [String: RuntimeStreamStatus], [String]) -> Void
    public typealias AttentionUpdate = @Sendable ([SessionActivity], [String: RuntimeStreamStatus], [String], [PendingAttentionRequest]) -> Void
    public typealias MetadataUpdate = @Sendable ([SessionActivity], [String: RuntimeStreamStatus], [String], [PendingAttentionRequest], [SessionNameUpdate]) -> Void
    public typealias PerformanceUpdate = @Sendable ([SessionActivity], [String: RuntimeStreamStatus], [String], [PendingAttentionRequest], [SessionNameUpdate], [SessionPerformanceUpdate]) -> Void
    /// Source bindings travel with the publication, independently of transient
    /// connection status, so completion acknowledgment uses the same routes.
    public typealias SourceUpdate = @Sendable ([SessionActivity], [String: RuntimeStreamStatus], [String], [PendingAttentionRequest], [SessionNameUpdate], [SessionPerformanceUpdate], RemoteControlSourceBindings) -> Void
    private struct Source: Equatable {
        let id: String
        let name: String?
        let alias: String?
        let home: String
        var desktopIPC = false
        var refreshPolicy = ActivityRefreshPolicy.collapsed
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id && lhs.name == rhs.name && lhs.alias == rhs.alias && lhs.home == rhs.home && lhs.desktopIPC == rhs.desktopIPC
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
    private struct DesktopConnection {
        let source: Source
        let id: UUID
        let collector: any DesktopActivityChannel
        var hosts: [String: String]
        let localRuntime: Bool
        var catalog: [String: RemoteControlActivityTarget]?
        var states: [String: RuntimeEventState] = [:]
        var observedControlHosts: Set<String> = []
        var observedRuntimeHosts: Set<String> = []
        var attentionThreads: [String: Set<String>] = [:]
    }
    private var desktop: DesktopConnection?
    private var lastDesktopObservedRuntimeHosts: Set<String> = []
    private var desktopRetryAfter = Date.distantPast
    private var primaryLocalIsDesktop = false
    private var attentionRequests: [String: PendingAttentionRequest] = [:]
    private var failed: [String: Source] = [:]
    private var retryAfter: [String: Date] = [:]
    private var callback: (@Sendable (RealtimeActivitySnapshot) async -> Void)?
    private var localUnavailable = true
    private var disconnected: [String: [SessionActivity]] = [:]
    private var pendingHints: [String: Set<String>] = [:]
    private let controlCatalog: RemoteControlCatalog
    private var refreshPolicy = ActivityRefreshPolicy.collapsed
    private var startGeneration = 0
    private var knownControls: [String: RemoteControlActivityTarget]?
    private var remoteControlBindings = RemoteControlSourceBindings(hostIDs: [], authoritative: false)
    private var controlAccountScope: String?
    private var controlAuthorizationRevision: UInt64 = 0
    public init(controlCatalog: RemoteControlCatalog, services: RealtimeActivityServices, retryInterval: TimeInterval = 30) {
        self.controlCatalog = controlCatalog; self.services = services
        self.retryInterval = retryInterval.isFinite ? min(30, max(0.01, retryInterval)) : 30
    }

    public func start(home: URL, includeSSH: Bool = true, includeRemoteControl: Bool = true, useSSHFallback: Bool = true, update: @escaping Update) async {
        await start(home: home, includeSSH: includeSSH, includeRemoteControl: includeRemoteControl, useSSHFallback: useSSHFallback) { activities, status, unavailable, _ in update(activities, status, unavailable) }
    }
    public func start(home: URL, includeSSH: Bool = true, includeRemoteControl: Bool = true, useSSHFallback: Bool = true, update: @escaping AttentionUpdate) async {
        await start(home: home, includeSSH: includeSSH, includeRemoteControl: includeRemoteControl, useSSHFallback: useSSHFallback) { activities, status, unavailable, requests, _ in
            update(activities, status, unavailable, requests)
        }
    }
    public func start(home: URL, includeSSH: Bool = true, includeRemoteControl: Bool = true, useSSHFallback: Bool = true,
                      refreshPolicy: ActivityRefreshPolicy = .collapsed, update: @escaping MetadataUpdate) async {
        await start(home: home, includeSSH: includeSSH, includeRemoteControl: includeRemoteControl, useSSHFallback: useSSHFallback, refreshPolicy: refreshPolicy) { activities, status, unavailable, requests, names, _ in
            update(activities, status, unavailable, requests, names)
        }
    }
    public func start(home: URL, includeSSH: Bool = true, includeRemoteControl: Bool = true, useSSHFallback: Bool = true,
                      refreshPolicy: ActivityRefreshPolicy = .collapsed, update: @escaping PerformanceUpdate) async {
        await start(home: home, includeSSH: includeSSH, includeRemoteControl: includeRemoteControl,
            useSSHFallback: useSSHFallback, refreshPolicy: refreshPolicy) { activities, status, unavailable, requests, names, performance, _ in
            update(activities, status, unavailable, requests, names, performance)
        }
    }
    public func start(home: URL, includeSSH: Bool = true, includeRemoteControl: Bool = true, useSSHFallback: Bool = true,
                      refreshPolicy: ActivityRefreshPolicy = .collapsed, update: @escaping SourceUpdate) async {
        await startAsync(home: home, includeSSH: includeSSH, includeRemoteControl: includeRemoteControl,
            useSSHFallback: useSSHFallback, refreshPolicy: refreshPolicy) { value in
                update(value.activities, value.statuses, value.unavailable, value.attention, value.names, value.performance, value.bindings)
            }
    }
    public func startAsync(home: URL, includeSSH: Bool = true, includeRemoteControl: Bool = true, useSSHFallback: Bool = true,
                           refreshPolicy: ActivityRefreshPolicy = .collapsed,
                           update: @escaping @Sendable (RealtimeActivitySnapshot) async -> Void) async {
        startGeneration += 1
        let generation = startGeneration
        if let previous = configuration, previous.home != home {
            controlAccountScope = nil; controlAuthorizationRevision = 0
            callback = nil
            configuration = nil; retryTask?.cancel(); retryTask = nil; localCandidates = []
            let old = desktop; desktop = nil
            let children = connections.values.map(\.process)
            for id in Array(connections.keys) { stop(id) }
            attentionRequests = [:]; failed = [:]; retryAfter = [:]; disconnected = [:]; pendingHints = [:]
            desktopRetryAfter = .distantPast; lastDesktopObservedRuntimeHosts = []
            let deadline = ShutdownDeadline()
            await deadline.perform([{ await old?.collector.stop() }, { await deadline.finish(readers: [], children: children) }])
            for child in children where child.isRunning { child.terminateImmediately() }
            guard generation == startGeneration else { return }
        }
        configuration = Configuration(home: home, includeSSH: includeSSH, includeRemoteControl: includeRemoteControl, useSSHFallback: useSSHFallback)
        self.refreshPolicy = refreshPolicy
        let cached = includeRemoteControl ? await controlCatalog.cachedTargets(home: home) : nil
        guard generation == startGeneration, !Task.isCancelled else { return }
        callback = update
        await reconcile(home: home, includeSSH: includeSSH, includeRemoteControl: includeRemoteControl,
            useSSHFallback: useSSHFallback, refreshPolicy: self.refreshPolicy, catalog: cached)
        guard generation == startGeneration, !Task.isCancelled else { return }
        // Local/SSH transports and their callbacks are already live while the
        // independent device metadata request waits on RPC or the network.
        if !includeRemoteControl { await controlCatalog.shutdown(); return }
        let catalog = await controlCatalog.targets(home: home)
        guard generation == startGeneration, !Task.isCancelled else { return }
        await reconcile(home: home, includeSSH: includeSSH, includeRemoteControl: includeRemoteControl,
            useSSHFallback: useSSHFallback, refreshPolicy: self.refreshPolicy, catalog: catalog)
    }
    private func reconcile(home: URL, includeSSH: Bool, includeRemoteControl: Bool, useSSHFallback: Bool,
                           refreshPolicy: ActivityRefreshPolicy, catalog: [RemoteControlActivityTarget]?) async {
        let generation = startGeneration
        let local = Source(id: "local", name: nil, alias: nil, home: home.path,
            desktopIPC: !services.controlAvailable(home), refreshPolicy: refreshPolicy)
        let authorization = includeRemoteControl ? services.remoteControlAuthorization?(home) : nil
        let scope = includeRemoteControl ? authorization?.scope : controlAccountScope
        let revision = authorization?.revision ?? 0
        let authorizationChanged = revision != controlAuthorizationRevision || scope != controlAccountScope
        if includeRemoteControl, controlAccountScope != nil, scope != controlAccountScope {
            let old = desktop; desktop = nil
            if let local = old?.states["local"] { disconnected["local"] = local.activities.filter { [.completed, .interrupted].contains($0.phase) } }
            disconnected = disconnected.filter { !$0.key.hasPrefix(ConnectionSource.controlPrefix) }
            attentionRequests = attentionRequests.filter { $0.value.sourceHostID?.hasPrefix(ConnectionSource.controlPrefix) != true }
            pendingHints = pendingHints.filter { !$0.key.hasPrefix(ConnectionSource.controlPrefix) }
            lastDesktopObservedRuntimeHosts = lastDesktopObservedRuntimeHosts.filter { !$0.hasPrefix(ConnectionSource.controlPrefix) }
            desktopRetryAfter = .distantPast
            if let old { await ShutdownDeadline().perform([{ await old.collector.stop() }]) }
            guard generation == startGeneration else { return }
        }
        controlAccountScope = scope; controlAuthorizationRevision = revision
        primaryLocalIsDesktop = local.desktopIPC
        var sources: [Source] = []
        localUnavailable = !(services.controlAvailable(home) || services.desktopAvailable(home))
        if !localUnavailable && !local.desktopIPC { sources.append(local) }
        let targets = includeSSH ? RemoteActivityTarget.readConfiguration(home: home) ?? [] : []
        if includeSSH && useSSHFallback {
            sources += targets.map { Source(id: $0.id, name: $0.name, alias: $0.alias, home: $0.home, refreshPolicy: refreshPolicy) }
        }
        let controls = includeRemoteControl && authorization?.revoked != true ? catalog ?? RemoteControlActivityTarget.configured(home: home) : []
        remoteControlBindings = .init(hostIDs: Set(controls.map(\.id)), authoritative: !includeRemoteControl || catalog != nil || authorization?.revoked == true,
                                      accountScope: scope)
        let controlTargets = catalog.map { Dictionary($0.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new }) }
        knownControls = controlTargets
        let names = Dictionary(targets.map { ($0.id, $0.name) } + controls.map { ($0.id, $0.name) }, uniquingKeysWith: { _, name in name })
        let desktopAvailable = services.desktopAvailable(home)
        if let current = desktop, current.source != local || !desktopAvailable {
            desktop = nil
            await ShutdownDeadline().perform([{ await current.collector.stop() }])
            guard generation == startGeneration else { return }
            attentionRequests.removeAll(); desktopRetryAfter = .distantPast
        }
        if var current = desktop, Set(current.hosts.keys) != Set(names.keys) || authorizationChanged {
            let allowed = Set(names.keys).union(["local"])
            for (host, state) in current.states where !allowed.contains(host) {
                disconnected[host] = state.activities.filter { [.completed, .interrupted].contains($0.phase) }
            }
            current.states = current.states.filter { allowed.contains($0.key) }
            current.observedControlHosts.formIntersection(allowed)
            current.observedRuntimeHosts.formIntersection(allowed)
            current.attentionThreads = current.attentionThreads.filter { allowed.contains($0.key) }
            attentionRequests = attentionRequests.filter { allowed.contains($0.value.sourceHostID ?? "local") }
            desktop = current
            await current.collector.setHosts(allowed)
            guard generation == startGeneration else { return }
        }
        desktop?.hosts = names; desktop?.catalog = controlTargets
        if desktopAvailable && desktop == nil && Date() >= desktopRetryAfter { await connectDesktop(local, hosts: names, catalog: controlTargets) }
        guard generation == startGeneration else { return }
        let wanted = Set(sources.map(\.id)).union(local.desktopIPC ? ["local"] : [])
        pendingHints = pendingHints.filter { wanted.contains($0.key) }
        for (id, connection) in Array(connections) where !wanted.contains(id) || sources.first(where: { $0.id == id }) != connection.source {
            stop(id)
            disconnected.removeValue(forKey: id)
        }
        for id in Array(failed.keys) where !wanted.contains(id) { failed.removeValue(forKey: id); retryAfter.removeValue(forKey: id); disconnected.removeValue(forKey: id) }
        for (id, connection) in Array(connections) where Date().timeIntervalSince(connection.lastFrame) > 45 {
            await closed(id, identity: connection.id)
        }
        for source in sources where connections[source.id] == nil && Date() >= (retryAfter[source.id] ?? .distantPast) { connect(source) }
        await updateRefreshPolicy(refreshPolicy)
        guard generation == startGeneration else { return }
        scheduleRetry()
        await publish()
    }
    /// Updates existing owned transports, without discovery or reconnecting.
    public func updateRefreshPolicy(_ policy: ActivityRefreshPolicy, flushPending: Bool = false) async {
        let generation = startGeneration
        refreshPolicy = policy
        await desktop?.collector.setBatchInterval(policy.interval, flushPending: flushPending)
        guard generation == startGeneration else { return }
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
        ActivitySourceMerger.merge(
            logged: connections.values.flatMap { $0.state.activities } + disconnected.values.flatMap { $0 },
            streamed: desktop?.states.values.flatMap { $0.activities } ?? [])
    }
    public func statuses() -> [String: RuntimeStreamStatus] {
        var result = connections.mapValues { $0.state.status }
        if let desktop {
            for (host, state) in desktop.states where state.status.connected || result[host] == nil {
                // Saved routes are fallback discovery hints, not device entries.
                // A catalog failure cannot revive deleted hosts in Settings.
                if host.hasPrefix("remote-control:"), desktop.catalog == nil,
                   !desktop.observedControlHosts.contains(host), !state.status.connected { continue }
                var status = state.status
                status.sourceName = desktop.hosts[host]
                status.remoteHostOnline = desktop.catalog?[host]?.online
                result[host] = status
            }
        }
        for (host, target) in knownControls ?? [:] where result[host] == nil {
            var status = RuntimeStreamStatus()
            status.sourceName = target.name; status.remoteHostOnline = target.online
            result[host] = status
        }
        if localUnavailable || (primaryLocalIsDesktop && desktop == nil) { result["local"] = RuntimeStreamStatus() }
        return result
    }
    public func shutdown(deadline: ShutdownDeadline = ShutdownDeadline()) async {
        let children = connections.values.map(\.process)
        startGeneration += 1; configuration = nil; retryTask?.cancel(); retryTask = nil
        callback = nil
        let old = desktop; desktop = nil
        attentionRequests.removeAll()
        for id in Array(connections.keys) { stop(id) }
        failed = [:]; retryAfter = [:]; disconnected = [:]; pendingHints = [:]
        localCandidates = []
        knownControls = nil; desktopRetryAfter = .distantPast
        lastDesktopObservedRuntimeHosts = []
        remoteControlBindings = .init(hostIDs: [], authoritative: false)
        let catalog = controlCatalog
        await deadline.perform([
            { await old?.collector.stop() },
            { await catalog.shutdown(deadline: deadline) },
            { await deadline.finish(readers: [], children: children) }
        ])
        for child in children where child.isRunning { child.terminateImmediately() }
    }
    public func invalidateRemoteControlCatalog(retryTransport: Bool = false) async {
        if retryTransport { desktopRetryAfter = .distantPast }
        await controlCatalog.invalidate()
    }
    private func connectDesktop(_ source: Source, hosts: [String: String], catalog: [String: RemoteControlActivityTarget]?) async {
        let id = UUID()
        let collector = services.makeDesktop(URL(fileURLWithPath: source.home), Set(hosts.keys).union(["local"]),
            source.desktopIPC, source.refreshPolicy.interval, { [weak self] bytes in
                await self?.receiveDesktop(bytes, id: id)
            }, { [weak self] in await self?.desktopClosed(id: id) })
        desktop = DesktopConnection(source: source, id: id, collector: collector, hosts: hosts,
            localRuntime: source.desktopIPC, catalog: catalog)
        lastDesktopObservedRuntimeHosts = []
        // A new authenticated pipe cannot reuse an old pipe's runtime evidence.
        disconnected.removeValue(forKey: source.id)
        do {
            try await collector.start()
            guard desktop?.id == id else { await collector.stop(); return }
            failed.removeValue(forKey: source.id)
            await collector.discover(localCandidates)
        } catch {
            guard desktop?.id == id else { await collector.stop(); return }
            desktop = nil; await collector.stop()
            desktopRetryAfter = Date().addingTimeInterval(retryInterval)
            if source.desktopIPC { failed[source.id] = source }
        }
    }
    private func receiveDesktop(_ bytes: Data, id: UUID) async {
        guard var current = desktop, current.id == id,
              let frame = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return }
        if frame["kind"] as? String == "discovery", let host = frame["hostId"] as? String, current.hosts[host] != nil,
           let ids = frame["threadIds"] as? [String], ids.count <= 32 {
            if services.diagnostics.enabled { services.diagnostics.record("desktopHint", source: host, frame: frame) }
            let valid = ids.filter { UUID(uuidString: $0) != nil }
            pendingHints[host, default: []].formUnion(valid)
            if pendingHints[host, default: []].count > 64 { pendingHints[host] = Set(pendingHints[host, default: []].sorted().suffix(64)) }
            sendHints(to: host)
            return
        } else if frame["kind"] as? String == "attention", let host = frame["hostId"] as? String,
           host == "local" || current.hosts[host] != nil,
           let thread = frame["threadId"] as? String, UUID(uuidString: thread) != nil,
           let rows = frame["requests"] as? [[String: String]], rows.count <= 64 {
            let thread = thread.lowercased()
            guard current.attentionThreads[host, default: []].count < 256 || current.attentionThreads[host, default: []].contains(thread) else { return }
            current.attentionThreads[host, default: []].insert(thread)
            let prefix = host + ":" + thread + ":"
            let previous = attentionRequests
            attentionRequests = attentionRequests.filter { !$0.key.hasPrefix(prefix) }
            for row in rows {
                guard let rawID = row["id"], rawID.count <= 256,
                      let kind = row["kind"].flatMap(PendingAttentionRequest.Kind.init(rawValue:)) else { continue }
                let key = prefix + rawID
                let question = row["questionKey"].flatMap { value in
                    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } ? value : nil
                }
                attentionRequests[key] = previous[key].flatMap { $0.kind == kind && $0.questionKey == question ? $0 : nil } ?? PendingAttentionRequest(id: key, threadID: thread.lowercased(),
                    sourceHostID: host == "local" ? nil : host, sourceName: current.hosts[host], kind: kind, detectedAt: Date(), questionKey: question)
            }
        } else {
            let host = frame["hostId"] as? String ?? "local"
            guard host == "local" ? current.localRuntime : current.hosts[host] != nil && host.hasPrefix("remote-control:") else { return }
            var state = current.states[host] ?? RuntimeEventState(sourceID: host == "local" ? nil : host, sourceName: current.hosts[host])
            if host.hasPrefix("remote-control:"), ["runtimeBatch", "streamInvalidated"].contains(frame["kind"] as? String ?? "") {
                current.observedControlHosts.insert(host)
            }
            // A validated runtime frame itself establishes a live source;
            // it need not wait for the next 15-second status heartbeat.
            if frame["kind"] as? String == "runtimeBatch", !state.status.connected {
                state.consume(["kind": "status", "connected": true])
            }
            state.consume(frame); current.states[host] = state
            if state.status.connected { disconnected.removeValue(forKey: host) }
        }
        let host = frame["hostId"] as? String ?? "local"
        if current.states[host]?.activities.contains(where: \.hasLiveEvidence) == true ||
            attentionRequests.values.contains(where: { ($0.sourceHostID ?? "local") == host }) {
            current.observedRuntimeHosts.insert(host)
        }
        desktop = current; await publish()
    }
    private func desktopClosed(id: UUID) async {
        guard let current = desktop, current.id == id else { return }
        for (host, state) in current.states {
            disconnected[host] = state.activities.map { value in
                var value = value
                if ![.completed, .interrupted].contains(value.phase) { value.markUnconfirmed() }
                return value
            }
        }
        if current.localRuntime { failed[current.source.id] = current.source }
        lastDesktopObservedRuntimeHosts = current.observedRuntimeHosts
        desktop = nil
        desktopRetryAfter = Date().addingTimeInterval(retryInterval); scheduleRetry(); await publish()
    }
    private func connect(_ source: Source) {
        let executable: URL, arguments: [String]
        let program = Data(RealtimeProbe.script.utf8).base64EncodedString()
        let encodedHome = Data(source.home.utf8).base64EncodedString()
        if let alias = source.alias {
            executable = services.ssh
            let command = "python3 -u -c 'import base64;exec(base64.b64decode(\"\(program)\").decode())' \(encodedHome) ssh-lifetime \(source.refreshPolicy.interval)"
            arguments = ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ForwardAgent=no",
                "-o", "ClearAllForwardings=yes", "-o", "ConnectTimeout=6", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", "--", alias, command]
        } else {
            executable = services.python
            arguments = ["-u", "-c", source.desktopIPC ? DesktopEventProbe.script : RealtimeProbe.script,
                encodedHome, "socket-only", String(source.refreshPolicy.interval), "control"]
        }
        let id = UUID()
        do {
            let child = try services.processes.launch(.init(executable: executable, arguments: arguments,
                environment: ProcessInfo.processInfo.environment), output: { [weak self] bytes in
                    await self?.receive(bytes, id: source.id, identity: id)
                }, ended: { [weak self] in await self?.closed(source.id, identity: id) })
            connections[source.id] = Connection(source: source, id: id, process: child,
                state: RuntimeEventState(sourceID: source.alias == nil ? nil : source.id, sourceName: source.name))
            retryAfter.removeValue(forKey: source.id)
            sendHints(to: source.id)
        } catch {
            failed[source.id] = source; retryAfter[source.id] = Date().addingTimeInterval(retryInterval)
        }
    }
    private func sendHints(to source: String) {
        guard let hints = pendingHints[source], !hints.isEmpty, let input = connections[source]?.process else { return }
        do {
            for offset in stride(from: 0, to: hints.count, by: 32) {
                let ids = Array(hints.sorted().dropFirst(offset).prefix(32))
                var bytes = try JSONSerialization.data(withJSONObject: ["kind": "discover", "threadIds": ids])
                bytes.append(10); try input.write(bytes)
            }
            pendingHints.removeValue(forKey: source)
        } catch { /* Retain bounded hints until the next successful connection. */ }
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
            connection.state.consume(frame)
            if services.diagnostics.enabled { services.diagnostics.record("remoteFrame", source: id, frame: frame,
                activities: connection.state.activities, status: connection.state.status) }
            failed.removeValue(forKey: id)
            disconnected.removeValue(forKey: id)
            if frame["kind"] as? String != "fallbackChunk" || frame["final"] as? Bool == true { publishFrame = true }
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
        failed[id] = connection.source; retryAfter[id] = Date().addingTimeInterval(retryInterval)
        stop(id); scheduleRetry(); await publish()
    }
    private func stop(_ id: String) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.process.close()
    }
    private var localCandidates: [String] = []
    /// Candidates remain bounded metadata; the host must authorize each follow.
    public func discover(_ candidates: [String]) async {
        localCandidates = Array(Set(candidates.compactMap { UUID(uuidString: $0)?.uuidString.lowercased() })).sorted().prefix(256).map { $0 }
        await desktop?.collector.discover(localCandidates)
    }
    private func scheduleRetry() {
        retryTask?.cancel(); retryTask = nil
        guard let config = configuration else { return }
        var dates = retryAfter.filter { connections[$0.key] == nil }.map(\.value)
        if desktop == nil, services.desktopAvailable(config.home) { dates.append(max(Date().addingTimeInterval(0.01), desktopRetryAfter)) }
        dates += connections.values.map { $0.lastFrame.addingTimeInterval(45) }
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
        let controls = config.includeRemoteControl ? await controlCatalog.cachedTargets(home: config.home) : nil
        guard generation == startGeneration else { return }
        await reconcile(home: config.home, includeSSH: config.includeSSH, includeRemoteControl: config.includeRemoteControl,
            useSSHFallback: config.useSSHFallback, refreshPolicy: refreshPolicy, catalog: controls)
    }
    private func publish() async {
        let status = statuses()
        let requests = attentionRequests.values.filter { request in
            guard let host = request.sourceHostID else { return true }
            return connections[host]?.state.isConfirmedIdle(thread: request.threadID) != true
        }
        let names = connections.values.flatMap { $0.state.nameUpdates } +
            (desktop?.states.values.flatMap { $0.nameUpdates } ?? [])
        let value = RealtimeActivitySnapshot(activities: activities(), statuses: status,
            unavailable: failed.values.filter { status[$0.id]?.connected != true }.compactMap(\.name).sorted(),
            attention: requests.sorted { $0.detectedAt < $1.detectedAt }, names: names,
            performance: connections.values.flatMap { $0.state.performanceUpdates } + (desktop?.states.values.flatMap { $0.performanceUpdates } ?? []),
            bindings: remoteControlBindings, attentionThreads: desktop?.attentionThreads["local"] ?? [],
            observedRuntimeHosts: desktop?.observedRuntimeHosts ?? lastDesktopObservedRuntimeHosts)
        if let hosts = desktop?.states.keys { for host in hosts { desktop?.states[host]?.releasePublishedState() } }
        for id in Array(connections.keys) { connections[id]?.state.releasePublishedState() }
        // Release this captured publication before an async consumer reenters.
        await callback?(value)
    }
}

public struct RealtimeActivitySnapshot: Sendable {
    public let activities: [SessionActivity]
    public let statuses: [String: RuntimeStreamStatus]
    public let unavailable: [String]
    public let attention: [PendingAttentionRequest]
    public let names: [SessionNameUpdate]
    public let performance: [SessionPerformanceUpdate]
    public let bindings: RemoteControlSourceBindings
    public let attentionThreads: Set<String>
    public let observedRuntimeHosts: Set<String>
    /// The engine protocol distinguishes runtime evidence from pipe readiness.
    public var localDesktopStatus: RuntimeStreamStatus {
        var status = statuses["local"] ?? RuntimeStreamStatus()
        status.sourceAvailable = observedRuntimeHosts.contains("local")
        return status
    }
    public var localDesktopAttention: [PendingAttentionRequest] {
        attention.filter { $0.sourceHostID == nil && attentionThreads.contains($0.threadID) }
    }
}
