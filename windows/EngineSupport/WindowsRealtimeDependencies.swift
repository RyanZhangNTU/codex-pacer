import Foundation
import PacerCore

/// Host assembly for Codex on SSH and WSL hosts; source generations, retry and
/// projection live in Core. Local Codex comes from Pacer's hook spool, read by
/// the engine's `LocalActivityReader`.
struct CodexDesktopServices: Sendable {
    /// Follows Dot tasks through the catalog poll until cancelled.
    typealias DurableObserver = @Sendable (_ home: URL,
        _ publish: @escaping @Sendable (DurableActivityCatalog?) async -> Void,
        _ publishHistory: @escaping @Sendable (String, [DurableTurnHistory]) async -> Void) async -> Void

    /// Production starts the monitor in owned background work, since SSH
    /// discovery can wait; test fixtures start it inline.
    let startsInBackground: Bool
    let observeDurable: DurableObserver?
    init(startsInBackground: Bool = false, observeDurable: DurableObserver? = nil) {
        self.startsInBackground = startsInBackground; self.observeDurable = observeDurable
    }
    static var platformLive: Self? {
        #if os(Windows)
        return Self(startsInBackground: true, observeDurable: { home, publish, publishHistory in
            // Desktop runs Dot tasks with the default profile; another home waits until the engine rebinds.
            guard WindowsActivityNavigation.isDefaultProfile(home, provider: .codex) else {
                while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
                return
            }
            await WindowsDurableCatalog.observe(home: home, publish: publish, publishHistory: publishHistory)
        })
        #else
        return nil
        #endif
    }
    func makeMonitor(retryInterval: TimeInterval = 30, ssh: WindowsSSHServices? = nil, wsl: WindowsWSLServices? = nil,
                     targets: (@Sendable (URL) async -> [RemoteActivityTarget])? = nil,
                     wslDisconnected: WindowsWSLServices.Disconnect? = nil) -> RealtimeActivityMonitor {
        let arguments: @Sendable (RemoteActivityTarget) -> [String]? = { target in
            if target.id.hasPrefix(ConnectionSource.wslPrefix) { return wsl?.registry.arguments(target) }
            return WindowsSSHServices.arguments(target)
        }
        let base = ssh?.processes ?? WindowsSSHProcessLauncher(ssh: WindowsExecutables.ssh)
        return RealtimeActivityMonitor(services: .init(
            processes: wsl?.launcher(base: base, disconnected: wslDisconnected) ?? base, ssh: ssh?.ssh ?? WindowsExecutables.ssh,
            sshTargets: targets, sshArguments: arguments), retryInterval: retryInterval)
    }
}

/// The last SSH and WSL snapshot of one Codex source generation.
struct CodexDesktopState: Sendable {
    let context: UInt64
    let activities: [SessionActivity]
    let names: [SessionNameUpdate]
    let performance: [SessionPerformanceUpdate]
    var statuses: [String: RuntimeStreamStatus] = [:]
    /// Failed sources without a stream status, such as an exited SSH helper.
    var unavailable: [String] = []
}
