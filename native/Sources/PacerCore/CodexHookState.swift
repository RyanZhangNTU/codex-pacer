import Foundation

/// What the hook spool says about local Codex threads: which rollouts to follow,
/// which turns are open and which permission requests wait. It is the only way
/// Pacer learns that a local Codex turn exists; rollouts add the details.
struct CodexHookState: Sendable {
    struct Thread: Equatable, Sendable {
        var transcript: URL?
        var lastAt: Date
        /// The turn a UserPromptSubmit opened and no Stop or Interrupt has closed.
        var openTurn: String?
        var context = TaskContextState()
        var approval: (turn: String?, kind: CodexHookEvent.Approval, at: Date)?
        /// Codex closed the thread (SessionEnd), usually because it quit.
        var endedAt: Date?
        static func == (lhs: Thread, rhs: Thread) -> Bool {
            lhs.transcript == rhs.transcript && lhs.lastAt == rhs.lastAt && lhs.openTurn == rhs.openTurn && lhs.endedAt == rhs.endedAt
                && lhs.context == rhs.context
                && lhs.approval?.turn == rhs.approval?.turn && lhs.approval?.kind == rhs.approval?.kind && lhs.approval?.at == rhs.approval?.at
        }
    }
    struct Child: Equatable, Sendable {
        var parent: String
        var transcript: URL?
        var startedAt: Date
        var stoppedAt: Date?
    }
    /// Rows older than this neither open nor keep a thread.
    static let retention: TimeInterval = 24 * 60 * 60
    static let maximumThreads = 256
    /// The most a first read takes from each spool file.
    static let startupBytes = CodexHookSpool.maximumBytes

    private(set) var threads: [String: Thread] = [:]
    private(set) var children: [String: Child] = [:]
    /// The newest row of any kind, for the "hook not running" check.
    private(set) var lastRowAt: Date?
    private var cursors: [String: (identity: String, offset: UInt64, fragment: Data)] = [:]

    mutating func reset() { threads.removeAll(); children.removeAll(); lastRowAt = nil; cursors.removeAll() }

    /// Reads what was appended since the last call. Returns whether anything changed.
    @discardableResult
    mutating func read(home: URL, now: Date, retaining active: Set<String> = [], signature: (URL) -> (identity: String, size: UInt64)?) -> Bool {
        var changed = false
        // The previous file first: after a rotation its tail precedes the new current file.
        for (key, url) in [("previous", CodexHookSpool.previous(home: home)), ("current", CodexHookSpool.current(home: home))] {
            guard let facts = signature(url) else { cursors.removeValue(forKey: key); continue }
            var cursor = cursors[key]
            if let rotated = cursors.first(where: { $0.key != key && $0.value.identity == facts.identity }), cursor?.identity != facts.identity {
                // The current file became the previous one: keep reading where it stopped.
                cursor = rotated.value
            }
            if cursor == nil || cursor!.identity != facts.identity || cursor!.offset > facts.size {
                cursor = (facts.identity, facts.size > UInt64(Self.startupBytes) ? facts.size - UInt64(Self.startupBytes) : 0, Data())
                if cursor!.offset > 0 { cursor!.fragment = Data([0]) } // Drop the partial first line.
            }
            guard var current = cursor else { continue }
            if current.offset < facts.size, let handle = try? FileHandle(forReadingFrom: url) {
                defer { try? handle.close() }
                if (try? handle.seek(toOffset: current.offset)) != nil,
                   let data = try? handle.read(upToCount: Int(facts.size - current.offset)) {
                    current.offset += UInt64(data.count)
                    current.fragment.append(data)
                    while let end = current.fragment.firstIndex(of: 10) {
                        let line = current.fragment.prefix(upTo: end)
                        let partial = line.first == 0
                        current.fragment.removeSubrange(...end)
                        if !partial, let event = CodexHookEvent.decode(Data(line)) {
                            changed = apply(event, home: home, now: now, identity: { signature($0)?.identity }) || changed
                        }
                    }
                    if current.fragment.count > 64 * 1024 { current.fragment.removeAll() }
                }
            }
            cursors[key] = current
        }
        changed = prune(now: now, retaining: active) || changed
        return changed
    }

