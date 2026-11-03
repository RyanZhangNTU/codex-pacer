import Foundation
import PacerCore

struct DeepSeekWebReply: Codable, Sendable {
    let state: String
    var normal: [String]?, bonus: [String]?
    var otherCurrency: Bool?, estimation: String?, alertEnabled: Bool?, alertBound: String?
    var sessionFingerprint: String?
    func balance(at date: Date) throws -> DeepSeekBalance {
        guard ["ok", "signedOut", "challenge", "offline", "invalid"].contains(state),
              [normal, bonus].compactMap({ $0 }).allSatisfy({ $0.count <= 64 && $0.allSatisfy { $0.utf8.count <= 64 && DeepSeekBalance.amount($0) != nil } }),
              [estimation, alertBound].compactMap({ $0 }).allSatisfy({ $0.utf8.count <= 64 && DeepSeekBalance.amount($0) != nil }) else {
            throw DeepSeekBalanceError.invalidReply
        }
        if state == "offline" { throw DeepSeekBalanceError.connectionFailed }
        var reply: [String: Any] = ["state": state, "normal": normal ?? [], "bonus": bonus ?? [],
            "otherCurrency": otherCurrency ?? false, "estimation": estimation as Any, "alertEnabled": alertEnabled ?? false,
            "alertBound": alertBound as Any]
        if let sessionFingerprint { reply["sessionFingerprint"] = sessionFingerprint }
        return try DeepSeekBalance.web(reply, at: date)
    }
}

struct DeepSeekWebHostMessage: Encodable, Sendable {
    let protocolVersion = EngineProtocol.version
    let type: String
    let operation = "deepseek.balance"
    let requestID: String, context: String
}

/// The host checks a read against its latest snapshot. Configuration may
/// suspend that projection while the balance coordinator starts its work.
struct DeepSeekWebHostPublication {
    private var pending: [DeepSeekWebHostMessage] = []
    var count: Int { pending.count }
    mutating func receive(_ message: DeepSeekWebHostMessage, publishedContext: String?, ready: Bool) -> [DeepSeekWebHostMessage] {
        pending.removeAll { $0.requestID == message.requestID }
        if message.type == "hostCancel" { return [message] }
        if ready && publishedContext == message.context { return [message] }
        if pending.count == DeepSeekWebBridge.maximumPendingRequests { pending.removeFirst() }
        pending.append(message)
        return []
    }
    mutating func published(context: String?) -> [DeepSeekWebHostMessage] {
        let current = pending.filter { $0.context == context }
        pending.removeAll { $0.context == context }
        return current
    }
    mutating func rebind(context: String) { pending.removeAll { $0.context != context } }
    mutating func reset() { pending.removeAll(keepingCapacity: true) }
}

/// The browser owns tokens. The engine requests a bounded numeric result and
/// cancels it explicitly when its binding, host or deadline changes.
actor DeepSeekWebBridge {
    static let maximumPendingRequests = 4
    private struct Pending {
        let context: String, at: Date
        let continuation: CheckedContinuation<DeepSeekBalance, Error>
        let timer: Task<Void, Never>
    }
    private var available = false
    private var pending: [String: Pending] = [:]
    private let timeout: UInt64
    private let now: @Sendable () -> Date
    private let output: @Sendable (DeepSeekWebHostMessage) async -> Void
    init(timeout: UInt64 = 20_000_000_000, now: @escaping @Sendable () -> Date,
         output: @escaping @Sendable (DeepSeekWebHostMessage) async -> Void) {
        self.timeout = timeout; self.now = now; self.output = output
    }
    func setAvailable(_ value: Bool) async {
        available = value
        if !value { for id in Array(pending.keys) { await cancel(id, failure: DeepSeekBalanceError.connectionFailed) } }
    }
    func revoke(context: String) async {
        for id in pending.filter({ $0.value.context == context }).map(\.key) { await cancel(id, failure: CancellationError()) }
    }
    func read(context: String) async throws -> DeepSeekBalance {
        guard available, pending.count < Self.maximumPendingRequests else { throw DeepSeekBalanceError.connectionFailed }
        try Task.checkCancellation()
        let id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let timer = Task { [weak self, timeout] in
                    do { try await Task.sleep(nanoseconds: timeout) } catch { return }
                    await self?.cancel(id, failure: DeepSeekBalanceError.connectionFailed)
                }
                pending[id] = .init(context: context, at: now(), continuation: continuation, timer: timer)
                Task { await send(id) }
            }
        } onCancel: { Task { await self.cancel(id, failure: CancellationError()) } }
    }
    func complete(id: String, context: String, reply: DeepSeekWebReply) -> Bool {
        guard available, let request = pending[id], request.context == context else { return false }
        pending.removeValue(forKey: id); request.timer.cancel()
        do { request.continuation.resume(returning: try reply.balance(at: request.at)) }
        catch { request.continuation.resume(throwing: error) }
        return true
    }
    private func send(_ id: String) async {
        guard available, let value = pending[id] else { return }
        await output(.init(type: "hostRequest", requestID: id, context: value.context))
    }
    private func cancel(_ id: String, failure: Error) async {
        guard let value = pending.removeValue(forKey: id) else { return }
        value.timer.cancel(); value.continuation.resume(throwing: failure)
        await output(.init(type: "hostCancel", requestID: id, context: value.context))
    }
}
