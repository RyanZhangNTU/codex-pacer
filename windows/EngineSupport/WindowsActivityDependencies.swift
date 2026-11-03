import Foundation
import PacerCore

extension ClaudeActivityMonitor {
    init(clock: @escaping @Sendable () -> Date = { Date() }, ssh: WindowsSSHServices? = nil, wsl: WindowsWSLServices? = nil) {
        let base = ssh?.processes ?? WindowsSSHProcessLauncher(ssh: WindowsExecutables.ssh)
        self.init(sshExecutable: ssh?.ssh ?? WindowsExecutables.ssh, processes: wsl?.launcher(base: base) ?? base,
            fileEvents: WindowsActivityLogWatcher(), telemetryTransport: WindowsTelemetryTransport(),
            remoteMirrorSessionIDs: { home in
                ClaudeDesktopRecords.remoteMirrorSessionIDs(claudeHome: home,
                    defaultClaudeHome: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude"),
                    directories: WindowsClaudeAccountBinding.locations(environment: ProcessInfo.processInfo.environment).map { $0.deletingLastPathComponent() },
                    files: WindowsFileSystem())
            }, files: WindowsFileSystem(), clock: clock, sshArguments: { target in
                if target.id.hasPrefix(ConnectionSource.wslPrefix) { return wsl?.registry.arguments(target) }
                return WindowsSSHServices.arguments(target)
            }, remoteHome: { $0.id.hasPrefix(ConnectionSource.wslPrefix) ? $0.home : "~/.claude" }, maximumRemoteTargets: 16)
    }
}

extension DeepSeekActivityMonitor {
    init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.init(files: WindowsFileSystem(), fileEvents: WindowsActivityLogWatcher(),
            liveSessions: { DeepSeekSessionLocks.held($0) }, clock: clock)
    }
}
