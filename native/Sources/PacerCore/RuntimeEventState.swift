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
    private var metricLogs: [String: SessionActivity] = [:]
    private var metricUpdates: [String: SessionPerformanceUpdate] = [:]
    private var names: [String: SessionNameUpdate] = [:]
    private var invalidated: Set<String> = []
    private var released: Set<String> = []
    private var idleOrder: [String: Int] = [:]
    private var confirmedIdle: [String: Date] = [:]
    private var arrival = 0
    private var snapshotID: String?
    private var nextSnapshotPart = 0
    private var stagedFallback: [String: SessionActivity] = [:]
    private(set) var status = RuntimeStreamStatus()
    let sourceID: String?
    let sourceName: String?

    init(sourceID: String?, sourceName: String?) { self.sourceID = sourceID; self.sourceName = sourceName }
    var performanceUpdates: [SessionPerformanceUpdate] { Array(metricUpdates.values) }
    var nameUpdates: [SessionNameUpdate] { Array(names.values) }
    var activities: [SessionActivity] {
        ActivitySourceMerger.merge(logged: Array(fallback.values),
            streamed: live.values.filter {
                (status.connected && ($0.hasLiveEvidence || invalidated.contains($0.id))) ||
                ($0.hasLiveEvidence && [.completed, .interrupted].contains($0.phase))
            }).map { value in
                var value = value
                if let logged = metricLogs[value.id] { value.mergePerformance(from: logged) }
                return value
            }.filter { value in
                guard let idle = confirmedIdle[value.id], ![.completed, .interrupted].contains(value.phase) else { return true }
                return (value.phaseChangedAt ?? value.turnStartedAt ?? .distantPast) > idle
            }
    }
    mutating func replaceLocalFallback(_ values: [SessionActivity]) {
        fallback = Dictionary(values.map { ($0.canonicalized().id, $0.canonicalized()) }, uniquingKeysWith: { _, newer in newer })
    }
    func isConfirmedIdle(thread: String) -> Bool {
        let id = (sourceID ?? "local") + ":" + thread.lowercased()
        guard let idle = confirmedIdle[id] else { return false }
        return ![live[id], fallback[id]].compactMap { $0 }.contains {
            [.running, .waitingForInput].contains($0.phase) && ($0.phaseChangedAt ?? .distantPast) > idle
        }
    }
    /// Deliver terminal/gap evidence once before reclaiming unloaded transport
    /// state. CompletionInbox owns card retention and rejects older log replay.
    mutating func releasePublishedState() {
        metricUpdates.removeAll()
        for id in released {
            if let value = live[id], let logged = fallback[id],
               let merged = ActivitySourceMerger.merge(logged: [logged], streamed: [value]).first {
                fallback[id] = merged
            }
            live.removeValue(forKey: id)
            names.removeValue(forKey: id)
            invalidated.remove(id)
            idleOrder.removeValue(forKey: id)
        }
        released.removeAll()
    }
    mutating func consume(_ frame: [String: Any]) {
        if frame["kind"] as? String == "performance", let rows = frame["sessions"] as? [[String: Any]], rows.count <= 32 {
            for row in rows {
                guard let thread = row["threadId"] as? String, UUID(uuidString: thread) != nil,
                      let records = row["records"] as? [[String: Any]], records.count <= 512 else { continue }
                let id = (sourceID ?? "local") + ":" + thread.lowercased()
                var value = row["reset"] as? Bool == true ? nil : metricLogs[id]
                if value == nil { value = SessionActivity(id: id, sourceHost: sourceName, sourceHostID: sourceID, phaseAwareRate: true) }
                let prelude = row["preludeCount"] as? Int ?? 0
                for (index, record) in records.enumerated() {
                    if let bytes = try? JSONSerialization.data(withJSONObject: record) { value!.consume(bytes) }
                    if row["partial"] as? Bool == true, index + 1 == prelude { value!.markPartialRate() }
                }
                metricLogs[id] = value
                if let update = SessionPerformanceUpdate(value!) { metricUpdates[id] = update }
            }
            if metricLogs.count > 64 {
                for id in metricLogs.keys.sorted(by: { (metricLogs[$0]?.lastObserved ?? .distantPast) > (metricLogs[$1]?.lastObserved ?? .distantPast) }).dropFirst(64) {
                    metricLogs.removeValue(forKey: id); metricUpdates.removeValue(forKey: id)
                }
            }
        } else if frame["kind"] as? String == "streamInvalidated", let thread = frame["threadId"] as? String {
            let id = (sourceID ?? "local") + ":" + thread.lowercased()
            if var value = live[id], ![.completed, .interrupted].contains(value.phase) {
                value.markUnconfirmed(); live[id] = value; invalidated.insert(id)
            }
        } else if frame["kind"] as? String == "runtimeBatch", let events = frame["events"] as? [[String: Any]], events.count <= 512 {
            for event in events { consume(["kind": "runtime", "event": event]) }
        } else if frame["kind"] as? String == "status" {
            status.connected = frame["connected"] as? Bool == true
            status.attachedThreads = frame["attached"] as? Int ?? 0
            status.notifications = frame["notifications"] as? Int ?? 0
            status.fallbackScans = frame["fallbackScans"] as? Int ?? 0
            status.watchingLogs = frame["watchingLogs"] as? Bool == true
            status.helperCpuSeconds = frame["helperCpuSeconds"] as? Double ?? 0
            status.helperLoopIterations = frame["helperLoopIterations"] as? Int ?? 0
            if !status.connected {
                live = live.filter { [.completed, .interrupted].contains($0.value.phase) }
                names = names.filter { live[$0.key] != nil }
                invalidated.removeAll()
                idleOrder = idleOrder.filter { live[$0.key] != nil }
                released.formIntersection(live.keys)
                snapshotID = nil; stagedFallback.removeAll()
            }
        } else if frame["kind"] as? String == "runtime", let event = frame["event"] as? [String: Any],
                  let thread = event["threadId"] as? String, UUID(uuidString: thread) != nil {
            let id = (sourceID ?? "local") + ":" + thread.lowercased()
            if event["method"] as? String == "thread/status/changed",
               ["notLoaded", "systemError"].contains(event["status"] as? String ?? ""), isConfirmedIdle(thread: thread) {
                // Terminal state may already have been published and reclaimed.
                // A later unload cannot create a fresh unknown task that clears
                // the completion inbox. A confirmed new turn clears this guard.
                if event["status"] as? String == "notLoaded" { released.insert(id) }
                return
            }
            var value = live[id] ?? fallback[id] ?? SessionActivity(id: id, sourceHost: sourceName, sourceHostID: sourceID, phaseAwareRate: true)
            if event["method"] as? String == "stream/released" {
                if ![.completed, .interrupted].contains(value.phase) { value.markUnconfirmed(); invalidated.insert(id) }
                live[id] = value; released.insert(id)
                return
            }
            value.consumeLive(event)
            let method = event["method"] as? String
            let hasName = (event["name"] as? String).map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
            if (method == "metadata" && hasName) ||
                (method == "thread/name/updated" && (event["name"] is String || event["name"] is NSNull)),
               let update = SessionNameUpdate(value) {
                names[id] = update
            }
            if event["method"] as? String == "thread/observed", event["status"] as? String == "idle", let seconds = event["at"] as? Double {
                confirmedIdle[id] = Date(timeIntervalSince1970: seconds)
                if confirmedIdle.count > 64 {
                    for key in confirmedIdle.keys.sorted(by: { confirmedIdle[$0]! > confirmedIdle[$1]! }).dropFirst(64) { confirmedIdle.removeValue(forKey: key) }
                }
            } else if event["method"] as? String == "turn/started" || event["method"] as? String == "turn/attached" ||
                        (event["method"] as? String == "thread/observed" && event["status"] as? String == "active") {
                confirmedIdle.removeValue(forKey: id)
            }
            if event["method"] as? String == "turn/completed", [.completed, .interrupted].contains(value.phase), let date = value.phaseChangedAt {
                confirmedIdle[id] = date
                if confirmedIdle.count > 64 {
                    for key in confirmedIdle.keys.sorted(by: { confirmedIdle[$0]! > confirmedIdle[$1]! }).dropFirst(64) { confirmedIdle.removeValue(forKey: key) }
                }
            }
            live[id] = value
            arrival &+= 1
            if value.hasLiveEvidence { invalidated.remove(id) }
            if event["method"] as? String == "thread/status/changed", event["status"] as? String == "notLoaded" {
                if value.phase == .unknown { invalidated.insert(id) }
                released.insert(id)
            } else if event["method"] as? String == "thread/status/changed", event["status"] as? String == "systemError", value.phase == .unknown {
                // Keep explicit invalidation ahead of an older running log.
                invalidated.insert(id)
            } else if value.hasLiveEvidence, [.running, .waitingForInput].contains(value.phase) {
                released.remove(id)
            }
            // Idle metadata never grows with every thread seen during a launch.
            if !value.hasLiveEvidence && !invalidated.contains(id) && !released.contains(id) {
                idleOrder[id] = arrival
            } else { idleOrder.removeValue(forKey: id) }
            if idleOrder.count > 64 {
                for key in idleOrder.keys.sorted(by: { (idleOrder[$0] ?? 0) > (idleOrder[$1] ?? 0) }).dropFirst(64) {
                    live.removeValue(forKey: key)
                    names.removeValue(forKey: key)
                    idleOrder.removeValue(forKey: key)
                }
            }
        } else if let rows = frame["sessions"] as? [[String: Any]] {
            let chunked = frame["kind"] as? String == "fallbackChunk"
            var current: [String: SessionActivity]
            if chunked {
                guard let id = frame["snapshotId"] as? String, id.count <= 64,
                      let part = frame["part"] as? Int, part >= 0, rows.count <= 32 else { return }
                if part == 0 { snapshotID = id; nextSnapshotPart = 0; stagedFallback = [:] }
                guard snapshotID == id, part == nextSnapshotPart else {
                    snapshotID = nil; stagedFallback = [:]; return
                }
                nextSnapshotPart += 1
                current = stagedFallback
            } else { current = [:] }
            for row in rows {
                guard let file = row["id"] as? String, file.count < 256, let records = row["records"] as? [[String: Any]] else { continue }
                let seeded = SessionActivity(id: (sourceID ?? "local") + ":" + file,
                    sourceHost: sourceName, sourceHostID: sourceID, phaseAwareRate: true).canonicalized()
                let continuation = chunked && row["continuation"] as? Bool == true
                var value = continuation ? (current[seeded.id] ?? seeded) :
                    (row["reset"] as? Bool == true ? seeded : (fallback[seeded.id] ?? seeded))
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
            if chunked {
                guard current.count <= 32 else { snapshotID = nil; stagedFallback = [:]; return }
                stagedFallback = current
                guard frame["final"] as? Bool == true else { return }
                snapshotID = nil; stagedFallback = [:]
            }
            fallback = current
        }
    }
}
