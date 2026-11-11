import Foundation

/// Bounded native transcript tailing. Only sanitized records survive a read.
struct ClaudeActivityReader {
    struct Result { let records: [Data]; let watchURLs: [URL]; let available: Bool; let caughtUp: Bool }
    private struct Cursor {
        var identity: String?; var created: Date?; var hasRead = false
        var offset: UInt64 = 0; var fragment = Data(); var session: String; var parent: String?
        var sanitized: Bool; var historicalEnd: UInt64?; var liveAfter: Date?
        var context = ClaudeTranscriptContext(); var discardingOversize = false
    }
    private struct Transcript {
        let url: URL
        let session: String
        let parent: String?
        let sanitized: Bool
    }
    private struct Newest<Value> {
        private struct Entry {
            let value: Value
            let date: Date
            let path: String
        }
        let limit: Int
        private var entries: [Entry] = []
        var values: [Value] { entries.map(\.value) }
        init(limit: Int) { self.limit = limit }
        mutating func insert(_ value: Value, date: Date, url: URL) {
            let path = url.path
            func precedes(_ entry: Entry) -> Bool {
                date > entry.date || (date == entry.date && path < entry.path)
            }
            if let last = entries.last, entries.count == limit, !precedes(last) { return }
            let index = entries.firstIndex(where: precedes) ?? entries.endIndex
            entries.insert(Entry(value: value, date: date, path: path), at: index)
            if entries.count > limit { entries.removeLast() }
        }
    }
    private let files: any PlatformFileSystem
    private let clock: @Sendable () -> Date
    private var cursors: [URL: Cursor] = [:]
    private var observationStarted: Date?
    private var observedFiles: Set<URL> = []
    static let initialReadBudget = 512 * 1024
    static let appendReadBudget = 128 * 1024
    static let maximumLiveBacklog = 8 * 1024 * 1024
    static let maximumDirectoryWatches = 99
    private var discoveryDirectories: [URL] = []
    private var lastDiscovery: Date?
    private var projectDates: [URL: Date] = [:]
    private(set) var projectWatchURL: URL?
    private(set) var scans = 0
    private(set) var fileReads = 0
    private(set) var bytesRead = 0
    private(set) var transcriptDocumentParses = 0
    var attachedTranscriptCount: Int { cursors.values.filter { !$0.sanitized }.count }
    func transcriptURL(for session: String) -> URL? {
        let matches = cursors.filter { !$0.value.sanitized && $0.value.session == session }.map(\.key)
        return matches.count == 1 ? matches.first : nil
    }
    init(files: any PlatformFileSystem, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.files = files; self.clock = clock
    }
    mutating func reset() {
        cursors.removeAll(); discoveryDirectories.removeAll(); observationStarted = nil; observedFiles.removeAll()
        lastDiscovery = nil; projectDates.removeAll(); projectWatchURL = nil
        scans = 0; fileReads = 0; bytesRead = 0; transcriptDocumentParses = 0
    }
    func discoveryDue(at now: Date, watchingProjects: Bool) -> Bool {
        guard let lastDiscovery else { return true }
        let elapsed = now.timeIntervalSince(lastDiscovery)
        if elapsed < 0 || elapsed >= (watchingProjects ? 300 : 60) { return true }
        // The root watch is not recursive. A new log in an unwatched project
        // changes its directory date, which we can check without listing it.
        return watchingProjects && projectDates.contains { project, previous in
            projectDate(project) != previous
        }
    }
    /// Removing a verified mirror is ownership correction, not a task ending.
    /// If its exclusion later disappears, discovery adds a fresh historical
    /// cursor rather than replaying its previous byte range as live evidence.
    @discardableResult mutating func excludeSessionIDs(_ ids: Set<String>) -> Set<URL> {
        let removed = Set(cursors.compactMap { url, cursor in
            !cursor.sanitized && (ids.contains(cursor.session) || cursor.parent.map(ids.contains) == true) ? url : nil
        })
        for url in removed { cursors.removeValue(forKey: url) }
        return removed
    }
    mutating func read(home: URL, discover: Bool, excludingSessionIDs: Set<String> = [], now suppliedNow: Date? = nil) -> Result {
        let now = suppliedNow ?? clock()
        let manager = FileManager.default, root = home.appendingPathComponent("projects"), spool = home.appendingPathComponent("pacer")
        let initialObservation = observationStarted == nil
        if initialObservation { observationStarted = now }
        excludeSessionIDs(excludingSessionIDs)
        var records: [Data] = []
        func unavailable(_ cursor: Cursor) -> Data? {
            guard !cursor.sanitized else { return nil }
            return ClaudeActivityRecord.encode(["kind": "unavailable", "origin": "reader", "sessionId": cursor.session, "at": now.timeIntervalSince1970])
        }
        func discontinuity(_ cursor: Cursor) -> Data? {
            guard !cursor.sanitized else { return nil }
            return ClaudeActivityRecord.encode(["kind": "discontinuity", "origin": "reader", "sessionId": cursor.session, "at": now.timeIntervalSince1970])
        }
        func emit(_ rows: [Data], historical: Bool) {
            guard historical else { records += rows; return }
            let values = rows.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if !values.isEmpty, let frame = ClaudeActivityRecord.encode(["kind": "claudeBatch", "attaching": true, "records": values]) { records.append(frame) }
        }
        if discover {
            scans += 1; lastDiscovery = now
            let projects = recentProjects(root)
            projectDates = Dictionary(uniqueKeysWithValues: projects.map { ($0, projectDate($0)) })
            let selected = discoverTranscripts(projects: projects, spool: spool, excluding: excludingSessionIDs, at: now)
            let desired = Set(selected.map(\.url))
            // Running cursors remain bounded alongside recently discovered
            // files. Replacing a file cannot replay an inherited old turn.
            for url in Array(cursors.keys) where !desired.contains(url) {
                if let cursor = cursors[url], let row = unavailable(cursor) { records.append(row) }; cursors.removeValue(forKey: url)
            }
            for transcript in selected {
                let url = transcript.url
                if cursors[url] == nil {
                    let boundary = !initialObservation && !observedFiles.contains(url) ? observationStarted : nil
                    cursors[url] = Cursor(session: transcript.session, parent: transcript.parent,
                        sanitized: transcript.sanitized, historicalEnd: nil, liveAfter: boundary)
                }
                rememberObserved(url, at: now)
            }
            // Vnode directory watches are not recursive. Retain each selected
            // root's project and nearest existing session/subagent parent so
            // later creation at either level triggers the same discovery path.
            var directories = [home, root, spool].map(nearestExistingDirectory)
            projectWatchURL = directories[1].path == root.path ? directories[1] : nil
            for transcript in selected where !transcript.sanitized {
                let file = transcript.url
                let project = transcript.parent == nil ? file.deletingLastPathComponent() :
                    file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                let sessionDirectory = project.appendingPathComponent(transcript.parent ?? transcript.session)
                directories += [project, sessionDirectory, sessionDirectory.appendingPathComponent("subagents")].map(nearestExistingDirectory)
            }
            directories += projects.prefix(2).map(nearestExistingDirectory)
            var seen: Set<URL> = []
            discoveryDirectories = Array(directories.filter { seen.insert($0).inserted }.prefix(Self.maximumDirectoryWatches))
        }
        var caughtUp = true, ownedBacklog = false
        // Hooks establish the current turn before transcript endings are
        // correlated. Like the SSH helper, transcripts wait while the owned
        // spool still has complete records, so a later hook prompt cannot
        // reopen a turn whose ending was read first and dropped.
        for url in cursors.keys.sorted(by: { (cursors[$0]?.sanitized == true ? 0 : 1, $0.path) < (cursors[$1]?.sanitized == true ? 0 : 1, $1.path) }) {
            if ownedBacklog, cursors[url]?.sanitized == false { caughtUp = false; continue }
            guard var cursor = cursors[url], let metadata = files.metadata(url), metadata.isRegularFile,
                  manager.isReadableFile(atPath: url.path) else {
                if let cursor = cursors[url], let row = unavailable(cursor) { records.append(row) }; cursors.removeValue(forKey: url); continue
            }
            // A hook/directory notification can refer to another watched file.
            // Keep existence/readability checks, but do not open every idle
            // transcript merely to seek to EOF and read zero bytes.
            let size = metadata.size, firstRead = !cursor.hasRead
            if cursor.hasRead, cursor.identity == metadata.identity, cursor.created == metadata.created,
               cursor.offset == size, !cursor.fragment.contains(10) { continue }
            let reset = firstRead || cursor.identity != metadata.identity || cursor.created != metadata.created || cursor.offset > size
            if reset {
                if !firstRead {
                    cursor.liveAfter = nil
                    if let row = discontinuity(cursor) { records.append(row) }
                } else if let boundary = cursor.liveAfter {
                    // A new path alone does not prove that its records are live.
                    if metadata.created.map({ $0 > boundary }) != true { cursor.liveAfter = nil }
                }
                cursor.identity = metadata.identity; cursor.created = metadata.created; cursor.offset = 0
                cursor.fragment.removeAll(); cursor.historicalEnd = size
                cursor.context = ClaudeTranscriptContext(); cursor.discardingOversize = false
            }
            let budget = reset ? Self.initialReadBudget : Self.appendReadBudget
            // A read budget is not a loss boundary. Desktop can append several
            // hundred KiB of attachments before one small model record; drain
            // those appends in bounded chunks so their ID chain stays intact.
            let maximumGap = reset && cursor.liveAfter == nil ? Self.initialReadBudget : Self.maximumLiveBacklog
            let gap = size - cursor.offset > UInt64(maximumGap)
            if gap {
                cursor.offset = size - UInt64(budget); cursor.fragment.removeAll()
                cursor.context = ClaudeTranscriptContext(); cursor.discardingOversize = false
                if let row = discontinuity(cursor) { records.append(row) }
            }
            do {
                var fragmentStart = cursor.offset - UInt64(cursor.fragment.count)
                let bytes = try files.read(url, offset: cursor.offset, maximumBytes: budget)
                fileReads += 1; bytesRead += bytes.count; cursor.hasRead = true
                cursor.offset += UInt64(bytes.count); cursor.fragment.append(bytes)
                if gap, let end = cursor.fragment.firstIndex(of: 10) {
                    fragmentStart += UInt64(cursor.fragment.distance(from: cursor.fragment.startIndex, to: end) + 1)
                    cursor.fragment.removeSubrange(...end)
                }
                if cursor.discardingOversize {
                    if let end = cursor.fragment.firstIndex(of: 10) {
                        fragmentStart += UInt64(cursor.fragment.distance(from: cursor.fragment.startIndex, to: end) + 1)
                        cursor.fragment.removeSubrange(...end); cursor.discardingOversize = false
                    } else { fragmentStart += UInt64(cursor.fragment.count); cursor.fragment.removeAll() }
                }
                var lines = 0
                while let end = cursor.fragment.firstIndex(of: 10), lines < 512 {
                    var historical = cursor.historicalEnd.map { fragmentStart < $0 } ?? false
                    let consumed = cursor.fragment.distance(from: cursor.fragment.startIndex, to: end) + 1
                    let line = cursor.fragment.prefix(upTo: end); cursor.fragment.removeSubrange(...end); lines += 1
                    fragmentStart += UInt64(consumed)
                    if line.count > ClaudeActivityRecord.maximumBytes {
                        cursor.context = ClaudeTranscriptContext()
                        if let row = discontinuity(cursor) { records.append(row) }; continue
                    }
                    let sanitized: [Data]
                    if cursor.sanitized {
                        // Owned hook spool is already sanitized; strict state
                        // validation still rejects extra/invalid records.
                        sanitized = line.count <= 16 * 1024 ? [Data(line)] : []
                        if historical, Self.isNewEvent(sanitized, after: cursor.liveAfter) { historical = false }
                    } else {
                        transcriptDocumentParses += 1
                        if let parsed = ClaudeTranscriptFields(Data(line)) {
                            if historical, let boundary = cursor.liveAfter,
                               let stamp = parsed.values["timestamp"]?.string(limit: 80), let at = ClaudeActivityRecord.date(stamp),
                               at.timeIntervalSince1970 >= boundary.timeIntervalSince1970 - 0.001 { historical = false }
                            let prompt = cursor.context.promptID(for: parsed, sessionID: cursor.session, parentID: cursor.parent)
                            if prompt == nil, cursor.context.awaitedParent != nil {
                                let owned = ClaudeActivityRecord.transcript(parsed, sessionID: cursor.session, parentID: cursor.parent,
                                    promptID: ClaudeTranscriptContext.pendingOwner)
                                sanitized = ClaudeTranscriptContext.unowned(owned)
                                cursor.context.deferLast(owned, historical: historical)
                            } else {
                                sanitized = ClaudeActivityRecord.transcript(parsed, sessionID: cursor.session, parentID: cursor.parent, promptID: prompt)
                            }
                        } else { sanitized = [] }
                    }
                    emit(sanitized, historical: historical)
                    // A late parent proves the owner of descendants read before it.
                    for release in cursor.context.takeReleased() { emit(release.rows, historical: release.historical) }
                }
                if cursor.fragment.contains(10) || cursor.offset < size { caughtUp = false; if cursor.sanitized { ownedBacklog = true } }
                if cursor.offset >= (cursor.historicalEnd ?? UInt64.max),
                   cursor.fragment.isEmpty || cursor.offset - UInt64(cursor.fragment.count) >= (cursor.historicalEnd ?? UInt64.max) {
                    cursor.historicalEnd = nil; cursor.liveAfter = nil
                }
                if cursor.fragment.count > ClaudeActivityRecord.maximumBytes {
                    cursor.fragment.removeAll(); cursor.context = ClaudeTranscriptContext(); cursor.discardingOversize = true
                    if let row = discontinuity(cursor) { records.append(row) }
                }
                cursors[url] = cursor
            } catch { if let row = unavailable(cursor) { records.append(row) }; cursors.removeValue(forKey: url) }
        }
        return Result(records: records, watchURLs: Array(cursors.keys) + discoveryDirectories,
            available: manager.isReadableFile(atPath: home.path), caughtUp: caughtUp)
    }
    private static func isNewEvent(_ rows: [Data], after boundary: Date?) -> Bool {
        guard let boundary, let row = rows.first,
              let fields = try? JSONSerialization.jsonObject(with: row) as? [String: Any],
              let at = fields["at"] as? Double, at.isFinite else { return false }
        return at >= boundary.timeIntervalSince1970 - 0.001
    }
    private mutating func rememberObserved(_ url: URL, at now: Date) {
        guard !observedFiles.contains(url) else { return }
        if observedFiles.count >= 4096 {
            // Paths that leave the cache still replay as history.
            observationStarted = max(observationStarted ?? now, now)
            observedFiles.removeAll(keepingCapacity: true)
        }
        observedFiles.insert(url)
    }
    private static let discoveryKeys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
    private func children(_ url: URL) -> FileManager.DirectoryEnumerator? {
        FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(Self.discoveryKeys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
    }
    private func recentProjects(_ root: URL) -> [URL] {
        guard let children = children(root) else { return [] }
        let resolvedRoot = root.resolvingSymlinksInPath().path + "/"
        var projects = Newest<URL>(limit: 64)
        for case let project as URL in children {
            guard let facts = try? project.resourceValues(forKeys: Self.discoveryKeys),
                  facts.isDirectory == true, facts.isSymbolicLink != true else { continue }
            projects.insert(project, date: facts.contentModificationDate ?? .distantPast, url: project)
        }
        return projects.values.filter { $0.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot) }
    }
    private mutating func discoverTranscripts(projects: [URL], spool: URL, excluding: Set<String>, at now: Date) -> [Transcript] {
        var candidates = Newest<Transcript>(limit: 32)
        for project in projects {
            guard let projectEntries = children(project) else { continue }
            // Only session directories can contain agents. Old logs without
            // that directory take one visit and no additional directory read.
            for case let entry as URL in projectEntries {
                guard let facts = try? entry.resourceValues(forKeys: Self.discoveryKeys),
                      facts.isSymbolicLink != true else { continue }
                if facts.isDirectory != true, entry.pathExtension == "jsonl",
                   let session = ClaudeActivityRecord.identifier(entry.deletingPathExtension().lastPathComponent) {
                    if excluding.contains(session) {
                        rememberObserved(entry, at: now)
                    } else {
                        candidates.insert(Transcript(url: entry, session: session, parent: nil, sanitized: false),
                            date: facts.contentModificationDate ?? .distantPast, url: entry)
                    }
                } else if facts.isDirectory == true, let parent = ClaudeActivityRecord.identifier(entry.lastPathComponent) {
                    let folder = entry.appendingPathComponent("subagents", isDirectory: true)
                    guard let folderFacts = try? folder.resourceValues(forKeys: Self.discoveryKeys),
                          folderFacts.isDirectory == true, folderFacts.isSymbolicLink != true,
                          FileManager.default.fileExists(atPath: project.appendingPathComponent(parent + ".jsonl").path),
                          let agents = children(folder) else { continue }
                    for case let agent as URL in agents where agent.pathExtension == "jsonl" {
                        let raw = agent.deletingPathExtension().lastPathComponent
                        guard raw.hasPrefix("agent-"), let id = ClaudeActivityRecord.identifier(String(raw.dropFirst(6))),
                              let agentFacts = try? agent.resourceValues(forKeys: Self.discoveryKeys),
                              agentFacts.isDirectory != true, agentFacts.isSymbolicLink != true else { continue }
                        if excluding.contains(parent) || excluding.contains(id) {
                            rememberObserved(agent, at: now)
                        } else {
                            candidates.insert(Transcript(url: agent, session: id, parent: parent, sanitized: false),
                                date: agentFacts.contentModificationDate ?? .distantPast, url: agent)
                        }
                    }
                }
            }
        }
        let events = spool.appendingPathComponent("events.jsonl")
        if FileManager.default.fileExists(atPath: events.path) {
            candidates.insert(Transcript(url: events, session: "hooks", parent: nil, sanitized: true),
                date: modified(events), url: events)
        }
        return candidates.values
    }
    private func directory(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    private func projectDate(_ url: URL) -> Date {
        // The directory enumerator may have cached resource values on the URL.
        modified(URL(fileURLWithPath: url.path, isDirectory: true))
    }
    private func nearestExistingDirectory(_ url: URL) -> URL {
        var candidate = url
        while !directory(candidate) {
            let parent = candidate.deletingLastPathComponent()
            if parent == candidate { break }; candidate = parent
        }
        return URL(fileURLWithPath: candidate.path, isDirectory: true)
    }
    private func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
}
