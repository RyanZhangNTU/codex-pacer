import Foundation
import PacerCore

extension ClaudeActivityMonitor {
    init(clock: @escaping @Sendable () -> Date = { Date() }, ssh: WindowsSSHServices? = nil) {
        self.init(sshExecutable: ssh?.ssh ?? WindowsExecutables.ssh, processes: ssh?.processes ?? WindowsSSHProcessLauncher(ssh: WindowsExecutables.ssh),
            fileEvents: WindowsActivityLogWatcher(), telemetryTransport: WindowsTelemetryTransport(),
            remoteMirrorSessionIDs: { home in
                ClaudeDesktopRecords.remoteMirrorSessionIDs(claudeHome: home,
                    defaultClaudeHome: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude"),
                    directories: WindowsClaudeAccountBinding.locations(environment: ProcessInfo.processInfo.environment).map { $0.deletingLastPathComponent() },
                    files: WindowsFileSystem())
            }, files: WindowsFileSystem(), clock: clock, sshArguments: { WindowsSSHServices.arguments($0) })
    }
}

extension DeepSeekActivityMonitor {
    init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.init(files: WindowsFileSystem(), fileEvents: WindowsActivityLogWatcher(),
            liveSessions: { DeepSeekSessionLocks.held($0) }, clock: clock)
    }
}
