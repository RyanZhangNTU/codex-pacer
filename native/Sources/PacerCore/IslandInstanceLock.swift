import Foundation
import Darwin

/// Shared by installed and preview copies. The OS releases ownership on exit,
/// including crashes; keep the file so concurrent launches always lock one inode.
public final class IslandInstanceLock {
    public let acquired: Bool
    private let descriptor: Int32

    public init(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            self.descriptor = descriptor
            acquired = true
        } else {
            let failure = errno
            Darwin.close(descriptor)
            guard failure == EWOULDBLOCK else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure)) }
            self.descriptor = -1
            acquired = false
        }
    }

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
    }
}
