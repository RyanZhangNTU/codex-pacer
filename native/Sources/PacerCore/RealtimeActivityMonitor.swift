import Foundation
import Darwin

/// Opt-in experiment. Each source gets one persistent helper connection; no
/// daemon is started and only our own helper/SSH children are terminated.
public actor RealtimeActivityMonitor {
    public typealias Update = @Sendable ([SessionActivity], [String: RuntimeStreamStatus], [String]) -> Void
    private struct Source: Equatable {
        let id: String
        let name: String?
        let alias: String?
        let home: String
    }
    private struct Connection {
        let source: Source
        let process: Process
        let output: FileHandle
        let reader: PipeChunkReader
        let continuation: AsyncStream<Data>.Continuation
        var task: Task<Void, Never>?
        var buffer = Data()
        var lastFrame = Date()
        var state: RuntimeEventState
    }
    private var connections: [String: Connection] = [:]
    private var failed: [String: Source] = [:]
    private var retryAfter: [String: Date] = [:]
    private var callback: Update?
    private var localUnavailable = true
    private var disconnected: [String: [SessionActivity]] = [:]
    public init() {}

    public func start(home: URL, includeSSH: Bool = true, update: @escaping Update) {
        callback = update
        let local = Source(id: "local", name: nil, alias: nil, home: home.path)
        var sources: [Source] = []
        localUnavailable = !Self.localEndpointAvailable(home: home)
        if !localUnavailable { sources.append(local) }
        if includeSSH {
            guard let targets = RemoteActivityTarget.readConfiguration(home: home) else { publish(); return }
            sources += targets.map { Source(id: $0.id, name: $0.name, alias: $0.alias, home: $0.home) }
        }
        let wanted = Set(sources.map(\.id))
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
    public func activities() -> [SessionActivity] { connections.values.flatMap { $0.state.activities } + disconnected.values.flatMap { $0 } }
    public func statuses() -> [String: RuntimeStreamStatus] {
        var result = connections.mapValues { $0.state.status }
        if localUnavailable { result["local"] = RuntimeStreamStatus() }
        return result
    }
    public func shutdown() async {
        callback = nil
        for id in Array(connections.keys) { stop(id) }
        failed = [:]; retryAfter = [:]; disconnected = [:]
        try? await Task.sleep(nanoseconds: 650_000_000)
    }
    public static func localEndpointAvailable(home: URL) -> Bool {
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
        let program = Data(RealtimeProbe.script.utf8).base64EncodedString()
        let encodedHome = Data(source.home.utf8).base64EncodedString()
        if let alias = source.alias {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            let command = "python3 -u -c 'import base64;exec(base64.b64decode(\"\(program)\").decode())' \(encodedHome)"
            process.arguments = ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ForwardAgent=no",
                "-o", "ClearAllForwardings=yes", "-o", "ConnectTimeout=6", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", "--", alias, command]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-u", "-c", RealtimeProbe.script, encodedHome, "socket-only"]
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let reader = PipeChunkReader(descriptor: output.fileHandleForReading.fileDescriptor)
        let channel = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(64))
        output.fileHandleForReading.readabilityHandler = { _ in
            guard let bytes = reader.read() else { return }
            if bytes.isEmpty { channel.continuation.finish() }
            else if case .dropped = channel.continuation.yield(bytes) { channel.continuation.finish() }
        }
        do { try process.run() }
        catch {
            reader.stop(); output.fileHandleForReading.readabilityHandler = nil; channel.continuation.finish()
            failed[source.id] = source; retryAfter[source.id] = Date().addingTimeInterval(30); return
        }
        var connection = Connection(source: source, process: process, output: output.fileHandleForReading,
            reader: reader, continuation: channel.continuation,
            state: RuntimeEventState(sourceID: source.alias == nil ? nil : source.id, sourceName: source.name))
        connection.task = Task { [weak self] in
            for await bytes in channel.stream {
                guard !Task.isCancelled else { return }
                await self?.receive(bytes, id: source.id, process: process)
            }
            await self?.closed(source.id, process: process)
        }
        connections[source.id] = connection
    }
    private func receive(_ data: Data, id: String, process: Process) {
        guard var connection = connections[id], connection.process === process else { return }
        connection.buffer.append(data)
        guard connection.buffer.count <= 4 * 1024 * 1024 else { closed(id, process: process); return }
        while let end = connection.buffer.firstIndex(of: 10) {
            let line = connection.buffer.prefix(upTo: end)
            connection.buffer.removeSubrange(...end)
            guard let frame = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            connection.lastFrame = Date()
            connection.state.consume(frame)
            failed.removeValue(forKey: id)
            disconnected.removeValue(forKey: id)
        }
        connections[id] = connection
        publish()
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
        connection.continuation.finish(); connection.task?.cancel(); try? connection.output.close()
        if connection.process.isRunning {
            connection.process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if connection.process.isRunning { kill(connection.process.processIdentifier, SIGKILL) }
            }
        }
    }
    private func publish() { callback?(activities(), statuses(), failed.values.compactMap(\.name).sorted()) }
}
