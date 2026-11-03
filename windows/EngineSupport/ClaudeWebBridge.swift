import Foundation
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

struct ClaudeWebHostMessage: Encodable, Sendable {
    let protocolVersion = EngineProtocol.version
    let type: String
    let operation = "claude.session"
    let requestID: String, context: String
}

/// A source-scoped request for Pacer's own browser session. Stale, cancelled or
/// foreign replies cannot resume a newer source's request.
actor ClaudeWebBridge {
    private struct Pending {
        let context: String
        let continuation: CheckedContinuation<ClaudeWebSession?, Error>
        let timer: Task<Void, Never>
    }
    private var available = false
    private var pending: [String: Pending] = [:]
    private let timeout: UInt64
    private let output: @Sendable (ClaudeWebHostMessage) async -> Void

    init(timeout: UInt64 = 20_000_000_000, output: @escaping @Sendable (ClaudeWebHostMessage) async -> Void) {
        self.timeout = timeout; self.output = output
    }
    func setAvailable(_ value: Bool) async {
        available = value
        if !value { for id in Array(pending.keys) { await cancel(id, error: ClaudeQuotaError.connectionFailed) } }
    }
    func read(context: String) async throws -> ClaudeWebSession? {
        guard available, pending.count < 4, UUID(uuidString: context) != nil else { throw ClaudeQuotaError.connectionFailed }
        try Task.checkCancellation()
        let id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let timer = Task { [weak self, timeout] in
                    do { try await Task.sleep(nanoseconds: timeout) } catch { return }
                    await self?.cancel(id, error: ClaudeQuotaError.connectionFailed)
                }
                pending[id] = .init(context: context, continuation: continuation, timer: timer)
                Task { await send(id) }
            }
        } onCancel: { Task { await self.cancel(id, error: CancellationError()) } }
    }
    func complete(id: String, context: String, reply: ClaudeWebSessionReply) -> Bool {
        guard available, let request = pending[id], request.context == context else { return false }
        pending.removeValue(forKey: id); request.timer.cancel()
        do { request.continuation.resume(returning: try reply.session()) }
        catch { request.continuation.resume(throwing: error) }
        return true
    }
    func cancel(context: String) async {
        for id in pending.compactMap({ $0.value.context == context ? $0.key : nil }) { await cancel(id, error: CancellationError()) }
    }
    private func send(_ id: String) async {
        guard available, let value = pending[id] else { return }
        await output(.init(type: "hostRequest", requestID: id, context: value.context))
    }
    private func cancel(_ id: String, error: Error) async {
        guard let value = pending.removeValue(forKey: id) else { return }
        value.timer.cancel(); value.continuation.resume(throwing: error)
        await output(.init(type: "hostCancel", requestID: id, context: value.context))
    }
}
