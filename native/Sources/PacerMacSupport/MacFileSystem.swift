import Darwin
import Foundation
import PacerCore

public struct MacFileSystem: PlatformFileSystem {
    public init() {}
    public func metadata(_ url: URL, followingSymbolicLinks: Bool) -> PlatformFileMetadata? {
        var info = stat()
        guard url.isFileURL else { return nil }
        let result = followingSymbolicLinks ? stat(url.path, &info) : lstat(url.path, &info)
        guard result == 0, info.st_size >= 0 else { return nil }
        return PlatformFileMetadata(identity: "\(info.st_dev):\(info.st_ino)", size: UInt64(info.st_size),
            modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9),
            created: Date(timeIntervalSince1970: Double(info.st_birthtimespec.tv_sec) + Double(info.st_birthtimespec.tv_nsec) / 1e9),
            isRegularFile: (info.st_mode & S_IFMT) == S_IFREG)
    }
    public func read(_ url: URL, offset: UInt64, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: maximumBytes) ?? Data()
    }
    public func replace(_ url: URL, with data: Data) -> Bool {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent("." + url.lastPathComponent + "-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
                attributes: [.posixPermissions: 0o600]) else { return false }
            defer { try? FileManager.default.removeItem(at: temporary) }
            let handle = try FileHandle(forWritingTo: temporary)
            do { try handle.write(contentsOf: data); try handle.close() }
            catch { try? handle.close(); return false }
            return temporary.path.withCString { source in
                url.path.withCString { destination in rename(source, destination) == 0 }
            }
        } catch { return false }
    }
}

extension CompletionDismissalStore {
    public init(fileURL: URL) { self.init(fileURL: fileURL, files: MacFileSystem()) }
    public static var applicationDefault: Self {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexPacerIsland", isDirectory: true)
        return Self(fileURL: directory.appendingPathComponent("completion-dismissals-v1.json"))
    }
}
