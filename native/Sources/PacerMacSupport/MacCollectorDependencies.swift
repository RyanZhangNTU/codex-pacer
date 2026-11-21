import Foundation
import Darwin
import PacerCore

extension ClaudeActivityMonitor {
    public init(sshExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.init(sshExecutable: sshExecutable, processes: MacHelperProcessLauncher(),
            fileEvents: MacActivityFileEvents(), telemetryTransport: MacTelemetryTransport(),
            remoteMirrorSessionIDs: { ClaudeApplicationResolver.remoteMirrorSessionIDs(claudeHome: $0) },
            files: MacFileSystem(), clock: clock, sshArguments: { $0.sshArguments() })
    }
}

extension RealtimeActivityMonitor {
    public init() {
        self.init(services: RealtimeActivityServices(processes: MacHelperProcessLauncher(),
            ssh: URL(fileURLWithPath: "/usr/bin/ssh"), diagnostics: RuntimeDiagnostics.observer,
            // One helper per machine, as on Windows, however many Desktop entries reach it.
            sshTargets: { await ClaudeSSHDiscovery.shared.configuredCodex(home: $0, userHome: FileManager.default.homeDirectoryForCurrentUser) },
            sshArguments: { target in
                guard let route = target.sshArguments() else { return nil }
                guard ConnectionSource.isManagedSSHSourceID(target.id) else { return route }
                // This helper owns its transport and can close it independently of Desktop.
                return ["-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ControlPersist=no",
                        "-o", "UpdateHostKeys=no", "-o", "PermitLocalCommand=no"] + route
            }))
    }
}
