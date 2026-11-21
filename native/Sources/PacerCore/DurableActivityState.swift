import Foundation

/// Dot tasks from the catalog poll alone. The catalog says which threads this
/// computer's executor runs; each thread's latest turn says whether it runs,
/// how it ended and its last progress report. Codex sends no Dot events to
/// Pacer, so nothing else adds or ends a Dot task.
public struct DurableActivityState: Sendable {
    private var catalog: DurableActivityCatalog?
    private var histories: [String: DurableTurnHistory] = [:]
    private var runtime = RuntimeEventState(sourceID: DurableActivityCatalog.hostID, sourceName: nil)

    public init() {}

    /// The account the catalog belongs to, which scopes acknowledgments.
    public var scope: String? { catalog?.scope }

    /// Only threads the current catalog lists.
    public var activities: [SessionActivity] {
        guard let catalog else { return [] }
        return runtime.activities.filter { $0.threadID.map(catalog.threadIDs.contains) ?? false }
    }

    /// A new account or executor starts over; a thread that leaves the catalog leaves the list.
    public mutating func setCatalog(_ value: DurableActivityCatalog?) {
        if value?.scope != catalog?.scope {
            histories.removeAll()
            runtime = RuntimeEventState(sourceID: DurableActivityCatalog.hostID, sourceName: nil)
        }
        catalog = value
        histories = histories.filter { value?.threadIDs.contains($0.key) == true }
    }

    /// Applies the latest turns the poll read. A turn already seen ended is not replayed,
    /// and an older turn cannot replace a newer one.
    package mutating func observe(_ observations: [DurableTurnHistory], scope: String, at now: Date) {
        guard let catalog, catalog.scope == scope else { return }
        var events: [[String: Any]] = []
        for var history in observations where catalog.threadIDs.contains(history.threadID) {
            let thread = history.threadID, turn = history.turnID
            let previous = histories[thread]
            let sameTurn = previous?.turnID == turn
            if sameTurn, previous?.status != .inProgress { continue }
            if !sameTurn, let start = history.startedAt, let previousStart = previous?.startedAt, start < previousStart { continue }
            func event(_ method: String, at date: Date = now) -> [String: Any] {
                ["method": method, "threadId": thread, "turnId": turn, "at": date.timeIntervalSince1970]
            }
            if let name = history.name, previous?.name != name {
                var metadata = event("thread/name/updated"); metadata["name"] = name
                events.append(metadata)
            }
            if !sameTurn {
                var start = event("turn/attached")
                start["startedAt"] = min(history.startedAt ?? history.report?.at ?? history.completedAt ?? now, now).timeIntervalSince1970
                start["rootTurnId"] = history.rootTurnID
                events.append(start)
            }
            let previousReport = sameTurn ? previous?.report : nil
            if let report = history.report, report.id != previousReport?.id, (report.at ?? now) >= (previousReport?.at ?? .distantPast) {
                var progress = event("progress/reported", at: min(report.at ?? history.completedAt ?? now, now))
                progress["percent"] = report.percent
                events.append(progress)
            } else {
                history.report = previousReport
            }
            histories[thread] = history
            if history.status != .inProgress {
                let at = min(max(history.completedAt ?? now, history.report?.at ?? .distantPast), now)
                var end = event("turn/completed", at: at); end["status"] = history.status.rawValue
                events.append(end)
                events.append(event("stream/released", at: at))
            }
        }
        guard !events.isEmpty else { return }
        if !runtime.status.connected { runtime.consume(["kind": "status", "connected": true]) }
        for start in stride(from: 0, to: events.count, by: 512) {
            runtime.consume(["kind": "runtimeBatch", "events": Array(events[start..<min(events.count, start + 512)])])
        }
    }

    /// Drops what the last publication already carried, as other sources do.
    public mutating func releasePublishedState() { runtime.releasePublishedState() }
}
