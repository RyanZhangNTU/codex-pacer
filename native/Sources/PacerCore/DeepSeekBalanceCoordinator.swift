import Foundation

public struct DeepSeekBalanceServices: Sendable {
    public var readKey: @Sendable () -> String?
    public var saveKey: @Sendable (String) -> Bool
    public var removeKey: @Sendable () -> Bool
    public var readAPI: @Sendable (String) async throws -> DeepSeekBalance
    public var fingerprint: @Sendable (DeepSeekBalance.Source, String) -> String?
    public var readWeb: (@Sendable (String) async throws -> DeepSeekBalance)?
    public var webSessionChanged: @Sendable (Bool) -> Void = { _ in }
    public var detect: @Sendable (URL, String?) -> DeepSeekAuthMode? = { DeepSeekAuthMode.detect(home: $0, recentProvider: $1) }
    public var loadHistory: @Sendable () async -> DeepSeekBalanceHistory = { .init() }
    public var saveHistory: @Sendable (DeepSeekBalanceHistory, UInt64) async -> Void = { _, _ in }
    public init(readKey: @escaping @Sendable () -> String?, saveKey: @escaping @Sendable (String) -> Bool,
                removeKey: @escaping @Sendable () -> Bool, readAPI: @escaping @Sendable (String) async throws -> DeepSeekBalance,
                fingerprint: @escaping @Sendable (DeepSeekBalance.Source, String) -> String?,
                readWeb: (@Sendable (String) async throws -> DeepSeekBalance)? = nil,
                webSessionChanged: @escaping @Sendable (Bool) -> Void = { _ in },
                detect: @escaping @Sendable (URL, String?) -> DeepSeekAuthMode? = { DeepSeekAuthMode.detect(home: $0, recentProvider: $1) },
                loadHistory: @escaping @Sendable () async -> DeepSeekBalanceHistory = { .init() },
                saveHistory: @escaping @Sendable (DeepSeekBalanceHistory, UInt64) async -> Void = { _, _ in }) {
        self.readKey = readKey; self.saveKey = saveKey; self.removeKey = removeKey; self.readAPI = readAPI
        self.fingerprint = fingerprint; self.readWeb = readWeb; self.webSessionChanged = webSessionChanged; self.detect = detect
        self.loadHistory = loadHistory; self.saveHistory = saveHistory
    }
}


public struct DeepSeekBalanceState: Sendable, Equatable {
    public let context: UInt64
    public let token: String
    public let source: DeepSeekBalanceSelection
    public let detected: DeepSeekAuthMode?
    public let balance: DeepSeekBalance?
    public let history: DeepSeekBalanceHistory
    public let error: DeepSeekBalanceError?
    public let refreshing: Bool, hasKey: Bool, webAvailable: Bool
    public var mode: DeepSeekAuthMode? { source.mode(detected: detected) }
    public let failureCount: Int
    public let lastAttempt: Date?
    public let successCount: UInt64
}

