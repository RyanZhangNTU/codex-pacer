#if os(Windows)
import Foundation

/// A single authenticated connection. One blocking reader feeds the actor one
/// projected frame at a time, so a slow consumer cannot grow an input queue.
actor WindowsDesktopCollector: CodexDesktopConnection {
    private let home: URL
    private let connect: @Sendable () throws -> WindowsDesktopTransport
    private let onFrame: @Sendable (Data) async -> Void
    private let onClosed: @Sendable () async -> Void
    private var transport: WindowsDesktopTransport?
    private var session: NativeDesktopSession?
    private var gate: WindowsDesktopSourceGate?
    private var reader: Task<Void, Never>?, timer: Task<Void, Never>?
    private var timerDate: Date?
    private var threads: [String] = []
    private var interval: TimeInterval
    private var started = false, finished = false
    private var opened = Date(), lastFlush = Date.distantPast, nextStatus = Date.distantPast
    private var iterations = 0

    init(home: URL, interval: TimeInterval,
         connect: @escaping @Sendable () throws -> WindowsDesktopTransport = { try .connectCodex() },
         onFrame: @escaping @Sendable (Data) async -> Void, onClosed: @escaping @Sendable () async -> Void) {
        self.home = home; self.interval = min(5, max(0.1, interval)); self.connect = connect
        self.onFrame = onFrame; self.onClosed = onClosed
    }
    func start() async {
        guard !started, !finished else { return }
        started = true
        do {
            let factory = connect
            let connection = try await Task.detached(priority: .utility) { try factory() }.value
            guard !finished else { connection.cancel(); return }
            guard let peer = connection.peerIdentity else { connection.cancel(); throw WindowsDesktopTransport.Failure.identityMismatch }
            transport = connection
            let access = WindowsDesktopSourceGate(home: home, peer: peer)
            gate = access; opened = Date()
            var wire = try NativeDesktopSession(hosts: ["local"]) { value in
                if value["method"] as? String == "thread-stream-following-changed",
                   let params = value["params"] as? [String: Any], params["following"] as? Bool == true {
                    guard params["hostId"] as? String == "local", let thread = params["conversationId"] as? String,
                          access.permit(thread) else { throw WindowsDesktopSourceGate.Failure.revoked }
                }
                try connection.send(value)
            }
            wire.localOrigin = { access.origin($0) }
            session = wire
            try discoverNow()
            reader = Task.detached(priority: .utility) { [weak self, connection] in
                do {
                    while !Task.isCancelled {
                        guard let turns = await self?.observedTurns() else { connection.cancel(); return }
                        let bytes = try connection.receive(observedTurnIDs: turns).data
                        guard !Task.isCancelled else { return }
                        await self?.receive(bytes)
                    }
                } catch { await self?.finish(flush: true) }
            }
            try await service()
        } catch { await finish(flush: false) }
    }
    func discover(_ value: [String]) async {
        guard !finished else { return }
        threads = Array(Set(value.compactMap { UUID(uuidString: $0)?.uuidString.lowercased() })).sorted().prefix(256).map { $0 }
        guard session != nil else { return }
        do { try discoverNow(); try await deliver(); schedule() }
        catch { await finish(flush: false) }
    }
    func setInterval(_ value: TimeInterval, flushPending: Bool) async {
        interval = min(5, max(0.1, value))
        guard !finished, session != nil else { return }
        do {
            if flushPending { try session?.publishEvents(); lastFlush = Date(); try await deliver() }
            schedule()
        } catch { await finish(flush: false) }
    }
    func stop() async { await finish(flush: false) }
    private func observedTurns() -> Set<String>? { finished ? nil : session?.observedTurnIDs }
    private func discoverNow() throws {
        guard let gate else { return }
        let keys = threads.filter { gate.permit($0) }.map { NativeDesktopSession.Key(host: "local", thread: $0) }
        guard !gate.revoked else { throw WindowsDesktopSourceGate.Failure.revoked }
        try session?.discover(keys)
    }
    private func receive(_ bytes: Data) async {
        guard !finished, let gate else { return }
        do {
            // Global handshakes are allowed. Every thread-bearing broadcast is
            // bound before it can discover, follow or mutate a projection.
            let root = try JSONFieldView.document(bytes, projectedItems: true)
            let fields = try root.fields(["type", "method", "params", "sourceClientId"])
            if fields["type"]?.string() == "broadcast", let params = fields["params"], params.isObject {
                let route = try params.fields(["hostId", "conversationId"])
                if let thread = route["conversationId"]?.string() {
                    guard route["hostId"]?.string() == "local" else { return }
                    let owner = fields["method"]?.string() == "thread-stream-state-changed" ? fields["sourceClientId"]?.string() : nil
                    guard gate.permit(thread, owner: owner) else {
                        if gate.revoked { throw WindowsDesktopSourceGate.Failure.revoked }
                        schedule()
                        return
                    }
                }
            }
            try session?.receive(bytes, projectedItems: true)
            guard !gate.revoked else { throw WindowsDesktopSourceGate.Failure.revoked }
            try await deliver(); schedule()
        } catch { await finish(flush: false) }
    }
    private func service() async throws {
        guard !finished, session != nil else { return }
        iterations += 1
        let now = Date()
        guard gate?.validate() == true else { throw WindowsDesktopSourceGate.Failure.revoked }
        if let gate {
            let ready = gate.dueRetries(at: now).filter { gate.permit($0) }.map { NativeDesktopSession.Key(host: "local", thread: $0) }
            try session?.discover(ready)
        }
        if session?.ready != true, now.timeIntervalSince(opened) >= 5 { throw WindowsDesktopTransport.Failure.timedOut }
        try session?.service(at: now)
        if session?.hasEvents == true, now.timeIntervalSince(lastFlush) >= interval {
            try session?.publishEvents(); lastFlush = now
        }
        if now >= nextStatus { try session?.status(loopIterations: iterations); nextStatus = now.addingTimeInterval(15) }
        try await deliver(); schedule()
    }
    private func schedule() {
        guard !finished, let session else { return }
        var next = nextStatus
        if !session.ready { next = min(next, opened.addingTimeInterval(5)) }
        if session.hasEvents { next = min(next, lastFlush.addingTimeInterval(interval)) }
        if let date = session.nextServiceDate { next = min(next, date) }
        if let date = gate?.nextRetryDate { next = min(next, date) }
        if let timerDate, timerDate <= next { return }
        timer?.cancel(); timerDate = next
        let delay = max(0.01, min(15, next.timeIntervalSinceNow))
        timer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            await self?.tick()
        }
    }
    private func tick() async {
        timer = nil; timerDate = nil
        do { try await service() } catch { await finish(flush: false) }
    }
    private func deliver(closing: Bool = false) async throws {
        let frames = session?.takeFrames() ?? []
        for bytes in frames {
            guard closing || !finished else { return }
            guard gate?.validate() == true else { throw WindowsDesktopSourceGate.Failure.revoked }
            await onFrame(bytes)
        }
    }
    private func finish(flush: Bool) async {
        guard !finished else { return }
        finished = true; timer?.cancel(); timer = nil; reader?.cancel(); reader = nil
        // EOF may follow a terminal event before the ordinary batch deadline.
        // Revoked file/process proofs never flush buffered events.
        if flush, gate?.validate() == true {
            try? session?.publishEvents(); try? await deliver(closing: true)
        }
        transport?.cancel(); session?.close(); session = nil; gate = nil; transport = nil
        await onClosed()
    }
}

