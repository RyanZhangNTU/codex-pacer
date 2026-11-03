import Foundation

/// Public routing facts only. Bearer credentials never leave the catalog RPC.
public struct RemoteControlAuthorizationSnapshot: Sendable {
    public let scope: String?
    public let hostIDs: Set<String>
    public let verified: Bool
    public let revoked: Bool
    public let revision: UInt64
    public init(scope: String? = nil, hostIDs: Set<String> = [], verified: Bool = false,
                revoked: Bool = false, revision: UInt64 = 0) {
        self.scope = scope; self.hostIDs = hostIDs; self.verified = verified; self.revoked = revoked; self.revision = revision
    }
}

/// Synchronous validation lets an IO driver reject a stale account before
/// forwarding a frame or opening a route, without doing another RPC.
package final class RemoteControlAuthorizationView: @unchecked Sendable {
    private let lock = NSLock()
    private var home: URL?
    private var value = RemoteControlAuthorizationSnapshot()
    private var validate: @Sendable () -> Bool = { false }
    package func snapshot(home: URL) -> RemoteControlAuthorizationSnapshot {
        lock.lock(); let matches = self.home == home, value = value, validate = validate; lock.unlock()
        guard matches else { return .init() }
        guard validate() else { return .init(scope: value.scope, revision: value.revision) }
        return value
    }
    package func publish(home: URL, scope: String?, hosts: Set<String>, verified: Bool, revoked: Bool = false,
                         validate: @escaping @Sendable () -> Bool) {
        lock.lock(); defer { lock.unlock() }
        self.home = home; self.validate = validate
        value = .init(scope: scope, hostIDs: hosts, verified: verified, revoked: revoked, revision: value.revision &+ 1)
    }
    package func clear(home: URL? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let home { self.home = home }
        value = .init(revoked: true, revision: value.revision &+ 1); validate = { true }
    }
    package func suspend() {
        lock.lock(); defer { lock.unlock() }
        value = .init(scope: value.scope, revoked: value.revoked, revision: value.revision &+ 1); validate = { true }
    }
}
