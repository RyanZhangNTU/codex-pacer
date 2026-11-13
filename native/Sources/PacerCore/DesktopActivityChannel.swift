import Foundation

/// Hosts own authenticated IO; the monitor owns source identity and publication.
public protocol DesktopActivityChannel: Sendable {
    func start() async throws
    func setHosts(_ hosts: Set<String>) async
    func discover(_ threads: [String]) async
    func discoverRemote(_ routes: [NativeDesktopSession.Key]) async
    func setBatchInterval(_ seconds: TimeInterval, flushPending: Bool) async
    func stop() async
}
public extension DesktopActivityChannel {
    func discoverRemote(_ routes: [NativeDesktopSession.Key]) async {}
}

public struct RealtimeActivityServices: Sendable {
    public let desktopAvailable: @Sendable (URL) -> Bool
    public let controlAvailable: @Sendable (URL) -> Bool
    public let makeDesktop: @Sendable (URL, Set<String>, Bool, TimeInterval,
        @escaping @Sendable (Data) async -> Void, @escaping @Sendable () async -> Void) -> any DesktopActivityChannel
    public let processes: any HelperProcessLauncher
    public let python: URL
    public let ssh: URL
    public let diagnostics: RuntimeDiagnosticObserver
    public let sshTargets: (@Sendable (URL) async -> [RemoteActivityTarget])?
    public let sshArguments: (@Sendable (RemoteActivityTarget) -> [String]?)?
    public let remoteControlAuthorization: (@Sendable (URL) -> RemoteControlAuthorizationSnapshot)?
    public let supportsDurable: Bool
    public init(desktopAvailable: @escaping @Sendable (URL) -> Bool,
                controlAvailable: @escaping @Sendable (URL) -> Bool,
                makeDesktop: @escaping @Sendable (URL, Set<String>, Bool, TimeInterval,
                    @escaping @Sendable (Data) async -> Void, @escaping @Sendable () async -> Void) -> any DesktopActivityChannel,
                processes: any HelperProcessLauncher, python: URL, ssh: URL,
                diagnostics: RuntimeDiagnosticObserver = RuntimeDiagnosticObserver(),
                sshTargets: (@Sendable (URL) async -> [RemoteActivityTarget])? = nil,
                sshArguments: (@Sendable (RemoteActivityTarget) -> [String]?)? = nil,
                remoteControlAuthorization: (@Sendable (URL) -> RemoteControlAuthorizationSnapshot)? = nil,
                supportsDurable: Bool = false) {
        self.desktopAvailable = desktopAvailable; self.controlAvailable = controlAvailable
        self.makeDesktop = makeDesktop; self.processes = processes; self.python = python; self.ssh = ssh
        self.diagnostics = diagnostics
        self.sshTargets = sshTargets; self.sshArguments = sshArguments
        self.remoteControlAuthorization = remoteControlAuthorization
        self.supportsDurable = supportsDurable
    }
}
