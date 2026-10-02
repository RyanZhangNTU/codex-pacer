import Foundation

public struct RuntimeStreamStatus: Equatable, Sendable {
    public var connected = false
    public var attachedThreads = 0
    public var notifications = 0
    public var fallbackScans = 0
    public var watchingLogs = false
    public var helperCpuSeconds = 0.0
    public var helperLoopIterations = 0
    public init() {}
}

/// Runtime data overlays only the corresponding source/thread. An accessible
/// socket without item evidence never masks a task discovered in its log.
struct RuntimeEventState: Sendable {
    private var fallback: [String: SessionActivity] = [:]
    private var live: [String: SessionActivity] = [:]
    private(set) var status = RuntimeStreamStatus()
    let sourceID: String?
    let sourceName: String?

    init(sourceID: String?, sourceName: String?) { self.sourceID = sourceID; self.sourceName = sourceName }
    var activities: [SessionActivity] {
        ActivitySourceMerger.merge(logged: Array(fallback.values),
            streamed: live.values.filter { $0.hasLiveEvidence && (status.connected || [.completed, .interrupted].contains($0.phase)) })
    }
    mutating func replaceLocalFallback(_ values: [SessionActivity]) {
        fallback = Dictionary(values.map { ($0.canonicalized().id, $0.canonicalized()) }, uniquingKeysWith: { _, newer in newer })
    }
    mutating func consume(_ frame: [String: Any]) {
        if frame["kind"] as? String == "runtimeBatch", let events = frame["events"] as? [[String: Any]], events.count <= 512 {
            for event in events { consume(["kind": "runtime", "event": event]) }
        } else if frame["kind"] as? String == "status" {
            status.connected = frame["connected"] as? Bool == true
            status.attachedThreads = frame["attached"] as? Int ?? 0
            status.notifications = frame["notifications"] as? Int ?? 0
            status.fallbackScans = frame["fallbackScans"] as? Int ?? 0
            status.watchingLogs = frame["watchingLogs"] as? Bool == true
            status.helperCpuSeconds = frame["helperCpuSeconds"] as? Double ?? 0
            status.helperLoopIterations = frame["helperLoopIterations"] as? Int ?? 0
            if !status.connected { live = live.filter { [.completed, .interrupted].contains($0.value.phase) } }
        } else if frame["kind"] as? String == "runtime", let event = frame["event"] as? [String: Any],
                  let thread = event["threadId"] as? String, UUID(uuidString: thread) != nil {
            let id = (sourceID ?? "local") + ":" + thread.lowercased()
            var value = live[id] ?? fallback[id] ?? SessionActivity(id: id, sourceHost: sourceName, sourceHostID: sourceID, phaseAwareRate: true)
            value.consumeLive(event)
            live[id] = value
        } else if let rows = frame["sessions"] as? [[String: Any]] {
            var current: [String: SessionActivity] = [:]
            for row in rows {
                guard let file = row["id"] as? String, file.count < 256, let records = row["records"] as? [[String: Any]] else { continue }
                let seeded = SessionActivity(id: (sourceID ?? "local") + ":" + file,
                    sourceHost: sourceName, sourceHostID: sourceID, phaseAwareRate: true).canonicalized()
                var value = row["reset"] as? Bool == true ? seeded : (fallback[seeded.id] ?? seeded)
                let partial = row["partial"] as? Bool == true
                let prelude = row["preludeCount"] as? Int ?? 0
                if partial && prelude == 0 { value.markPartialRate() }
                for (index, record) in records.enumerated() {
                    if let bytes = try? JSONSerialization.data(withJSONObject: record) { value.consume(bytes) }
                    if partial && index + 1 == prelude { value.markPartialRate() }
                }
                value.updateTitle(row["title"] as? String)
                if fallback[seeded.id] == nil, [.running, .waitingForInput].contains(value.phase),
                   Date().timeIntervalSince(value.lastObserved ?? .distantPast) > 900 { value.markUnconfirmed() }
                current[value.canonicalized().id] = value.canonicalized()
            }
            fallback = current
        }
    }
}
