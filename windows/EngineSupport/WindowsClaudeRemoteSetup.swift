import Foundation
import PacerCore

struct EngineClaudeRemoteSetup: Codable, Equatable, Sendable {
    let sourceID: String
    let context: String
    let configured: Bool
    let inFlight: Bool
    let canRetry: Bool
    let message: String?
    let retryAt: Double?
}

struct EngineClaudeRemoteServices: Sendable {
    var digest: String
    var install: @Sendable (RemoteActivityTarget) async throws -> ClaudeHookInstaller.Status
    var shutdown: @Sendable () async -> Void
    var loadDigests: @Sendable () -> [String: String]
    var saveDigests: @Sendable ([String: String]) -> Void
}

/// Selection, version comparison and backoff use ClaudeRemoteAutoSetup.
/// The host owns tasks, source tokens and immutable protocol snapshots.
actor WindowsClaudeRemoteCoordinator {
    typealias Update = @Sendable ([EngineClaudeRemoteSetup], UInt64) async -> Void
    typealias Configured = @Sendable (String, UInt64) async -> Void
    private struct Job { let ticket: ApplicationWorkRegistry.Ticket; let target: RemoteActivityTarget }
    private var work = ApplicationWorkRegistry()
    private let services: EngineClaudeRemoteServices
    private let now: @Sendable () -> Date
    private var configured: [String: String]
    private var targets: [RemoteActivityTarget] = []
    private var statuses: [String: RuntimeStreamStatus] = [:]
    private var failures: [String: Date] = [:]
    private var messages: [String: String] = [:]
    private var jobs: [String: Job] = [:]
    private var enabled = false, cleaning = false
    private var version: UInt64 = 0
    private var context = UUID().uuidString.lowercased()
    private var update: Update?
    private var didConfigure: Configured?
    private var retryWake: Task<Void, Never>?
    private var retryDate: Date?
    private let maximumTargets: Int
    init(services: EngineClaudeRemoteServices, now: @escaping @Sendable () -> Date = { Date() }, maximumTargets: Int = 8) {
        self.services = services; self.now = now; configured = services.loadDigests()
        self.maximumTargets = min(16, max(1, maximumTargets))
    }
    func configure(targets: [RemoteActivityTarget], statuses: [String: RuntimeStreamStatus], enabled: Bool,
                   version: UInt64, update: @escaping Update, didConfigure: @escaping Configured = { _, _ in }) async {
        let replacing = self.version != version || self.enabled != enabled
        self.update = update; self.didConfigure = didConfigure; self.enabled = enabled; self.version = version
        let next = enabled ? Array(targets.prefix(maximumTargets)) : []
        let changedWSL = self.targets.filter { $0.id.hasPrefix(ConnectionSource.wslPrefix) && !next.contains($0) }.map(\.id)
        if !changedWSL.isEmpty {
            context = UUID().uuidString.lowercased()
            for id in changedWSL { failures[id] = nil; messages[id] = nil }
        }
        self.targets = next; self.statuses = statuses
        if replacing {
            context = UUID().uuidString.lowercased()
            retryWake?.cancel(); retryWake = nil; retryDate = nil
            work.cancel(); jobs.removeAll(); failures.removeAll(); messages.removeAll()
            if !cleaning {
                cleaning = true
                await services.shutdown()
                cleaning = false
            }
        }
        for (id, job) in Array(jobs) where !self.targets.contains(job.target) { work.cancel(job.ticket.key); jobs[id] = nil }
        let allowed = Set(self.targets.map(\.id))
        failures = failures.filter { allowed.contains($0.key) }; messages = messages.filter { allowed.contains($0.key) }
        reconcile()
        await publish()
    }
    func retry(sourceID: String, context: String) async -> Bool {
        guard enabled, !cleaning, self.context == context, let target = targets.first(where: { $0.id == sourceID }), jobs[sourceID] == nil else { return false }
        failures[sourceID] = nil; messages[sourceID] = nil
        start(target); await publish(); return true
    }
    func shutdown() async {
        enabled = false; targets = []; statuses = [:]; context = UUID().uuidString.lowercased()
        work.cancel(); jobs.removeAll()
        retryWake?.cancel(); retryWake = nil; retryDate = nil
        if !cleaning { cleaning = true; await services.shutdown(); cleaning = false }
        reconcile(); await publish()
    }
    private func reconcile() {
        guard enabled, !cleaning else { return }
        for target in ClaudeRemoteAutoSetup.pending(targets: targets, statuses: statuses, configured: configured,
            digest: services.digest, failures: failures, inFlight: Set(jobs.keys), now: now()) { start(target) }
        scheduleRetryWake()
    }
    private func scheduleRetryWake() {
        let date = targets.compactMap { target -> Date? in
            guard jobs[target.id] == nil, configured[target.alias] != services.digest,
                  let status = statuses[target.id], status.connected, status.sourceAvailable != false else { return nil }
            return failures[target.id]?.addingTimeInterval(ClaudeRemoteAutoSetup.retryInterval)
        }.filter { $0 > now() }.min()
        guard date != retryDate else { return }
        retryWake?.cancel(); retryWake = nil; retryDate = date
        guard let date else { return }
        let token = context, seconds = max(0.01, date.timeIntervalSince(now()))
        retryWake = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
            await self?.retryDue(context: token)
        }
    }
    private func retryDue(context: String) async {
        guard self.context == context, enabled, !cleaning else { return }
        retryWake = nil; retryDate = nil; reconcile(); await publish()
    }
    private func start(_ target: RemoteActivityTarget) {
        let request = work.begin(.init(.setup, provider: .claude, identifier: target.id), version: version), services = self.services
        let task = Task { [weak self] in
            do { _ = try await services.install(target); await self?.finished(target, request: request, failure: nil) }
            catch { await self?.finished(target, request: request, failure: error as? ClaudeRemoteSetup.Failure ?? .setupFailed) }
        }
        work.attach(task, to: request); jobs[target.id] = .init(ticket: request, target: target)
    }
    private func finished(_ target: RemoteActivityTarget, request: ApplicationWorkRegistry.Ticket, failure: ClaudeRemoteSetup.Failure?) async {
        guard enabled, work.owns(request), request.version == version, jobs[target.id]?.ticket == request, targets.contains(target) else { return }
        work.finish(request)
        jobs[target.id] = nil
        guard failure != .cancelled else { await publish(); return }
        if let failure {
            failures[target.id] = now()
            messages[target.id] = L10n.text(failure == .missingHome ? "provider.remote_source_missing" : "provider.remote_configure_failed")
        } else {
            configured[target.alias] = services.digest
            configured = Dictionary(uniqueKeysWithValues: configured.sorted { $0.key < $1.key }.suffix(32).map { ($0.key, $0.value) })
            services.saveDigests(configured); failures[target.id] = nil; messages[target.id] = nil
        }
        scheduleRetryWake()
        await publish()
        if failure == nil { await didConfigure?(target.id, request.version) }
    }
    private func publish() async {
        let rows = targets.map { target in
            EngineClaudeRemoteSetup(sourceID: target.id, context: context, configured: configured[target.alias] == services.digest,
                inFlight: jobs[target.id] != nil, canRetry: enabled && !cleaning && jobs[target.id] == nil,
                message: messages[target.id], retryAt: failures[target.id].map { $0.addingTimeInterval(ClaudeRemoteAutoSetup.retryInterval).timeIntervalSince1970 })
        }
        await update?(rows, version)
    }
}

