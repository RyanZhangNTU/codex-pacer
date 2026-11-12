import Foundation
import Darwin
import PacerCore

extension ClaudeLiveSessionRegistry {
    public static func holder(for sessionID: String, claudeHome: URL, currentProcess: pid_t = getpid(),
                              processStart: (pid_t) -> Date? = processStartDate) -> pid_t? {
        holder(for: sessionID, claudeHome: claudeHome, currentProcess: currentProcess,
            files: MacFileSystem(), processStart: processStart)
    }
    public static func holders(sessions: Set<String>? = nil, claudeHome: URL, currentProcess: pid_t = getpid(),
                               processStart: (pid_t) -> Date? = processStartDate) -> [String: pid_t] {
        holders(sessions: sessions, claudeHome: claudeHome, currentProcess: currentProcess, files: MacFileSystem(), processStart: processStart)
    }
    public static func processStartDate(_ pid: pid_t) -> Date? { ProcessOwnership.processStartDate(pid) }
}
