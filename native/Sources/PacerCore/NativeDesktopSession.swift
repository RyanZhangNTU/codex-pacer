import Foundation

public struct NativeDesktopSession {
    public struct Key: Hashable, Sendable {
        public let host: String
        public let thread: String
        public init(host: String, thread: String) { self.host = host; self.thread = thread }
    }
    private(set) var ready = false
    private var client: String?
    private var followed: Set<Key> = []
    private var waiting: [Key] = []
    private var excluded: Set<Key> = []
    private var originExcluded: Set<Key> = []
    var localOrigin: (String) -> CodexRolloutMetadata? = { _ in nil }
    private var streams: [Key: DesktopWireProjection] = [:]
    /// Saved routes alone are idle. Losing an observed runtime remains a
    /// failure until a usable stream returns, even after snapshot retries end.
    private var invalidatedRemoteHosts: Set<String> = []
    private var dormant: [Key: UInt64] = [:]
    private var retirementSequence: UInt64 = 0
    private struct SnapshotWait { var retry: Int; var next: Date }
    private var awaitingSnapshot: [Key: SnapshotWait] = [:]
    private static let snapshotDelays: [TimeInterval] = [0.5, 1, 2, 5]
    private static let durableSnapshotDelays: [TimeInterval] = [0.5, 1, 2, 5, 10, 18, 25]
    private var durableCatalog: DurableActivityCatalog?
    private var durableHistory: [String: DurableTurnHistory] = [:]
    private var durableIPCActivity: [String: Date] = [:]
    private var durableIPCEndings: [String: String] = [:]
    private struct HostEvent { let host: String; let value: [String: Any] }
    private var events: [HostEvent] = []
    private var frames: [Data] = []
    private(set) var notifications = 0
    private(set) var hosts: Set<String>
    let localRuntime: Bool
    private func suppliesRuntime(_ host: String) -> Bool {
        if host == "local" { return localRuntime }
        if host == DurableActivityCatalog.hostID { return durableCatalog != nil }
        return host.hasPrefix("remote-control:")
    }
    private func allows(_ key: Key) -> Bool {
        hosts.contains(key.host) &&
            (key.host != DurableActivityCatalog.hostID || durableCatalog?.threadIDs.contains(key.thread) == true)
    }
    var send: ([String: Any]) throws -> Void
    init(hosts: Set<String>, localRuntime: Bool = true, send: @escaping ([String: Any]) throws -> Void) throws {
        self.hosts = hosts; self.localRuntime = localRuntime; self.send = send
        try send(["type": "request", "method": "initialize", "requestId": UUID().uuidString,
            "sourceClientId": "initializing-client", "version": 0, "params": ["clientType": "codex-pacer-events"]])
    }
    private static func valid(_ value: String?) -> String? {
        guard let value, let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value.lowercased() else { return nil }
        return value.lowercased()
    }
    private mutating func frame(_ value: [String: Any]) throws {
        frames.append(try JSONSerialization.data(withJSONObject: value))
        guard frames.count <= 64 else { throw JSONFieldView.Failure.limit }
    }
    private mutating func follow(_ key: Key, value: Bool) throws {
        guard let client else { return }
        if value, key.host == "local", let metadata = localOrigin(key.thread) {
            if metadata.origin.ignored {
                excluded.insert(key); originExcluded.insert(key)
                return
            }
            try queue(["method": "metadata", "threadId": key.thread, "at": (metadata.observedAt ?? Date()).timeIntervalSince1970,
                "embedded": metadata.origin.embedded, "ignoredSession": false, "localRolloutPath": metadata.url.path], host: key.host)
        }
        try send(["type": "broadcast", "method": "thread-stream-following-changed", "sourceClientId": client,
            "version": 1, "params": ["conversationId": key.thread, "hostId": key.host, "following": value]])
        if value {
            followed.insert(key)
            if streams[key] == nil && awaitingSnapshot[key] == nil {
                awaitingSnapshot[key] = SnapshotWait(retry: 0, next: Date().addingTimeInterval(Self.snapshotDelays[0]))
            }
        } else { followed.remove(key); awaitingSnapshot.removeValue(forKey: key) }
    }
    private mutating func drain() throws {
        for key in waiting where allows(key) && followed.filter({ $0.host == key.host && dormant[$0] == nil }).count < 32 {
            if !excluded.contains(key) && !followed.contains(key) { try follow(key, value: true) }
        }
        waiting.removeAll { followed.contains($0) || excluded.contains($0) }
    }
    private mutating func queue(_ event: [String: Any], host: String) throws {
        let method = event["method"] as? String ?? ""
        var value = event
        if let previous = events.last, previous.host == host, (method.contains("Delta") || method.hasSuffix("/delta")),
           previous.value["method"] as? String == method, previous.value["threadId"] as? String == event["threadId"] as? String,
           previous.value["itemId"] as? String == event["itemId"] as? String {
            if previous.value["hasText"] as? Bool == true {
                value["hasText"] = true
                value["firstDeltaAt"] = previous.value["firstDeltaAt"] ?? previous.value["at"]
            }
            events[events.count - 1] = HostEvent(host: host, value: value)
        } else { events.append(HostEvent(host: host, value: value)) }
        let toolBoundary = ["item/started", "item/completed"].contains(method) && RuntimeItemKind.isTool(event["itemType"] as? String ?? "")
        // A busy multi-chat stream must flush at the bound during a long batch,
        // rather than disconnecting and losing its observed response windows.
        if events.count >= 512 || toolBoundary || event["firstTextDelta"] as? Bool == true ||
            ["turn/started", "turn/completed", "thread/status/changed", "subagents/updated"].contains(method) { try publishEvents() }
    }
    private mutating func release(_ key: Key, at now: Date) throws {
        if dormant[key] == nil, suppliesRuntime(key.host),
           key.host != DurableActivityCatalog.hostID || (streams[key] != nil && !durableHistoryIsActive(key.thread)) {
            try queue(["method": "stream/released", "threadId": key.thread, "at": now.timeIntervalSince1970], host: key.host)
        }
        try follow(key, value: false); streams.removeValue(forKey: key)
        if key.host == DurableActivityCatalog.hostID { durableIPCActivity.removeValue(forKey: key.thread) }
        dormant.removeValue(forKey: key)
        waiting.removeAll { $0 == key }; try drain()
    }
    private mutating func retire(_ key: Key, at now: Date) throws {
        // The owner only broadcasts while it has followers. Unfollowing at a
        // turn ending can hide the next turn in an already-open conversation.
        // Keep bounded revision/header-only interests, outside active slots.
        if dormant[key] == nil {
            let turn = streams[key]?.currentTurnID
            let deliveredIPC = turn != nil && durableIPCEndings[key.thread] == turn
            let deliveredHistory = durableHistory[key.thread].map { $0.turnID == turn && $0.status != .inProgress } ?? false
            if suppliesRuntime(key.host), key.host != DurableActivityCatalog.hostID || (deliveredIPC && !deliveredHistory) {
                try queue(["method": "stream/released", "threadId": key.thread, "at": now.timeIntervalSince1970], host: key.host)
            }
            retirementSequence &+= 1; dormant[key] = retirementSequence
        }
        let inactive = dormant.filter { $0.key.host == key.host }.sorted { $0.value < $1.value }
        for entry in inactive.prefix(max(0, inactive.count - 64)) { try release(entry.key, at: now) }
        try drain()
    }
    var dormantSubscriptionCount: Int { dormant.count }
    var retainedItemCount: Int { streams.values.reduce(0) { $0 + $1.retainedItemCount } }
    var observedTurnIDs: Set<String> { Set(streams.values.compactMap(\.currentTurnID)) }
    var durableIPCObservations: [String: Date] { durableIPCActivity }

