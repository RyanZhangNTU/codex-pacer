import Foundation
import Darwin

/// Claude's local collector stays native; only configured SSH hosts receive an
/// owned Python helper, whose lifetime is tied to this actor's input pipe.
public actor ClaudeActivityMonitor {
    public typealias Update = @Sendable ([SessionActivity], [String: RuntimeStreamStatus], [PendingAttentionRequest], [SessionPerformanceUpdate]) async -> Void
    private var callback: Update?
    private var home: URL?
    private var localReader = ClaudeActivityReader()
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
    private struct Connection {
        let target: RemoteActivityTarget
        let process: Process
        let input: FileHandle
        let output: FileHandle
        let reader: PipeChunkReader
        let continuation: AsyncStream<Data>.Continuation
        let readHandler: @Sendable (FileHandle) -> Void
        var task: Task<Void, Never>?
        var buffer = Data()
        var state: ClaudeActivityState
        var lastFrame = Date()
    }
    private var connections: [String: Connection] = [:]
    private var disconnected: [String: ClaudeActivityState] = [:]
    private var wanted: [String: RemoteActivityTarget] = [:]
    private var retry: [String: Date] = [:]
    public init() { sshExecutable = URL(fileURLWithPath: "/usr/bin/ssh") }
    init(sshExecutable: URL) { self.sshExecutable = sshExecutable }
    public func start(home: URL, remoteTargets: [RemoteActivityTarget] = [], refreshPolicy: ActivityRefreshPolicy = .collapsed, update: @escaping Update) async {
        callback = update; policy = refreshPolicy
        if self.home != home {
            stopLocal(); self.home = home; localReader.reset(); local = ClaudeActivityState()
            watcher = ActivityLogWatcher(interval: 0.1, maximumDirectoryWatches: ClaudeActivityReader.maximumDirectoryWatches) { [weak self] discover in Task { await self?.readLocal(discover: discover) } }
            let generation = localGeneration
            let receiver = ClaudeActivityTelemetry { [weak self] bytes in Task { await self?.receiveTelemetry(bytes, generation: generation) } }
            do { try receiver.start(); telemetry = receiver } catch { receiver.stop() }
            await readLocal(discover: true, attaching: true)
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
        wanted = Dictionary(remoteTargets.prefix(8).filter { target in
            target.alias.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,128}\z"#, options: .regularExpression) != nil
        }.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for (id, connection) in connections where wanted[id] != connection.target { stopRemote(id); disconnected.removeValue(forKey: id) }
        for id in Array(disconnected.keys) where wanted[id] == nil { disconnected.removeValue(forKey: id); retry.removeValue(forKey: id) }
        await connectWanted(); await publish()
    }
    public func activities() -> [SessionActivity] { local.activities + connections.values.flatMap { $0.state.activities } + disconnected.values.flatMap { $0.activities } }
    /// Cached source-scoped exclusions; reading these never scans metadata.
    public func excludedLocalActivityIDs() -> Set<String> { local.excludedActivityIDs }
    func localWatchCount() async -> Int { await watcher?.activeWatchCount() ?? 0 }
    public func statuses() -> [String: RuntimeStreamStatus] {
        var result = disconnected.mapValues { $0.status }; result.merge(connections.mapValues { $0.state.status }) { _, new in new }; result["local"] = local.status
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
                data.append(10); try? connection.input.write(contentsOf: data)
            }
        }
        if flushPending { Task { await readLocal(discover: false); await publish() } }
    }
    public func shutdown() async {
        callback = nil; stopLocal(); home = nil
        for id in Array(connections.keys) { stopRemote(id) }
        wanted.removeAll(); disconnected.removeAll(); retry.removeAll(); localReader.reset(); local = ClaudeActivityState()
    }
    private func stopLocal() {
        localGeneration = UUID()
        localMirrorRoots.removeAll()
        discovery?.cancel(); discovery = nil; catchup?.cancel(); catchup = nil; pendingPublish?.cancel(); pendingPublish = nil
        watcher?.stop(); watcher = nil; telemetry?.stop(); telemetry = nil
    }
    private func maintain() async {
        await readLocal(discover: true)
        for (id, connection) in connections where Date().timeIntervalSince(connection.lastFrame) > 45 { closed(id, process: connection.process) }
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
        for bytes in result.records { local.consume(bytes) }
        if result.caughtUp { local.finalizeHistoricalBaseline() }
        if let status = ClaudeActivityRecord.encode(["kind": "status", "connected": result.available, "watchingLogs": !watchURLs.isEmpty, "scans": localReader.scans]) { local.consume(status) }
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
    private func refreshLocalExclusions(home: URL) {
        localMirrorRoots = ClaudeApplicationResolver.remoteMirrorSessionIDs(claudeHome: home)
        local.setExcludedSessionIDs(localMirrorRoots)
    }
    private func continueRead() async { catchup = nil; await readLocal(discover: false) }
    private func receiveTelemetry(_ bytes: Data, generation: UUID) async {
        guard localGeneration == generation, home != nil else { return }
        local.consume(bytes); await schedulePublish(immediate: false)
    }
    private func connectWanted() async {
        for target in wanted.values where connections[target.id] == nil && Date() >= (retry[target.id] ?? .distantPast) { connect(target) }
    }
    private func connect(_ target: RemoteActivityTarget) {
        let process = Process(), input = Pipe(), output = Pipe()
        let program = Data(ClaudeActivityProbe.script.utf8).base64EncodedString()
        let command = "python3 -u -c 'import base64;exec(base64.b64decode(\"\(program)\").decode())' \(Data("~/.claude".utf8).base64EncodedString()) \(policy.interval)"
        process.executableURL = sshExecutable
        process.arguments = ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes", "-o", "ConnectTimeout=6", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", "--", target.alias, command]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        // OS readiness callbacks read available bytes without occupying Swift's
        // cooperative executor while a quiet SSH pipe waits for a heartbeat.
        // Rearming only after actor consumption keeps ordered backpressure.
        let reader = PipeChunkReader(descriptor: output.fileHandleForReading.fileDescriptor)
        let channel = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let readHandler = reader.pausingHandler(channel.continuation)
        output.fileHandleForReading.readabilityHandler = readHandler
        do { try process.run() }
        catch {
            reader.stop(); output.fileHandleForReading.readabilityHandler = nil; channel.continuation.finish()
            try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
            retry[target.id] = Date().addingTimeInterval(30); disconnected[target.id] = ClaudeActivityState(sourceID: target.id, sourceName: target.name); return
        }
        var connection = Connection(target: target, process: process, input: input.fileHandleForWriting, output: output.fileHandleForReading,
            reader: reader, continuation: channel.continuation, readHandler: readHandler,
            state: disconnected.removeValue(forKey: target.id) ?? ClaudeActivityState(sourceID: target.id, sourceName: target.name))
        connection.task = Task { [weak self] in
            for await bytes in channel.stream {
                guard !Task.isCancelled else { return }
                await self?.receiveRemote(bytes, id: target.id, process: process)
            }
            await self?.remoteEOF(target.id, process: process)
        }
        connections[target.id] = connection
    }
    private func receiveRemote(_ bytes: Data, id: String, process: Process) async {
        guard var connection = connections[id], connection.process === process else { return }
        defer {
            if let current = connections[id], current.process === process { current.output.readabilityHandler = current.readHandler }
        }
        connection.buffer.append(bytes)
        guard connection.buffer.count <= 2 * 1024 * 1024 else { closed(id, process: process); await publish(); return }
        var urgent = false, received = false
        while let end = connection.buffer.firstIndex(of: 10) {
            let frame = Data(connection.buffer.prefix(upTo: end)); connection.buffer.removeSubrange(...end)
            guard let value = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else { continue }
            connection.state.consume(frame); connection.lastFrame = Date(); received = true
            urgent = urgent || Self.urgent(value)
        }
        connections[id] = connection
        if received { await schedulePublish(immediate: urgent) }
    }
    private func remoteEOF(_ id: String, process: Process) async { closed(id, process: process); await publish() }
    private func closed(_ id: String, process: Process) {
        guard var connection = connections[id], connection.process === process else { return }
        connection.state.unavailable(); disconnected[id] = connection.state; retry[id] = Date().addingTimeInterval(30); stopRemote(id)
    }
    private func stopRemote(_ id: String) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        // EOF first allows the remote helper to close its listener and watches.
        try? connection.input.close(); connection.reader.stop(); connection.output.readabilityHandler = nil
        connection.continuation.finish(); connection.task?.cancel(); try? connection.output.close()
        if connection.process.isRunning {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if connection.process.isRunning { connection.process.terminate() }
            }
        }
    }
    private func publish() async {
        pendingPublish?.cancel(); pendingPublish = nil
        let attention = local.attention + connections.values.flatMap { $0.state.attention }
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
