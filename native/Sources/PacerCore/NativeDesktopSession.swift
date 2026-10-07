import Foundation

struct NativeDesktopSession {
    struct Key: Hashable { let host: String; let thread: String }
    private(set) var ready = false
    private var client: String?
    private var followed: Set<Key> = []
    private var waiting: [Key] = []
    private var excluded: Set<Key> = []
    private var streams: [Key: DesktopWireProjection] = [:]
    private var dormant: [Key: UInt64] = [:]
    private var retirementSequence: UInt64 = 0
    private struct SnapshotWait { var retry: Int; var next: Date }
    private var awaitingSnapshot: [Key: SnapshotWait] = [:]
    private static let snapshotDelays: [TimeInterval] = [0.5, 1, 2, 5]
    private struct HostEvent { let host: String; let value: [String: Any] }
    private var events: [HostEvent] = []
    private var frames: [Data] = []
    private(set) var notifications = 0
    let hosts: Set<String>
    let localRuntime: Bool
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
        for key in waiting where followed.filter({ $0.host == key.host && dormant[$0] == nil }).count < 32 {
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
        guard events.count <= 512 else { throw JSONFieldView.Failure.limit }
        if event["firstTextDelta"] as? Bool == true || ["turn/started", "turn/completed", "thread/status/changed"].contains(method) { try publishEvents() }
    }
    private mutating func release(_ key: Key, at now: Date) throws {
        if dormant[key] == nil, key.host == "local" && localRuntime { try queue(["method": "stream/released", "threadId": key.thread, "at": now.timeIntervalSince1970], host: key.host) }
        try follow(key, value: false); streams.removeValue(forKey: key)
        dormant.removeValue(forKey: key)
        waiting.removeAll { $0 == key }; try drain()
    }
    private mutating func retire(_ key: Key, at now: Date) throws {
        // The owner only broadcasts while it has followers. Unfollowing at a
        // turn ending can hide the next turn in an already-open conversation.
        // Keep bounded revision/header-only interests, outside active slots.
        if dormant[key] == nil {
            if key.host == "local" && localRuntime { try queue(["method": "stream/released", "threadId": key.thread, "at": now.timeIntervalSince1970], host: key.host) }
            retirementSequence &+= 1; dormant[key] = retirementSequence
        }
        let inactive = dormant.filter { $0.key.host == key.host }.sorted { $0.value < $1.value }
        for entry in inactive.prefix(max(0, inactive.count - 64)) { try release(entry.key, at: now) }
        try drain()
    }
    var dormantSubscriptionCount: Int { dormant.count }
    var retainedItemCount: Int { streams.values.reduce(0) { $0 + $1.retainedItemCount } }
    var nextServiceDate: Date? { awaitingSnapshot.values.map(\.next).min() }
    mutating func service(at now: Date) throws {
        // The routing ID may be saved before its owner can answer a follow.
        // Silence after that first request is not a working subscription. Retry
        // without waiting for another packet; expire orphan hints to free slots.
        for (key, wait) in awaitingSnapshot where now >= wait.next {
            let retry = wait.retry + 1
            if retry < Self.snapshotDelays.count {
                awaitingSnapshot[key] = SnapshotWait(retry: retry, next: now.addingTimeInterval(Self.snapshotDelays[retry]))
                try follow(key, value: true)
            } else { try release(key, at: now) }
        }
    }
    mutating func discover(_ keys: [Key]) throws {
        var added: [Key] = []
        for key in keys where hosts.contains(key.host) && Self.valid(key.thread) != nil {
            if !followed.contains(key) && !excluded.contains(key) && !waiting.contains(key) && waiting.count < 256 { waiting.append(key); added.append(key) }
        }
        for host in Set(added.map(\.host)) where host != "local" {
            try frame(["kind": "discovery", "hostId": host, "threadIds": added.filter { $0.host == host }.prefix(32).map(\.thread)])
        }
        if ready { try drain() }
    }
    mutating func receive(_ bytes: Data, at now: Date = Date()) throws {
        let root = try JSONFieldView.document(bytes)
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
        guard kind == "broadcast", let params = fields["params"], params.isObject else { return }
        let p = try params.fields(["conversationId", "hostId", "following", "change"])
        guard let host = p["hostId"]?.string(), hosts.contains(host), let thread = Self.valid(p["conversationId"]?.string()) else { return }
        let key = Key(host: host, thread: thread)
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
        guard fields["version"]?.integer() == 11, let owner = Self.valid(fields["sourceClientId"]?.string()) else { throw JSONFieldView.Failure.malformed }
        notifications += 1
        let old = streams[key]
        var projection = old ?? DesktopWireProjection(threadID: thread, attentionOnly: host != "local" || !localRuntime)
        do {
            let output = try projection.consume(change, owner: owner, at: now)
            streams[key] = projection
            awaitingSnapshot.removeValue(forKey: key)
            if host != "local", (projection.isActive && (old?.isActive != true || old?.currentTurnID != projection.currentTurnID)) ||
                (projection.isTerminal && old?.isActive == true) {
                try frame(["kind": "discovery", "hostId": host, "threadIds": [thread]])
            }
            for event in output { try queue(event, host: host) }
            if old == nil || old?.requests != projection.requests {
                try frame(["kind": "attention", "hostId": host, "threadId": thread,
                    "requests": projection.requests.map { ["id": $0.id, "kind": $0.kind.rawValue] }])
            }
            if projection.isTerminal && projection.requests.isEmpty { try retire(key, at: now) }
            else { dormant.removeValue(forKey: key) }
        } catch {
            streams.removeValue(forKey: key)
            dormant.removeValue(forKey: key)
            // A rejected patch cannot erase earlier valid evidence, especially
            // a completion awaiting the normal batch flush. Deliver it before
            // invalidating the projection so the consumer observes wire order.
            try publishEvents()
            if host == "local" && localRuntime { try frame(["kind": "streamInvalidated", "hostId": host, "threadId": thread]) }
            switch error {
            case DesktopProjectionFailure.review, DesktopProjectionFailure.ephemeral:
                if excluded.count < 1024 { excluded.insert(key) }
                try frame(["kind": "attention", "hostId": host, "threadId": thread, "requests": []])
                try follow(key, value: false); waiting.removeAll { $0 == key }; try drain()
            default:
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
        for host in hosts.sorted() where host == "local" && localRuntime {
            let current = streams.filter { $0.key.host == host }
            try frame(["kind": "status", "hostId": host, "connected": ready && (host == "local" || !current.isEmpty),
                "attached": current.filter { $0.value.isActive }.count,
                "notifications": notifications, "fallbackScans": 0, "watchingLogs": false,
                "helperLoopIterations": loopIterations])
        }
    }
    mutating func takeFrames() -> [Data] { let result = frames; frames.removeAll(keepingCapacity: true); return result }
    mutating func close() {
        for key in followed { try? follow(key, value: false) }
        followed.removeAll(); streams.removeAll(); dormant.removeAll(); awaitingSnapshot.removeAll(); waiting.removeAll(); events.removeAll(); frames.removeAll()
    }
}
