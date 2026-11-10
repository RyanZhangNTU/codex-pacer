import Foundation
import Darwin
import PacerCore

/// A read-only companion to the Desktop socket. The cloud connection can only
/// seed IPC interests for Dot threads assigned to this Desktop's executor.
enum MacDurableCatalog {
    static func observe(home: URL, peer: pid_t, publish: @Sendable (DurableActivityCatalog?) -> Void) async {
        var connection: Connection?
        var previous: DurableActivityCatalog?
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
                    let client = CodexClient(executable: executor.cli, home: home, timeout: 8)
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
                    try await next.initialize()
                }
                guard let connection else { throw CodexClientError.disconnected }
                let result = try await connection.read(retaining: previous)
                try Task.checkCancellation()
                guard MacDurableExecutor.find(peer: peer) == executor,
                      CodexClient.authenticationFingerprint(home: home, files: MacFileSystem()) == fingerprint else {
                    throw CodexClientError.accountMismatch
                }
                if previous?.scope != result.catalog.scope { await MacDurableRefresh.shared.interrupt(home: home) }
                previous = result.catalog
                publish(result.catalog)
                await MacDurableRefresh.shared.observe(home: home, executor: executor, catalogIdle: result.executorIdle)
                retryDelay = 5
                delay = 15
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
        private let scope: String
        private let session: URLSession
        private let socket: URLSessionWebSocketTask
        private var nextID = 0

        init(request: URLRequest, scope: String, executor: MacDurableExecutor, fingerprint: String?) {
            self.scope = scope; self.executor = executor; self.fingerprint = fingerprint
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
            session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
            socket = session.webSocketTask(with: request)
            socket.maximumMessageSize = 4 * 1024 * 1024
            socket.resume()
        }

        func close() {
            socket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        func initialize() async throws {
            _ = try await request("initialize", params: [
                "clientInfo": ["name": "codex-pacer", "title": "Codex Pacer", "version": "1"],
                "capabilities": ["experimentalApi": true]
            ])
            try await socket.send(.string(#"{"method":"initialized","params":{}}"#))
        }

        func read(retaining previous: DurableActivityCatalog?) async throws -> (catalog: DurableActivityCatalog, executorIdle: Bool) {
            var ids: [String] = [], cursor: String?
            var idle = true, complete = false
            for _ in 0..<4 {
                var params: [String: Any] = [
                    "limit": 50, "archived": false, "useStateDbOnly": true, "sortKey": "updated_at", "sortDirection": "desc"
                ]
                if let cursor { params["cursor"] = cursor }
                let reply = try await request("thread/list", params: params)
                let fields = try JSONFieldView.document(reply).fields(["result"])
                guard let result = fields["result"] else { throw CodexClientError.invalidResponse }
                let page = try DurableActivityCatalog.page(result, environmentID: executor.environmentID,
                    retaining: previous?.scope == scope ? previous?.threadIDs ?? [] : [])
                ids.append(contentsOf: page.threadIDs)
                idle = idle && page.executorIdle
                guard let next = page.nextCursor else { complete = true; break }
                guard ids.count < 64, next != cursor else { break }
                cursor = next
            }
            return (DurableActivityCatalog(scope: scope, threadIDs: ids), idle && complete)
        }

        private func request(_ method: String, params: [String: Any]) async throws -> Data {
            nextID += 1
            let id = nextID, socket = socket
            let bytes = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                socket.cancel(with: .goingAway, reason: nil)
            }
            defer { timeout.cancel() }
            return try await withTaskCancellationHandler {
                try await socket.send(.string(String(decoding: bytes, as: UTF8.self)))
                for _ in 0..<256 {
                    let data: Data
                    switch try await socket.receive() {
                    case .data(let bytes): data = bytes
                    case .string(let text): data = Data(text.utf8)
                    @unknown default: throw CodexClientError.invalidResponse
                    }
                    let fields = try JSONFieldView.document(data).fields(["id", "result"])
                    guard fields["id"]?.integer() == id else { continue }
                    guard fields["result"] != nil else { throw CodexClientError.invalidResponse }
                    return data
                }
                throw CodexClientError.invalidResponse
            } onCancel: {
                socket.cancel(with: .goingAway, reason: nil)
            }
        }
    }
}
