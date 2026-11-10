import Foundation
import Darwin
import PacerCore

/// The Desktop owner supplies live IPC. For an assigned thread without usable
/// IPC, read bounded turn and tool-result pages over the same catalog connection.
enum MacDurableCatalog {
    private struct Poll {
        let checkedAt: Date
        let updatedAt: Date?
        var activeTurn: String?
        var settled = false
    }

    static func observe(home: URL, peer: pid_t, publish: @Sendable (DurableActivityCatalog?) -> Void,
                        ipcObservations: @Sendable () -> [String: Date],
                        publishHistory: @Sendable (String, [DurableTurnHistory]) -> Void) async {
        var connection: Connection?
        var previous: DurableActivityCatalog?
        var polls: [String: Poll] = [:]
        let mailbox = MacDurableProgressMailbox(home: home)
        var since = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
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
                    try await next.initialize()
                }
                guard let connection else { throw CodexClientError.disconnected }
                let result = try await connection.read(retaining: previous)
                try Task.checkCancellation()
                guard MacDurableExecutor.find(peer: peer) == executor,
                      CodexClient.authenticationFingerprint(home: home, files: MacFileSystem()) == fingerprint else {
                    throw CodexClientError.accountMismatch
                }
                if previous?.scope != result.catalog.scope {
                    await MacDurableRefresh.shared.interrupt(home: home)
                    polls.removeAll()
                    if previous != nil { since = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)) }
                }
                previous = result.catalog
                publish(result.catalog)
                let now = Date(), ipc = ipcObservations()
                polls = polls.filter { result.catalog.threadIDs.contains($0.key) }
                let candidates = result.entries.filter { entry in
                    let previous = polls[entry.id]
                    guard ipc[entry.id].map({ now.timeIntervalSince($0) >= 20 }) ?? true else { return false }
                    if entry.active || previous?.activeTurn != nil { return true }
                    if previous?.settled == true && previous?.updatedAt == entry.updatedAt { return false }
                    return entry.updatedAt.map { $0 >= since } ?? false
                }.sorted {
                    (polls[$0.id]?.checkedAt ?? .distantPast) < (polls[$1.id]?.checkedAt ?? .distantPast)
                }
                let receipts = candidates.isEmpty ? [:] : mailbox.read(at: now)
                var history: [DurableTurnHistory] = []
                var newestLocalReportTurnStart: Date?
                for entry in candidates.prefix(4) {
                    try Task.checkCancellation()
                    if Date().timeIntervalSince(now) >= 6 { break }
                    let previous = polls[entry.id]
                    var poll = Poll(checkedAt: now, updatedAt: entry.updatedAt, activeTurn: previous?.activeTurn)
                    polls[entry.id] = poll
                    do {
                        guard var turn = try await connection.latestTurn(entry) else { continue }
                        let active = turn.status == .inProgress
                        poll.settled = !active
                        poll.activeTurn = active ? turn.turnID : nil
                        if active || (turn.completedAt ?? turn.startedAt).map({ $0 >= since }) == true || previous?.activeTurn == turn.turnID {
                            if let receipt = receipts[entry.id + ":" + turn.turnID.lowercased()],
                               turn.useLocalReceipt(receipt), let startedAt = turn.startedAt {
                                newestLocalReportTurnStart = max(newestLocalReportTurnStart ?? .distantPast, startedAt)
                            }
                            // The Mac receipt can arrive before Durable history persists the
                            // call. A failed item page cannot erase the verified turn.
                            if turn.report == nil || !active,
                               let persisted = try? await connection.latestReport(turn, thread: entry.id),
                               turn.report == nil || (persisted.at ?? .distantPast) >= (turn.report?.at ?? .distantPast) {
                                turn.report = persisted
                            }
                            history.append(turn)
                        }
                        polls[entry.id] = poll
                    } catch {
                        // An unavailable history page must not discard the
                        // valid catalog or interrupt normal Desktop IPC.
                        break
                    }
                }
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

        func read(retaining previous: DurableActivityCatalog?) async throws
            -> (catalog: DurableActivityCatalog, entries: [DurableActivityCatalog.Entry], executorIdle: Bool) {
            var entries: [DurableActivityCatalog.Entry] = [], cursor: String?
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
                for entry in page.entries where entries.count < 64 && !entries.contains(where: { $0.id == entry.id }) {
                    entries.append(entry)
                }
                idle = idle && page.executorIdle
                guard let next = page.nextCursor else { complete = true; break }
                guard entries.count < 64, next != cursor else { break }
                cursor = next
            }
            return (DurableActivityCatalog(scope: scope, threadIDs: entries.map(\.id)), entries, idle && complete)
        }

        func latestTurn(_ thread: DurableActivityCatalog.Entry) async throws -> DurableTurnHistory? {
            let result = try await response("thread/turns/list", params: [
                "threadId": thread.id, "limit": 1, "sortDirection": "desc", "itemsView": "notLoaded"
            ])
            return try DurableTurnHistory.latest(result, thread: thread)
        }

        func latestReport(_ turn: DurableTurnHistory, thread: String) async throws -> DurableTurnHistory.Report? {
            var cursor: String?
            for _ in 0..<2 {
                var params: [String: Any] = ["threadId": thread, "turnId": turn.turnID, "limit": 32, "sortDirection": "desc"]
                if let cursor { params["cursor"] = cursor }
                let page = try turn.receiptPage(await response("thread/items/list", params: params))
                if let report = page.report { return report }
                guard let next = page.next, next != cursor else { break }
                cursor = next
            }
            return nil
        }

        private func response(_ method: String, params: [String: Any]) async throws -> JSONFieldView {
            let reply = try await request(method, params: params)
            let fields = try JSONFieldView.document(reply).fields(["result"])
            guard let result = fields["result"] else { throw CodexClientError.invalidResponse }
            return result
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
