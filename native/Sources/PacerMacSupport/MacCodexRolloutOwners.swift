import Foundation
import Darwin
import PacerCore

extension CodexRolloutOwners {
    public static func userProcesses() -> [pid_t] {
        let size = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard size > 0 else { return [] }
        var values = [pid_t](repeating: 0, count: min(8192, Int(size) / MemoryLayout<pid_t>.stride + 32))
        let count = values.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, Int32($0.count)) }
        return Array(values.prefix(max(0, Int(count)) / MemoryLayout<pid_t>.stride)).filter { $0 > 1 }
    }
    public static func openFiles(_ pid: pid_t) -> [URL] {
        openFiles(pid) { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }
    }
    /// Files the process holds open for writing whose name `named` accepts.
    public static func openFiles(_ pid: pid_t, named: (String) -> Bool) -> [URL] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: min(4096, Int(size) / MemoryLayout<proc_fdinfo>.stride + 16))
        let count = descriptors.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        var result: [URL] = []
        for descriptor in descriptors.prefix(max(0, Int(count)) / MemoryLayout<proc_fdinfo>.stride) where descriptor.proc_fdtype == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            let count = proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout.size(ofValue: info)))
            guard count == MemoryLayout.size(ofValue: info), info.pfi.fi_openflags & 2 != 0 else { continue }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { bytes in String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) }
            let name = (path as NSString).lastPathComponent
            if path.hasPrefix("/"), named(name) { result.append(URL(fileURLWithPath: path)) }
        }
        return result
    }
    public static func holders(rollouts: [String: URL], processes: () -> [pid_t] = userProcesses,
                               files: (pid_t) -> [URL] = openFiles,
                               processStart: (pid_t) -> Date? = ProcessOwnership.processStartDate) -> [String: pid_t] {
        holders(rollouts: rollouts, currentProcess: getpid(), processes: processes, files: files, processStart: processStart)
    }
    public static func holders(sessions: Set<String>, home: URL) -> [String: pid_t] {
        holders(sessions: sessions, home: home, currentProcess: getpid(), processes: userProcesses,
            files: openFiles, processStart: ProcessOwnership.processStartDate)
    }
}
