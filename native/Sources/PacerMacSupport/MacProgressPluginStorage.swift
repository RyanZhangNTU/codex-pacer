import Darwin
import Foundation
import PacerCore

/// Keep each operation relative to an open, user-owned parent. A replaced
/// directory cannot redirect a read, unlink, or atomic rename to another tree.
package struct MacProgressPluginStorage: ProgressPluginStorage {
    let profile: URL
    package init(profile: URL) { self.profile = profile.standardizedFileURL }

    /// A cached stdio process reopens the flag on every call. Local reporters
    /// outside the user profile are scoped to their configured data folder.
    package static func flagEnabled(_ flag: URL) -> Bool {
        let user = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let root = flag.standardizedFileURL.pathComponents.starts(with: user.pathComponents)
            ? user : flag.deletingLastPathComponent().deletingLastPathComponent()
        let on = LocalHarnessProgressSetup.on
        return (try? Self(profile: root).read(flag, maximumBytes: on.count)) == on
    }

    private func failure() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    private let unsafe = ClaudeHookInstaller.Failure.unsafePath
    private func parent<T>(_ url: URL, _ body: (Int32, String) throws -> T) throws -> T {
        let parts = url.standardizedFileURL.pathComponents, root = profile.pathComponents
        guard parts.starts(with: root) else { throw unsafe }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var fd = open(profile.path, flags)
        guard fd >= 0 else { throw failure() }
        defer { close(fd) }
        func checkDirectory() throws {
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid() else { throw unsafe }
        }
        try checkDirectory()
        let relative = parts.dropFirst(root.count)
        for component in relative.dropLast() {
            let child = openat(fd, component, flags)
            guard child >= 0 else { throw failure() }
            close(fd); fd = child
            try checkDirectory()
        }
        return try body(fd, relative.last ?? ".")
    }
    private func info(_ url: URL) throws -> stat? {
        do {
            return try parent(url) { fd, name in
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure() }
                guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR ||
                        (info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1) else { throw unsafe }
                return info
            }
        } catch let error as POSIXError where error.code == .ENOENT { return nil }
    }
    package func validate(_ url: URL) throws { _ = try info(url) }
    package func exists(_ url: URL) -> Bool { (try? info(url)) != nil }
    package func isDirectory(_ url: URL) -> Bool {
        guard let value = try? info(url) else { return false }
        return value.st_mode & S_IFMT == S_IFDIR
    }
    package func isReadable(_ url: URL) -> Bool { exists(url) }

    package func read(_ url: URL) throws -> Data { try read(url, maximumBytes: 2 * 1024 * 1024) }
    private func read(_ url: URL, maximumBytes: Int) throws -> Data {
        try parent(url) { fd, name in
            let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard file >= 0 else { throw failure() }
            let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_nlink == 1, info.st_uid == getuid(), info.st_size <= maximumBytes else { throw unsafe }
            return try handle.read(upToCount: maximumBytes + 1) ?? Data()
        }
    }
    package func createDirectory(_ url: URL, permissions: UInt16) throws {
        try parent(url) { fd, name in
            guard mkdirat(fd, name, permissions) == 0 else { throw failure() }
        }
    }
    package func replace(_ url: URL, with data: Data, permissions: UInt16) throws {
        try validate(url)
        try parent(url) { fd, name in
            let temp = ".pacer-" + UUID().uuidString
            let file = openat(fd, temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, permissions)
            guard file >= 0 else { throw failure() }
            defer { unlinkat(fd, temp, 0) }
            let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.close()
            guard renameat(fd, temp, fd, name) == 0 else { throw failure() }
        }
    }
    package func remove(_ url: URL) throws { try unlink(url, flags: 0) }
    package func removeEmptyDirectory(_ url: URL) throws { try unlink(url, flags: AT_REMOVEDIR) }
    private func unlink(_ url: URL, flags: Int32) throws {
        try validate(url)
        try parent(url) { fd, name in
            guard unlinkat(fd, name, flags) == 0 else { throw failure() }
        }
    }
    package func names(in directory: URL) throws -> Set<String> {
        try parent(directory) { fd, name in
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw failure() }
            guard let stream = fdopendir(child) else { close(child); throw failure() }
            defer { closedir(stream) }
            var entries = Set<String>()
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    if errno != 0 { throw failure() }
                    return entries
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name != "." && name != ".." { entries.insert(name) }
            }
        }
    }
}
