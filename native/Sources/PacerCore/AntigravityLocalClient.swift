import Foundation

package enum AntigravityHubCandidateLimit {
    case all(upTo: Int)
    case newest(Int)
}

/// Only the host can attest the hub's owner, server executable, listener and process start identity.
package protocol AntigravityLocalHost: Sendable {
    var maximumHubDirectoryEntries: Int { get }
    var hubCandidateLimit: AntigravityHubCandidateLimit { get }
    /// Changes even for an owner/link change or a write with a restored mtime.
    func hubChangeTime(_ hub: URL) -> UInt64?
    func processIdentity(pid: Int32) -> String?
    func serverIdentity(hub: URL, pid: Int32, httpPort: UInt16) -> String?
    func post(_ request: AntigravityLocalRequest) async throws -> (Int, Data)
}

/// The language server leaves its hub file behind when it exits, one per start,
/// so only the newest files are checked; two live servers still bind none.
extension AntigravityLocalHost {
    package var maximumHubDirectoryEntries: Int { 4096 }
    package var hubCandidateLimit: AntigravityHubCandidateLimit { .newest(32) }
}

package struct AntigravityLocalRequest: Sendable {
    package let port: UInt16
    package let path: String
    package let headers: [String: String]
    package let body: Data
    package let maximumBytes: Int
}

