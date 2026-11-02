import Foundation

extension ClaudeActivityMonitor {
    init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.init(sshExecutable: WindowsExecutables.ssh, processes: WindowsHelperProcessLauncher(),
            fileEvents: WindowsActivityLogWatcher(), telemetryTransport: WindowsTelemetryTransport(),
            remoteMirrorSessionIDs: { home in
                ClaudeDesktopRecords.remoteMirrorSessionIDs(claudeHome: home,
                    defaultClaudeHome: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude"),
                    directories: WindowsClaudeAccountBinding.locations(environment: ProcessInfo.processInfo.environment).map { $0.deletingLastPathComponent() },
                    files: WindowsFileSystem())
            }, files: WindowsFileSystem(), clock: clock)
    }
}

extension DeepSeekActivityMonitor {
    init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.init(files: WindowsFileSystem(), fileEvents: WindowsActivityLogWatcher(),
            liveSessions: { DeepSeekSessionLocks.held($0) }, clock: clock)
    }
}
