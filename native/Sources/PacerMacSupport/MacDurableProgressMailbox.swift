import Darwin
import Foundation
import PacerCore

/// Bounded latest receipts from the local Durable reporter. The collector
/// still has to verify the account, executor, thread and current turn.
package struct MacDurableProgressMailbox {
    private let home: URL
    private let storage = MacClaudeHookStorage()
    private var root: URL { home.appendingPathComponent("pacer/codex-progress/durable-marketplace") }
    private var directory: URL { root.appendingPathComponent("receipts") }
    private var lockFile: URL { directory.appendingPathComponent("write.lock") }
    private var snapshot: URL { directory.appendingPathComponent("latest.json") }

    package init(home: URL) { self.home = home }

    func prepare() throws {
        try validatePath()
        if !storage.exists(directory) { try storage.createDirectory(directory, permissions: 0o700) }
        try validateDirectory()
        let fd = open(lockFile.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        if fd >= 0 { close(fd) }
        else if errno != EEXIST { throw failure() }
        try withLock {}
    }

    func discard() throws {
        guard storage.exists(directory) else { return }
        try validateDirectory()
        if storage.exists(lockFile) {
            try withLock {
                try unlinkIfPresent(snapshot)
                try unlinkIfPresent(lockFile)
                if rmdir(directory.path) != 0 { throw failure() }
            }
        } else {
            try unlinkIfPresent(snapshot)
            if rmdir(directory.path) != 0 { throw failure() }
        }
    }

    package func record(_ receipt: DurableProgressReceipt) {
        try? withLock {
            let now = Date()
            guard receipt.isRecent(at: now) else { return }
            var receipts = read(at: now)
            let key = receipt.threadID + ":" + receipt.turnID
            if let previous = receipts[key], previous.callID == receipt.callID || previous.at > receipt.at { return }
            receipts[key] = receipt
            let recent = receipts.sorted { $0.value.at > $1.value.at }.prefix(64)
            let bytes = try JSONEncoder().encode(Dictionary(uniqueKeysWithValues: recent.map { ($0.key, $0.value) }))
            try storage.validate(snapshot)
            try storage.replace(snapshot, with: bytes, permissions: 0o600)
        }
    }

    func read(at now: Date = Date()) -> [String: DurableProgressReceipt] {
        guard (try? validateDirectory()) != nil,
              let data = try? storage.read(snapshot), data.count <= 64 * 1024,
              let records = try? JSONDecoder().decode([String: DurableProgressReceipt].self, from: data),
              records.count <= 64 else { return [:] }
        return records.filter { $0.key == $0.value.threadID + ":" + $0.value.turnID && $0.value.isRecent(at: now) }
    }

    private func validatePath() throws {
        for url in [home, home.appendingPathComponent("pacer"), root.deletingLastPathComponent(), root, directory] {
            try storage.validate(url)
        }
    }

    private func validateDirectory() throws {
        try validatePath()
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw ClaudeHookInstaller.Failure.unsafePath }
    }

    private func withLock(_ work: () throws -> Void) throws {
        try validateDirectory()
        let fd = open(lockFile.path, O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw failure() }
        defer { close(fd) }
        var file = stat()
        guard fstat(fd, &file) == 0, file.st_mode & S_IFMT == S_IFREG,
              file.st_uid == getuid(), file.st_mode & 0o077 == 0 else { throw ClaudeHookInstaller.Failure.unsafePath }
        for _ in 0..<6 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                var current = stat()
                // An old writer may still hold a descriptor after uninstall.
                guard lstat(lockFile.path, &current) == 0, file.st_dev == current.st_dev,
                      file.st_ino == current.st_ino else { throw ClaudeHookInstaller.Failure.unsafePath }
                try work()
                return
            }
            guard errno == EWOULDBLOCK || errno == EINTR else { throw failure() }
            usleep(5_000)
        }
        throw POSIXError(.EWOULDBLOCK)
    }

    private func unlinkIfPresent(_ file: URL) throws {
        if unlink(file.path) != 0 && errno != ENOENT { throw failure() }
    }

    private func failure() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
