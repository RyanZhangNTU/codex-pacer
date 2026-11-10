#if os(Windows)
import Foundation
import FoundationNetworking
import PacerCore

enum WindowsDurableCatalog {
    struct Binding: Equatable, Sendable {
        let executor: WindowsDurableExecutor
        let fingerprint: String

        func isCurrent(home: URL) -> Bool {
            executor.isAlive && CodexClient.authenticationFingerprint(home: home, files: WindowsFileSystem()) == fingerprint
        }
    }

    private struct Connection {
        let binding: Binding
        let reader: DurableCatalogReader
        let expires = Date().addingTimeInterval(120)
    }

    static func observe(home: URL, desktop: WindowsProcessIdentity, package: URL,
                        publish: @Sendable (DurableActivityCatalog?, Binding?) async -> Void,
                        ipc: @Sendable () async -> [String: Date],
                        publishHistory: @Sendable (String, Binding, [DurableTurnHistory]) async -> Void) async {
        var connection: Connection?, previous: DurableActivityCatalog?
        var history = DurableHistoryPoll(), retryDelay = 5.0
        let mailbox = WindowsDurableProgressMailbox(home: home)
        defer { connection?.reader.close() }
        while !Task.isCancelled {
            let delay: TimeInterval
            do {
                try WindowsLocalProfileStorage().validate(home.appendingPathComponent("auth.json"))
                guard let executor = WindowsDurableExecutor.find(desktop: desktop, package: package),
                      let fingerprint = CodexClient.authenticationFingerprint(home: home, files: WindowsFileSystem()) else {
                    throw CodexClientError.disconnected
                }
                let binding = Binding(executor: executor, fingerprint: fingerprint)
                if connection?.binding != binding || (connection?.expires ?? .distantPast) <= Date() {
                    connection?.reader.close()
                    connection = nil
                    let client = CodexClient(executable: executor.packagedCLI, home: home, timeout: 8)
                    let credentials: (request: URLRequest, scope: String)
                    do { credentials = try await client.durableCatalogCredentials() }
                    catch { await client.shutdown(); throw error }
                    await client.shutdown()
                    try Task.checkCancellation()
                    guard binding.isCurrent(home: home) else { throw CodexClientError.accountMismatch }
                    let reader = DurableCatalogReader(socket: try WindowsDurableSocket(credentials.request),
                        scope: credentials.scope, environmentID: executor.environmentID)
                    connection = Connection(binding: binding, reader: reader)
                    try await reader.initialize()
                }
                guard let reader = connection?.reader else { throw CodexClientError.disconnected }
                let result = try await reader.read(retaining: previous)
                try Task.checkCancellation()
                guard binding.isCurrent(home: home) else { throw CodexClientError.accountMismatch }
                if previous?.scope != result.catalog.scope { history.reset(startingNow: previous != nil) }
                previous = result.catalog
                await publish(result.catalog, binding)
                let now = Date()
                let updates = try await history.read(result, using: reader, ipc: await ipc(), receipts: mailbox.read(at:), at: now)
                try Task.checkCancellation()
                guard binding.isCurrent(home: home) else { throw CodexClientError.accountMismatch }
                if !updates.isEmpty { await publishHistory(result.catalog.scope, binding, updates) }
                retryDelay = 5
                delay = max(1, 15 - Date().timeIntervalSince(now))
            } catch {
                connection?.reader.close()
                connection = nil
                if Task.isCancelled { break }
                await publish(nil, nil)
                delay = retryDelay
                retryDelay = min(60, retryDelay * 2)
            }
            do { try await Task.sleep(for: .seconds(delay)) } catch { break }
        }
    }
}
#endif
