import Foundation
import PacerCore

typealias CodexDesktopConnection = DesktopActivityChannel

/// Host assembly only; source generations, retry and projection live in Core.
struct CodexDesktopServices: Sendable {
    typealias Connection = @Sendable (URL, TimeInterval, @escaping @Sendable (Data) async -> Void,
                                     @escaping @Sendable () async -> Void) -> any DesktopActivityChannel
    typealias RoutedConnection = @Sendable (URL, Set<String>, Bool, TimeInterval, @escaping @Sendable (Data) async -> Void,
                                           @escaping @Sendable () async -> Void) -> any DesktopActivityChannel
    let makeConnection: Connection
    let catalog: RemoteControlCatalog?
    let routed: RoutedConnection?
    let setExecutable: @Sendable (String) -> Void
    let supportsDurable: Bool
    init(makeConnection: @escaping Connection, supportsDurable: Bool = false) {
        self.makeConnection = makeConnection; catalog = nil; routed = nil; setExecutable = { _ in }
        self.supportsDurable = supportsDurable
    }
    init(makeConnection: @escaping Connection, catalog: RemoteControlCatalog, routed: @escaping RoutedConnection,
         setExecutable: @escaping @Sendable (String) -> Void = { _ in }, supportsDurable: Bool = false) {
        self.makeConnection = makeConnection; self.catalog = catalog; self.routed = routed; self.setExecutable = setExecutable
        self.supportsDurable = supportsDurable
    }
    func authorization(home: URL) -> RemoteControlAuthorizationSnapshot? { catalog?.authorization.snapshot(home: home) }
    static var platformLive: Self? {
        #if os(Windows)
        let path = ExecutablePath()
        let catalog = RemoteControlCatalog(fetch: { try await WindowsRemoteControlHTTP.fetch($0) }, files: WindowsFileSystem(), makeClient: { home in
            guard let executable = CodexClient.findExecutable(customPath: path.get()) else { return nil }
            return CodexClient(executable: executable, home: home, timeout: 8)
        })
        return .init(makeConnection: { home, interval, frame, closed in
            WindowsDesktopCollector(home: home, interval: interval, onFrame: frame, onClosed: closed)
        }, catalog: catalog, routed: { home, hosts, local, interval, frame, closed in
            WindowsDesktopCollector(home: home, interval: interval, hosts: hosts, localRuntime: local,
                authorization: { catalog.authorization.snapshot(home: home) }, onFrame: frame, onClosed: closed)
        }, setExecutable: { path.set($0) }, supportsDurable: true)
        #else
        return nil
        #endif
    }
    func makeMonitor(retryInterval: TimeInterval = 30, ssh: WindowsSSHServices? = nil, wsl: WindowsWSLServices? = nil,
                     targets: (@Sendable (URL) async -> [RemoteActivityTarget])? = nil,
                     wslDisconnected: WindowsWSLServices.Disconnect? = nil) -> RealtimeActivityMonitor {
        let catalog = catalog ?? RemoteControlCatalog(fetch: { _ in throw CodexClientError.invalidResponse },
            files: WindowsFileSystem(), makeClient: { _ in nil })
        let authorization: (@Sendable (URL) -> RemoteControlAuthorizationSnapshot)?
        if self.catalog != nil { authorization = { catalog.authorization.snapshot(home: $0) } } else { authorization = nil }
        let arguments: (@Sendable (RemoteActivityTarget) -> [String]?)?
        arguments = { target in
            if target.id.hasPrefix(ConnectionSource.wslPrefix) { return wsl?.registry.arguments(target) }
            return WindowsSSHServices.arguments(target)
        }
        let base = ssh?.processes ?? WindowsSSHProcessLauncher(ssh: WindowsExecutables.ssh)
        return RealtimeActivityMonitor(controlCatalog: catalog, services: .init(
            desktopAvailable: { _ in true }, controlAvailable: { _ in false },
            makeDesktop: { home, hosts, local, interval, frame, closed in
                if let routed { return routed(home, hosts, local, interval, frame, closed) }
                return makeConnection(home, interval, frame, closed)
            }, processes: wsl?.launcher(base: base, disconnected: wslDisconnected) ?? base, python: WindowsExecutables.python, ssh: ssh?.ssh ?? WindowsExecutables.ssh,
            sshTargets: targets, sshArguments: arguments,
            remoteControlAuthorization: authorization, supportsDurable: supportsDurable),
            retryInterval: retryInterval)
    }
    private final class ExecutablePath: @unchecked Sendable {
        private let lock = NSLock(); private var value = ""
        func get() -> String { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ value: String) { lock.lock(); self.value = value; lock.unlock() }
    }
}
struct CodexDesktopState: Sendable {
    let context: UInt64
    let activities: [SessionActivity]
    let attention: [PendingAttentionRequest]
    let attentionThreads: Set<String>
    let names: [SessionNameUpdate]
    let performance: [SessionPerformanceUpdate]
    let status: RuntimeStreamStatus
    var statuses: [String: RuntimeStreamStatus] = [:]
    var bindings = RemoteControlSourceBindings(hostIDs: [], authoritative: false)
    var durableAccountScope: String?
    /// Failed sources without a stream status, such as an exited SSH helper.
    var unavailable: [String] = []
    var remoteControlDirectory: RemoteControlDirectoryStatus?
    var remoteStatuses: [String: RuntimeStreamStatus] { statuses.filter { $0.key != "local" } }
}
