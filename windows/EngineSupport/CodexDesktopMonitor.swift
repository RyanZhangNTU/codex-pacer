import Foundation

protocol CodexDesktopConnection: Sendable {
    func start() async
    func discover(_ threads: [String]) async
    func setInterval(_ seconds: TimeInterval, flushPending: Bool) async
    func stop() async
}
struct CodexDesktopServices: Sendable {
    let makeConnection: @Sendable (URL, TimeInterval, @escaping @Sendable (Data) async -> Void,
                                  @escaping @Sendable () async -> Void) -> any CodexDesktopConnection
    static var platformLive: Self? {
        #if os(Windows)
        return .init { home, interval, frame, closed in
            WindowsDesktopCollector(home: home, interval: interval, onFrame: frame, onClosed: closed)
        }
        #else
        return nil
        #endif
    }
}
struct CodexDesktopState: Sendable {
    let context: UInt64
    let activities: [SessionActivity]
    let attention: [PendingAttentionRequest]
    let attentionThreads: Set<String>
    let names: [SessionNameUpdate]
    let performance: [SessionPerformanceUpdate]
    let status: RuntimeStreamStatus
}

/// Owns source generations and reconnects, independently of log collection.
/// An initialized pipe is only transport evidence; activity comes from the
/// shared runtime parser, and a disconnect keeps proven terminal evidence.
actor CodexDesktopMonitor {
    private let services: CodexDesktopServices
    private let output: @Sendable (CodexDesktopState) async -> Void
    private let retryNanoseconds: UInt64
    private var home: URL?
    private var enabled = false, expanded = false
    private var context: UInt64 = 0, revision: UInt64 = 0
    private var connection: (any CodexDesktopConnection)?
    private var opening: Task<Void, Never>?, retry: Task<Void, Never>?
    private var state = RuntimeEventState(sourceID: nil, sourceName: nil)
    private var requests: [String: PendingAttentionRequest] = [:]
    private var attentionThreads: Set<String> = []
    private var threads: [String] = []
    private var runtimeObserved = false

    init(services: CodexDesktopServices, retryInterval: TimeInterval = 30, output: @escaping @Sendable (CodexDesktopState) async -> Void) {
        self.services = services; self.output = output
        retryNanoseconds = UInt64((retryInterval.isFinite ? min(30, max(0.01, retryInterval)) : 30) * 1_000_000_000)
    }
    func configure(home: URL, enabled: Bool, expanded: Bool, context: UInt64) async {
        self.context = context; self.expanded = expanded
        guard self.home != home || self.enabled != enabled else {
            await connection?.setInterval(expanded ? 1 : 5, flushPending: expanded)
            await emit(); return
        }
        revision += 1
        let previous = connection
        connection = nil; opening?.cancel(); opening = nil; retry?.cancel(); retry = nil
        self.home = home; self.enabled = enabled; threads = []
        state = RuntimeEventState(sourceID: nil, sourceName: nil); requests = [:]; attentionThreads = []; runtimeObserved = false
        await emit()
        await ShutdownDeadline().perform([{ await previous?.stop() }])
    }
    func discover(_ candidates: [String]) async {
        threads = Array(candidates.prefix(256))
        guard enabled, let home else { return }
        if connection == nil, retry == nil { begin(home) }
        await connection?.discover(threads)
    }
    func setExpanded(_ value: Bool) async {
        expanded = value
        await connection?.setInterval(value ? 1 : 5, flushPending: value)
    }
    private func begin(_ home: URL) {
        guard enabled, connection == nil else { return }
        revision += 1; runtimeObserved = false
        // The inbox has already received valid endings. A new pipe handshake
        // must not reuse old terminal evidence as proof of a working stream.
        state = RuntimeEventState(sourceID: nil, sourceName: nil); requests = [:]; attentionThreads = []
        let current = revision
        let created = services.makeConnection(home, expanded ? 1 : 5, { [weak self] bytes in
            await self?.receive(bytes, revision: current)
        }, { [weak self] in await self?.closed(revision: current) })
        connection = created
        opening = Task { await created.start() }
    }
    private func receive(_ bytes: Data, revision current: UInt64) async {
        guard enabled, revision == current, connection != nil,
              let frame = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              frame["hostId"] as? String == "local" else { return }
        if frame["kind"] as? String == "attention", let value = frame["threadId"] as? String,
           let thread = UUID(uuidString: value)?.uuidString.lowercased(),
           let rows = frame["requests"] as? [[String: String]], rows.count <= 64 {
            if attentionThreads.count >= 256, !attentionThreads.contains(thread) { return }
            attentionThreads.insert(thread)
            let prefix = "local:" + thread + ":", previous = requests
            requests = requests.filter { !$0.key.hasPrefix(prefix) }
            for row in rows {
                guard let raw = row["id"], !raw.isEmpty, raw.utf8.count <= 256,
                      let kind = row["kind"].flatMap(PendingAttentionRequest.Kind.init(rawValue:)) else { continue }
                let key = prefix + raw
                let question = row["questionKey"].flatMap { value in
                    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } ? value : nil
                }
                requests[key] = previous[key].flatMap { $0.kind == kind && $0.questionKey == question ? $0 : nil } ??
                    .init(id: key, threadID: thread, sourceHostID: nil, sourceName: nil, kind: kind, detectedAt: Date(), questionKey: question)
            }
        } else {
            if frame["kind"] as? String == "runtimeBatch" { state.consume(["kind": "status", "connected": true]) }
            state.consume(frame)
        }
        runtimeObserved = runtimeObserved || state.activities.contains(where: \.hasLiveEvidence) || !requests.isEmpty
        await emit()
    }
    private func closed(revision current: UInt64) async {
        guard enabled, revision == current, connection != nil else { return }
        connection = nil; opening = nil
        state.consume(["kind": "status", "connected": false]); requests = [:]; attentionThreads = []
        let delay = retryNanoseconds
        retry = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            await self?.reconnect(revision: current)
        }
        await emit()
    }
    private func reconnect(revision current: UInt64) async {
        guard enabled, revision == current, let home else { return }
        retry = nil; begin(home)
        await connection?.discover(threads)
    }
    private func emit() async {
        let current = revision
        var status = state.status
        status.sourceAvailable = runtimeObserved
        let value = CodexDesktopState(context: context, activities: state.activities,
            attention: requests.values.sorted { $0.detectedAt < $1.detectedAt }, attentionThreads: attentionThreads,
            names: state.nameUpdates, performance: state.performanceUpdates, status: status)
        await output(value)
        if revision == current { state.releasePublishedState() }
    }
    func stop() async {
        revision += 1; enabled = false
        let previous = connection
        connection = nil; opening?.cancel(); opening = nil; retry?.cancel(); retry = nil
        state = RuntimeEventState(sourceID: nil, sourceName: nil); requests = [:]; attentionThreads = []; threads = []
        await ShutdownDeadline().perform([{ await previous?.stop() }])
    }
}