/// Kept on the collector actor. Origins for unbound threads are explicitly
/// ignored because the shared Mac session accepts an absent local origin.
private final class WindowsDesktopSourceGate {
    enum Failure: Error { case revoked }
    private let binding: WindowsDesktopSourceBinding
    private var proofs: [String: WindowsDesktopSourceBinding.Proof] = [:]
    private var owners: [String: String] = [:]
    private struct Denial { let at: Date; let attempts: Int }
    private var denied: [String: Denial] = [:]
    private(set) var revoked = false
    init(home: URL, peer: WindowsProcessIdentity) { binding = .init(home: home, peer: peer) }
    func permit(_ value: String, owner: String? = nil) -> Bool {
        guard !revoked, let id = UUID(uuidString: value)?.uuidString.lowercased() else { return false }
        if let proof = proofs[id] {
            guard binding.isCurrent(proof) else { revoked = true; return false }
            if let owner, owners[id] != owner {
                guard UUID(uuidString: owner) != nil, let renewed = binding.authorize(id) else { revoked = true; return false }
                proofs[id] = renewed; owners[id] = owner
            }
            return true
        }
        guard proofs.count < 256, denied[id].map({ Date().timeIntervalSince($0.at) >= 2 }) ?? true else { return false }
        guard let proof = binding.authorize(id) else {
            denied[id] = Denial(at: Date(), attempts: min(4, (denied[id]?.attempts ?? 0) + 1))
            if denied.count > 256 { denied.removeValue(forKey: denied.min(by: { $0.value.at < $1.value.at })!.key) }
            return false
        }
        if let owner { guard UUID(uuidString: owner) != nil else { return false }; owners[id] = owner }
        proofs[id] = proof; denied.removeValue(forKey: id); return true
    }
    func origin(_ thread: String) -> CodexRolloutMetadata? {
        if permit(thread), let proof = proofs[thread.lowercased()], let row = binding.currentMetadata(proof) { return row }
        return .init(origin: .init(embedded: false, ignored: true), url: binding.home, observedAt: nil, parentThreadID: nil)
    }
    func validate() -> Bool {
        guard !revoked else { return false }
        if proofs.values.contains(where: { !binding.isCurrent($0) }) { revoked = true }
        return !revoked
    }
    // A routing hint can precede its rollout header. Retry a bounded number of
    // times without waiting for a second log write or polling quiet profiles.
    var nextRetryDate: Date? { denied.values.filter { $0.attempts < 4 }.map { $0.at.addingTimeInterval(2) }.min() }
    func dueRetries(at now: Date) -> [String] { denied.filter { $0.value.attempts < 4 && now.timeIntervalSince($0.value.at) >= 2 }.map(\.key) }
}
#endif
