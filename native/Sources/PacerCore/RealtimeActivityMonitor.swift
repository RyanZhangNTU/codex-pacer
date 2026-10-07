import Foundation
import Darwin

/// Each source gets one persistent helper connection; no
/// daemon is started and only our own helper/SSH children are terminated.
public actor RealtimeActivityMonitor {
    public typealias Update = @Sendable ([SessionActivity], [String: RuntimeStreamStatus], [String]) -> Void
    public typealias AttentionUpdate = @Sendable ([SessionActivity], [String: RuntimeStreamStatus], [String], [PendingAttentionRequest]) -> Void
    public typealias MetadataUpdate = @Sendable ([SessionActivity], [String: RuntimeStreamStatus], [String], [PendingAttentionRequest], [SessionNameUpdate]) -> Void
    private struct Source: Equatable {
        let id: String
        let name: String?
        let alias: String?
        let home: String
        var desktopIPC = false
    }
    private struct Connection {
        let source: Source
        let process: Process
        let output: FileHandle
        let input: FileHandle?
        let reader: PipeChunkReader
        let continuation: AsyncStream<Data>.Continuation
        let readHandler: @Sendable (FileHandle) -> Void
        var task: Task<Void, Never>?
        var buffer = Data()
        var lastFrame = Date()
        var state: RuntimeEventState
    }
    private var connections: [String: Connection] = [:]
    private struct DesktopConnection {
        let source: Source
        let collector: NativeDesktopCollector
        let hosts: [String: String]
        let localRuntime: Bool
        let continuation: AsyncStream<Data>.Continuation
        var delivery: Task<Void, Never>?
        var states: [String: RuntimeEventState] = [:]
    }
    private var desktop: DesktopConnection?
    private var desktopRetryAfter = Date.distantPast
    private var primaryLocalIsDesktop = false
    private var attentionRequests: [String: PendingAttentionRequest] = [:]
    private var failed: [String: Source] = [:]
    private var retryAfter: [String: Date] = [:]
    private var callback: MetadataUpdate?
    private var localUnavailable = true
    private var disconnected: [String: [SessionActivity]] = [:]
    private var pendingHints: [String: Set<String>] = [:]
    public init() {}

    public func start(home: URL, includeSSH: Bool = true, useSSHFallback: Bool = true, update: @escaping Update) {
        start(home: home, includeSSH: includeSSH, useSSHFallback: useSSHFallback) { activities, status, unavailable, _ in update(activities, status, unavailable) }
    }
    public func start(home: URL, includeSSH: Bool = true, useSSHFallback: Bool = true, update: @escaping AttentionUpdate) {
        start(home: home, includeSSH: includeSSH, useSSHFallback: useSSHFallback) { activities, status, unavailable, requests, _ in
            update(activities, status, unavailable, requests)
        }
    }
    public func start(home: URL, includeSSH: Bool = true, useSSHFallback: Bool = true, update: @escaping MetadataUpdate) {
        callback = update
        let local = Source(id: "local", name: nil, alias: nil, home: home.path,
            desktopIPC: !Self.controlEndpointAvailable(home: home))
        primaryLocalIsDesktop = local.desktopIPC
        var sources: [Source] = []
        localUnavailable = !Self.localEndpointAvailable(home: home)
        if !localUnavailable && !local.desktopIPC { sources.append(local) }
        let targets = includeSSH ? RemoteActivityTarget.readConfiguration(home: home) ?? [] : []
        if includeSSH && useSSHFallback {
            sources += targets.map { Source(id: $0.id, name: $0.name, alias: $0.alias, home: $0.home) }
        }
        let names = Dictionary(targets.map { ($0.id, $0.name) }, uniquingKeysWith: { _, name in name })
        let desktopAvailable = Self.desktopEndpointAvailable(home: home)
        if let current = desktop, current.source != local || current.hosts != names || !desktopAvailable {
            desktop = nil; current.collector.stop(); current.continuation.finish(); current.delivery?.cancel()
            attentionRequests.removeAll(); desktopRetryAfter = .distantPast
        }
        if desktopAvailable && desktop == nil && Date() >= desktopRetryAfter { connectDesktop(local, hosts: names) }
        let wanted = Set(sources.map(\.id)).union(local.desktopIPC ? ["local"] : [])
        pendingHints = pendingHints.filter { wanted.contains($0.key) }
        for (id, connection) in Array(connections) where !wanted.contains(id) || sources.first(where: { $0.id == id }) != connection.source {
            stop(id)
            disconnected.removeValue(forKey: id)
        }
        for id in Array(failed.keys) where !wanted.contains(id) { failed.removeValue(forKey: id); retryAfter.removeValue(forKey: id); disconnected.removeValue(forKey: id) }
        for (id, connection) in Array(connections) where Date().timeIntervalSince(connection.lastFrame) > 45 {
            closed(id, process: connection.process)
        }
        for source in sources where connections[source.id] == nil && Date() >= (retryAfter[source.id] ?? .distantPast) { connect(source) }
        publish()
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
                result[host] = state.status
            }
        }
        if localUnavailable || (primaryLocalIsDesktop && desktop == nil) { result["local"] = RuntimeStreamStatus() }
        return result
    }
    public func shutdown() async {
        callback = nil
        if let current = desktop { desktop = nil; current.collector.stop(); current.continuation.finish(); current.delivery?.cancel() }
        attentionRequests.removeAll()
        for id in Array(connections.keys) { stop(id) }
        failed = [:]; retryAfter = [:]; disconnected = [:]; pendingHints = [:]
        try? await Task.sleep(nanoseconds: 650_000_000)
    }
    private func connectDesktop(_ source: Source, hosts: [String: String]) {
        let id = UUID()
        let frames = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let collector = NativeDesktopCollector(id: id, home: URL(fileURLWithPath: source.home), hosts: Set(hosts.keys).union(["local"]),
            localRuntime: source.desktopIPC, onFrame: { bytes in
                // Never silently keep a stream after dropping one of its frames.
                if case .dropped = frames.continuation.yield(bytes) { frames.continuation.finish() }
            }, onClosed: { frames.continuation.finish() })
        desktop = DesktopConnection(source: source, collector: collector, hosts: hosts, localRuntime: source.desktopIPC,
            continuation: frames.continuation)
        do {
            try collector.start(); failed.removeValue(forKey: source.id); disconnected.removeValue(forKey: source.id)
            desktop?.delivery = Task { [weak self] in
                for await bytes in frames.stream {
                    guard !Task.isCancelled else { break }
                    await self?.receiveDesktop(bytes, id: id)
                }
                collector.stop()
                if !Task.isCancelled { await self?.desktopClosed(id: id) }
            }
        }
        catch {
            frames.continuation.finish(); collector.stop(); desktop = nil
            desktopRetryAfter = Date().addingTimeInterval(30); if source.desktopIPC { failed[source.id] = source }
        }
    }
    private func receiveDesktop(_ bytes: Data, id: UUID) {
        guard var current = desktop, current.collector.id == id,
              let frame = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return }
        if frame["kind"] as? String == "discovery", let host = frame["hostId"] as? String, current.hosts[host] != nil,
           let ids = frame["threadIds"] as? [String], ids.count <= 32 {
            if RuntimeDiagnostics.enabled { RuntimeDiagnostics.record("desktopHint", source: host, frame: frame) }
            let valid = ids.filter { UUID(uuidString: $0) != nil }
            pendingHints[host, default: []].formUnion(valid)
            if pendingHints[host, default: []].count > 64 { pendingHints[host] = Set(pendingHints[host, default: []].sorted().suffix(64)) }
            sendHints(to: host)
            return
        } else if frame["kind"] as? String == "attention", let host = frame["hostId"] as? String,
           host == "local" || current.hosts[host] != nil,
           let thread = frame["threadId"] as? String, UUID(uuidString: thread) != nil,
           let rows = frame["requests"] as? [[String: String]], rows.count <= 64 {
            let prefix = host + ":" + thread.lowercased() + ":"
            let previous = attentionRequests
            attentionRequests = attentionRequests.filter { !$0.key.hasPrefix(prefix) }
            for row in rows {
                guard let rawID = row["id"], rawID.count <= 256,
                      let kind = row["kind"].flatMap(PendingAttentionRequest.Kind.init(rawValue:)) else { continue }
                let key = prefix + rawID
                attentionRequests[key] = previous[key].flatMap { $0.kind == kind ? $0 : nil } ?? PendingAttentionRequest(id: key, threadID: thread.lowercased(),
                    sourceHostID: host == "local" ? nil : host, sourceName: current.hosts[host], kind: kind, detectedAt: Date())
            }
        } else {
            let host = frame["hostId"] as? String ?? "local"
            guard host == "local", current.localRuntime else { return }
            var state = current.states[host] ?? RuntimeEventState(sourceID: host == "local" ? nil : host, sourceName: current.hosts[host])
            // A validated runtime frame itself establishes a live source;
            // it need not wait for the next 15-second status heartbeat.
            if frame["kind"] as? String == "runtimeBatch", !state.status.connected {
                state.consume(["kind": "status", "connected": true])
            }
            state.consume(frame); current.states[host] = state
            if state.status.connected { disconnected.removeValue(forKey: host) }
        }
        desktop = current; publish()
    }
    private func desktopClosed(id: UUID) {
        guard let current = desktop, current.collector.id == id else { return }
        for (host, state) in current.states {
            disconnected[host] = state.activities.map { value in
                var value = value
                if ![.completed, .interrupted].contains(value.phase) { value.markUnconfirmed() }
                return value
            }
        }
        if current.localRuntime { failed[current.source.id] = current.source }
        desktop = nil; desktopRetryAfter = Date().addingTimeInterval(30); publish()
    }
    public static func localEndpointAvailable(home: URL) -> Bool {
        controlEndpointAvailable(home: home) || desktopEndpointAvailable(home: home)
    }
    private static func desktopEndpointAvailable(home: URL) -> Bool {
        let directory = home.appendingPathComponent("ipc")
        let path = directory.appendingPathComponent("ipc.sock")
        for (url, type) in [(directory, FileAttributeType.typeDirectory), (path, .typeSocket)] {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attrs[.type] as? FileAttributeType == type,
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  let permissions = attrs[.posixPermissions] as? NSNumber,
                  permissions.intValue & 0o077 == 0 else { return false }
        }
        return true
    }
    private static func controlEndpointAvailable(home: URL) -> Bool {
        let path = home.appendingPathComponent("app-server-control/app-server-control.sock")
        guard let link = try? FileManager.default.attributesOfItem(atPath: path.path),
              let owner = link[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid() else { return false }
        let actual = path.resolvingSymlinksInPath()
        guard let target = try? FileManager.default.attributesOfItem(atPath: actual.path),
              target[.type] as? FileAttributeType == .typeSocket,
              (target[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let permissions = target[.posixPermissions] as? NSNumber, permissions.intValue & 0o077 == 0 else { return false }
        return true // The helper also verifies both parent directories and the WS handshake.
    }
    private func connect(_ source: Source) {
        let process = Process(), output = Pipe()
        let input = source.alias == nil ? nil : Pipe()
        let program = Data(RealtimeProbe.script.utf8).base64EncodedString()
        let encodedHome = Data(source.home.utf8).base64EncodedString()
        if let alias = source.alias {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            let command = "python3 -u -c 'import base64;exec(base64.b64decode(\"\(program)\").decode())' \(encodedHome) ssh-lifetime"
            process.arguments = ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ForwardAgent=no",
                "-o", "ClearAllForwardings=yes", "-o", "ConnectTimeout=6", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", "--", alias, command]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-u", "-c", source.desktopIPC ? DesktopEventProbe.script : RealtimeProbe.script,
                encodedHome, "socket-only"]
        }
        // Keep SSH stdin open while the owner lives. EOF lets the remote helper
        // stop immediately, even if no event would otherwise touch stdout.
        if let input { process.standardInput = input }
        else { process.standardInput = FileHandle.nullDevice }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let reader = PipeChunkReader(descriptor: output.fileHandleForReading.fileDescriptor)
        let channel = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let readHandler = reader.pausingHandler(channel.continuation)
        output.fileHandleForReading.readabilityHandler = readHandler
        do { try process.run() }
        catch {
            try? input?.fileHandleForWriting.close()
            reader.stop(); output.fileHandleForReading.readabilityHandler = nil; channel.continuation.finish()
            failed[source.id] = source; retryAfter[source.id] = Date().addingTimeInterval(30); return
        }
        var connection = Connection(source: source, process: process, output: output.fileHandleForReading,
            input: input?.fileHandleForWriting,
            reader: reader, continuation: channel.continuation, readHandler: readHandler,
            state: RuntimeEventState(sourceID: source.alias == nil ? nil : source.id, sourceName: source.name))
        connection.task = Task { [weak self] in
            for await bytes in channel.stream {
                guard !Task.isCancelled else { return }
                await self?.receive(bytes, id: source.id, process: process)
            }
            await self?.closed(source.id, process: process)
        }
        connections[source.id] = connection
        sendHints(to: source.id)
    }
    private func sendHints(to source: String) {
        guard let hints = pendingHints[source], !hints.isEmpty, let input = connections[source]?.input else { return }
        do {
            for offset in stride(from: 0, to: hints.count, by: 32) {
                let ids = Array(hints.sorted().dropFirst(offset).prefix(32))
                var bytes = try JSONSerialization.data(withJSONObject: ["kind": "discover", "threadIds": ids])
                bytes.append(10); try input.write(contentsOf: bytes)
            }
            pendingHints.removeValue(forKey: source)
        } catch { /* Retain bounded hints until the next successful connection. */ }
    }
    private func receive(_ data: Data, id: String, process: Process) {
        guard var connection = connections[id], connection.process === process else { return }
        defer {
            if let current = connections[id], current.process === process {
                current.output.readabilityHandler = current.readHandler
            }
        }
        connection.buffer.append(data)
        guard connection.buffer.count <= 4 * 1024 * 1024 else { closed(id, process: process); return }
        var publishFrame = false
        while let end = connection.buffer.firstIndex(of: 10) {
            let line = connection.buffer.prefix(upTo: end)
            connection.buffer.removeSubrange(...end)
            guard let frame = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            connection.lastFrame = Date()
            connection.state.consume(frame)
            if RuntimeDiagnostics.enabled { RuntimeDiagnostics.record("remoteFrame", source: id, frame: frame,
                activities: connection.state.activities, status: connection.state.status) }
            failed.removeValue(forKey: id)
            disconnected.removeValue(forKey: id)
            if frame["kind"] as? String != "fallbackChunk" || frame["final"] as? Bool == true { publishFrame = true }
        }
        connections[id] = connection
        if publishFrame { publish() }
    }
    private func closed(_ id: String, process: Process) {
        guard let connection = connections[id], connection.process === process else { return }
        disconnected[id] = connection.state.activities.map { value in
            var value = value
            if ![.completed, .interrupted].contains(value.phase) { value.markUnconfirmed() }
            return value
        }
        failed[id] = connection.source; retryAfter[id] = Date().addingTimeInterval(30)
        stop(id); publish()
    }
    private func stop(_ id: String) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.reader.stop(); connection.output.readabilityHandler = nil
        try? connection.input?.close()
        connection.continuation.finish(); connection.task?.cancel(); try? connection.output.close()
        if connection.process.isRunning {
            connection.process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if connection.process.isRunning { kill(connection.process.processIdentifier, SIGKILL) }
            }
        }
    }
    private func publish() {
        let status = statuses()
        let requests = attentionRequests.values.filter { request in
            guard let host = request.sourceHostID else { return true }
            return connections[host]?.state.isConfirmedIdle(thread: request.threadID) != true
        }
        let names = connections.values.flatMap { $0.state.nameUpdates } +
            (desktop?.states.values.flatMap { $0.nameUpdates } ?? [])
        callback?(activities(), status, failed.values.filter { status[$0.id]?.connected != true }.compactMap(\.name).sorted(),
                  requests.sorted { $0.detectedAt < $1.detectedAt }, names)
        if let hosts = desktop?.states.keys { for host in hosts { desktop?.states[host]?.releasePublishedState() } }
        for id in Array(connections.keys) { connections[id]?.state.releasePublishedState() }
    }
}
