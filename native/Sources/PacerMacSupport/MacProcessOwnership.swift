import Foundation
import Darwin
import PacerCore

extension ProcessOwnership {
    public static func owner(of pid: pid_t, currentProcess: pid_t = getpid(), isApplication: (pid_t) -> Bool,
                             parent: (pid_t) -> pid_t? = parentProcess) -> pid_t? {
        findOwner(of: pid, currentProcess: currentProcess, isApplication: isApplication, parent: parent)
    }
    public static func processStartDate(_ pid: pid_t) -> Date? {
        information(pid).map {
            let start = $0.kp_proc.p_starttime
            return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
        }
    }

    public static func parentProcess(_ pid: pid_t) -> pid_t? {
        information(pid).map { $0.kp_eproc.e_ppid }
    }

    /// `proc_pidinfo` is denied for the root-owned `login` that Terminal and
    /// iTerm place above each shell; the process table is readable.
    private static func information(_ pid: pid_t) -> kinfo_proc? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.stride,
              info.kp_proc.p_pid == pid else { return nil }
        return info
    }
}