    private func durableHistoryIsActive(_ thread: String) -> Bool {
        guard let history = durableHistory[thread] else { return false }
        return history.status == .inProgress && durableIPCEndings[thread] != history.turnID
    }

    mutating func observeDurableHistory(_ observations: [DurableTurnHistory], scope: String, at now: Date) throws {
        let host = DurableActivityCatalog.hostID
        guard durableCatalog?.scope == scope else { return }
        for var history in observations {
            let thread = history.threadID, turn = history.turnID
            let key = Key(host: host, thread: thread)
            guard allows(key), !excluded.contains(key), durableIPCEndings[thread] != turn else { continue }
            let previous = durableHistory[thread]
            let sameTurn = previous?.turnID == turn
            let stream = streams[key]
            let sameWireTurn = stream?.currentTurnID == turn
            if sameTurn, previous?.status != .inProgress { continue }
            if let start = history.startedAt {
                if !sameTurn, let previousStart = previous?.startedAt, start < previousStart { continue }
                if !sameWireTurn, let wireStart = stream?.currentTurnStartedAt, start.addingTimeInterval(1) <= wireStart { continue }
            }
            if sameWireTurn, stream?.isActive == true, history.status == .inProgress,
               let received = durableIPCActivity[thread], now.timeIntervalSince(received) < 20 { continue }

            func event(_ method: String, at date: Date = now) -> [String: Any] {
                ["method": method, "threadId": thread, "turnId": turn, "at": date.timeIntervalSince1970]
            }
            if let name = history.name, previous?.name != name {
                var metadata = event("thread/name/updated")
                metadata["name"] = name
                try queue(metadata, host: host)
            }
            if !sameTurn, !(sameWireTurn && stream?.isActive == true) {
                var start = event("turn/attached")
                let evidenceStart = history.startedAt ?? history.report?.at ?? history.completedAt ?? now
                start["startedAt"] = min(evidenceStart, now).timeIntervalSince1970
                start["rootTurnId"] = history.rootTurnID
                try queue(start, host: host)
            }
            let previousReport = sameTurn ? previous?.report : nil
            if let report = history.report, report.id != previousReport?.id,
               (report.at ?? now) >= (previousReport?.at ?? .distantPast) {
                let at = min(report.at ?? history.completedAt ?? now, now)
                var progress = event("progress/reported", at: at)
                progress["percent"] = report.percent
                try queue(progress, host: host)
            } else {
                history.report = previousReport
            }
            durableHistory[thread] = history
            if history.status != .inProgress {
                let at = min(max(history.completedAt ?? now, history.report?.at ?? .distantPast), now)
                var end = event("turn/completed", at: at)
                end["status"] = history.status.rawValue
                try queue(end, host: host)
                try queue(event("stream/released", at: at), host: host)
            }
        }
        try publishEvents()
    }

