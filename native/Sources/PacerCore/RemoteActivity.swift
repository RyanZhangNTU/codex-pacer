import Foundation
import Darwin

public struct RemoteActivityTarget: Equatable, Sendable {
    public let id: String
    public let name: String
    public let alias: String
    public let home: String

    public static func configured(home: URL) -> [RemoteActivityTarget] { readConfiguration(home: home) ?? [] }
    static func readConfiguration(home: URL) -> [RemoteActivityTarget]? {
        let file = home.appendingPathComponent(".codex-global-state.json")
        guard let data = try? Data(contentsOf: file), data.count < 8 * 1024 * 1024,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let connections = value["codex-managed-remote-connections"] as? [[String: Any]] else { return nil }
        let flags = value["remote-connection-auto-connect-by-host-id"] as? [String: Bool] ?? [:]
        let routes = value["app-server-migrated-pinned-thread-ids-by-host"] as? [String: Any] ?? [:]
        return connections.compactMap { c in
            guard c["source"] as? String == "discovered", let id = c["hostId"] as? String,
                  id.hasPrefix("remote-ssh-discovered:"), flags[id] == true,
                  let alias = c["alias"] as? String,
                  alias.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,128}$"#, options: .regularExpression) != nil else { return nil }
            let path = routes.keys.first { $0.hasPrefix(id + ":/") }.map { String($0.dropFirst(id.count + 1)) } ?? "~/.codex"
            return RemoteActivityTarget(id: id, name: c["displayName"] as? String ?? alias, alias: alias, home: path)
        }.prefix(8).map { $0 }
    }
}

public actor RemoteActivityMonitor {
    public typealias Update = @Sendable ([SessionActivity], [String]) -> Void
    private struct Connection {
        let target: RemoteActivityTarget
        let process: Process
        let output: FileHandle
        let reader: PipeChunkReader
        let continuation: AsyncStream<Data>.Continuation
        var task: Task<Void, Never>?
        var buffer = Data()
        var lastFrame = Date()
        var activities: [String: SessionActivity] = [:]
    }
    private var connections: [String: Connection] = [:]
    private var retryAfter: [String: Date] = [:]
    private var failures: [String: String] = [:]
    private var callback: Update?
    private var disconnected: [String: [SessionActivity]] = [:]

    public init() {}
    public func start(home: URL, update: @escaping Update) {
        callback = update
        guard let targets = RemoteActivityTarget.readConfiguration(home: home) else { publish(); return }
        for connection in Array(connections.values) where Date().timeIntervalSince(connection.lastFrame) > 30 {
            closed(connection.target, process: connection.process)
        }
        let ids = Set(targets.map(\.id))
        for id in Array(connections.keys) where !ids.contains(id) { stop(id); disconnected.removeValue(forKey: id) }
        for id in Array(failures.keys) where !ids.contains(id) { failures.removeValue(forKey: id); retryAfter.removeValue(forKey: id); disconnected.removeValue(forKey: id) }
        for target in targets where connections[target.id] == nil && Date() >= (retryAfter[target.id] ?? .distantPast) { connect(target) }
        publish()
    }
    public func currentActivities() -> [SessionActivity] { connections.values.flatMap { $0.activities.values } + disconnected.values.flatMap { $0 } }
    public func unavailableSources() -> [String] { failures.values.sorted() }
    public func shutdown() async {
        callback = nil
        for id in Array(connections.keys) { stop(id) }
        failures.removeAll(); retryAfter.removeAll(); disconnected.removeAll()
        try? await Task.sleep(nanoseconds: 650_000_000)
    }
    private func connect(_ target: RemoteActivityTarget) {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        let program = Data(RemoteProbe.script.utf8).base64EncodedString()
        let home = Data(target.home.utf8).base64EncodedString()
        let command = "python3 -u -c 'import base64;exec(base64.b64decode(\"\(program)\").decode())' \(home)"
        process.arguments = ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ForwardAgent=no",
            "-o", "ClearAllForwardings=yes", "-o", "ConnectTimeout=6", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2", "--", target.alias, command]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let reader = PipeChunkReader(descriptor: output.fileHandleForReading.fileDescriptor)
        let channel = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(64))
        output.fileHandleForReading.readabilityHandler = { _ in
            guard let data = reader.read() else { return }
            if data.isEmpty { channel.continuation.finish() }
            else if case .dropped = channel.continuation.yield(data) { channel.continuation.finish() }
        }
        do { try process.run() }
        catch {
            reader.stop(); output.fileHandleForReading.readabilityHandler = nil; channel.continuation.finish()
            failures[target.id] = target.name; retryAfter[target.id] = Date().addingTimeInterval(30); return
        }
        var connection = Connection(target: target, process: process, output: output.fileHandleForReading, reader: reader, continuation: channel.continuation)
        connection.task = Task { [weak self] in
            for await data in channel.stream {
                guard !Task.isCancelled else { return }
                await self?.receive(data, id: target.id, process: process)
            }
            await self?.closed(target, process: process)
        }
        connections[target.id] = connection
    }
    private func receive(_ data: Data, id: String, process: Process) {
        guard var connection = connections[id], connection.process === process else { return }
        connection.buffer.append(data)
        guard connection.buffer.count <= 4 * 1024 * 1024 else { closed(connection.target, process: process); return }
        while let end = connection.buffer.firstIndex(of: 10) {
            let line = connection.buffer.prefix(upTo: end)
            connection.buffer.removeSubrange(...end)
            guard let frame = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let sessions = frame["sessions"] as? [[String: Any]] else { continue }
            connection.lastFrame = Date()
            var currentIDs: Set<String> = []
            for session in sessions {
                guard let fileID = session["id"] as? String, fileID.count <= 256, let records = session["records"] as? [[String: Any]] else { continue }
                let activityID = id + ":" + fileID
                currentIDs.insert(activityID)
                let firstObservation = connection.activities[activityID] == nil
                var activity = connection.activities[activityID] ?? SessionActivity(id: activityID, sourceHost: connection.target.name)
                if session["reset"] as? Bool == true { activity = SessionActivity(id: activityID, sourceHost: connection.target.name) }
                for record in records { if let bytes = try? JSONSerialization.data(withJSONObject: record) { activity.consume(bytes) } }
                if firstObservation, [.running, .waitingForInput].contains(activity.phase),
                   Date().timeIntervalSince(activity.lastObserved ?? .distantPast) > 900 { activity.markUnconfirmed() }
                if !activity.isInternalReview { connection.activities[activityID] = activity }
                else { connection.activities.removeValue(forKey: activityID) }
            }
            connection.activities = connection.activities.filter { currentIDs.contains($0.key) }
            failures.removeValue(forKey: id)
            disconnected.removeValue(forKey: id)
        }
        connections[id] = connection
        publish()
    }
    private func closed(_ target: RemoteActivityTarget, process: Process) {
        guard connections[target.id]?.process === process else { return }
        disconnected[target.id] = connections[target.id]?.activities.values.map { value in
            var value = value; value.markUnconfirmed(); return value
        }
        stop(target.id)
        failures[target.id] = target.name
        retryAfter[target.id] = Date().addingTimeInterval(30)
        publish()
    }
    private func stop(_ id: String) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.reader.stop(); connection.output.readabilityHandler = nil
        connection.continuation.finish(); connection.task?.cancel(); try? connection.output.close()
        if connection.process.isRunning {
            connection.process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { if connection.process.isRunning { kill(connection.process.processIdentifier, SIGKILL) } }
        }
    }
    private func publish() { callback?(currentActivities(), failures.values.sorted()) }
}
