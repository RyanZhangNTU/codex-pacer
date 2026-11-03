import Foundation
import PacerCore

typealias CodexDesktopConnection = DesktopActivityChannel

/// Host assembly only; source generations, retry and projection live in Core.
struct CodexDesktopServices: Sendable {
    let makeConnection: @Sendable (URL, TimeInterval, @escaping @Sendable (Data) async -> Void,
                                  @escaping @Sendable () async -> Void) -> any DesktopActivityChannel
    static var platformLive: Self? {
        #if os(Windows)
        return .init { home, interval, frame, closed in
            WindowsDesktopCollector(home: home, interval: interval, onFrame: frame, onClosed: closed)
        }
        #else
        return nil
        #endif
    }
    func makeMonitor(retryInterval: TimeInterval = 30, ssh: WindowsSSHServices? = nil,
                     targets: (@Sendable (URL) async -> [RemoteActivityTarget])? = nil) -> RealtimeActivityMonitor {
        let catalog = RemoteControlCatalog(fetch: { _ in throw CodexClientError.invalidResponse },
            files: WindowsFileSystem(), makeClient: { _ in nil })
        return RealtimeActivityMonitor(controlCatalog: catalog, services: .init(
            desktopAvailable: { _ in true }, controlAvailable: { _ in false },
            makeDesktop: { home, _, _, interval, frame, closed in makeConnection(home, interval, frame, closed) },
            processes: ssh?.processes ?? WindowsSSHProcessLauncher(ssh: WindowsExecutables.ssh),
            python: WindowsExecutables.python, ssh: ssh?.ssh ?? WindowsExecutables.ssh,
            sshTargets: targets, sshArguments: { WindowsSSHServices.arguments($0) }),
            retryInterval: retryInterval)
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
    var remoteStatuses: [String: RuntimeStreamStatus] = [:]
}
