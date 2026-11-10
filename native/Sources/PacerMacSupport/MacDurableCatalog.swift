import Foundation
import Darwin
import PacerCore

/// The Desktop owner supplies live IPC. For an assigned thread without usable
/// IPC, read bounded turn and tool-result pages over the same catalog connection.
enum MacDurableCatalog {
    static func observe(home: URL, peer: pid_t, publish: @Sendable (DurableActivityCatalog?) -> Void,
                        ipcObservations: @Sendable () -> [String: Date],
                        publishHistory: @Sendable (String, [DurableTurnHistory]) -> Void) async {
        var connection: Connection?
        var previous: DurableActivityCatalog?
        var polls = DurableHistoryPoll()
        let mailbox = MacDurableProgressMailbox(home: home)
        defer { connection?.close() }
        await MacDurableRefresh.shared.interrupt(home: home)
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
                if previous?.scope != result.catalog.scope {
                    await MacDurableRefresh.shared.interrupt(home: home)
                    polls.reset(startingNow: previous != nil)
                }
                previous = result.catalog
                publish(result.catalog)
                let now = Date()
                let (history, newestLocalReportTurnStart) = try await polls.read(result, using: connection.reader,
                    ipc: ipcObservations(), receipts: mailbox.read(at:), at: now)
                if !history.isEmpty {
                    try Task.checkCancellation()
                    guard MacDurableExecutor.find(peer: peer) == executor,
                          CodexClient.authenticationFingerprint(home: home, files: MacFileSystem()) == fingerprint else {
                        throw CodexClientError.accountMismatch
                    }
                    publishHistory(result.catalog.scope, history)
                }
                // Verify any available receipt before considering a refresh.
                // History reads can outlast the catalog's idle observation.
                try Task.checkCancellation()
                let recentlyIdle = result.executorIdle && Date().timeIntervalSince(now) < 1
                await MacDurableRefresh.shared.observe(home: home, executor: executor, catalogIdle: recentlyIdle,
                                                       verifiedReportTurnStartedAt: newestLocalReportTurnStart)
                retryDelay = 5
                delay = max(1, 15 - Date().timeIntervalSince(now))
            } catch {
                connection?.close()
                connection = nil
                await MacDurableRefresh.shared.interrupt(home: home)
                if Task.isCancelled { break }
                publish(nil)
                delay = retryDelay
                retryDelay = min(60, retryDelay * 2)
            }
            do { try await Task.sleep(for: .seconds(delay)) } catch { break }
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
        let expiresAt = Date().addingTimeInterval(120)
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