    mutating func setDurableCatalog(_ value: DurableActivityCatalog?, at now: Date) throws {
        let host = DurableActivityCatalog.hostID
        let old = durableCatalog
        durableCatalog = hosts.contains(host) ? value : nil
        let allowed = durableCatalog?.threadIDs ?? []
        waiting.removeAll { $0.host == host && !allowed.contains($0.thread) }
        if old?.scope != durableCatalog?.scope {
            events.removeAll { $0.host == host }
            durableHistory.removeAll()
            durableIPCActivity.removeAll()
            durableIPCEndings.removeAll()
            waiting.removeAll { $0.host == host }
            for key in Array(followed) where key.host == host { try follow(key, value: false) }
            streams = streams.filter { $0.key.host != host }
            dormant = dormant.filter { $0.key.host != host }
            excluded = excluded.filter { $0.host != host }
            try frame(["kind": "durableScope", "hostId": host, "scope": durableCatalog.map { $0.scope as Any } ?? NSNull()])
        } else {
            for thread in durableHistory.keys.filter({ !allowed.contains($0) }) {
                if durableHistoryIsActive(thread) {
                    try queue(["method": "stream/released", "threadId": thread, "at": now.timeIntervalSince1970], host: host)
                }
                durableHistory.removeValue(forKey: thread)
            }
            durableIPCEndings = durableIPCEndings.filter { allowed.contains($0.key) }
            for key in Array(followed) where key.host == host && !allows(key) {
                if streams[key]?.requests.isEmpty == false {
                    try frame(["kind": "attention", "hostId": host, "threadId": key.thread, "requests": []])
                }
                try release(key, at: now)
            }
        }
        try discover((durableCatalog?.threadIDs ?? []).sorted().map { Key(host: host, thread: $0) })
    }
    mutating func setHosts(_ wanted: Set<String>, resetting resets: Set<String> = [], at now: Date = Date()) throws {
        guard wanted != hosts || !resets.isEmpty else { return }
        try publishEvents()
        hosts = wanted
        if !wanted.contains(DurableActivityCatalog.hostID), durableCatalog != nil { try setDurableCatalog(nil, at: now) }
        waiting.removeAll { !wanted.contains($0.host) }
        let renewed = followed.filter { wanted.contains($0.host) && resets.contains($0.host) }
        for key in Array(followed) where !wanted.contains(key.host) || resets.contains(key.host) { try release(key, at: now) }
        excluded = excluded.filter { wanted.contains($0.host) && !resets.contains($0.host) }
        invalidatedRemoteHosts.formIntersection(wanted)
        invalidatedRemoteHosts.subtract(resets)
        try discover(Array(renewed))
        try status(loopIterations: 0)
    }
    var nextServiceDate: Date? { awaitingSnapshot.values.map(\.next).min() }
    mutating func service(at now: Date) throws {
        // The routing ID may be saved before its owner can answer a follow.
        // Silence after that first request is not a working subscription. Retry
        // without waiting for another packet; expire orphan hints to free slots.
        for (key, wait) in awaitingSnapshot where now >= wait.next {
            let retry = wait.retry + 1
            let delays = key.host == DurableActivityCatalog.hostID ? Self.durableSnapshotDelays : Self.snapshotDelays
            if retry < delays.count {
                awaitingSnapshot[key] = SnapshotWait(retry: retry, next: now.addingTimeInterval(delays[retry]))
                try follow(key, value: true)
            } else { try release(key, at: now) }
        }
    }
    mutating func discover(_ keys: [Key]) throws {
        var added: [Key] = []
        for key in keys where allows(key) && Self.valid(key.thread) != nil {
            if originExcluded.contains(key), let metadata = localOrigin(key.thread), !metadata.origin.ignored {
                excluded.remove(key); originExcluded.remove(key)
            }
            if !followed.contains(key) && !excluded.contains(key) && !waiting.contains(key) && waiting.count < 256 { waiting.append(key); added.append(key) }
        }
        for host in Set(added.map(\.host)) where host != "local" {
            try frame(["kind": "discovery", "hostId": host, "threadIds": added.filter { $0.host == host }.prefix(32).map(\.thread)])
        }
        if ready { try drain() }
    }
    mutating func observeRemoteRoute(host: String, thread: String, method: String?, version: Int?,
                                     sender: String?, following: Bool?) throws {
        guard ready, host.hasPrefix(ConnectionSource.controlPrefix),
              RemoteControlCatalogIdentity.validIdentifier(String(host.dropFirst(ConnectionSource.controlPrefix.count))),
              let thread = Self.valid(thread), Self.valid(sender) != nil else { return }
        let announcesRoute = method == "thread-stream-following-status-requested" ||
            (method == "thread-stream-following-changed" && following == true)
        guard (announcesRoute && version == 1) || (method == "thread-stream-state-changed" && version == 11) else { return }
        try frame(["kind": "remoteControlRoute", "hostId": host, "threadId": thread])
    }
    mutating func receive(_ bytes: Data, at now: Date = Date(), projectedItems: Bool = false) throws {
        let root = try JSONFieldView.document(bytes, projectedItems: projectedItems)
        guard root.isObject else { throw JSONFieldView.Failure.malformed }
        let fields = try root.fields(["type", "method", "requestId", "resultType", "result", "version", "sourceClientId", "targetClientIds", "params"])
        let kind = fields["type"]?.string(), method = fields["method"]?.string()
        if kind == "client-discovery-request" {
            if let id = fields["requestId"]?.scalarIdentifier() { try send(["type": "client-discovery-response", "requestId": id, "response": ["canHandle": false]]) }
            return
        }
        if kind == "request" {
            if let id = fields["requestId"]?.scalarIdentifier() { try send(["type": "response", "requestId": id, "resultType": "error", "error": "no-handler-for-request"]) }
            return
        }
        if kind == "response" && method == "initialize" {
            guard fields["resultType"]?.string() == "success", let result = fields["result"], result.isObject,
                  let id = Self.valid(try result.fields(["clientId"])["clientId"]?.string()) else { throw JSONFieldView.Failure.malformed }
            client = id; ready = true; try drain(); try status(loopIterations: 0); return
        }
        if kind == "broadcast", method == "client-status-changed", fields["version"]?.integer() == 0,
           let params = fields["params"], params.isObject {
            let status = try params.fields(["clientId", "status"])
            if status["status"]?.string() == "disconnected", let owner = Self.valid(status["clientId"]?.string()),
               fields["sourceClientId"]?.string() == owner {
                try publishEvents()
                for (key, projection) in Array(streams) where projection.isOwned(by: owner) {
                    if key.host.hasPrefix("remote-control:"), projection.runtimeAvailable, !projection.isTerminal {
                        invalidatedRemoteHosts.insert(key.host)
                    }
                    if key.host == DurableActivityCatalog.hostID { durableIPCActivity.removeValue(forKey: key.thread) }
                    if suppliesRuntime(key.host), key.host != DurableActivityCatalog.hostID || !durableHistoryIsActive(key.thread) {
                        try frame(["kind": "streamInvalidated", "hostId": key.host, "threadId": key.thread])
                    }
                    streams.removeValue(forKey: key); dormant.removeValue(forKey: key)
                    awaitingSnapshot[key] = SnapshotWait(retry: 0, next: now.addingTimeInterval(Self.snapshotDelays[0]))
                    try follow(key, value: true)
                }
            }
            return
        }
        guard kind == "broadcast", let params = fields["params"], params.isObject else { return }
        let p = try params.fields(["conversationId", "hostId", "following", "change"])
        guard let host = p["hostId"]?.string(), let thread = Self.valid(p["conversationId"]?.string()) else { return }
        guard hosts.contains(host) else {
            try observeRemoteRoute(host: host, thread: thread, method: method, version: fields["version"]?.integer(),
                                   sender: fields["sourceClientId"]?.string(), following: p["following"]?.boolean())
            return
        }
        let key = Key(host: host, thread: thread)
        guard allows(key) else { return }
        // Existing owners may publish targeted patches before asking a newly
        // connected observer for its following status. Use routing metadata to
        // request our own snapshot; never consume another client's patch stream.
        if ready, method == "thread-stream-state-changed", fields["version"]?.integer() == 11,
           Self.valid(fields["sourceClientId"]?.string()) != nil, !followed.contains(key), !excluded.contains(key) {
            if !waiting.contains(key), waiting.count < 256 { waiting.append(key) }
            try drain(); return
        }
        if let targets = fields["targetClientIds"], !targets.isNull {
            let clients = try targets.elements(maximumCount: 128).compactMap { $0.string() }
            if let client, !clients.contains(client) { return }
        }
        if (method == "thread-read-state-changed" && fields["version"]?.integer() == 3) ||
           (method == "thread-queued-followups-changed" && fields["version"]?.integer() == 2) {
            try discover([key]); return
        }
        if ["thread-stream-following-changed", "thread-stream-following-status-requested"].contains(method ?? ""), fields["version"]?.integer() == 1 {
            if method == "thread-stream-following-status-requested", ready, followed.contains(key) {
                // An owner becoming ready/reconnecting asks existing followers
                // to announce themselves again. Having sent an earlier follow
                // is not a reason to ignore this request.
                awaitingSnapshot[key] = SnapshotWait(retry: 0, next: Date().addingTimeInterval(Self.snapshotDelays[0]))
                if host != "local" { try frame(["kind": "discovery", "hostId": host, "threadIds": [thread]]) }
                try follow(key, value: true); return
            }
            if method == "thread-stream-following-status-requested" || p["following"]?.boolean() == true {
                try discover([key])
            } else if p["following"]?.boolean() == false { waiting.removeAll { $0 == key } }
            return
        }
        guard ready, method == "thread-stream-state-changed", followed.contains(key), let change = p["change"], change.isObject else { return }
        if key.host == "local", let metadata = localOrigin(thread), metadata.origin.ignored {
            excluded.insert(key); originExcluded.insert(key)
            try frame(["kind": "attention", "hostId": host, "threadId": thread, "requests": []])
            try follow(key, value: false); streams.removeValue(forKey: key); try drain()
            return
        }
        guard fields["version"]?.integer() == 11, let owner = Self.valid(fields["sourceClientId"]?.string()) else { throw JSONFieldView.Failure.malformed }
        notifications += 1
        let old = streams[key]
        var projection = old ?? DesktopWireProjection(threadID: thread, attentionOnly: !suppliesRuntime(host),
                                                      requiresResumedRuntime: host.hasPrefix("remote-control:"))
        do {
            if projectedItems, try change.fields(["_pacerRejected"])["_pacerRejected"]?.boolean() == true { throw JSONFieldView.Failure.limit }
            let output = try projection.consume(change, owner: owner, at: now)
            streams[key] = projection
            if host == DurableActivityCatalog.hostID {
                durableIPCActivity[thread] = projection.isActive ? now : nil
                if let terminal = output.last(where: { $0["method"] as? String == "turn/completed" }) {
                    durableIPCEndings[thread] = terminal["turnId"] as? String
                }
            }
            if projection.runtimeAvailable { invalidatedRemoteHosts.remove(host) }
            if !projection.runtimeAvailable, old?.runtimeAvailable == true, suppliesRuntime(host) {
                if host.hasPrefix("remote-control:") { invalidatedRemoteHosts.insert(host) }
                try publishEvents()
                try frame(["kind": "streamInvalidated", "hostId": host, "threadId": thread])
            }
            let previousChildren = Set(old?.collaborationThreadIDs ?? [])
            try discover(projection.collaborationThreadIDs.filter { $0 != thread && !previousChildren.contains($0) }.map { Key(host: host, thread: $0) })
            awaitingSnapshot.removeValue(forKey: key)
            if host != "local", (projection.isActive && (old?.isActive != true || old?.currentTurnID != projection.currentTurnID)) ||
                (projection.isTerminal && old?.isActive == true) {
                try frame(["kind": "discovery", "hostId": host, "threadIds": [thread]])
            }
            for event in output {
                if host == DurableActivityCatalog.hostID, let history = durableHistory[thread] {
                    if history.status != .inProgress, event["turnId"] as? String == history.turnID { continue }
                    if durableHistoryIsActive(thread), projection.currentTurnID == nil || projection.currentTurnID == history.turnID,
                       event["method"] as? String == "thread/status/changed",
                       ["notLoaded", "systemError"].contains(event["status"] as? String ?? "") { continue }
                }
                try queue(event, host: host)
            }
            if old == nil || old?.requests != projection.requests {
                try frame(["kind": "attention", "hostId": host, "threadId": thread,
                    "requests": projection.requests.map { request in
                        var row = ["id": request.id, "kind": request.kind.rawValue]
                        if let key = request.questionKey { row["questionKey"] = key }
                        return row
                    }])
            }
            if projection.isTerminal && projection.requests.isEmpty { try retire(key, at: now) }
            else { dormant.removeValue(forKey: key) }
        } catch {
            streams.removeValue(forKey: key)
            if host == DurableActivityCatalog.hostID { durableIPCActivity.removeValue(forKey: thread) }
            dormant.removeValue(forKey: key)
            // A rejected patch cannot erase earlier valid evidence, especially
            // a completion awaiting the normal batch flush. Deliver it before
            // invalidating the projection so the consumer observes wire order.
            try publishEvents()
            if suppliesRuntime(host), host != DurableActivityCatalog.hostID || !durableHistoryIsActive(thread) {
                try frame(["kind": "streamInvalidated", "hostId": host, "threadId": thread])
            }
            switch error {
            case DesktopProjectionFailure.review, DesktopProjectionFailure.ephemeral:
                if excluded.count < 1024 { excluded.insert(key) }
                try frame(["kind": "attention", "hostId": host, "threadId": thread, "requests": []])
                try follow(key, value: false); waiting.removeAll { $0 == key }; try drain()
            default:
                if host.hasPrefix("remote-control:") { invalidatedRemoteHosts.insert(host) }
                if awaitingSnapshot[key] == nil { try follow(key, value: true) }
            }
        }
    }
    var hasEvents: Bool { !events.isEmpty }
    mutating func publishEvents() throws {
        guard !events.isEmpty else { return }
        // Separate host envelopes keep identical thread IDs and fallback data
        // from different machines isolated, preserving order within each host.
        for host in Set(events.map(\.host)).sorted() {
            try frame(["kind": "runtimeBatch", "hostId": host, "events": events.filter { $0.host == host }.map(\.value)])
        }
        events.removeAll(keepingCapacity: true)
    }
    mutating func status(loopIterations: Int) throws {
        for host in hosts.sorted() where suppliesRuntime(host) {
            let current = streams.filter { $0.key.host == host }
            let hasHistory = host == DurableActivityCatalog.hostID && !durableHistory.isEmpty
            let connected = ready && (host == "local" || hasHistory || current.values.contains { $0.runtimeAvailable })
            let waitingForSession = ready && host.hasPrefix("remote-control:") && !connected && !invalidatedRemoteHosts.contains(host)
            let remoteRuntimeLost = ready && !connected && invalidatedRemoteHosts.contains(host) &&
                !awaitingSnapshot.keys.contains { $0.host == host }
            try frame(["kind": "status", "hostId": host, "connected": connected, "waitingForSession": waitingForSession,
                "remoteRuntimeLost": remoteRuntimeLost,
                "attached": current.filter { $0.value.isActive }.count,
                "notifications": notifications, "fallbackScans": 0, "watchingLogs": false,
                "helperLoopIterations": loopIterations])
        }
    }
    mutating func takeFrames() -> [Data] { let result = frames; frames.removeAll(keepingCapacity: true); return result }
    mutating func close() {
        for key in followed { try? follow(key, value: false) }
        followed.removeAll(); streams.removeAll(); invalidatedRemoteHosts.removeAll(); dormant.removeAll(); awaitingSnapshot.removeAll(); waiting.removeAll(); events.removeAll(); frames.removeAll()
    }
}
