import Foundation

/// Bounded native transcript tailing. Only sanitized records survive a read.
struct ClaudeActivityReader {
    struct Result {
        let records: [Data], watchURLs: [URL]
        let available: Bool, caughtUp: Bool, discoveryPending: Bool, discoveryFinished: Bool
        let retirementPending: Bool
    }
    private struct Observation {
        let metadata: PlatformFileMetadata?
        let through: UInt64
        let at: Date
    }
    private struct Cursor {
        var identity: String?; var created: Date?; var hasRead = false
        var offset: UInt64 = 0; var fragment = Data(); var session: String; var parent: String?
        var sanitized: Bool; var historicalEnd: UInt64?; var liveAfter: Date?
        var replay: Observation?
        var metadata: PlatformFileMetadata?
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
                // Match the SSH helper when a filesystem gives many entries
                // the same modification time.
                date > entry.date || (date == entry.date && entry.path.utf8.lexicographicallyPrecedes(path.utf8))
            }
            if let last = entries.last, entries.count == limit, !precedes(last) { return }
            let index = entries.firstIndex(where: precedes) ?? entries.endIndex
            entries.insert(Entry(value: value, date: date, path: path), at: index)
            if entries.count > limit { entries.removeLast() }
        }
    }
    private struct Inventory {
        let root: URL
        let rootDate: Date
        let canFollowUp: Bool
        private let liveAfter: Date
        private let attached: Set<URL>
        private let observed: [URL: Observation]
        private let resolvedRoot: String
        private var roots: FileManager.DirectoryEnumerator?
        private var newestProjects = Newest<URL>(limit: ClaudeActivityReader.maximumProjects)
        private var remainingProjects: ArraySlice<URL>?
        private var project: URL?
        private var entries: FileManager.DirectoryEnumerator?
        private var agents: FileManager.DirectoryEnumerator?
        private var parent: String?
        private var newestLogs = Newest<Transcript>(limit: ClaudeActivityReader.maximumFileWatches)
        private var freshLogs = Newest<Transcript>(limit: ClaudeActivityReader.newLogSlots)
        private(set) var projects: [URL] = []
        private(set) var projectDates: [URL: Date] = [:]
        private(set) var finished = false
        var evictionReadBoundaries: [URL: PlatformFileMetadata]?
        var transcripts: [Transcript] { newestLogs.values }
        var freshTranscripts: [Transcript] { freshLogs.values }
        init(root: URL, liveAfter: Date, attached: Set<URL>, observed: [URL: Observation], canFollowUp: Bool) {
            self.root = root
            self.liveAfter = liveAfter; self.attached = attached; self.observed = observed; self.canFollowUp = canFollowUp
            rootDate = ClaudeActivityReader.projectDate(root)
            resolvedRoot = root.resolvingSymlinksInPath().path + "/"
            roots = ClaudeActivityReader.children(root)
        }
        private mutating func consider(_ transcript: Transcript, date: Date) {
            let url = transcript.url
            newestLogs.insert(transcript, date: date, url: url)
            let previous = observed[url]
            if !attached.contains(url), date > liveAfter, date > (previous?.metadata?.modified ?? previous?.at ?? .distantPast) {
                freshLogs.insert(transcript, date: date, url: url)
            }
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
                consider(Transcript(url: url, session: id, parent: parent, sanitized: false), date: facts.contentModificationDate ?? .distantPast)
                return nil
            }
            if let project, let entries {
                guard let url = entries.nextObject() as? URL else { self.entries = nil; return nil }
                guard let facts = ClaudeActivityReader.visibleEntry(url) else { return nil }
                if facts.isDirectory != true, url.pathExtension == "jsonl",
                   let session = ClaudeActivityRecord.identifier(url.deletingPathExtension().lastPathComponent) {
                    if excluding.contains(session) { return url }
                    consider(Transcript(url: url, session: session, parent: nil, sanitized: false), date: facts.contentModificationDate ?? .distantPast)
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
    // These cursors have no file watch. They finish a frozen byte range while
    // the newly selected files begin reading in the vacated slots.
    private var retiring: [URL: PlatformFileMetadata] = [:]
    private var observationStarted: Date?
    private var observedFiles: [URL: Observation] = [:]
    static let initialReadBudget = 512 * 1024
    static let appendReadBudget = 128 * 1024
    static let maximumLiveBacklog = 8 * 1024 * 1024
    static let maximumProjects = 64
    static let maximumFileWatches = 32
    private static let newLogSlots = 2
    static let maximumDirectoryWatches = 99
    static let discoveryStepLimit = 512
    private var inventory: Inventory?
    private var repeatDiscovery = false
    private var lastPassCanFollowUp = false
    private var discoveryDirectories: [URL] = []
    private var lastDiscovery: Date?
    private var projectRootStamp: (url: URL, date: Date)?
    private var projectDates: [URL: Date] = [:]
    private(set) var projectWatchURL: URL?
    private(set) var scans = 0
    private(set) var lastDiscoverySteps = 0
    private(set) var fileReads = 0
    private(set) var bytesRead = 0
    private(set) var transcriptDocumentParses = 0
    var attachedTranscriptCount: Int { cursors.filter { !$0.value.sanitized && retiring[$0.key] == nil }.count }
    func transcriptURL(for session: String) -> URL? {
        let matches = cursors.filter { !$0.value.sanitized && $0.value.session == session && retiring[$0.key] == nil }.map(\.key)
        return matches.count == 1 ? matches.first : nil
    }
    init(files: any PlatformFileSystem, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.files = files; self.clock = clock
    }
    mutating func reset() {
        cursors.removeAll(); retiring.removeAll(); discoveryDirectories.removeAll(); observationStarted = nil; observedFiles.removeAll()
        lastDiscovery = nil; projectDates.removeAll(); projectWatchURL = nil
        projectRootStamp = nil
        inventory = nil; repeatDiscovery = false; lastPassCanFollowUp = false; lastDiscoverySteps = 0
        scans = 0; fileReads = 0; bytesRead = 0; transcriptDocumentParses = 0
    }
    func discoveryDue(at now: Date) -> Bool {
        guard inventory == nil, !repeatDiscovery, retiring.isEmpty else { return false }
        guard let lastDiscovery else { return true }
        let elapsed = now.timeIntervalSince(lastDiscovery)
        // Appending to an unwatched file does not change its directory stamp.
        return elapsed < 0 || elapsed >= 60
    }
    func watchDiscoveryDelay(at now: Date) -> TimeInterval {
        guard inventory == nil, let lastDiscovery else { return 0 }
        let elapsed = now.timeIntervalSince(lastDiscovery)
        return elapsed < 0 ? 0 : max(0, 1 - elapsed)
    }
    @discardableResult mutating func checkCompletedInventory() -> Bool {
        guard inventory == nil, lastPassCanFollowUp else { return false }
        repeatDiscovery = repeatDiscovery || inventoryDirectoriesChanged()
        return repeatDiscovery
    }
    private func inventoryDirectoriesChanged() -> Bool {
        if let root = projectRootStamp, Self.projectDate(root.url) != root.date { return true }
        return projectDates.contains { project, previous in Self.projectDate(project) != previous }
    }
    /// Removing a verified mirror is ownership correction, not a task ending.
    /// If its exclusion later disappears, discovery adds a fresh historical
    /// cursor rather than replaying its previous byte range as live evidence.
    @discardableResult mutating func excludeSessionIDs(_ ids: Set<String>) -> Set<URL> {
        let removed = Set(cursors.compactMap { url, cursor in
            !cursor.sanitized && (ids.contains(cursor.session) || cursor.parent.map(ids.contains) == true) ? url : nil
        })
        for url in removed { cursors.removeValue(forKey: url); retiring.removeValue(forKey: url) }
        return removed
    }
    mutating func read(home: URL, discover: Bool, excludingSessionIDs: Set<String> = [],
                       retainingSessionIDs: Set<String> = [], waitingSessionIDs: Set<String> = [], now suppliedNow: Date? = nil) -> Result {
        let now = suppliedNow ?? clock()
        let manager = FileManager.default, root = home.appendingPathComponent("projects"), spool = home.appendingPathComponent("pacer")
        let cutoff = observationStarted ?? now
        observationStarted = cutoff
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
        func promoted(_ row: Data, after cutover: Date) -> Data? {
            guard var value = (try? JSONSerialization.jsonObject(with: row)) as? [String: Any],
                  value["promptId"] is String, value["unownedTurn"] as? Bool != true,
                  let at = value["at"] as? Double, at.isFinite, at > cutover.timeIntervalSince1970 else { return nil }
            value["observedWhileUnwatched"] = true
            return ClaudeActivityRecord.encode(value)
        }
        if discover, inventory?.canFollowUp == true || !retiring.isEmpty { repeatDiscovery = true }
        if inventory == nil, retiring.isEmpty, discover || repeatDiscovery {
            let canFollowUp = discover
            scans += 1; repeatDiscovery = false
            inventory = Inventory(root: root, liveAfter: cutoff, attached: Set(cursors.keys), observed: observedFiles, canFollowUp: canFollowUp)
            // Do not make the live hook spool wait for a large inventory.
            if cursors.count < Self.maximumFileWatches, cursors[events] == nil, files.metadata(events)?.isRegularFile == true {
                attach(hookSpool, liveAfter: cutoff)
            }
            if discoveryDirectories.isEmpty { updateDiscoveryWatches(home: home, root: root, spool: spool, projects: [], selected: []) }
        }
        lastDiscoverySteps = 0
        var discoveryFinished = false
        if var scan = inventory {
            for _ in 0..<Self.discoveryStepLimit where !scan.finished {
                lastDiscoverySteps += 1
                if let excluded = scan.step(excluding: excludingSessionIDs), observedFiles[excluded] == nil {
                    rememberObserved(excluded, metadata: nil, through: 0, at: now)
                }
            }
            inventory = scan.finished ? nil : scan
            if scan.finished {
                let current = cursors.sorted {
                    let lhs = $0.value.metadata?.modified ?? .distantPast, rhs = $1.value.metadata?.modified ?? .distantPast
                    return lhs == rhs ? $1.key.path.utf8.lexicographicallyPrecedes($0.key.path.utf8) : lhs > rhs
                }.map { Transcript(url: $0.key, session: $0.value.session, parent: $0.value.parent, sanitized: $0.value.sanitized) }
                func eligible(_ transcript: Transcript) -> Bool {
                    !excludingSessionIDs.contains(transcript.session) && transcript.parent.map(excludingSessionIDs.contains) != true
                }
                let fresh = scan.freshTranscripts.filter { eligible($0) && files.metadata($0.url)?.isRegularFile == true }
                var selected = [Transcript](), seen = Set<URL>()
                func add(_ values: [Transcript], limit: Int = Self.maximumFileWatches) {
                    for transcript in values where selected.count < limit && eligible(transcript) && seen.insert(transcript.url).inserted {
                        selected.append(transcript)
                    }
                }
                if files.metadata(events)?.isRegularFile == true { add([hookSpool]) }
                add(current.filter { !$0.sanitized && waitingSessionIDs.contains($0.session) }, limit: Self.maximumFileWatches - fresh.count)
                add(fresh)
                add(current.filter { !$0.sanitized && retainingSessionIDs.contains($0.session) })
                add(scan.transcripts)
                let firstSelection = scan.evictionReadBoundaries == nil
                if scan.evictionReadBoundaries == nil {
                    scan.evictionReadBoundaries = Dictionary(uniqueKeysWithValues: cursors.compactMap { url, cursor in
                        guard !seen.contains(url), cursor.hasRead, let metadata = files.metadata(url), metadata.isRegularFile,
                              cursorNeedsRead(cursor, through: metadata) else { return nil }
                        return (url, metadata)
                    })
                }
                if firstSelection, scan.evictionReadBoundaries?.isEmpty == false {
                    // One read lets a queued event renew an active lease. Do
                    // not make the new files wait for the rest of the backlog.
                    inventory = scan
                } else {
                    discoveryFinished = true
                    lastDiscovery = now; projectDates = scan.projectDates
                    projectRootStamp = (scan.root, scan.rootDate)
                    lastPassCanFollowUp = scan.canFollowUp
                    // The project may have changed before its watch was installed.
                    checkCompletedInventory()
                    for url in Array(cursors.keys) where !seen.contains(url) {
                        guard let cursor = cursors[url] else { continue }
                        if cursor.hasRead, let boundary = scan.evictionReadBoundaries?[url] ?? files.metadata(url), boundary.isRegularFile,
                           cursorNeedsRead(cursor, through: boundary) {
                            retiring[url] = boundary
                        } else {
                            release(url, cursor: cursor, at: now)
                            if let row = unavailable(cursor) { records.append(row) }
                        }
                    }
                    for transcript in selected {
                        attach(transcript, liveAfter: cutoff)
                    }
                    updateDiscoveryWatches(home: home, root: root, spool: spool, projects: scan.projects, selected: selected)
                }
            }
        }
        var caughtUp = true, ownedBacklog = false
        // Hooks establish the current turn before transcript endings are
        // correlated. Like the SSH helper, transcripts wait while the owned
        // spool still has complete records, so a later hook prompt cannot
        // reopen a turn whose ending was read first and dropped.
        func readOrder(_ url: URL) -> Int { cursors[url]?.sanitized == true ? 0 : retiring[url] == nil ? 1 : 2 }
        for url in cursors.keys.sorted(by: { (readOrder($0), $0.path) < (readOrder($1), $1.path) }) {
            let retirement = retiring[url]
            if ownedBacklog, cursors[url]?.sanitized == false { if retirement == nil { caughtUp = false }; continue }
            guard var cursor = cursors[url], let metadata = files.metadata(url), metadata.isRegularFile,
                  manager.isReadableFile(atPath: url.path),
                  retirement.map({ Self.sameFile(metadata, $0) && metadata.size >= $0.size }) ?? true else {
                if let cursor = cursors[url] {
                    release(url, cursor: cursor, at: now)
                    if let row = unavailable(cursor) { records.append(row) }
                }
                continue
            }
            // A hook/directory notification can refer to another watched file.
            // Keep existence/readability checks, but do not open every idle
            // transcript merely to seek to EOF and read zero bytes.
            let attachedMetadata = cursor.metadata
            let preflight: PlatformFileMetadata? = (inventory?.evictionReadBoundaries?[url]).flatMap { boundary in
                Self.sameFile(metadata, boundary) && metadata.size >= boundary.size ? boundary : nil
            }
            let readBoundary = retirement ?? preflight
            cursor.metadata = readBoundary ?? metadata
            let size = readBoundary?.size ?? metadata.size, firstRead = !cursor.hasRead
            if cursor.hasRead, cursor.identity == metadata.identity, cursor.created == metadata.created,
               cursor.offset == size, !cursor.fragment.contains(10) {
                if retirement != nil {
                    release(url, cursor: cursor, at: now)
                    if let row = unavailable(cursor) { records.append(row) }
                } else if attachedMetadata != metadata { cursors[url] = cursor }
                continue
            }
            let reset = firstRead || cursor.identity != metadata.identity || cursor.created != metadata.created || cursor.offset > size
            if reset {
                if !firstRead {
                    cursor.liveAfter = nil; cursor.replay = nil
                    if let row = discontinuity(cursor) { records.append(row) }
                } else if attachedMetadata.map({ !Self.sameFile($0, metadata) }) == true ||
                          cursor.replay?.metadata.map({ !Self.sameFile($0, metadata) || size < (cursor.replay?.through ?? 0) }) == true {
                    // A replaced or truncated path is a fresh baseline.
                    cursor.liveAfter = nil; cursor.replay = nil
                }
                cursor.identity = metadata.identity; cursor.created = metadata.created; cursor.offset = 0
                cursor.fragment.removeAll(); cursor.historicalEnd = size
                cursor.context = ClaudeTranscriptContext(); cursor.discardingOversize = false
            }
            let budget = reset ? Self.initialReadBudget : Self.appendReadBudget
            // A read budget is not a loss boundary. Desktop can append several
            // hundred KiB of attachments before one small model record; drain
            // those appends in bounded chunks so their ID chain stays intact.
            let maximumGap = reset ? Self.initialReadBudget : Self.maximumLiveBacklog
            let gap = size - cursor.offset > UInt64(maximumGap)
            if gap {
                cursor.offset = size - UInt64(budget); cursor.fragment.removeAll()
                cursor.context = ClaudeTranscriptContext(); cursor.discardingOversize = false
                if let row = discontinuity(cursor) { records.append(row) }
            }
            do {
                var fragmentStart = cursor.offset - UInt64(cursor.fragment.count)
                let maximumBytes = Int(min(UInt64(budget), size - cursor.offset))
                let bytes = maximumBytes > 0 ? try files.read(url, offset: cursor.offset, maximumBytes: maximumBytes) : Data()
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
                    let historical = cursor.historicalEnd.map { fragmentStart < $0 } ?? false
                    let cutover = historical && fragmentStart >= (cursor.replay?.through ?? 0) ? cursor.liveAfter : nil
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
                    } else {
                        transcriptDocumentParses += 1
                        if let parsed = ClaudeTranscriptFields(Data(line)) {
                            let prompt = cursor.context.promptID(for: parsed, sessionID: cursor.session, parentID: cursor.parent)
                            if prompt == nil, cursor.context.awaitedParent != nil {
                                let owned = ClaudeActivityRecord.transcript(parsed, sessionID: cursor.session, parentID: cursor.parent,
                                    promptID: ClaudeTranscriptContext.pendingOwner)
                                sanitized = ClaudeTranscriptContext.unowned(owned)
                                if let cutover {
                                    for row in owned {
                                        let live = promoted(row, after: cutover)
                                        cursor.context.deferLast([live ?? row], historical: live == nil)
                                    }
                                } else { cursor.context.deferLast(owned, historical: historical) }
                            } else {
                                sanitized = ClaudeActivityRecord.transcript(parsed, sessionID: cursor.session, parentID: cursor.parent, promptID: prompt)
                            }
                        } else { sanitized = [] }
                    }
                    if let cutover {
                        for row in sanitized {
                            if let live = promoted(row, after: cutover) { records.append(live) }
                            else { emit([row], historical: historical) }
                        }
                    } else { emit(sanitized, historical: historical) }
                    // A late parent proves the owner of descendants read before it.
                    for release in cursor.context.takeReleased() { emit(release.rows, historical: release.historical) }
                }
                if cursor.fragment.contains(10) || cursor.offset < size {
                    if retirement == nil { caughtUp = false }
                    if cursor.sanitized { ownedBacklog = true }
                }
                if cursor.offset >= (cursor.historicalEnd ?? UInt64.max),
                   cursor.fragment.isEmpty || cursor.offset - UInt64(cursor.fragment.count) >= (cursor.historicalEnd ?? UInt64.max) {
                    cursor.historicalEnd = nil; cursor.liveAfter = nil; cursor.replay = nil
                }
                if cursor.fragment.count > ClaudeActivityRecord.maximumBytes {
                    cursor.fragment.removeAll(); cursor.context = ClaudeTranscriptContext(); cursor.discardingOversize = true
                    if let row = discontinuity(cursor) { records.append(row) }
                }
                if let retirement, !cursorNeedsRead(cursor, through: retirement) {
                    release(url, cursor: cursor, at: now)
                    if let row = unavailable(cursor) { records.append(row) }
                } else { cursors[url] = cursor }
            } catch {
                release(url, cursor: cursor, at: now)
                if let row = unavailable(cursor) { records.append(row) }
            }
        }
        return Result(records: records, watchURLs: cursors.keys.filter { retiring[$0] == nil } + discoveryDirectories,
            available: manager.isReadableFile(atPath: home.path), caughtUp: caughtUp,
            discoveryPending: inventory != nil || repeatDiscovery || !retiring.isEmpty,
            discoveryFinished: discoveryFinished, retirementPending: !retiring.isEmpty)
    }
    private static func sameFile(_ lhs: PlatformFileMetadata, _ rhs: PlatformFileMetadata) -> Bool {
        lhs.identity == rhs.identity && lhs.created == rhs.created
    }
    private mutating func rememberObserved(_ url: URL, metadata: PlatformFileMetadata?, through: UInt64, at now: Date) {
        if observedFiles[url] == nil, observedFiles.count >= 512,
           let oldest = observedFiles.min(by: { $0.value.at < $1.value.at })?.key { observedFiles.removeValue(forKey: oldest) }
        observedFiles[url] = Observation(metadata: metadata, through: through, at: now)
    }
    private mutating func release(_ url: URL, cursor: Cursor, at now: Date) {
        rememberObserved(url, metadata: cursor.metadata, through: cursor.offset - UInt64(cursor.fragment.count), at: now)
        cursors.removeValue(forKey: url); retiring.removeValue(forKey: url)
    }
    private mutating func attach(_ transcript: Transcript, liveAfter: Date) {
        let url = transcript.url
        if cursors[url] == nil {
            let replay = observedFiles[url]
            let boundary = replay?.metadata == nil ? max(liveAfter, replay?.at ?? liveAfter) : liveAfter
            let metadata = files.metadata(url)
            cursors[url] = Cursor(session: transcript.session, parent: transcript.parent,
                sanitized: transcript.sanitized, historicalEnd: nil, liveAfter: metadata == nil ? nil : boundary, replay: replay, metadata: metadata)
        }
    }
    private func cursorNeedsRead(_ cursor: Cursor, through boundary: PlatformFileMetadata) -> Bool {
        guard cursor.identity == boundary.identity, cursor.created == boundary.created, cursor.offset <= boundary.size else { return false }
        if cursor.offset < boundary.size { return true }
        let parsed = cursor.offset - UInt64(cursor.fragment.count)
        return parsed < boundary.size && cursor.fragment.contains(10)
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
