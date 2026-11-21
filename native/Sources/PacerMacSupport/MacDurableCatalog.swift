import Foundation
import Darwin
import PacerCore

/// Codex sends Pacer no Dot events, so the catalog poll is the only source: the
/// catalog for which threads run here, then bounded turn and tool-result pages.
enum MacDurableCatalog {
    /// A Dot task in flight or updated within the recent window, or a panel in
    /// view, polls every 15 seconds; otherwise every 90. A dark display pauses it.
    static let activeInterval: TimeInterval = 15, idleInterval: TimeInterval = 90

    static func observe(home: URL, publish: @Sendable (DurableActivityCatalog?) -> Void,
                        publishHistory: @Sendable (String, [DurableTurnHistory]) -> Void,
                        panelInView: @Sendable () -> Bool = { false },
                        display: MacDisplayActivity? = .shared) async {
        var connection: Connection?
        var previous: DurableActivityCatalog?
        var polls = DurableHistoryPoll()
        let mailbox = MacDurableProgressMailbox(home: home)
        defer { connection?.close() }
        var retryDelay = 5.0
        while !Task.isCancelled {
            let delay: TimeInterval
            do {
                guard let executor = MacDurableExecutor.findRunning() else { throw CodexClientError.disconnected }
                let fingerprint = CodexClient.authenticationFingerprint(home: home, files: MacFileSystem())
                if connection?.executor != executor || connection?.fingerprint != fingerprint ||
                    (connection?.expiresAt ?? .distantPast) <= Date() {
                    connection?.close()
                    connection = nil
                    guard let cli = MacDurableExecutor.verifiedCLI(in: executor.application) else { throw CodexClientError.disconnected }
                    let client = CodexClient(executable: cli, home: home, timeout: 8)
                    let credentials: (request: URLRequest, scope: String)
                    do {
                        credentials = try await client.durableCatalogCredentials()
                    } catch {
                        await client.shutdown()
                        throw error
                    }
                    await client.shutdown()
                    try Task.checkCancellation()
                    let next = Connection(request: credentials.request, scope: credentials.scope,
                        executor: executor, fingerprint: fingerprint)
                    connection = next
                    try await next.reader.initialize()
                }
                guard let connection else { throw CodexClientError.disconnected }
                let result = try await connection.reader.read(retaining: previous)
                try Task.checkCancellation()
                guard MacDurableExecutor.findRunning() == executor,
                      CodexClient.authenticationFingerprint(home: home, files: MacFileSystem()) == fingerprint else {
                    throw CodexClientError.accountMismatch
                }
                if previous?.scope != result.catalog.scope { polls.reset(startingNow: previous != nil) }
                previous = result.catalog
                publish(result.catalog)
                let now = Date()
                let history = try await polls.read(result, using: connection.reader,
                    receipts: mailbox.read(at:), at: now)
                if !history.isEmpty {
                    try Task.checkCancellation()
                    guard MacDurableExecutor.findRunning() == executor,
                          CodexClient.authenticationFingerprint(home: home, files: MacFileSystem()) == fingerprint else {
                        throw CodexClientError.accountMismatch
                    }
                    publishHistory(result.catalog.scope, history)
                }
                retryDelay = 5
                let recent = now.addingTimeInterval(-DurableActivityCatalog.recentWindow)
                let busy = polls.followsActiveTurn || result.entries.contains { $0.active || ($0.updatedAt ?? .distantPast) >= recent }
                delay = max(1, (busy ? activeInterval : idleInterval) - Date().timeIntervalSince(now))
            } catch {
                connection?.close()
                connection = nil
                if Task.isCancelled { break }
                publish(nil)
                delay = retryDelay
                retryDelay = min(60, retryDelay * 2)
            }
            do { try await pace(delay, panelInView: panelInView, isDark: { display?.isDark == true }) } catch { break }
        }
    }

