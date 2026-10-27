import Darwin
import Foundation

/// Ownership comes from an open rollout, never from task text, argv or a cwd
/// guess. Zotero's codex-acp app-server kept its rollout open in all 60 idle
/// samples after a synthetic request on macOS (Codex 0.159.3 adapter).
public enum CodexRolloutOwners {
    public static func holders(rollouts: [String: URL], processes: () -> [pid_t] = userProcesses,
                               files: (pid_t) -> [URL] = openFiles,
                               processStart: (pid_t) -> Date? = ProcessOwnership.processStartDate) -> [String: pid_t] {
        let paths = Dictionary(rollouts.filter { $0.value.isFileURL }.map {
            ($0.value.standardizedFileURL.resolvingSymlinksInPath().path, $0.key)
        }, uniquingKeysWith: { first, _ in first })
        guard !paths.isEmpty else { return [:] }
        var result: [String: pid_t] = [:]
        for pid in processes().prefix(2048) where pid > 1 && pid != getpid() {
            guard let started = processStart(pid) else { continue }
            let matching = files(pid).prefix(4096).compactMap { paths[$0.standardizedFileURL.path] }
            guard processStart(pid) == started else { continue }
            for session in matching where result[session] == nil { result[session] = pid }
            if result.count == paths.count { break }
        }
        return result
    }
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
    public static func holders(sessions: Set<String>, home: URL) -> [String: pid_t] {
        let lookup = CodexOriginLookup(home: home)
        let paths = Dictionary(sessions.compactMap { session -> (String, URL)? in
            guard let record = lookup.lookup(session), record.origin.embedded, !record.origin.ignored else { return nil }
            return (session, record.url)
        }, uniquingKeysWith: { first, _ in first })
        return holders(rollouts: paths)
    }
}
