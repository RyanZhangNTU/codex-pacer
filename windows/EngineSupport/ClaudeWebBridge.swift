import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PacerCore

/// These values exist only while answering an owned cookie request. They never
/// enter activity snapshots, preferences, quota history or diagnostics.
struct ClaudeWebSessionReply: Codable, Sendable {
    let state: String
    var cookieHeader: String?, sessionHash: String?, organizationID: String?, userAgent: String?

    func session() throws -> ClaudeWebSession? {
        switch state {
        case "signedOut": return nil
        case "offline": throw ClaudeQuotaError.connectionFailed
        case "ok": break
        default: throw ClaudeQuotaError.invalidReply
        }
        guard let cookieHeader, cookieHeader.utf8.count <= 32768, let sessionHash,
              organizationID == nil || ClaudeWebQuotaDecoder.uuid(organizationID) != nil,
              userAgent == nil || (userAgent!.utf8.count <= 512 && !userAgent!.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)) else {
            throw ClaudeQuotaError.invalidReply
        }
        let value = ClaudeWebSession(cookieHeader: cookieHeader, sessionHash: sessionHash, organizationID: organizationID, userAgent: userAgent)
        guard ClaudeWebQuotaDecoder.sessionKey(value) != nil else { throw ClaudeQuotaError.invalidReply }
        return value
    }
}

/// A claude.ai reply read in Pacer's own browser profile, the browser that passed
/// the site's verification. The engine's own HTTPS client looks like a different
/// client to Cloudflare, which challenged it again after every sign-in (#243).
struct ClaudeWebFetchReply: Codable, Sendable {
    /// JSON replies fit in one engine command with room to spare; the quota replies are a few KB.
    static let maximumBodyBytes = 40 * 1024
    let state: String
    var status: Int?, contentType: String?, cfMitigated: String?, retryAfter: String?, body: String?

    func response(for url: URL) throws -> (Data, HTTPURLResponse) {
        switch state {
        case "ok": break
        case "signedOut": throw ClaudeQuotaError.notLoggedIn
        case "offline": throw ClaudeQuotaError.connectionFailed
        default: throw ClaudeQuotaError.invalidReply
        }
        let headers = [("Content-Type", contentType), ("cf-mitigated", cfMitigated), ("Retry-After", retryAfter)]
        guard let status, (100...599).contains(status), let body, body.utf8.count <= Self.maximumBodyBytes,
              headers.allSatisfy({ $0.1.map { $0.utf8.count <= 256 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) } ?? true }),
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                  headerFields: Dictionary(uniqueKeysWithValues: headers.compactMap { name, value in value.map { (name, $0) } })) else {
            throw ClaudeQuotaError.invalidReply
        }
        return (Data(body.utf8), response)
    }

    /// The only reads: the account, its workspaces and one workspace's usage.
    static func allowed(_ path: String) -> Bool {
        if path == "/api/account" || path == "/api/organizations" { return true }
        let prefix = "/api/organizations/", parts = path.hasPrefix(prefix) ? path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false) : []
        guard parts.count == 2, ClaudeWebQuotaDecoder.uuid(String(parts[0])) == String(parts[0]) else { return false }
        return parts[1] == "usage" || parts[1] == "usage?cedar_ember=1"
    }
}

struct ClaudeWebHostMessage: Encodable, Sendable {
    let protocolVersion = EngineProtocol.version
    let type: String
    var operation = "claude.session"
    let requestID: String, context: String
    var path: String? = nil
}