    /// Opening the panel shortens an idle wait to the active interval; a dark
    /// display holds the next read until it lights, then reads at once.
    static func pace(_ delay: TimeInterval, panelInView: () -> Bool, isDark: () -> Bool,
                     clock: () -> Date = { Date() }, step: TimeInterval = 5) async throws {
        let start = clock()
        var darkened = false
        while true {
            if isDark() { darkened = true }
            else if darkened { return }
            else {
                let due = panelInView() ? min(delay, activeInterval) : delay
                let remaining = due - clock().timeIntervalSince(start)
                if remaining <= 0 { return }
                try await Task.sleep(for: .seconds(min(step, remaining)))
                continue
            }
            try await Task.sleep(for: .seconds(step))
        }
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private final class Connection {
        let executor: MacDurableExecutor
        let fingerprint: String?
        let expiresAt = Date().addingTimeInterval(DurableCatalogReader.connectionLifetime)
        let reader: DurableCatalogReader

        init(request: URLRequest, scope: String, executor: MacDurableExecutor, fingerprint: String?) {
            self.executor = executor; self.fingerprint = fingerprint
            reader = DurableCatalogReader(socket: Socket(request), scope: scope, environmentID: executor.environmentID)
        }

        func close() { reader.close() }
    }

    private final class Socket: DurableCatalogSocket, @unchecked Sendable {
        private let session: URLSession
        private let socket: URLSessionWebSocketTask

        init(_ request: URLRequest) {
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
            session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
            socket = session.webSocketTask(with: request)
            socket.maximumMessageSize = 4 * 1024 * 1024
            socket.resume()
        }

        func send(_ bytes: Data) async throws { try await socket.send(.string(String(decoding: bytes, as: UTF8.self))) }

        func receive() async throws -> Data {
            switch try await socket.receive() {
            case .data(let bytes): return bytes
            case .string(let text): return Data(text.utf8)
            @unknown default: throw CodexClientError.invalidResponse
            }
        }

        func close() {
            socket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }
    }
}

/// Follows Dot tasks while the Dot switch and the Codex module are on.
public final class MacDurableMonitor: @unchecked Sendable {
    /// One poll of a Codex home: it reports the catalog and the latest turns until cancelled.
    package typealias Observe = @Sendable (_ home: URL, _ catalog: @escaping @Sendable (DurableActivityCatalog?) -> Void,
                                           _ history: @escaping @Sendable (String, [DurableTurnHistory]) -> Void,
                                           _ panelInView: @escaping @Sendable () -> Bool) async -> Void
    private let observe: Observe
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var home: URL?
    private var state = DurableActivityState()
    private var generation = 0

    public convenience init() {
        self.init { home, catalog, history, panelInView in
            await MacDurableCatalog.observe(home: home, publish: catalog, publishHistory: history, panelInView: panelInView)
        }
    }
    package init(observe: @escaping Observe) { self.observe = observe }

    /// `publish` receives the current Dot tasks and the account scope, in order.
    /// A poll already following `home` keeps going with its state: route refreshes
    /// ask again every 30 seconds, and starting over would treat a turn that ended
    /// since the last poll as history.
    public func start(home: URL, panelInView: @escaping @Sendable () -> Bool,
                      publish: @escaping @Sendable ([SessionActivity], String?) -> Void) {
        lock.lock()
        if task != nil, self.home == home { lock.unlock(); return }
        task?.cancel(); state = DurableActivityState(); generation += 1; self.home = home
        let current = generation
        lock.unlock()
        let emit: @Sendable ((inout DurableActivityState) -> Void) -> Void = { [weak self] change in
            guard let self else { return }
            self.lock.lock()
            guard self.generation == current else { self.lock.unlock(); return }
            change(&self.state)
            let activities = self.state.activities, scope = self.state.scope
            self.state.releasePublishedState()
            self.lock.unlock()
            publish(activities, scope)
        }
        let observe = self.observe
        let started = Task.detached(priority: .utility) {
            await observe(home, { catalog in emit { $0.setCatalog(catalog) } },
                          { scope, turns in emit { $0.observe(turns, scope: scope, at: Date()) } }, panelInView)
        }
        lock.lock(); if generation == current { task = started } else { started.cancel() }; lock.unlock()
    }

    public func stop() {
        lock.lock(); task?.cancel(); task = nil; home = nil; generation += 1; state = DurableActivityState(); lock.unlock()
    }
}
