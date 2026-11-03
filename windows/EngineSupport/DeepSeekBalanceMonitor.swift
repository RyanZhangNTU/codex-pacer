import Foundation
#if os(Windows)
import FoundationNetworking
#endif

typealias DeepSeekBalanceMonitor = DeepSeekBalanceCoordinator

extension DeepSeekBalanceServices {
    static var live: Self {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexPacer/DeepSeekBalance", isDirectory: true)
        let history = DeepSeekBalanceHistoryStore(file: directory.appendingPathComponent("history-v1.json"))
        let fingerprints = DeepSeekHistoryCredential(saltFile: directory.appendingPathComponent("history-salt-v1.bin"), files: WindowsFileSystem())
        return .init(readKey: { DeepSeekAPIKeyStore.read() }, saveKey: { DeepSeekAPIKeyStore.save($0) },
            removeKey: {
                #if os(Windows)
                return DeepSeekAPIKeyStore.remove()
                #else
                DeepSeekAPIKeyStore.remove(); return !DeepSeekAPIKeyStore.exists
                #endif
            }, readAPI: { key in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
                let session = URLSession(configuration: configuration, delegate: BalanceRedirectPolicy(), delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                return try await DeepSeekAPIBalanceClient.read(key: key, session: session)
            }, fingerprint: { fingerprints.fingerprint(source: $0, identity: $1) }, loadHistory: { await history.load(now: Date()) }, saveHistory: { await history.save($0, revision: $1) })
    }
    static func demo(now: @escaping @Sendable () -> Date) -> Self {
        let memory = DemoKey()
        let fingerprints = DeepSeekHistoryCredential(loadSalt: { Data(repeating: 0xa5, count: 32) }, saveSalt: { _ in })
        return .init(readKey: { memory.read() }, saveKey: { memory.save($0) }, removeKey: { memory.remove() },
            readAPI: { _ in .init(total: 86.4, granted: 6.4, capturedAt: now(), source: .apiKey) },
            fingerprint: { fingerprints.fingerprint(source: $0, identity: $1) },
            readWeb: { _ in
                guard memory.isSignedIn(), let value = EngineWalletSource.demo(at: now()).balance else { throw DeepSeekBalanceError.signedOut }
                return .init(total: value.total, granted: value.granted, available: value.available, tokenEstimation: value.tokenEstimation,
                    alertBound: value.alertBound, capturedAt: value.capturedAt, source: value.source, sessionFingerprint: String(repeating: "0", count: 64))
            },
            webSessionChanged: { memory.setSignedIn($0) }, detect: { _, _ in .account },
            loadHistory: { EngineWalletSource.demo(at: now()).history })
    }
    private final class DemoKey: @unchecked Sendable {
        private let lock = NSLock(); private var key: String?, signedIn = true
        func read() -> String? { lock.lock(); defer { lock.unlock() }; return key }
        func save(_ value: String) -> Bool { lock.lock(); key = value; lock.unlock(); return true }
        func remove() -> Bool { lock.lock(); key = nil; lock.unlock(); return true }
        func isSignedIn() -> Bool { lock.lock(); defer { lock.unlock() }; return signedIn }
        func setSignedIn(_ value: Bool) { lock.lock(); signedIn = value; lock.unlock() }
    }
    private final class BalanceRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    }
}
