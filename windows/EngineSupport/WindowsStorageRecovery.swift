import Foundation

/// Windows-only recovery for Pacer-owned numeric stores. No file bytes enter diagnostics.
final class WindowsStorageRecovery: @unchecked Sendable {
    static let shared = WindowsStorageRecovery()
    enum Kind: String { case quota, deepseek, dismissals }
    private let lock = NSRecursiveLock()
    private let files = WindowsFileSystem()
    private var checked: [URL: PlatformFileMetadata] = [:]
    private var future: [URL: Kind] = [:]
    private var counts: [String: Int] = [:]

    func prepare(_ file: URL, kind: Kind, maximumBytes: Int, valid: (Data) -> Bool) {
        lock.lock(); defer { lock.unlock() }
        guard safePath(file), let info = files.metadata(file), info.isRegularFile else {
            checked[file] = nil; future[file] = nil; return
        }
        if checked[file] == info { return }
        // An unreadable or concurrently changing file is not evidence of corruption.
        guard let data = try? files.read(file, offset: 0, maximumBytes: maximumBytes + 1),
              UInt64(data.count) == min(info.size, UInt64(maximumBytes + 1)), files.metadata(file) == info else { return }
        if Self.isFuture(data) { future[file] = kind; checked[file] = info; return }
        future[file] = nil
        if info.size <= maximumBytes && valid(data) { checked[file] = info; return }
        if quarantine(file) { counts[kind.rawValue, default: 0] += 1; checked[file] = nil }
    }

    private static func isFuture(_ data: Data) -> Bool {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = object["version"] as? NSNumber { return version.doubleValue > 1 }
        // Preserve a recognizable future header even when its body exceeds today's read bound.
        let text = String(decoding: data.prefix(4096), as: UTF8.self)
        guard let match = text.range(of: #"^\s*\{\s*"version"\s*:\s*([0-9]+)\s*[,}]"#, options: .regularExpression) else { return false }
        let header = String(text[match])
        return header.split(separator: ":").last.flatMap { Int($0.filter(\.isNumber)) }.map { $0 > 1 } ?? false
    }

    private func safePath(_ file: URL) -> Bool {
        var path = file
        while true {
            if let info = files.metadata(path), !info.isRegularFile && !info.isDirectory { return false }
            let parent = path.deletingLastPathComponent()
            if parent == path { return true }
            path = parent
        }
    }

    @discardableResult private func quarantine(_ file: URL) -> Bool {
        guard safePath(file), files.metadata(file)?.isRegularFile == true else { return false }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        let prefix = file.lastPathComponent + ".damaged-"
        let backup = file.deletingLastPathComponent().appendingPathComponent(prefix + formatter.string(from: Date()) + "-" + UUID().uuidString.lowercased())
        do { try FileManager.default.moveItem(at: file, to: backup) }
        catch { counts["failed", default: 0] += 1; return false }
        let pattern = "^" + NSRegularExpression.escapedPattern(for: prefix) + #"\d{8}T\d{9}Z-[0-9a-f-]{36}$"#
        let backups = ((try? files.entries(in: file.deletingLastPathComponent())) ?? []).filter {
            $0.lastPathComponent.range(of: pattern, options: .regularExpression) != nil && files.metadata($0)?.isRegularFile == true
        }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for older in backups.filter({ $0 != backup }).dropFirst(2) {
            do { if safePath(older) { try FileManager.default.removeItem(at: older) } }
            catch { counts["failed", default: 0] += 1 }
        }
        return true
    }

    func status() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["quota": counts[Kind.quota.rawValue, default: 0], "deepseek": counts[Kind.deepseek.rawValue, default: 0],
                "dismissals": counts[Kind.dismissals.rawValue, default: 0], "failed": counts["failed", default: 0],
                "futureFiles": future.keys.map(\.lastPathComponent).sorted()]
    }

    /// Called only by the explicit Settings action, and only for already observed owned stores.
    func recoverFutureFiles() -> Bool {
        lock.lock(); defer { lock.unlock() }
        var success = true
        for (file, kind) in Array(future) {
            guard safePath(file), let info = files.metadata(file), info.isRegularFile,
                  let data = try? files.read(file, offset: 0, maximumBytes: kind == .quota ? 3 * 1024 * 1024 + 1 : 65537), Self.isFuture(data) else { success = false; continue }
            if quarantine(file) { counts[kind.rawValue, default: 0] += 1; future[file] = nil; checked[file] = nil }
            else { success = false }
        }
        return success
    }
}

/// Runs the existing shared decoders/validation against a bounded immutable snapshot.
private struct RecoverySnapshotFiles: PlatformFileSystem {
    let data: Data
    func metadata(_ url: URL, followingSymbolicLinks: Bool) -> PlatformFileMetadata? {
        .init(identity: "snapshot", size: UInt64(data.count), modified: .distantPast, created: nil, isRegularFile: true)
    }
    func entries(in directory: URL) throws -> [URL] { [] }
    func read(_ url: URL, offset: UInt64, maximumBytes: Int) throws -> Data { Data(data.dropFirst(Int(offset)).prefix(maximumBytes)) }
    func replace(_ url: URL, with data: Data) -> Bool { true }
}

struct WindowsRecoveringHistoryFiles: PlatformFileSystem {
    let kind: WindowsStorageRecovery.Kind
    var recovery: WindowsStorageRecovery = .shared
    private let files = WindowsFileSystem()
    private func prepare(_ url: URL) {
        recovery.prepare(url, kind: kind, maximumBytes: kind == .quota ? 3 * 1024 * 1024 : 65536) { data in
            let snapshotFiles = RecoverySnapshotFiles(data: data)
            switch kind {
            case .quota:
                struct Envelope: Decodable { let snapshot: QuotaSnapshot }
                guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), let scope = envelope.snapshot.accountScope else { return false }
                return QuotaCycleCache(directory: url.deletingLastPathComponent(), files: snapshotFiles)
                    .load(home: url, accountScope: scope, now: envelope.snapshot.capturedAt) != nil
            case .dismissals:
                struct Envelope: Decodable { let version: Int; let digests: [String]; let cloudEndings: [CompletionDismissalStore.CloudEnding]? }
                guard let value = try? JSONDecoder().decode(Envelope.self, from: data), value.version == 1 else { return false }
                return CompletionDismissalStore(fileURL: url, files: snapshotFiles).saveDigests(value.digests, cloudEndings: value.cloudEndings ?? [])
            case .deepseek: return false // The DeepSeek actor supplies its existing decoder directly.
            }
        }
    }
    func metadata(_ url: URL, followingSymbolicLinks: Bool) -> PlatformFileMetadata? { prepare(url); return files.metadata(url, followingSymbolicLinks: followingSymbolicLinks) }
    func entries(in directory: URL) throws -> [URL] { try files.entries(in: directory) }
    func read(_ url: URL, offset: UInt64, maximumBytes: Int) throws -> Data { try files.read(url, offset: offset, maximumBytes: maximumBytes) }
    func replace(_ url: URL, with data: Data) -> Bool { prepare(url); return files.replace(url, with: data) }
}