    /// Applies one row; rows arrive in order within a file and at most seconds apart across a rotation.
    @discardableResult
    private mutating func apply(_ event: CodexHookEvent, home: URL, now: Date, identity: (URL) -> String?) -> Bool {
        guard now.timeIntervalSince(event.at) < Self.retention, event.at <= now.addingTimeInterval(300) else { return false }
        lastRowAt = max(lastRowAt ?? event.at, event.at)
        let before = threads[event.thread]
        var thread = before ?? Thread(transcript: nil, lastAt: event.at)
        thread.lastAt = max(thread.lastAt, event.at)
        func transcript(_ path: String?, following previous: URL?) -> URL? {
            guard let url = CodexHookSpool.transcript(path, home: home) else { return previous }
            // Keep the existing cursor when Windows returns another spelling of the same file.
            if let previous, previous != url, CodexHookSpool.sameWindowsSpelling(previous, url),
               let id = identity(previous), id == identity(url) { return previous }
            return url
        }
        thread.transcript = transcript(event.transcript, following: thread.transcript ?? children[event.thread]?.transcript)
        switch event.kind {
        case .preCompact, .postCompact:
            guard event.agent == nil, let turn = event.turn, thread.openTurn == nil || thread.openTurn == turn else { return false }
            if event.kind == .preCompact { thread.context.preCompact(turn: turn, at: event.at) }
            else { thread.context.postCompact(turn: turn, at: event.at) }
        case .userPromptSubmit:
            thread.openTurn = event.turn; thread.approval = nil; thread.endedAt = nil
        case .stop, .interrupt:
            if event.turn == nil || thread.openTurn == event.turn { thread.openTurn = nil }
            thread.approval = nil
        case .permissionRequest:
            if let kind = event.approval { thread.approval = (event.turn, kind, event.at) }
        case .sessionEnd:
            thread.endedAt = event.at; thread.openTurn = nil; thread.approval = nil
        case .subagentStart, .subagentStop:
            guard let agent = event.agent else { break }
            var child = children[agent] ?? Child(parent: event.thread, transcript: nil, startedAt: event.at)
            child.transcript = transcript(event.agentTranscript, following: child.transcript ?? threads[agent]?.transcript)
            if event.kind == .subagentStop { child.stoppedAt = event.at } else { child.stoppedAt = nil; child.startedAt = event.at }
            let changed = children[agent] != child
            children[agent] = child
            threads[event.thread] = thread
            return changed || before != thread
        }
        threads[event.thread] = thread
        return before != thread
    }

    /// A subagent's rollout path arrives only with SubagentStop; while it runs, its
    /// file is found by name next to its parent's, or in today's or yesterday's folder.
    mutating func locateChildren(home: URL, now: Date, list: (URL) -> [URL]) {
        for (id, child) in children where child.transcript == nil && child.stoppedAt == nil {
            var folders: [URL] = []
            if let parent = threads[child.parent]?.transcript { folders.append(parent.deletingLastPathComponent()) }
            folders += CodexHookState.dayFolders(home: home, around: child.startedAt).filter { !folders.contains($0) }
            for folder in folders {
                if let match = list(folder).first(where: { CodexRolloutName.threadID(of: $0) == id }) {
                    children[id]?.transcript = match.standardizedFileURL; break
                }
            }
        }
    }

    static func dayFolders(home: URL, around date: Date) -> [URL] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy/MM/dd"
        return [0, -1].compactMap { Calendar.current.date(byAdding: .day, value: $0, to: date) }
            .map { home.appendingPathComponent("sessions/" + formatter.string(from: $0), isDirectory: true) }
    }

    /// Rollouts worth following: threads with recent rows and every known subagent of them.
    func transcripts(now: Date, recent: TimeInterval) -> [(url: URL, at: Date)] {
        var values: [(URL, Date)] = []
        for thread in threads.values {
            guard let url = thread.transcript, thread.openTurn != nil || now.timeIntervalSince(thread.lastAt) < recent else { continue }
            values.append((url, thread.lastAt))
        }
        for child in children.values {
            guard let url = child.transcript, let parent = threads[child.parent] else { continue }
            if child.stoppedAt == nil || now.timeIntervalSince(child.stoppedAt!) < recent { values.append((url, max(parent.lastAt, child.startedAt))) }
        }
        return values.sorted { $0.1 > $1.1 }.map { (url: $0.0, at: $0.1) }
    }

    /// Threads, lowercased, whose turn a hook opened and that wrote a row within
    /// `limit`, with their subagents: their rollouts change as those turns go on.
    func openThreads(now: Date, limit: TimeInterval) -> Set<String> {
        var values = Set(threads.filter { $0.value.openTurn != nil && now.timeIntervalSince($0.value.lastAt) < limit }.keys.map { $0.lowercased() })
        for (agent, child) in children where values.contains(child.parent.lowercased()) { values.insert(agent.lowercased()) }
        return values
    }

    @discardableResult
    private mutating func prune(now: Date, retaining active: Set<String>) -> Bool {
        let before = threads.count + children.count
        let keptActive = active.union(active.compactMap { children[$0]?.parent })
        threads = threads.filter { now.timeIntervalSince($0.value.lastAt) < Self.retention || keptActive.contains($0.key) }
        if threads.count > Self.maximumThreads {
            let kept = threads.sorted { $0.value.lastAt > $1.value.lastAt }.prefix(Self.maximumThreads)
            threads = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        children = children.filter { threads[$0.value.parent] != nil }
        return before != threads.count + children.count
    }
}
