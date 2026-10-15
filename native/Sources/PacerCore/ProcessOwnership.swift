import Darwin
import Foundation

/// Shared process ancestry and PID-reuse checks for both provider adapters.
public enum ProcessOwnership {
    /// Walks up from the holder to the first process `isApplication` accepts:
    /// the terminal, editor or app that embeds the provider and shows the session.
    public static func owner(of pid: pid_t, currentProcess: pid_t = getpid(), isApplication: (pid_t) -> Bool,
                             parent: (pid_t) -> pid_t? = parentProcess) -> pid_t? {
        var current = pid, visited = Set<pid_t>()
        for _ in 0..<32 {
            guard current > 1, current != currentProcess, visited.insert(current).inserted else { return nil }
            if isApplication(current) { return current }
            guard let next = parent(current) else { return nil }
            current = next
        }
        return nil
    }

    public static func processStartDate(_ pid: pid_t) -> Date? {
        information(pid).map { Date(timeIntervalSince1970: TimeInterval($0.kp_proc.p_starttime.tv_sec)) }
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
