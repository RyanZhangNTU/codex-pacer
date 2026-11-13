import Foundation
import Darwin
import PacerCore

/// The Desktop owner supplies live IPC. For an assigned thread without usable
/// IPC, read bounded turn and tool-result pages over the same catalog connection.
enum MacDurableCatalog {
    /// A Dot task in flight or updated within the recent window, or a panel in
    /// view, polls every 15 seconds; otherwise every 90. A dark display pauses it.
    static let activeInterval: TimeInterval = 15, idleInterval: TimeInterval = 90

    static func observe(home: URL, peer: pid_t, publish: @Sendable (DurableActivityCatalog?) -> Void,
                        ipcObservations: @Sendable () -> [String: Date],
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
                guard let executor = MacDurableExecutor.find(peer: peer) else { throw CodexClientError.disconnected }
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
                guard MacDurableExecutor.find(peer: peer) == executor,
                      CodexClient.authenticationFingerprint(home: home, files: MacFileSystem()) == fingerprint else {
                    throw CodexClientError.accountMismatch
                }
                if previous?.scope != result.catalog.scope { polls.reset(startingNow: previous != nil) }
                previous = result.catalog
                publish(result.catalog)
                let now = Date()
                let history = try await polls.read(result, using: connection.reader,
                    ipc: ipcObservations(), receipts: mailbox.read(at:), at: now)
                if !history.isEmpty {
                    try Task.checkCancellation()
                    guard MacDurableExecutor.find(peer: peer) == executor,
                          CodexClient.authenticationFingerprint(home: home, files: MacFileSystem()) == fingerprint else {
                        throw CodexClientError.accountMismatch
                    }
                    publishHistory(result.catalog.scope, history)
                }
                retryDelay = 5
                let recent = now.addingTimeInterval(-DurableActivityCatalog.recentWindow)
                let busy = polls.followsActiveTurn || result.entries.contains { $0.active || ($0.updatedAt ?? .distantPast) >= recent } ||
                    ipcObservations().values.contains { $0 >= recent }
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