final class WindowsClaudeSetupOperation: ClaudeRemoteSetupOperation, @unchecked Sendable {
    private let executable: URL, arguments: [String], environment: [String: String]
    private let lock = NSLock()
    private var bytes = Data(), problem: ClaudeRemoteSetup.Failure?, child: (any ChildProcessConnection)?
    private let wsl: WindowsWSLServices?
    private var sourceIsCurrent: @Sendable () -> Bool = { true }
    init(executable: URL, arguments: [String], environment: [String: String], wsl: WindowsWSLServices? = nil) {
        self.executable = executable; self.arguments = arguments; self.environment = environment
        self.wsl = wsl
    }
    var failure: ClaudeRemoteSetup.Failure? { lock.lock(); defer { lock.unlock() }; return problem }
    func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard problem == nil, child == nil else { throw problem ?? .connectionFailed }
        if arguments.first == "--pacer-wsl" {
            guard arguments.count == 4, arguments[1] == "claude", let wsl,
                  let profile = wsl.registry.profile(id: arguments[2], provider: .claude),
                  let invocation = WindowsWSLInvocation(profile: profile, provider: .claude, command: arguments[3], setup: true) else { throw ClaudeRemoteSetup.Failure.invalidTarget }
            sourceIsCurrent = { wsl.registry.profile(id: profile.id, provider: .claude) == profile }
            child = try wsl.start(.init(executable: wsl.executable, arguments: invocation.arguments, environment: WindowsWSLInvocation.environment(environment)),
                invocation.input, { [weak self] in self?.receive($0) }, {})
            // WSL's small supervisor owns the Linux child group. Keep stdin
            // open until completion; cancellation EOF then kills only that group.
            return
        }
        let invocation = try WindowsSSHInvocation(arguments: arguments)
        let process = try WindowsHelperProcess(.init(executable: executable, arguments: invocation.arguments, environment: environment),
            initialInput: invocation.input, privateErrors: true, output: { [weak self] in self?.receive($0) }, ended: {})
        child = process; process.finishInput()
    }
    private func receive(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard bytes.count + data.count <= 4096 else { problem = .invalidResponse; return }
        bytes.append(data)
    }
    func result() throws -> (data: Data, exitStatus: Int32)? {
        lock.lock(); defer { lock.unlock() }
        if let problem { throw problem }
        guard sourceIsCurrent() else { throw ClaudeRemoteSetup.Failure.cancelled }
        guard let child, !child.isRunning, child.ioClosed.isFinished else { return nil }
        guard let status = child.terminationStatus else { throw ClaudeRemoteSetup.Failure.connectionFailed }
        return (bytes, status)
    }
    func abort(_ failure: ClaudeRemoteSetup.Failure) {
        lock.lock(); problem = failure; let process = child; lock.unlock()
        process?.close(); process?.terminateImmediately()
    }
    func close() { lock.lock(); let process = child; lock.unlock(); process?.close() }
}
