import Foundation
#if os(Windows)
import FoundationNetworking
#endif

struct DeepSeekBalanceServices: Sendable {
    var readKey: @Sendable () -> String?
    var saveKey: @Sendable (String) -> Bool
    var removeKey: @Sendable () -> Bool
    var readAPI: @Sendable (String) async throws -> DeepSeekBalance
    var readWeb: (@Sendable (String) async throws -> DeepSeekBalance)?
    var webSessionChanged: @Sendable (Bool) -> Void = { _ in }
    var detect: @Sendable (URL, String?) -> DeepSeekAuthMode? = { DeepSeekAuthMode.detect(home: $0, recentProvider: $1) }
    var loadHistory: @Sendable () async -> DeepSeekBalanceHistory = { .init() }
    var saveHistory: @Sendable (DeepSeekBalanceHistory, UInt64) async -> Void = { _, _ in }

    static var live: Self {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexPacer/DeepSeekBalance", isDirectory: true)
        let history = DeepSeekBalanceHistoryStore(file: directory.appendingPathComponent("history-v1.json"))
        return .init(readKey: { DeepSeekAPIKeyStore.read() }, saveKey: { DeepSeekAPIKeyStore.save($0) },
            removeKey: {
                #if os(Windows)
                return DeepSeekAPIKeyStore.remove()
                #else
                DeepSeekAPIKeyStore.remove(); return !DeepSeekAPIKeyStore.exists
                #endif
            }, readAPI: { key in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
                let session = URLSession(configuration: configuration, delegate: BalanceRedirectPolicy(), delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                return try await DeepSeekAPIBalanceClient.read(key: key, session: session)
            }, loadHistory: { await history.load(now: Date()) }, saveHistory: { await history.save($0, revision: $1) })
    }
    static func demo(now: @escaping @Sendable () -> Date) -> Self {
        let memory = DemoKey()
        return .init(readKey: { memory.read() }, saveKey: { memory.save($0) }, removeKey: { memory.remove() },
            readAPI: { _ in .init(total: 86.4, granted: 6.4, capturedAt: now(), source: .apiKey) },
            readWeb: { _ in guard memory.isSignedIn() else { throw DeepSeekBalanceError.signedOut }; return EngineWalletSource.demo(at: now()).balance! },
            webSessionChanged: { memory.setSignedIn($0) }, detect: { _, _ in .account },
            loadHistory: { EngineWalletSource.demo(at: now()).history })
    }
    private final class DemoKey: @unchecked Sendable {
        private let lock = NSLock(); private var key: String?, signedIn = true
        func read() -> String? { lock.lock(); defer { lock.unlock() }; return key }
        func save(_ value: String) -> Bool { lock.lock(); key = value; lock.unlock(); return true }
        func remove() -> Bool { lock.lock(); key = nil; lock.unlock(); return true }
        func isSignedIn() -> Bool { lock.lock(); defer { lock.unlock() }; return signedIn }
        func setSignedIn(_ value: Bool) { lock.lock(); signedIn = value; lock.unlock() }
    }
    private final class BalanceRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    }
}

struct DeepSeekBalanceState: Sendable, Equatable {
    let context: UInt64
    let token: String
    let source: DeepSeekBalanceSelection
    let detected: DeepSeekAuthMode?
    let balance: DeepSeekBalance?
    let history: DeepSeekBalanceHistory
    let error: DeepSeekBalanceError?
    let refreshing: Bool, hasKey: Bool, webAvailable: Bool
    var mode: DeepSeekAuthMode? { source.mode(detected: detected) }
}

