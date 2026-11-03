import Foundation
import CryptoKit

/// A local salt binds numeric wallet history without storing the credential.
public final class DeepSeekHistoryCredential: Sendable {
    public static let saltDefaultsKey = "deepseekBalanceHistorySalt.v1"
    private static let lock = NSLock()
    private let loadSalt: @Sendable () throws -> Data?
    private let saveSalt: @Sendable (Data) throws -> Void
    private enum Failure: Error { case unavailable }

    public init(loadSalt: @escaping @Sendable () throws -> Data?, saveSalt: @escaping @Sendable (Data) throws -> Void) {
        self.loadSalt = loadSalt; self.saveSalt = saveSalt
    }
    public convenience init(defaults: UserDefaults) {
        let storage = DefaultsSalt(defaults)
        self.init(loadSalt: { storage.load() }, saveSalt: { storage.save($0) })
    }
    public convenience init(saltFile: URL, files: any PlatformFileSystem) {
        self.init(loadSalt: {
            guard let info = files.metadata(saltFile, followingSymbolicLinks: false) else { return nil }
            guard info.isRegularFile, !info.isDirectory else { throw Failure.unavailable }
            if info.size != 32 { return Data() }
            return try files.read(saltFile, offset: 0, maximumBytes: 33)
        }, saveSalt: { value in
            guard files.replace(saltFile, with: value) else { throw Failure.unavailable }
        })
    }

    public func fingerprint(source: DeepSeekBalance.Source, identity: String) -> String? {
        guard !identity.isEmpty, identity.utf8.count <= 4096 else { return nil }
        Self.lock.lock(); defer { Self.lock.unlock() }
        do {
            var salt = try loadSalt()
            if salt?.count != 32 {
                var generator = SystemRandomNumberGenerator()
                let value = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
                try saveSalt(value)
                guard try loadSalt() == value else { return nil }
                salt = value
            }
            guard let salt else { return nil }
            let message = Data(("codex-pacer/deepseek-history/v1\0" + source.rawValue + "\0" + identity).utf8)
            return Self.authenticationCode(message: message, key: salt).prefix(16).map { String(format: "%02x", $0) }.joined()
        } catch { return nil }
    }
    static func isValid(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// RFC 2104 over each host's existing SHA-256 provider.
    static func authenticationCode(message: Data, key: Data) -> [UInt8] {
        var block = key.count > 64 ? Array(SHA256.hash(data: key)) : Array(key)
        block += repeatElement(0, count: 64 - block.count)
        let inner = Array(SHA256.hash(data: block.map { $0 ^ 0x36 } + message))
        return Array(SHA256.hash(data: block.map { $0 ^ 0x5c } + inner))
    }
    private final class DefaultsSalt: @unchecked Sendable {
        // UserDefaults is thread-safe; the outer lock serializes salt creation.
        private let defaults: UserDefaults
        init(_ defaults: UserDefaults) { self.defaults = defaults }
        func load() -> Data? {
            guard defaults.object(forKey: saltDefaultsKey) != nil else { return nil }
            return defaults.data(forKey: saltDefaultsKey) ?? Data()
        }
        func save(_ data: Data) { defaults.set(data, forKey: saltDefaultsKey) }
    }
}
