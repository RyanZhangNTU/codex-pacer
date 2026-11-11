import Foundation

/// Incremental, bounded reads of `sessions/<workspace>/<session>/session.v4.jsonl.zstd`.
/// Cursors stop at frame boundaries, so a frame still being written is read
/// whole on a later pass. Files older than eight days are never opened.
struct DeepSeekSessionReader {
    struct Line: Sendable {
        let session: String
        let record: DeepSeekLogRecord
        let attaching: Bool
    }
    struct Result: Sendable {
        var lines: [Line] = []
        var watchURLs: [URL] = []
        var available = false
        var caughtUp = true
        /// A new session directory has no log yet; look again shortly.
        var awaitingLog = false
    }
    private struct Cursor {
        let url: URL
        var offset: UInt64 = 0
        var identity: String?
        var session: String?
        var baselineEnd: UInt64
        var modified: Date
    }
    static let logName = "session.v4.jsonl.zstd"
    static let window: TimeInterval = 8 * 86_400
    static let maximumFiles = 256
    private var cursors: [String: Cursor] = [:]
    private var startedAt: Date?
    private(set) var scans = 0
    var perPassBytes = 32 << 20
    private let files: any PlatformFileSystem
    init(files: any PlatformFileSystem) { self.files = files }

    mutating func reset() { cursors.removeAll(); startedAt = nil; scans = 0 }

    /// Lock files of known sessions, for checking whether Harness still has them open.
    func lockURLs(sessions: Set<String>) -> [String: URL] {
        Dictionary(cursors.values.compactMap { cursor in
            cursor.session.flatMap { sessions.contains($0) ? ($0, cursor.url.deletingLastPathComponent().appendingPathComponent("session.lock")) : nil }
        }, uniquingKeysWith: { first, _ in first })
    }

    mutating func read(home: URL, discover: Bool, now: Date = Date()) -> Result {
        var result = Result()
        let root = home.appendingPathComponent("sessions", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { return result }
        result.available = true
        let initial = startedAt == nil
        if initial { startedAt = now }
        if discover || initial {
            scans += 1
            let found = Self.discover(root: root, now: now, files: files)
            result.awaitingLog = found.awaitingLog
            for (path, file) in found.files where cursors[path] == nil {
                // A log that existed before Pacer started replays as history.
                let created = files.metadata(file.url)?.created ?? .distantPast
                cursors[path] = Cursor(url: file.url, baselineEnd: initial || created < startedAt! ? file.size : 0, modified: file.modified)
            }
            for path in cursors.keys where found.files[path] == nil { cursors.removeValue(forKey: path) }
        }
        var budget = perPassBytes
        for path in cursors.keys.sorted(by: { cursors[$0]!.modified > cursors[$1]!.modified }) {
            guard budget > 0 else { result.caughtUp = false; break }
            guard var cursor = cursors[path] else { continue }
            let (lines, read, more) = Self.readFrames(&cursor, budget: budget, files: files)
            budget -= read
            result.lines += lines; result.caughtUp = result.caughtUp && !more
            cursors[path] = cursor
        }
        let recent = cursors.values.sorted { $0.modified > $1.modified }
        result.watchURLs = [root] + Self.workspaces(root: root, limit: 3) + recent.prefix(28).map(\.url)
        return result
    }

    private static func readFrames(_ cursor: inout Cursor, budget: Int, files: any PlatformFileSystem) -> (lines: [Line], read: Int, more: Bool) {
        guard let metadata = files.metadata(cursor.url, followingSymbolicLinks: true) else { return ([], 0, false) }
        let size = metadata.size
        cursor.modified = metadata.modified
        if cursor.identity.map({ $0 != metadata.identity }) == true || size < cursor.offset {
            cursor.offset = 0; cursor.session = nil; cursor.baselineEnd = size
        }
        cursor.identity = metadata.identity
        guard size > cursor.offset else { return ([], 0, false) }
        let start = cursor.offset
        // One append is one frame. A frame larger than this pass's allowance
        // is read again whole, up to a bound beyond which the log is left.
        let remaining = size - start
        var count = Int(min(remaining, UInt64(max(budget, 1 << 20)))), data = Data(), output = ZstdFrameDecoder.Output()
        for attempt in 0..<2 {
            guard let read = try? files.read(cursor.url, offset: start, maximumBytes: count), !read.isEmpty, read.count <= count else { return ([], 0, false) }
            data = read
            do { output = try ZstdFrameDecoder.decode(data, maxLineBytes: DeepSeekSessionLog.maximumLineBytes) }
            catch { cursor.offset = size; return ([], data.count, false) } // Not a Harness log; do not reread it each pass.
            guard output.consumed == 0, UInt64(data.count) < remaining else { break }
            if attempt == 1 { cursor.offset = size; return ([], data.count, false) }
            count = Int(min(remaining, 64 << 20))
        }
        var lines: [Line] = []
        for batch in output.batches {
            // A catch-up pass can contain both captured history and frames
            // appended since startup. A torn baseline frame stays historical.
            let attaching = start + UInt64(batch.compressedOffset) < cursor.baselineEnd
            for raw in output.lines[batch.lines] {
                let truncated = raw.count >= DeepSeekSessionLog.maximumLineBytes
                guard let record = DeepSeekSessionLog.parse(raw, truncated: truncated, light: attaching) else { continue }
                if case .header(let header) = record.event { cursor.session = header.session }
                guard let session = cursor.session else { continue }
                lines.append(Line(session: session, record: record, attaching: attaching))
            }
        }
        cursor.offset += UInt64(output.consumed)
        // A torn tail at the end of the file waits for its writer; bytes left
        // unread by this pass's allowance are more work.
        return (lines, data.count, output.more || start + UInt64(data.count) < size)
    }

    private struct Found { let url: URL; let size: UInt64; let modified: Date }
    private static func discover(root: URL, now: Date, files: any PlatformFileSystem) -> (files: [String: Found], awaitingLog: Bool) {
        var found: [Found] = [], awaiting = false
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        for workspace in workspaces(root: root, limit: 64) {
            let entries = (try? FileManager.default.contentsOfDirectory(at: workspace, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles])) ?? []
            for directory in entries.prefix(2048) {
                let log = directory.appendingPathComponent(logName)
                guard let metadata = files.metadata(log) else {
                    let created = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    if let created, now.timeIntervalSince(created) < 10 { awaiting = true }
                    continue
                }
                guard now.timeIntervalSince(metadata.modified) <= window, metadata.size > 0 else { continue }
                found.append(Found(url: log, size: metadata.size, modified: metadata.modified))
            }
        }
        let kept = found.sorted { $0.modified > $1.modified }.prefix(maximumFiles)
        return (Dictionary(kept.map { ($0.url.path, $0) }, uniquingKeysWith: { first, _ in first }), awaiting)
    }
    /// Workspace directories, most recently changed first.
    private static func workspaces(root: URL, limit: Int) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { modified($0) > modified($1) }.prefix(limit).map { $0 }
    }
    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }
}