/// Collection is independent of log reads. Every binding/key change revokes
/// the old task before any cache operation awaits; late responses stay private.
public actor DeepSeekBalanceCoordinator {
    private var services: DeepSeekBalanceServices
    private let now: @Sendable () -> Date
    private let output: @Sendable (DeepSeekBalanceState) async -> Void
    private var home: URL?
    private var source = DeepSeekBalanceSelection.automatic
    private var detected: DeepSeekAuthMode?, recentProvider: String?
    private var enabled = false, hasKey = false, historyLoaded = false, paused = false, disconnectFailed = false
    private var context: UInt64 = 0, revision: UInt64 = 0
    private var token = UUID().uuidString
    private var balance: DeepSeekBalance?, error: DeepSeekBalanceError?
    private var history = DeepSeekBalanceHistory()
    private var historyAvailable = true
    private var historyRevision: UInt64 = 0
    private var work: Task<Void, Never>?, attempt: UUID?, lastAttempt: Date?
    private var failures = 0
    private var successes: UInt64 = 0
    private let generation = QuotaWorkGeneration()
    private var epoch: UInt64 = 0
    private var pendingSeed: DeepSeekBalanceState?

    public init(services: DeepSeekBalanceServices, seed: DeepSeekBalanceState? = nil, now: @escaping @Sendable () -> Date = { Date() },
         output: @escaping @Sendable (DeepSeekBalanceState) async -> Void) {
        self.services = services; self.now = now; self.output = output
        pendingSeed = seed
    }
    public func configure(home: URL, source: DeepSeekBalanceSelection, enabled: Bool, recentProvider: String?, context: UInt64) async {
        let next = services.detect(home, recentProvider), oldContext = self.context
        self.context = context; self.recentProvider = recentProvider
        guard self.home != home || self.source != source || self.enabled != enabled || self.detected != next else {
            if oldContext != context { await emit() }; return
        }
        let oldMode = self.home == home && self.enabled == enabled ? self.source.mode(detected: self.detected) : nil
        let seed = self.home == nil ? pendingSeed : nil; pendingSeed = nil
        revoke(); let current = revision
        self.home = home; self.source = source; self.enabled = enabled; detected = next
        if !historyLoaded {
            let restored = await services.loadHistory()
            guard revision == current else { return }
            history = restored; historyLoaded = true
        }
        if let mode = source.mode(detected: next) {
            let binding = DeepSeekBalanceBinding(source: source, mode: mode)
            if !binding.retainsHistory(history, previousMode: oldMode) {
                history = .init(); historyAvailable = true; await persistHistory()
                guard revision == current else { return }
            }
        } else if oldMode != nil {
            history = .init(); historyAvailable = true; await persistHistory()
            guard revision == current else { return }
        }
        if let seed {
            lastAttempt = seed.lastAttempt; failures = seed.failureCount; successes = seed.successCount
            balance = seed.balance; error = seed.error
            // A seed may contain a live balance while identity storage was
            // unavailable. Never pair it with an older restored history.
            if seed.history.credentialFingerprint != history.credentialFingerprint || seed.history.samples.isEmpty && !history.samples.isEmpty {
                historyAvailable = false
            }
        }
        updateCredentialState(); await emit()
    }
    public static func refreshInterval(active: Bool, failures: Int) -> TimeInterval {
        (active ? 60.0 : 300.0) * pow(2, Double(min(3, max(0, failures))))
    }
    public static func isDue(lastAttempt: Date?, failures: Int, active: Bool, force: Bool = false,
                             requested: Bool = false, turnEnded: Bool = false, now: Date) -> Bool {
        let elapsed = lastAttempt.map { now.timeIntervalSince($0) } ?? .infinity
        return force || requested || elapsed >= refreshInterval(active: active, failures: failures) || turnEnded && elapsed > 20
    }
    public static func credentialError(mode: DeepSeekAuthMode?, key: String?, webAvailable: Bool) -> DeepSeekBalanceError? {
        if mode == .apiKey && key == nil { return .missingKey }
        if mode == .account && !webAvailable { return .signedOut }
        return nil
    }
    @discardableResult public func refreshIfDue(active: Bool, force: Bool = false, requested: Bool = false, turnEnded: Bool = false) async -> Bool {
        guard enabled, !paused, generation.contains(epoch), let home, let mode = source.mode(detected: detected), work == nil else { return false }
        guard force || !disconnectFailed else { return false }
        guard force || error?.needsConnection != true else { return false }
        guard Self.isDue(lastAttempt: lastAttempt, failures: failures, active: active, force: force, requested: requested, turnEnded: turnEnded, now: now()) else { return false }
        let key = mode == .apiKey ? services.readKey().flatMap(DeepSeekAPIKeyStore.validated) : nil
        hasKey = key != nil
        if mode == .apiKey && key == nil { error = .missingKey; await emit(); return false }
        if mode == .account && services.readWeb == nil { error = .signedOut; await emit(); return false }
        lastAttempt = now(); let identifier = UUID(), current = revision
        attempt = identifier; let webContext = token
        work = Task { [weak self, services] in
            let result: Result<DeepSeekBalance, Error>
            do { result = .success(mode == .apiKey ? try await services.readAPI(key!) : try await services.readWeb!(webContext)) }
            catch { result = .failure(error) }
            await self?.finish(result, key: key, home: home, revision: current, attempt: identifier)
        }
        await emit(); return true
    }
    public func saveKey(_ raw: String, token: String) async -> Bool {
        guard enabled, !paused, token == self.token, source.mode(detected: detected) == .apiKey,
              let key = DeepSeekAPIKeyStore.validated(raw), services.saveKey(key) else { return false }
        revoke(); let current = revision
        history = .init(); historyAvailable = true; historyLoaded = true; await persistHistory()
        guard revision == current, enabled else { return true }
        updateCredentialState(); await emit(); _ = await refreshIfDue(active: true, force: true); return true
    }
    public func removeKey(token: String) async -> Bool {
        guard enabled, !paused, token == self.token, source.mode(detected: detected) == .apiKey else { return false }
        guard services.removeKey() else { return false }
        revoke(); let current = revision
        history = .init(); historyAvailable = true; historyLoaded = true; await persistHistory()
        guard revision == current else { return true }
        updateCredentialState(); await emit(); return true
    }
    public func setWebReader(_ reader: (@Sendable (String) async throws -> DeepSeekBalance)?) async {
        services.readWeb = reader
        if source.mode(detected: detected) != .apiKey {
            // Runtime discovery may change while the host clears its profile.
            // Keep that operation's token so its completion can release the pause.
            if paused { await emit(); return }
            let failed = disconnectFailed
            revoke(); disconnectFailed = failed; updateCredentialState()
            if failed { error = .connectionFailed }
            await emit()
            if !failed { _ = await refreshIfDue(active: true, force: true) }
        } else { await emit() }
    }
    public func webSessionChanged(token: String) async -> Bool {
        await webSessionChanged(token: token, newSession: true)
    }
    public func webSessionChanged(token: String, newSession: Bool) async -> Bool {
        guard enabled, !paused, token == self.token, source.mode(detected: detected) != .apiKey else { return false }
        services.webSessionChanged(true); revoke(); let current = revision
        if newSession { history = .init(); historyAvailable = true; historyLoaded = true; await persistHistory() }
        guard revision == current, enabled else { return false }
        updateCredentialState(); await emit(); _ = await refreshIfDue(active: true, force: true); return true
    }
    /// Profile clearing happens in the browser host. Pause collection first so
    /// no read can recreate site data between cancellation and the clear.
    public func beginDisconnect(token: String) async -> String? {
        guard enabled, !paused, token == self.token, services.removeKey() else { return nil }
        services.webSessionChanged(false); revoke(); paused = true; let current = revision
        history = .init(); historyAvailable = true; historyLoaded = true; await persistHistory()
        guard revision == current, enabled else { return nil }
        updateCredentialState()
        error = source.mode(detected: detected) == .apiKey ? .missingKey : .signedOut
        await emit(); return self.token
    }
    public func completeDisconnect(token: String, success: Bool) async -> Bool {
        guard enabled, paused, token == self.token else { return false }
        paused = false; updateCredentialState()
        if !success { error = .connectionFailed; disconnectFailed = true }
        await emit(); return true
    }
    public func currentState() -> DeepSeekBalanceState {
        .init(context: context, token: token, source: source, detected: detected, balance: balance,
            history: historyAvailable ? history : .init(), error: error, refreshing: work != nil || paused, hasKey: hasKey, webAvailable: services.readWeb != nil,
            failureCount: failures, lastAttempt: lastAttempt, successCount: successes)
    }
    public var refreshCompletion: Task<Void, Never>? { work }
    public nonisolated func invalidateSource() { generation.invalidate() }
    public func stop() async {
        let pending = work
        enabled = false; revoke()
        await ShutdownDeadline().perform([{ await pending?.value }])
    }
    private func revoke() {
        revision &+= 1; token = UUID().uuidString
        generation.invalidate(); epoch = generation.capture()
        work?.cancel(); work = nil; attempt = nil; balance = nil; error = nil; hasKey = false
        lastAttempt = nil; failures = 0; paused = false; disconnectFailed = false
    }
    private func updateCredentialState() {
        guard enabled else { return }
        let mode = source.mode(detected: detected)
        hasKey = mode == .apiKey && services.readKey().flatMap(DeepSeekAPIKeyStore.validated) != nil
        if mode == .apiKey && !hasKey { error = .missingKey }
        else if mode == .account && services.readWeb == nil { error = .signedOut }
    }
    private func emit() async { await output(currentState()) }
    private func persistHistory() async {
        // A source/key change may overtake an older suspended disk write.
        // The store accepts the newest mutation regardless of actor scheduling.
        historyRevision &+= 1
        await services.saveHistory(history, historyRevision)
    }
    private func finish(_ result: Result<DeepSeekBalance, Error>, key: String?, home: URL, revision: UInt64, attempt: UUID) async {
        guard enabled, generation.contains(epoch), self.revision == revision, self.attempt == attempt, !Task.isCancelled else { return }
        let actual = services.detect(home, recentProvider)
        if actual != detected {
            await configure(home: home, source: source, enabled: enabled, recentProvider: recentProvider, context: context)
            _ = await refreshIfDue(active: true, force: true); return
        }
        work = nil; self.attempt = nil
        switch result {
        case .success(let value):
            guard value.source == (source.mode(detected: detected) == .apiKey ? .apiKey : .web) else {
                error = .invalidReply; failures = min(4, failures + 1); await emit(); return
            }
            let identity = value.source == .apiKey ? key : DeepSeekBalance.sessionIdentity(value.sessionFingerprint)
            guard let identity else {
                error = .invalidReply; failures = min(4, failures + 1); await emit(); return
            }
            let fingerprint = services.fingerprint(value.source, identity)
            balance = value; error = nil; failures = 0
            successes &+= 1
            if let fingerprint, DeepSeekHistoryCredential.isValid(fingerprint) {
                historyAvailable = true
                history.record(total: value.total, at: value.capturedAt, source: value.source.rawValue, credentialFingerprint: fingerprint)
                await persistHistory()
                guard enabled, generation.contains(epoch), self.revision == revision else { return }
            } else {
                // A failed salt read/write cannot append to another credential's
                // history or replace its last committed bytes.
                historyAvailable = false
            }
        case .failure(let failure):
            error = failure as? DeepSeekBalanceError ?? .connectionFailed
            if error?.needsConnection == true { balance = nil }
            failures = min(4, failures + 1)
        }
        await emit()
    }
}
