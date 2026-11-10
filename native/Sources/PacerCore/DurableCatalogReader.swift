import Foundation

/// A single reader uses a socket at a time. The hosts choose the transport
/// and verify the account and executor before publishing what it reads.
package protocol DurableCatalogSocket: Sendable {
    func send(_ bytes: Data) async throws
    func receive() async throws -> Data
    func close()
}

package final class DurableCatalogReader {
    package struct Result {
        package let catalog: DurableActivityCatalog
        package let entries: [DurableActivityCatalog.Entry]
        package let executorIdle: Bool
    }

    private let socket: any DurableCatalogSocket
    private let scope: String
    private let environmentID: String
    private var nextID = 0

    package init(socket: any DurableCatalogSocket, scope: String, environmentID: String) {
        self.socket = socket; self.scope = scope; self.environmentID = environmentID
    }

    package func close() { socket.close() }

    package func initialize() async throws {
        _ = try await request("initialize", params: [
            "clientInfo": ["name": "codex-pacer", "title": "Codex Pacer", "version": "1"],
            "capabilities": ["experimentalApi": true]
        ])
        try await socket.send(Data(#"{"method":"initialized","params":{}}"#.utf8))
    }

    package func read(retaining previous: DurableActivityCatalog?) async throws -> Result {
        var entries: [DurableActivityCatalog.Entry] = [], cursor: String?
        var idle = true, complete = false
        for _ in 0..<4 {
            var params: [String: Any] = [
                "limit": 50, "archived": false, "useStateDbOnly": true, "sortKey": "updated_at", "sortDirection": "desc"
            ]
            if let cursor { params["cursor"] = cursor }
            let page = try DurableActivityCatalog.page(await request("thread/list", params: params),
                environmentID: environmentID, retaining: previous?.scope == scope ? previous?.threadIDs ?? [] : [])
            for entry in page.entries where entries.count < 64 && !entries.contains(where: { $0.id == entry.id }) {
                entries.append(entry)
            }
            idle = idle && page.executorIdle
            guard let next = page.nextCursor else { complete = true; break }
            guard entries.count < 64, next != cursor else { break }
            cursor = next
        }
        return Result(catalog: .init(scope: scope, threadIDs: entries.map(\.id)), entries: entries, executorIdle: idle && complete)
    }

    package func latestTurn(_ thread: DurableActivityCatalog.Entry) async throws -> DurableTurnHistory? {
        let result = try await request("thread/turns/list", params: [
            "threadId": thread.id, "limit": 1, "sortDirection": "desc", "itemsView": "notLoaded"
        ])
        return try DurableTurnHistory.latest(result, thread: thread)
    }

    package func latestReport(_ turn: DurableTurnHistory, thread: String) async throws -> DurableTurnHistory.Report? {
        var cursor: String?
        for _ in 0..<2 {
            var params: [String: Any] = ["threadId": thread, "turnId": turn.turnID, "limit": 32, "sortDirection": "desc"]
            if let cursor { params["cursor"] = cursor }
            let page = try turn.receiptPage(await request("thread/items/list", params: params))
            if let report = page.report { return report }
            guard let next = page.next, next != cursor else { break }
            cursor = next
        }
        return nil
    }

    private func request(_ method: String, params: [String: Any]) async throws -> JSONFieldView {
        nextID += 1
        let id = nextID, socket = socket
        let bytes = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            socket.close()
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await socket.send(bytes)
            for _ in 0..<256 {
                let fields = try JSONFieldView.document(await socket.receive()).fields(["id", "result"])
                guard fields["id"]?.integer() == id else { continue }
                guard let result = fields["result"] else { throw CodexClientError.invalidResponse }
                return result
            }
            throw CodexClientError.invalidResponse
        } onCancel: {
            socket.close()
        }
    }
}

/// Only recent turns or a turn already seen in flight can add activity.
/// Rotate the candidates so a busy executor cannot starve the later rows.
package struct DurableHistoryPoll {
    private struct Poll {
        let checkedAt: Date
        let updatedAt: Date?
        var activeTurn: String?
        var settled = false
    }

    private var polls: [String: Poll] = [:]
    private var since = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))

    package init() {}

    package mutating func reset(startingNow: Bool) {
        polls.removeAll()
        if startingNow { since = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)) }
    }

    package mutating func read(_ result: DurableCatalogReader.Result, using connection: DurableCatalogReader,
                               ipc: [String: Date], receipts readReceipts: (Date) -> [String: DurableProgressReceipt],
                               at now: Date) async throws -> (history: [DurableTurnHistory], latestReportTurnStart: Date?) {
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
        let receipts = candidates.isEmpty ? [:] : readReceipts(now)
        var history: [DurableTurnHistory] = [], latestReportTurnStart: Date?
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
                        latestReportTurnStart = max(latestReportTurnStart ?? .distantPast, startedAt)
                    }
                    if turn.report == nil || !active,
                       let persisted = try? await connection.latestReport(turn, thread: entry.id),
                       turn.report == nil || (persisted.at ?? .distantPast) >= (turn.report?.at ?? .distantPast) {
                        turn.report = persisted
                    }
                    history.append(turn)
                }
                polls[entry.id] = poll
            } catch {
                // A failed history page cannot revoke a valid catalog or IPC.
                break
            }
        }
        return (history, latestReportTurnStart)
    }
}
