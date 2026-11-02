import Foundation
import Darwin
import PacerCore

extension ClaudeLiveSessionRegistry {
    public static func holder(for sessionID: String, claudeHome: URL, currentProcess: pid_t = getpid(),
                              processStart: (pid_t) -> Date? = processStartDate) -> pid_t? {
        holder(for: sessionID, claudeHome: claudeHome, currentProcess: currentProcess,
            files: MacFileSystem(), processStart: processStart)
    }
    public static func holders(claudeHome: URL, currentProcess: pid_t = getpid(),
                               processStart: (pid_t) -> Date? = processStartDate) -> [String: pid_t] {
        holders(claudeHome: claudeHome, currentProcess: currentProcess, files: MacFileSystem(), processStart: processStart)
    }
    public static func owner(of pid: pid_t, currentProcess: pid_t = getpid(), isApplication: (pid_t) -> Bool,
                             parent: (pid_t) -> pid_t? = ProcessOwnership.parentProcess) -> pid_t? {
        ProcessOwnership.owner(of: pid, currentProcess: currentProcess, isApplication: isApplication, parent: parent)
    }
    public static func processStartDate(_ pid: pid_t) -> Date? { ProcessOwnership.processStartDate(pid) }
    public static func parentProcess(_ pid: pid_t) -> pid_t? { ProcessOwnership.parentProcess(pid) }
}