/// Collection is independent of log reads. Every binding/key change revokes
/// the old task before any cache operation awaits; late responses stay private.
actor DeepSeekBalanceMonitor {
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
    private var historyRevision: UInt64 = 0
    private var work: Task<Void, Never>?, attempt: UUID?, lastAttempt: Date?
    private var failures = 0

    init(services: DeepSeekBalanceServices, now: @escaping @Sendable () -> Date = { Date() },
         output: @escaping @Sendable (DeepSeekBalanceState) async -> Void) {
        self.services = services; self.now = now; self.output = output
    }
    func configure(home: URL, source: DeepSeekBalanceSelection, enabled: Bool, recentProvider: String?, context: UInt64) async {
        let next = services.detect(home, recentProvider), oldContext = self.context
        self.context = context; self.recentProvider = recentProvider
        guard self.home != home || self.source != source || self.enabled != enabled || self.detected != next else {
            if oldContext != context { await emit() }; return
        }
        let oldMode = self.home == home && self.enabled == enabled ? self.source.mode(detected: self.detected) : nil
        revoke(); let current = revision
        self.home = home; self.source = source; self.enabled = enabled; detected = next
        if !historyLoaded {
            let restored = await services.loadHistory()
            guard revision == current else { return }
            history = restored; historyLoaded = true
        }
        if let mode = source.mode(detected: next) {
            let expected = mode == .account ? "web" : "apiKey"
            if history.source != expected || oldMode.map({ $0 != mode }) == true {
                history = .init(); await persistHistory()
                guard revision == current else { return }
            }
        } else if oldMode != nil {
            history = .init(); await persistHistory()
            guard revision == current else { return }
        }
        updateCredentialState(); await emit()
    }
    static func refreshInterval(active: Bool, failures: Int) -> TimeInterval {
        (active ? 60.0 : 300.0) * pow(2, Double(min(3, max(0, failures))))
    }
    @discardableResult func refreshIfDue(active: Bool, force: Bool = false, turnEnded: Bool = false) async -> Bool {
        guard enabled, !paused, let home, let mode = source.mode(detected: detected), work == nil else { return false }
        guard force || !disconnectFailed else { return false }
        guard force || error?.needsConnection != true else { return false }
        let elapsed = lastAttempt.map { now().timeIntervalSince($0) } ?? .infinity
        guard force || elapsed >= Self.refreshInterval(active: active, failures: failures) || turnEnded && elapsed > 20 else { return false }
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
            await self?.finish(result, home: home, revision: current, attempt: identifier)
        }
        await emit(); return true
    }
    func saveKey(_ raw: String, token: String) async -> Bool {
        guard enabled, !paused, token == self.token, source.mode(detected: detected) == .apiKey,
              let key = DeepSeekAPIKeyStore.validated(raw), services.saveKey(key) else { return false }
        revoke(); let current = revision
        history = .init(); historyLoaded = true; await persistHistory()
        guard revision == current, enabled else { return true }
        updateCredentialState(); await emit(); _ = await refreshIfDue(active: true, force: true); return true
    }
    func removeKey(token: String) async -> Bool {
        guard enabled, !paused, token == self.token, source.mode(detected: detected) == .apiKey else { return false }
        guard services.removeKey() else { return false }
        revoke(); let current = revision
        history = .init(); historyLoaded = true; await persistHistory()
        guard revision == current else { return true }
        updateCredentialState(); await emit(); return true
    }
    func setWebReader(_ reader: (@Sendable (String) async throws -> DeepSeekBalance)?) async {
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
    func webSessionChanged(token: String) async -> Bool {
        guard enabled, !paused, token == self.token, source.mode(detected: detected) != .apiKey else { return false }
        services.webSessionChanged(true); revoke(); let current = revision
        history = .init(); historyLoaded = true; await persistHistory()
        guard revision == current, enabled else { return false }
        updateCredentialState(); await emit(); _ = await refreshIfDue(active: true, force: true); return true
    }
    /// Profile clearing happens in the browser host. Pause collection first so
    /// no read can recreate site data between cancellation and the clear.
    func beginDisconnect(token: String) async -> String? {
        guard enabled, !paused, token == self.token, services.removeKey() else { return nil }
        services.webSessionChanged(false); revoke(); paused = true; let current = revision
        history = .init(); historyLoaded = true; await persistHistory()
        guard revision == current, enabled else { return nil }
        updateCredentialState()
        error = source.mode(detected: detected) == .apiKey ? .missingKey : .signedOut
        await emit(); return self.token
    }
    func completeDisconnect(token: String, success: Bool) async -> Bool {
        guard enabled, paused, token == self.token else { return false }
        paused = false; updateCredentialState()
        if !success { error = .connectionFailed; disconnectFailed = true }
        await emit(); return true
    }
    func currentState() -> DeepSeekBalanceState {
        .init(context: context, token: token, source: source, detected: detected, balance: balance,
            history: history, error: error, refreshing: work != nil || paused, hasKey: hasKey, webAvailable: services.readWeb != nil)
    }
    var refreshCompletion: Task<Void, Never>? { work }
    func stop() { enabled = false; revoke() }
    private func revoke() {
        revision &+= 1; token = UUID().uuidString
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
    private func finish(_ result: Result<DeepSeekBalance, Error>, home: URL, revision: UInt64, attempt: UUID) async {
        guard enabled, self.revision == revision, self.attempt == attempt, !Task.isCancelled else { return }
        let actual = services.detect(home, recentProvider)
        if actual != detected {
            await configure(home: home, source: source, enabled: enabled, recentProvider: recentProvider, context: context)
            _ = await refreshIfDue(active: true, force: true); return
        }
        work = nil; self.attempt = nil
        switch result {
        case .success(let value):
            guard value.source == (source.mode(detected: detected) == .apiKey ? .apiKey : .web) else {
                error = .invalidReply; failures += 1; await emit(); return
            }
            balance = value; error = nil; failures = 0
            history.record(total: value.total, at: value.capturedAt, source: value.source.rawValue)
            await persistHistory()
            guard enabled, self.revision == revision else { return }
        case .failure(let failure):
            error = failure as? DeepSeekBalanceError ?? .connectionFailed
            if error?.needsConnection == true { balance = nil }
            failures = min(4, failures + 1)
        }
        await emit()
    }
}
