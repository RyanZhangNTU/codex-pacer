import Foundation

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
    func makeMonitor(retryInterval: TimeInterval = 30) -> RealtimeActivityMonitor {
        let catalog = RemoteControlCatalog(fetch: { _ in throw CodexClientError.invalidResponse },
            files: WindowsFileSystem(), makeClient: { _ in nil })
        return RealtimeActivityMonitor(controlCatalog: catalog, services: .init(
            desktopAvailable: { _ in true }, controlAvailable: { _ in false },
            makeDesktop: { home, _, _, interval, frame, closed in makeConnection(home, interval, frame, closed) },
            processes: WindowsHelperProcessLauncher(), python: WindowsExecutables.python, ssh: WindowsExecutables.ssh),
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
}
