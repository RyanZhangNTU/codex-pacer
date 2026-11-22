import Darwin
import Foundation
import PacerCore

/// Whether a Codex rollout still has a writer. Codex keeps the rollout of every
/// thread it has loaded open for reading and writing, so a running turn whose
/// rollout no process holds open for writing has lost its writer.
///
/// Only this user's processes are listed, and only their open files are
/// compared by device and inode (about 10 ms for a thousand processes); memory
/// maps and working directories are never walked.
public enum MacRolloutWriters {
    /// `LocalActivityReader.WriterProbe` for this Mac. Nil whenever a process that
    /// could be a writer could not be read, so an unreadable writer never ends a running turn.
    public static let probe: LocalActivityReader.WriterProbe = { rollout, _ in hasWriter(rollout) }

    static func hasWriter(_ file: URL) -> Bool? {
        var target = stat()
        guard stat(file.path, &target) == 0 else { return nil }
        guard let pids = userProcesses() else { return nil }
        var complete = true
        for pid in pids {
            switch writes(pid, device: target.st_dev, inode: target.st_ino) {
            case true?: return true
            case false?: continue
            // Some of macOS's own agents (routined, lsd, ScreenTimeAgent…) always refuse
            // to show their files. They run from the sealed system volume and never write
            // a Codex rollout, so they cannot leave the answer unknown.
            case nil: if executablePath(pid).map(isSystemExecutable) != true { complete = false }
            }
        }
        return complete ? false : nil
    }

    /// Whether an executable lives on macOS's sealed, read-only system volume,
    /// where no other software, Codex included, can be installed.
    static func isSystemExecutable(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("/../"), !path.hasPrefix("/usr/local/") else { return false }
        return ["/System/", "/usr/", "/bin/", "/sbin/"].contains { path.hasPrefix($0) }
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var bytes = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
        return String(cString: bytes)
    }

    private static func userProcesses() -> [pid_t]? {
        let stride = MemoryLayout<pid_t>.stride
        let needed = proc_listpids(UInt32(PROC_UID_ONLY), UInt32(getuid()), nil, 0)
        guard needed > 0 else { return nil }
        // Room for processes started between the two calls; a full buffer may have missed some.
        var pids = [pid_t](repeating: 0, count: Int(needed) / stride + 64)
        let size = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), UInt32(getuid()), $0.baseAddress, Int32($0.count))
        }
        guard size > 0, Int(size) < pids.count * stride else { return nil }
        return pids.prefix(Int(size) / stride).filter { $0 > 0 }
    }

    /// Whether `pid` holds the file open for writing; false when it does not, has
    /// no open files or has exited (a zombie answers as exited), nil when it could not be read.
    private static func writes(_ pid: pid_t, device: dev_t, inode: ino_t) -> Bool? {
        let stride = MemoryLayout<proc_fdinfo>.stride
        errno = 0
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return needed == 0 && errno == 0 || errno == ESRCH ? false : nil }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        errno = 0
        let size = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard size > 0 else { return size == 0 && errno == 0 || errno == ESRCH ? false : nil }
        var complete = Int(size) < fds.count * stride
        let infoSize = Int32(MemoryLayout<vnode_fdinfo>.stride)
        for fd in fds.prefix(Int(size) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfo()
            errno = 0
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEINFO, &info, infoSize) == infoSize else {
                if errno == ESRCH { return false }
                if errno != EBADF { complete = false }
                continue
            }
            guard info.pvi.vi_stat.vst_ino == inode, info.pvi.vi_stat.vst_dev == device else { continue }
            if info.pfi.fi_openflags & UInt32(FWRITE) != 0 { return true }
        }
        return complete ? false : nil
    }
}