package actor AntigravityLocalClient {
    enum Method {
        case userStatus, quota, list, conversation(UUID), steps(UUID, offset: Int), metadata(UUID), generators(UUID)
    }
    package enum Failure: Error { case unavailable, revoked, oversized, unsupported, timedOut }

    private struct Binding: Equatable {
        let file: URL
        let stamp: PlatformFileMetadata
        let changeTime: UInt64
        let pid: Int32
        let port: UInt16
        let process: String
        let token: String
    }

    private let directory: URL
    private let uptime: @Sendable () -> TimeInterval
    private var directoryStamp: PlatformFileMetadata?
    private var otherHubs: [(URL, PlatformFileMetadata?)] = []
    private var hubFiles: [(URL, UInt16)] = []
    // Stale hub files commonly outlive the server. Never cache their credentials.
    private var inactive: [URL: (stamp: PlatformFileMetadata, pid: Int32)] = [:]
    private let io: LocalHarnessIO
    private var binding: Binding?
    private var catalog = AntigravityModelCatalog()
    private var catalogAttempt: Date?
    private var catalogMisses: Set<String> = []

    func modelCatalog(for id: String, session: UInt64) async -> AntigravityModelCatalog {
        guard session == generation, catalog.resolve(id) == nil, !catalogMisses.contains(id),
              io.now().timeIntervalSince(catalogAttempt ?? .distantPast) >= 60 else { return catalog }
        catalogAttempt = io.now()
        if let data = try? await call(.userStatus, generation: session), generation == session,
           let updated = try? AntigravityModelCatalog(data) {
            catalog = updated
            if updated.resolve(id) == nil {
                if catalogMisses.count >= 256 { catalogMisses.removeAll() }
                catalogMisses.insert(id)
            }
        }
        return catalog
    }
    private var refused: (file: URL, stamp: PlatformFileMetadata, process: String, retry: TimeInterval)?
    private var pending: [UUID: Task<(Int, Data), Error>] = [:]
    private(set) var generation: UInt64 = 0
    init(home: URL, io: LocalHarnessIO, uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.uptime = uptime
        directory = home.appendingPathComponent("daemon", isDirectory: true); self.io = io
    }

    func revoke() {
        generation &+= 1
        binding = nil
        catalog = AntigravityModelCatalog(); catalogAttempt = nil; catalogMisses.removeAll()
        for task in pending.values { task.cancel() }
        pending.removeAll()
    }

    @discardableResult func discover() -> UInt64? {
        let candidate = discoverBinding()
        if candidate != binding { revoke(); binding = candidate }
        return candidate == nil ? nil : generation
    }

    /// Quota and in-flight activity reads can validate their session without
    /// choosing a replacement or scanning the daemon directory again.
    func isCurrent(_ expected: UInt64, checkDirectory: Bool = false) -> Bool {
        guard generation == expected, let binding else { return false }
        guard io.files.metadata(binding.file) == binding.stamp,
              io.antigravity?.hubChangeTime(binding.file) == binding.changeTime,
              io.antigravity?.processIdentity(pid: binding.pid) == binding.process else {
            revoke()
            return false
        }
        // A newly created hub or an in-place edit to a competitor can make
        // the selection ambiguous during an HTTP read. Let activity rediscover.
        if checkDirectory {
            return io.files.metadata(directory) == directoryStamp && otherHubs.allSatisfy { io.files.metadata($0.0) == $0.1 }
        }
        return true
    }

    private func discoverBinding() -> Binding? {
        guard let host = io.antigravity, let stamp = io.files.metadata(directory), stamp.isDirectory else { return nil }
        if directoryStamp != stamp {
            guard let entries = try? io.files.entries(in: directory, maximum: host.maximumHubDirectoryEntries) else { return nil }
            hubFiles = entries.compactMap { url in
                let name = url.lastPathComponent
                guard name.hasPrefix("hub_"), name.hasSuffix(".json"),
                      let port = UInt16(name.dropFirst(4).dropLast(5)), port > 0, name == "hub_\(port).json" else { return nil }
                return (url, port)
            }
            directoryStamp = stamp
            inactive.removeAll()
        }
        let stamped = hubFiles.map { ($0.0, $0.1, io.files.metadata($0.0)) }
        let candidates = stamped.compactMap { (url, port, metadata) -> (URL, UInt16, PlatformFileMetadata)? in
            guard let stamp = metadata, stamp.isRegularFile, (1...4096).contains(stamp.size) else { return nil }
            return (url, port, stamp)
        }
        let count: Int
        switch host.hubCandidateLimit {
        case .all(let maximum):
            guard candidates.count <= maximum else { return nil }
            count = candidates.count
        case .newest(let maximum):
            count = maximum
        }
        let newest = candidates.sorted { lhs, rhs in
            if lhs.2.modified == rhs.2.modified { return lhs.1 < rhs.1 }
            return lhs.2.modified > rhs.2.modified
        }
        var result: Binding?
        for (file, port, stamp) in newest.prefix(count) {
            if let binding, binding.file == file, binding.stamp == stamp,
               host.hubChangeTime(file) == binding.changeTime, host.processIdentity(pid: binding.pid) == binding.process {
                guard result == nil else { return nil }
                result = binding
                continue
            }
            if let prior = inactive[file], prior.stamp == stamp, host.processIdentity(pid: prior.pid) == nil { continue }
            guard let changeTime = host.hubChangeTime(file),
                  let data = try? io.files.read(file, offset: 0, maximumBytes: 4097),
                  let fields = try? JSONFieldView.document(data, maximumBytes: 4096).fields(["httpPort", "pid", "csrfToken"]),
                  fields["httpPort"]?.integer() == Int(port),
                  let pid = fields["pid"]?.integer().flatMap(Int32.init(exactly:)), pid > 1 else { continue }
            guard let process = host.processIdentity(pid: pid) else {
                inactive[file] = (stamp, pid)
                continue
            }
            if let refused, refused.file == file, refused.stamp == stamp, refused.process == process, uptime() < refused.retry {
                return nil
            }
            guard let token = fields["csrfToken"]?.string(limit: 257), (1...256).contains(token.utf8.count),
                  token.utf8.allSatisfy({ (33...126).contains($0) }),
                  let identity = host.serverIdentity(hub: file, pid: pid, httpPort: port), identity == process,
                  host.processIdentity(pid: pid) == identity, io.files.metadata(file) == stamp,
                  host.hubChangeTime(file) == changeTime else { continue }
            guard result == nil else { return nil }
            result = Binding(file: file, stamp: stamp, changeTime: changeTime, pid: pid, port: port, process: identity, token: token)
        }
        otherHubs = stamped.compactMap { $0.0 == result?.file ? nil : ($0.0, $0.2) }
        return result
    }

    private func connectionLost(_ current: Binding) {
        refused = (current.file, current.stamp, current.process, uptime() + 2)
        revoke()
    }

    func call(_ method: Method, generation expected: UInt64) async throws -> Data {
        guard isCurrent(expected), let current = binding, let host = io.antigravity else { throw Failure.revoked }
        let service: String, name: String, body: [String: Any], cap: Int
        switch method {
        case .userStatus, .quota:
            service = "exa.language_server_pb.LanguageServerService"
            if case .userStatus = method { name = "GetUserStatus"; cap = 512 * 1024 }
            else { name = "RetrieveUserQuotaSummary"; cap = 64 * 1024 }
            body = [:]
        case .list:
            service = "product.v1.ConversationService"; name = "ListConversations"
            body = ["pageSize": 100, "includeArchived": false]; cap = 256 * 1024
        case .conversation(let id):
            service = "product.v1.ConversationService"; name = "GetConversation"
            body = ["conversationId": id.uuidString.lowercased()]; cap = 256 * 1024
        case .steps(let id, let offset):
            guard (0...Int(Int32.max)).contains(offset) else { throw Failure.unsupported }
            service = "exa.language_server_pb.LanguageServerService"; name = "GetCascadeTrajectorySteps"
            body = ["cascadeId": id.uuidString.lowercased(), "stepOffset": offset]; cap = 2 * 1024 * 1024
        case .metadata(let id):
            service = "exa.language_server_pb.LanguageServerService"; name = "GetConversationMetadata"
            body = ["conversationId": id.uuidString.lowercased()]; cap = 256 * 1024
        case .generators(let id):
            service = "exa.language_server_pb.LanguageServerService"; name = "GetCascadeTrajectoryGeneratorMetadata"
            body = ["cascadeId": id.uuidString.lowercased()]; cap = 2 * 1024 * 1024
        }
        let headers = ["Content-Type": "application/json", "Connect-Protocol-Version": "1",
                       "x-antigravity-csrf-token": current.token, "x-codeium-csrf-token": current.token]
        let request = AntigravityLocalRequest(port: current.port, path: "/\(service)/\(name)", headers: headers,
                                              body: try JSONSerialization.data(withJSONObject: body), maximumBytes: cap)
        let key = UUID(), task = Task { try await host.post(request) }
        pending[key] = task
        defer { pending.removeValue(forKey: key) }
        let response: (Int, Data)
        do { response = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch let error as Failure { throw error }
        catch let error as URLError where error.code == .timedOut {
            // A slow reply can retain its scoped quota if the full proof
            // still holds. No subsequent call inherits an unverified timeout.
            if generation == expected, host.serverIdentity(hub: current.file, pid: current.pid, httpPort: current.port) != current.process {
                connectionLost(current)
            }
            throw Failure.timedOut
        }
        catch { if generation == expected { connectionLost(current) }; throw Failure.unavailable }
        guard isCurrent(expected) else { throw Failure.revoked }
        if response.0 == 401 || response.0 == 403 { connectionLost(current); throw Failure.revoked }
        guard response.0 == 200 else { throw Failure.unsupported }
        guard response.1.count <= cap else { throw Failure.oversized }
        return response.1
    }
}
