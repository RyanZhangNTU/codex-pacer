import Foundation
import PacerCore

/// Harness holds each open session's `session.lock` for writing, even while idle.
public enum DeepSeekSessionLocks {
    public static func held(_ locks: [String: URL], processes: () -> [pid_t] = CodexRolloutOwners.userProcesses,
                     files: (pid_t) -> [URL] = { pid in CodexRolloutOwners.openFiles(pid) { $0 == "session.lock" } }) -> Set<String> {
        guard !locks.isEmpty else { return [] }
        return Set(CodexRolloutOwners.holders(rollouts: locks, processes: processes, files: files).keys)
    }
}

extension DeepSeekActivityMonitor {
    public init(liveSessions: @escaping @Sendable ([String: URL]) -> Set<String> = { DeepSeekSessionLocks.held($0) }) {
        self.init(files: MacFileSystem(), fileEvents: MacActivityFileEvents(), liveSessions: liveSessions)
    }
}
