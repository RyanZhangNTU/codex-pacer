import Foundation

/// Hosts revoke publication synchronously, before entering an actor or awaiting
/// client shutdown. Cancellation alone cannot invalidate an uncooperative read.
final class QuotaWorkGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var invalidators: [@Sendable () -> Void] = []
    func invalidate() {
        lock.lock(); value &+= 1
        let callbacks = invalidators; invalidators = []; lock.unlock()
        for callback in callbacks { callback() }
    }
    func onInvalidate(_ callback: @escaping @Sendable () -> Void) {
        // A coordinator owns one current connection. Replacing this callback
        // releases a failed connection instead of retaining every past retry.
        lock.lock(); invalidators = [callback]; lock.unlock()
    }
    func capture() -> UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    func contains(_ expected: UInt64) -> Bool { capture() == expected }
}
