#if os(Windows)
import Foundation
import PacerCore

/// A single authenticated connection. One blocking reader feeds the actor one
/// projected frame at a time, so a slow consumer cannot grow an input queue.
actor WindowsDesktopCollector: DesktopActivityChannel {
    private let home: URL
    private let connect: @Sendable () throws -> WindowsDesktopTransport
    private let onFrame: @Sendable (Data) async -> Void
    private let onClosed: @Sendable () async -> Void
    private var hosts: Set<String>
    private let localRuntime: Bool
    private let authorization: (@Sendable () -> RemoteControlAuthorizationSnapshot)?
    private var transport: WindowsDesktopTransport?
    private var session: DesktopCollectionSession?
    private var gate: WindowsDesktopSourceGate?
    private var remoteGate: WindowsRemoteControlGate?
    private var durableTask: Task<Void, Never>?
    private var durableJob: UUID?
    private var durableBinding: WindowsDurableCatalog.Binding?
    private var durableThreads: Set<String> = []
    private var durableRevision = 0
    private var delivering = false
    private var reader: Task<Void, Never>?, timer: Task<Void, Never>?
    private var timerDate: Date?
    private var threads: [String] = []
    private var interval: TimeInterval
    private var started = false, finished = false

    init(home: URL, interval: TimeInterval,
         connect: @escaping @Sendable () throws -> WindowsDesktopTransport = { try .connectCodex() },
         hosts: Set<String> = ["local"], localRuntime: Bool = true,
         authorization: (@Sendable () -> RemoteControlAuthorizationSnapshot)? = nil,
         onFrame: @escaping @Sendable (Data) async -> Void, onClosed: @escaping @Sendable () async -> Void) {
        self.home = home; self.interval = min(5, max(0.1, interval)); self.connect = connect
        self.hosts = hosts; self.localRuntime = localRuntime; self.authorization = authorization
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
            let remote = WindowsRemoteControlGate(authorization: authorization)
            let allowed = try allowedHosts(remote, transport: connection)
            gate = access
            remoteGate = remote
            let wire = try DesktopCollectionSession(hosts: allowed, localRuntime: localRuntime, batchInterval: interval, localOrigin: { access.origin($0) }) { value in
                if value["method"] as? String == "thread-stream-following-changed",
                   let params = value["params"] as? [String: Any], params["following"] as? Bool == true {
                    guard let host = params["hostId"] as? String, let thread = params["conversationId"] as? String,
                          host == DurableActivityCatalog.hostID ||
                            (host == "local" ? access.permit(thread) : remote.permit(host)) else { throw WindowsDesktopSourceGate.Failure.revoked }
                }
                try connection.send(value)
            }
            session = wire
            updateDurable()
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
    func setBatchInterval(_ value: TimeInterval, flushPending: Bool) async {
        interval = min(5, max(0.1, value))
        guard !finished, session != nil else { return }
        do {
            try session?.setBatchInterval(interval, flushPending: flushPending)
            try await deliver()
            schedule()
        } catch { await finish(flush: false) }
    }
    func setHosts(_ hosts: Set<String>) async {
        guard !finished else { return }
        self.hosts = hosts
        do {
            if let remoteGate, let transport { try session?.setHosts(allowedHosts(remoteGate, transport: transport)) }
            updateDurable()
            try await deliver(); schedule()
        }
        catch { await finish(flush: false) }
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
            guard remoteGate?.validate() != false else { throw WindowsDesktopSourceGate.Failure.revoked }
            try revokeDurableIfStale()
            // Global handshakes are allowed. Every thread-bearing broadcast is
            // bound before it can discover, follow or mutate a projection.
            let root = try JSONFieldView.document(bytes, projectedItems: true)
            let fields = try root.fields(["type", "method", "params", "sourceClientId", "version"])
            if fields["type"]?.string() == "broadcast", let params = fields["params"], params.isObject {
                let route = try params.fields(["hostId", "conversationId", "following"])
                if let thread = route["conversationId"]?.string() {
                    guard let host = route["hostId"]?.string() else { return }
                    if host == DurableActivityCatalog.hostID {
                        guard durableThreads.contains(thread.lowercased()) else { try await deliver(); return }
                    } else if host != "local" {
                        guard remoteGate?.permit(host) == true else {
                            try session?.observeRemoteRoute(host: host, thread: thread, method: fields["method"]?.string(),
                                version: fields["version"]?.integer(), sender: fields["sourceClientId"]?.string(), following: route["following"]?.boolean())
                            try await deliver()
                            return
                        }
                    } else {
                        let owner = fields["method"]?.string() == "thread-stream-state-changed" ? fields["sourceClientId"]?.string() : nil
                        guard gate.permit(thread, owner: owner) else {
                            if gate.revoked { throw WindowsDesktopSourceGate.Failure.revoked }
                            schedule()
                            return
                        }
                    }
                }
            }
            try session?.receive(bytes)
            guard !gate.revoked else { throw WindowsDesktopSourceGate.Failure.revoked }
            try await deliver(); schedule()
        } catch { await finish(flush: false) }
    }
    func discoverRemote(_ routes: [NativeDesktopSession.Key]) async {
        guard !finished, let remoteGate else { return }
        do {
            try session?.discover(routes.filter { remoteGate.permit($0.host) })
            try await deliver(); schedule()
        } catch { await finish(flush: false) }
    }
    private func service() async throws {
        guard !finished, session != nil else { return }
        let now = Date()
        guard gate?.validate() == true, remoteGate?.validate() != false else { throw WindowsDesktopSourceGate.Failure.revoked }
        try revokeDurableIfStale()
        if let gate {
            let ready = gate.dueRetries(at: now).filter { gate.permit($0) }.map { NativeDesktopSession.Key(host: "local", thread: $0) }
            try session?.discover(ready)
        }
        try session?.service(at: now)
        try await deliver(); schedule()
    }
    private func schedule() {
        guard !finished, let session else { return }
        var next = session.nextServiceDate
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
    private func deliver() async throws {
        guard !delivering else { return }
        delivering = true
        defer { delivering = false }
        // A catalog update and a pipe read can arrive while onFrame awaits.
        // Deliver the scope change before any following events for that scope.
        while !finished {
            let frames = session?.takeFrames() ?? []
            if frames.isEmpty { return }
            let revision = durableRevision
            for bytes in frames {
                guard !finished else { return }
                guard gate?.validate() == true, remoteGate?.validate() != false else { throw WindowsDesktopSourceGate.Failure.revoked }
                if durableRevision > 0, let needsBinding = Self.durableFrameNeedsBinding(bytes),
                   revision != durableRevision || (needsBinding && durableBinding?.isCurrent(home: home) != true) { continue }
                await onFrame(bytes)
            }
        }
    }

    private static func durableFrameNeedsBinding(_ bytes: Data) -> Bool? {
        guard let fields = try? JSONFieldView.document(bytes).fields(["hostId", "kind", "scope"]),
              fields["hostId"]?.string() == DurableActivityCatalog.hostID else { return nil }
        return fields["kind"]?.string() != "durableScope" || fields["scope"]?.isNull != true
    }

    private func allowedHosts(_ remote: WindowsRemoteControlGate, transport: WindowsDesktopTransport) throws -> Set<String> {
        var allowed = try remote.update(hosts)
        if hosts.contains(DurableActivityCatalog.hostID), transport.codexPackage != nil,
           WindowsActivityNavigation.isDefaultProfile(home, provider: .codex) { allowed.insert(DurableActivityCatalog.hostID) }
        return allowed
    }

    private func updateDurable() {
        guard session?.hosts.contains(DurableActivityCatalog.hostID) == true,
              let transport, let package = transport.codexPackage, let peer = transport.peerIdentity else {
            durableTask?.cancel(); durableTask = nil; durableJob = nil
            if durableBinding != nil { durableBinding = nil; durableThreads = []; durableRevision += 1 }
            return
        }
        guard durableTask == nil else { return }
        let job = UUID(), home = home
        durableJob = job
        durableTask = Task.detached(priority: .utility) { [weak self] in
            await WindowsDurableCatalog.observe(home: home, desktop: peer, package: package, publish: { [weak self] catalog, binding in
                await self?.receiveDurable(catalog, binding: binding, job: job)
            }, ipc: { [weak self] in await self?.durableIPC(job: job) ?? [:] },
            publishHistory: { [weak self] scope, binding, history in
                await self?.receiveDurableHistory(history, scope: scope, binding: binding, job: job)
            })
        }
    }

    private func durableIPC(job: UUID) -> [String: Date] {
        durableJob == job ? session?.durableIPCObservations ?? [:] : [:]
    }

    private func revokeDurableIfStale() throws {
        guard durableBinding?.isCurrent(home: home) == false else { return }
        durableBinding = nil; durableThreads = []; durableRevision += 1
        try session?.setDurableCatalog(nil)
    }

    private func receiveDurable(_ catalog: DurableActivityCatalog?, binding: WindowsDurableCatalog.Binding?, job: UUID) async {
        guard !finished, durableJob == job else { return }
        do {
            try revokeDurableIfStale()
            if binding?.isCurrent(home: home) != false {
                if durableBinding != binding {
                    if durableBinding != nil { try session?.setDurableCatalog(nil) }
                    durableRevision += 1
                }
                durableBinding = binding; durableThreads = catalog?.threadIDs ?? []
                try session?.setDurableCatalog(catalog)
            }
            try await deliver(); schedule()
        } catch { await finish(flush: false) }
    }

    private func receiveDurableHistory(_ history: [DurableTurnHistory], scope: String,
                                       binding: WindowsDurableCatalog.Binding, job: UUID) async {
        guard !finished, durableJob == job else { return }
        do {
            try revokeDurableIfStale()
            if durableBinding == binding {
                try session?.observeDurableHistory(history, scope: scope, at: Date())
            }
            try await deliver(); schedule()
        } catch { await finish(flush: false) }
    }
    private func finish(flush: Bool) async {
        guard !finished else { return }
        finished = true; timer?.cancel(); timer = nil; reader?.cancel(); reader = nil
        durableTask?.cancel(); durableTask = nil; durableJob = nil
        // Release the authenticated IO before awaiting a possibly stalled consumer.
        // The last valid batch still precedes EOF; revoked proofs never flush.
        let access = gate
        let remote = remoteGate
        transport?.cancel()
        let frames = session?.finish(flush: flush && access?.validate() == true && remote?.validate() != false) ?? []
        session = nil; gate = nil; remoteGate = nil; transport = nil
        for bytes in frames {
            guard access?.validate() == true, remote?.validate() != false else { break }
            if Self.durableFrameNeedsBinding(bytes) == true, durableBinding?.isCurrent(home: home) != true { continue }
            await onFrame(bytes)
        }
        await onClosed()
    }
}

/// The authenticated Desktop pipe supplies IO; the shared catalog supplies
/// the account scope and the exact allowed device IDs. Saved hints grant none.
final class WindowsRemoteControlGate {
    enum Failure: Error { case revoked }
    private let authorization: (@Sendable () -> RemoteControlAuthorizationSnapshot)?
    private var requested: Set<String> = []
    private var scope: String?
    init(authorization: (@Sendable () -> RemoteControlAuthorizationSnapshot)?) { self.authorization = authorization }
    func update(_ hosts: Set<String>) throws -> Set<String> {
        requested = hosts
        let state = authorization?() ?? .init()
        let verified = state.verified && state.scope != nil && !state.revoked
        if let scope, !verified || state.scope != scope { throw Failure.revoked }
        if verified { scope = state.scope }
        let allowed = verified ? hosts.intersection(state.hostIDs).filter { $0.hasPrefix(ConnectionSource.controlPrefix) } : []
        return Set(allowed).union(hosts.contains("local") ? ["local"] : [])
    }
    func validate() -> Bool {
        guard let scope else { return true }
        let state = authorization?() ?? .init()
        return state.verified && !state.revoked && state.scope == scope
    }
    func permit(_ host: String) -> Bool {
        guard host.hasPrefix(ConnectionSource.controlPrefix), requested.contains(host), validate() else { return false }
        let state = authorization?() ?? .init()
        return state.verified && !state.revoked && state.scope != nil && state.scope == scope && state.hostIDs.contains(host)
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