/// A source-scoped request for Pacer's own browser session. Stale, cancelled or
/// foreign replies cannot resume a newer source's request.
actor ClaudeWebBridge {
    private enum Waiter {
        case session(CheckedContinuation<ClaudeWebSession?, Error>)
        case fetch(CheckedContinuation<ClaudeWebFetchReply, Error>, path: String)
        var path: String? { if case .fetch(_, let path) = self { return path }; return nil }
        func fail(_ error: Error) {
            switch self {
            case .session(let continuation): continuation.resume(throwing: error)
            case .fetch(let continuation, _): continuation.resume(throwing: error)
            }
        }
    }
    private struct Pending {
        let context: String
        let waiter: Waiter
        let timer: Task<Void, Never>
    }
    private var available = false, fetching = false
    private var pending: [String: Pending] = [:]
    private let timeout: UInt64
    private let output: @Sendable (ClaudeWebHostMessage) async -> Void

    init(timeout: UInt64 = 20_000_000_000, output: @escaping @Sendable (ClaudeWebHostMessage) async -> Void) {
        self.timeout = timeout; self.output = output
    }
    func setAvailable(_ value: Bool, fetching: Bool = false) async {
        available = value; self.fetching = value && fetching
        if !value { for id in Array(pending.keys) { await cancel(id, error: ClaudeQuotaError.connectionFailed) } }
    }
    /// The host reads claude.ai in its own browser profile (#243); hosts before it leave reads to the engine.
    var fetchesInBrowser: Bool { available && fetching }
    func read(context: String) async throws -> ClaudeWebSession? {
        try await request(context: context, allowed: available, fetch: false) { .session($0) }
    }
    func fetch(context: String, path: String) async throws -> ClaudeWebFetchReply {
        try await request(context: context, allowed: fetchesInBrowser && ClaudeWebFetchReply.allowed(path), fetch: true) { .fetch($0, path: path) }
    }
    /// At most four cookie reads and four page reads wait at once.
    private func request<T>(context: String, allowed: Bool, fetch: Bool,
                            waiter: @escaping (CheckedContinuation<T, Error>) -> Waiter) async throws -> T {
        guard allowed, pending.values.filter({ ($0.waiter.path != nil) == fetch }).count < 4,
              UUID(uuidString: context) != nil else { throw ClaudeQuotaError.connectionFailed }
        try Task.checkCancellation()
        let id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let timer = Task { [weak self, timeout] in
                    do { try await Task.sleep(nanoseconds: timeout) } catch { return }
                    await self?.cancel(id, error: ClaudeQuotaError.connectionFailed)
                }
                pending[id] = .init(context: context, waiter: waiter(continuation), timer: timer)
                Task { await send(id) }
            }
        } onCancel: { Task { await self.cancel(id, error: CancellationError()) } }
    }
    func complete(id: String, context: String, reply: ClaudeWebSessionReply) -> Bool {
        guard available, let request = pending[id], request.context == context, case .session(let continuation) = request.waiter else { return false }
        pending.removeValue(forKey: id); request.timer.cancel()
        do { continuation.resume(returning: try reply.session()) }
        catch { continuation.resume(throwing: error) }
        return true
    }
    func complete(id: String, context: String, fetched reply: ClaudeWebFetchReply) -> Bool {
        guard available, let request = pending[id], request.context == context, case .fetch(let continuation, _) = request.waiter else { return false }
        pending.removeValue(forKey: id); request.timer.cancel()
        continuation.resume(returning: reply)
        return true
    }
    func cancel(context: String) async {
        for id in pending.compactMap({ $0.value.context == context ? $0.key : nil }) { await cancel(id, error: CancellationError()) }
    }
    private func send(_ id: String) async {
        guard available, let value = pending[id] else { return }
        let path = value.waiter.path
        await output(.init(type: "hostRequest", operation: path == nil ? "claude.session" : "claude.fetch", requestID: id, context: value.context, path: path))
    }
    private func cancel(_ id: String, error: Error) async {
        guard let value = pending.removeValue(forKey: id) else { return }
        value.timer.cancel(); value.waiter.fail(error)
        await output(.init(type: "hostCancel", operation: value.waiter.path == nil ? "claude.session" : "claude.fetch", requestID: id, context: value.context))
    }
}
