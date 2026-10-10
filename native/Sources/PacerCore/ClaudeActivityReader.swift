import Foundation

/// Bounded native transcript tailing. Only sanitized records survive a read.
struct ClaudeActivityReader {
    struct Result { let records: [Data]; let watchURLs: [URL]; let available: Bool; let caughtUp: Bool }
    private struct Cursor { var inode: UInt64; var offset: UInt64; var fragment = Data(); var session: String; var parent: String?; var sanitized: Bool; var historicalEnd: UInt64?; var context = ClaudeTranscriptContext(); var discardingOversize = false }
    private var cursors: [URL: Cursor] = [:]
    static let maximumDirectoryWatches = 99
    private var discoveryDirectories: [URL] = []
    private(set) var scans = 0
    private(set) var fileReads = 0
    private(set) var transcriptDocumentParses = 0
    var attachedTranscriptCount: Int { cursors.values.filter { !$0.sanitized }.count }
    mutating func reset() { cursors.removeAll(); discoveryDirectories.removeAll(); scans = 0; fileReads = 0; transcriptDocumentParses = 0 }
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
    mutating func read(home: URL, discover: Bool, excludingSessionIDs: Set<String> = [], now: Date = Date()) -> Result {
        let manager = FileManager.default, root = home.appendingPathComponent("projects"), spool = home.appendingPathComponent("pacer")
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
        var candidates: [(URL, Date, String, String?, Bool)] = []
        if discover {
            scans += 1
            let projects = entries(root).filter { directory($0) }.sorted { modified($0) > modified($1) }.prefix(64)
            for project in projects {
                guard project.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { continue }
                // Known mirrors do not spend either the per-project discovery
                // allowance or the final 32-file cursor/watch allowance.
                let files = entries(project).filter {
                    let raw = $0.deletingPathExtension().lastPathComponent
                    let id = UUID(uuidString: raw)?.uuidString.lowercased() ?? raw
                    return !excludingSessionIDs.contains(id)
                }.prefix(256)
                for file in files where file.pathExtension == "jsonl" {
                    guard let session = ClaudeActivityRecord.identifier(file.deletingPathExtension().lastPathComponent),
                          !excludingSessionIDs.contains(session) else { continue }
                    candidates.append((file, modified(file), session, nil, false))
                    let agentFolder = project.appendingPathComponent(session + "/subagents")
                    for agent in entries(agentFolder).prefix(64) where agent.pathExtension == "jsonl" {
                        let raw = agent.deletingPathExtension().lastPathComponent
                        guard raw.hasPrefix("agent-"), let id = ClaudeActivityRecord.identifier(String(raw.dropFirst(6))) else { continue }
                        candidates.append((agent, modified(agent), id, session, false))
                    }
                }
            }
            let events = spool.appendingPathComponent("events.jsonl")
            if manager.fileExists(atPath: events.path) { candidates.append((events, modified(events), "hooks", nil, true)) }
            let selected = Array(candidates.sorted { $0.1 > $1.1 }.prefix(32))
            let desired = Set(selected.map { $0.0 })
            // Running cursors remain bounded alongside recently discovered
            // files. Replacing a file cannot replay an inherited old turn.
            for url in Array(cursors.keys) where !desired.contains(url) {
                if let cursor = cursors[url], let row = unavailable(cursor) { records.append(row) }; cursors.removeValue(forKey: url)
            }
            for (url, _, session, parent, sanitized) in selected where cursors[url] == nil {
                cursors[url] = Cursor(inode: 0, offset: 0, session: session, parent: parent, sanitized: sanitized, historicalEnd: nil)
            }
            // Vnode directory watches are not recursive. Retain each selected
            // root's project and nearest existing session/subagent parent so
            // later creation at either level triggers the same discovery path.
            var directories = [home, root, spool].map(nearestExistingDirectory)
            for (file, _, session, parent, sanitized) in selected where !sanitized {
                let project = parent == nil ? file.deletingLastPathComponent() :
                    file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                let sessionDirectory = project.appendingPathComponent(parent ?? session)
                directories += [project, sessionDirectory, sessionDirectory.appendingPathComponent("subagents")].map(nearestExistingDirectory)
            }
            directories += projects.prefix(2).map(nearestExistingDirectory)
            var seen: Set<URL> = []
            discoveryDirectories = Array(directories.filter { seen.insert($0).inserted }.prefix(Self.maximumDirectoryWatches))
        }
        var caughtUp = true
        for url in cursors.keys.sorted(by: { $0.path < $1.path }) {
            guard var cursor = cursors[url], let attributes = try? manager.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                  manager.isReadableFile(atPath: url.path) else {
                if let cursor = cursors[url], let row = unavailable(cursor) { records.append(row) }; cursors.removeValue(forKey: url); continue
            }
            // A hook/directory notification can refer to another watched file.
            // Keep existence/readability checks, but do not open every idle
            // transcript merely to seek to EOF and read zero bytes.
            if cursor.inode == inode, cursor.offset == size, !cursor.fragment.contains(10) { continue }
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                if let row = unavailable(cursor) { records.append(row) }; cursors.removeValue(forKey: url); continue
            }
            fileReads += 1
            defer { try? handle.close() }
            let reset = cursor.inode != inode || cursor.offset > size
            if reset { cursor.inode = inode; cursor.offset = 0; cursor.fragment.removeAll(); cursor.historicalEnd = size; cursor.context = ClaudeTranscriptContext(); cursor.discardingOversize = false }
            let budget = cursor.offset == 0 ? 512 * 1024 : 128 * 1024
            // A read budget is not a loss boundary. Desktop can append several
            // hundred KiB of attachments before one small model record; drain
            // those appends in bounded chunks so their ID chain stays intact.
            let gap = size - cursor.offset > UInt64(cursor.offset == 0 ? budget : 8 * 1024 * 1024)
            if gap {
                cursor.offset = size - UInt64(budget); cursor.fragment.removeAll()
                cursor.context = ClaudeTranscriptContext(); cursor.discardingOversize = false
                if let row = discontinuity(cursor) { records.append(row) }
            }
            do {
                var fragmentStart = cursor.offset - UInt64(cursor.fragment.count)
                try handle.seek(toOffset: cursor.offset)
                let bytes = try handle.read(upToCount: budget) ?? Data(); cursor.offset += UInt64(bytes.count); cursor.fragment.append(bytes)
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
                            sanitized = ClaudeActivityRecord.transcript(parsed, sessionID: cursor.session, parentID: cursor.parent, promptID: prompt)
                        } else { sanitized = [] }
                    }
                    if historical {
                        let rows = sanitized.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                        if !rows.isEmpty, let frame = ClaudeActivityRecord.encode(["kind": "claudeBatch", "attaching": true, "records": rows]) { records.append(frame) }
                    } else { records += sanitized }
                }
                if cursor.fragment.contains(10) || cursor.offset < size { caughtUp = false }
                if cursor.offset >= (cursor.historicalEnd ?? UInt64.max),
                   cursor.fragment.isEmpty || cursor.offset - UInt64(cursor.fragment.count) >= (cursor.historicalEnd ?? UInt64.max) { cursor.historicalEnd = nil }
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
    private func entries(_ url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
    }
    private func directory(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
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
