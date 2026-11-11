import Foundation

/// Bounded native transcript tailing. Only sanitized records survive a read.
struct ClaudeActivityReader {
    struct Result {
        let records: [Data], watchURLs: [URL]
        let available: Bool, caughtUp: Bool, discoveryPending: Bool
    }
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
    private struct Inventory {
        private let resolvedRoot: String
        private var roots: FileManager.DirectoryEnumerator?
        private var newestProjects = Newest<URL>(limit: ClaudeActivityReader.maximumProjects)
        private var remainingProjects: ArraySlice<URL>?
        private var project: URL?
        private var entries: FileManager.DirectoryEnumerator?
        private var agents: FileManager.DirectoryEnumerator?
        private var parent: String?
        private var newestLogs = Newest<Transcript>(limit: ClaudeActivityReader.maximumFileWatches)
        private(set) var projects: [URL] = []
        private(set) var projectDates: [URL: Date] = [:]
        private(set) var finished = false
        var transcripts: [Transcript] { newestLogs.values }

        init(root: URL) {
            resolvedRoot = root.resolvingSymlinksInPath().path + "/"
            roots = ClaudeActivityReader.children(root)
        }

        /// Each step opens one directory or advances one nonrecursive iterator.
        /// Keeping the iterator avoids repeatedly visiting the same prefix.
        mutating func step(excluding: Set<String>) -> URL? {
            if remainingProjects == nil {
                if let url = roots?.nextObject() as? URL {
                    if let facts = ClaudeActivityReader.visibleEntry(url), facts.isDirectory == true {
                        newestProjects.insert(url, date: facts.contentModificationDate ?? .distantPast, url: url)
                    }
                } else {
                    roots = nil
                    projects = newestProjects.values.filter { $0.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot) }
                    remainingProjects = projects[...]
                }
                return nil
            }
            if let agents, let parent {
                guard let url = agents.nextObject() as? URL else { self.agents = nil; self.parent = nil; return nil }
                let raw = url.deletingPathExtension().lastPathComponent
                guard url.pathExtension == "jsonl", raw.hasPrefix("agent-"),
                      let id = ClaudeActivityRecord.identifier(String(raw.dropFirst(6))),
                      let facts = ClaudeActivityReader.visibleEntry(url), facts.isDirectory != true else { return nil }
                if excluding.contains(parent) || excluding.contains(id) { return url }
                newestLogs.insert(Transcript(url: url, session: id, parent: parent, sanitized: false),
                    date: facts.contentModificationDate ?? .distantPast, url: url)
                return nil
            }
            if let project, let entries {
                guard let url = entries.nextObject() as? URL else { self.entries = nil; return nil }
                guard let facts = ClaudeActivityReader.visibleEntry(url) else { return nil }
                if facts.isDirectory != true, url.pathExtension == "jsonl",
                   let session = ClaudeActivityRecord.identifier(url.deletingPathExtension().lastPathComponent) {
                    if excluding.contains(session) { return url }
                    newestLogs.insert(Transcript(url: url, session: session, parent: nil, sanitized: false),
                        date: facts.contentModificationDate ?? .distantPast, url: url)
                } else if facts.isDirectory == true, let session = ClaudeActivityRecord.identifier(url.lastPathComponent) {
                    let folder = url.appendingPathComponent("subagents", isDirectory: true)
                    if let facts = ClaudeActivityReader.visibleEntry(folder), facts.isDirectory == true,
                       FileManager.default.fileExists(atPath: project.appendingPathComponent(session + ".jsonl").path) {
                        agents = ClaudeActivityReader.children(folder); parent = session
                    }
                }
                return nil
            }
            guard let next = remainingProjects?.popFirst() else { finished = true; return nil }
            project = next
            projectDates[next] = ClaudeActivityReader.projectDate(next)
            entries = ClaudeActivityReader.children(next)
            return nil
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
    static let maximumProjects = 64
    static let maximumFileWatches = 32
    static let maximumDirectoryWatches = 99
    static let discoveryStepLimit = 512
    private var inventory: Inventory?
    private var repeatDiscovery = false
    private var discoveryDirectories: [URL] = []
    private var lastDiscovery: Date?
    private var projectDates: [URL: Date] = [:]
    private(set) var projectWatchURL: URL?
    private(set) var scans = 0
    private(set) var lastDiscoverySteps = 0
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
        inventory = nil; repeatDiscovery = false; lastDiscoverySteps = 0
        scans = 0; fileReads = 0; bytesRead = 0; transcriptDocumentParses = 0
    }
    func discoveryDue(at now: Date, watchingProjects: Bool) -> Bool {
        guard inventory == nil, !repeatDiscovery else { return false }
        guard let lastDiscovery else { return true }
        let elapsed = now.timeIntervalSince(lastDiscovery)
        if elapsed < 0 || elapsed >= (watchingProjects ? 300 : 60) { return true }
        // The root watch is not recursive. A new log in an unwatched project
        // changes its directory date, which we can check without listing it.
        return watchingProjects && projectDates.contains { project, previous in
            Self.projectDate(project) != previous
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
    mutating func read(home: URL, discover: Bool, excludingSessionIDs: Set<String> = [],
                       retainingSessionIDs: Set<String> = [], now suppliedNow: Date? = nil) -> Result {
        let now = suppliedNow ?? clock()
        let manager = FileManager.default, root = home.appendingPathComponent("projects"), spool = home.appendingPathComponent("pacer")
        let initialObservation = observationStarted == nil
        if initialObservation { observationStarted = now }
        excludeSessionIDs(excludingSessionIDs)
        let events = spool.appendingPathComponent("events.jsonl")
        let hookSpool = Transcript(url: events, session: "hooks", parent: nil, sanitized: true)
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
        if discover, inventory != nil { repeatDiscovery = true }
        if inventory == nil, discover || repeatDiscovery {
            scans += 1; repeatDiscovery = false; inventory = Inventory(root: root)
            // Do not make the live hook spool wait for a large inventory.
            if cursors.count < Self.maximumFileWatches, cursors[events] == nil, files.metadata(events)?.isRegularFile == true {
                attach(hookSpool, initialObservation: initialObservation, at: now)
            }
            if discoveryDirectories.isEmpty { updateDiscoveryWatches(home: home, root: root, spool: spool, projects: [], selected: []) }
        }
        lastDiscoverySteps = 0
        if var scan = inventory {
            for _ in 0..<Self.discoveryStepLimit where !scan.finished {
                lastDiscoverySteps += 1
                if let excluded = scan.step(excluding: excludingSessionIDs) { rememberObserved(excluded, at: now) }
            }
            inventory = scan.finished ? nil : scan
            if scan.finished {
                lastDiscovery = now; projectDates = scan.projectDates
                var selected = cursors.keys.sorted { $0.path < $1.path }.compactMap { url -> Transcript? in
                    guard let cursor = cursors[url], cursor.sanitized || retainingSessionIDs.contains(cursor.session) else { return nil }
                    return Transcript(url: url, session: cursor.session, parent: cursor.parent, sanitized: cursor.sanitized)
                }
                if selected.count < Self.maximumFileWatches, manager.fileExists(atPath: events.path), !selected.contains(where: { $0.url == events }) {
                    selected.append(hookSpool)
                }
                var seen = Set(selected.map(\.url))
                for transcript in scan.transcripts where selected.count < Self.maximumFileWatches {
                    guard !excludingSessionIDs.contains(transcript.session),
                          transcript.parent.map(excludingSessionIDs.contains) != true,
                          seen.insert(transcript.url).inserted else { continue }
                    selected.append(transcript)
                }
                let projects = scan.projects
                for url in Array(cursors.keys) where !seen.contains(url) {
                    if let cursor = cursors[url], let row = unavailable(cursor) { records.append(row) }
                    cursors.removeValue(forKey: url)
                }
                for transcript in selected {
                    attach(transcript, initialObservation: initialObservation, at: now)
                }
                updateDiscoveryWatches(home: home, root: root, spool: spool, projects: projects, selected: selected)
            }
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
            available: manager.isReadableFile(atPath: home.path), caughtUp: caughtUp, discoveryPending: inventory != nil || repeatDiscovery)
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
    private mutating func attach(_ transcript: Transcript, initialObservation: Bool, at now: Date) {
        let url = transcript.url
        if cursors[url] == nil {
            let boundary = !initialObservation && !observedFiles.contains(url) ? observationStarted : nil
            cursors[url] = Cursor(session: transcript.session, parent: transcript.parent,
                sanitized: transcript.sanitized, historicalEnd: nil, liveAfter: boundary)
        }
        rememberObserved(url, at: now)
    }
    private mutating func updateDiscoveryWatches(home: URL, root: URL, spool: URL, projects: [URL], selected: [Transcript]) {
        // Vnode watches are not recursive. Watch the selected project's
        // nearest existing session and subagent parents.
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
    private static let discoveryKeys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]
    private static func children(_ url: URL) -> FileManager.DirectoryEnumerator? {
        FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(Self.discoveryKeys),
            options: [.skipsSubdirectoryDescendants])
    }
    private static func visibleEntry(_ url: URL) -> URLResourceValues? {
        // Count hidden entries too. Asking the iterator to skip them can
        // hide a long directory traversal inside one nextObject call.
        guard !url.lastPathComponent.hasPrefix("."), let facts = try? url.resourceValues(forKeys: Self.discoveryKeys),
              facts.isHidden != true, facts.isSymbolicLink != true else { return nil }
        return facts
    }
    private func directory(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    private static func projectDate(_ url: URL) -> Date {
        // The directory enumerator may have cached resource values on the URL.
        (try? URL(fileURLWithPath: url.path, isDirectory: true)
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
    private func nearestExistingDirectory(_ url: URL) -> URL {
        var candidate = url
        while !directory(candidate) {
            let parent = candidate.deletingLastPathComponent()
            if parent == candidate { break }; candidate = parent
        }
        return URL(fileURLWithPath: candidate.path, isDirectory: true)
    }
}
