import Foundation
import Darwin
import PacerCore

/// The Desktop owner supplies live IPC. For an assigned thread without usable
/// IPC, read bounded turn and tool-result pages over the same catalog connection.
enum MacDurableCatalog {
    private struct Binding: Equatable {
        let executor: MacDurableExecutor
        let fingerprint: String?

        func isCurrent(home: URL, peer: pid_t) -> Bool {
            MacDurableExecutor.find(peer: peer) == executor &&
                CodexClient.authenticationFingerprint(home: home, files: MacFileSystem()) == fingerprint
        }
    }

    static func observe(home: URL, peer: pid_t, publish: @Sendable (DurableActivityCatalog?) -> Void,
                        ipcObservations: @Sendable () -> [String: Date],
                        publishHistory: @Sendable (String, [DurableTurnHistory]) -> Void) async {
        var connection: Connection?
        var previous: DurableActivityCatalog?
        var verifiedBinding: Binding?
        var polls = DurableHistoryPoll()
        func revoke() {
            if previous != nil { polls.reset(startingNow: true) }
            previous = nil; verifiedBinding = nil; publish(nil)
        }
        let mailbox = MacDurableProgressMailbox(home: home)
        defer { connection?.close() }
        var retryDelay = 5.0
        while !Task.isCancelled {
            let delay: TimeInterval
            do {
                guard let executor = MacDurableExecutor.find(peer: peer) else { throw CodexClientError.disconnected }
                let fingerprint = CodexClient.authenticationFingerprint(home: home, files: MacFileSystem())
                let binding = Binding(executor: executor, fingerprint: fingerprint)
                if let verifiedBinding, verifiedBinding != binding { revoke() }
                if connection?.binding != binding || (connection?.expiresAt ?? .distantPast) <= Date() {
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
                    guard binding.isCurrent(home: home, peer: peer) else { throw CodexClientError.accountMismatch }
                    if let scope = previous?.scope, scope != credentials.scope { revoke() }
                    let next = Connection(request: credentials.request, scope: credentials.scope, binding: binding)
                    connection = next
                    try await next.reader.initialize()
                }
                guard let connection else { throw CodexClientError.disconnected }
                let result = try await connection.reader.read(retaining: previous, activeTurns: polls.activeThreads)
                try Task.checkCancellation()
                guard binding.isCurrent(home: home, peer: peer) else { throw CodexClientError.accountMismatch }
                if previous?.scope != result.catalog.scope { polls.reset(startingNow: previous != nil) }
                previous = result.catalog
                verifiedBinding = binding
                publish(result.catalog)
                let now = Date()
                let history = try await polls.read(result, using: connection.reader,
                    ipc: ipcObservations(), receipts: mailbox.read(at:), at: now)
                if !history.isEmpty {
                    try Task.checkCancellation()
                    guard binding.isCurrent(home: home, peer: peer) else { throw CodexClientError.accountMismatch }
                    publishHistory(result.catalog.scope, history)
                }
                retryDelay = 5
                delay = max(1, 15 - Date().timeIntervalSince(now))
            } catch {
                connection?.close()
                connection = nil
                if Task.isCancelled { break }
                switch error {
                case CodexClientError.notLoggedIn, CodexClientError.accountMismatch:
                    revoke()
                default:
                    if let previous, let verifiedBinding, verifiedBinding.fingerprint != nil,
                       verifiedBinding.isCurrent(home: home, peer: peer) {
                        // Drop live permissions during the outage. The verified account still owns its inbox.
                        publish(.init(scope: previous.scope, threadIDs: []))
                    } else {
                        revoke()
                    }
                }
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
        let binding: Binding
        let expiresAt = Date().addingTimeInterval(DurableCatalogReader.connectionLifetime)
        let reader: DurableCatalogReader

        init(request: URLRequest, scope: String, binding: Binding) {
            self.binding = binding
            reader = DurableCatalogReader(socket: Socket(request), scope: scope, environmentID: binding.executor.environmentID)
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
