import AppKit

/// Whether anyone can see this Mac's screen. Polls that only feed the display
/// pause while it is dark or locked and catch up as soon as it lights again.
final class MacDisplayActivity: @unchecked Sendable {
    static let shared = MacDisplayActivity()
    private let lock = NSLock()
    private var reasons: Set<String> = []
    private var observers: [NSObjectProtocol] = []

    private init() {
        // Distributed notifications reach the registering thread's run loop.
        if Thread.isMainThread { register() } else { DispatchQueue.main.async { self.register() } }
    }
    var isDark: Bool { lock.lock(); defer { lock.unlock() }; return !reasons.isEmpty }

    private func register() {
        let center = NSWorkspace.shared.notificationCenter
        for (name, reason, dark) in [(NSWorkspace.screensDidSleepNotification, "display", true),
                                     (NSWorkspace.screensDidWakeNotification, "display", false),
                                     (NSWorkspace.sessionDidResignActiveNotification, "session", true),
                                     (NSWorkspace.sessionDidBecomeActiveNotification, "session", false)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.set(reason, dark) })
        }
        let distributed = DistributedNotificationCenter.default()
        for (name, dark) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            observers.append(distributed.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in self?.set("lock", dark) })
        }
    }
    private func set(_ reason: String, _ dark: Bool) {
        lock.lock(); defer { lock.unlock() }
        if dark { reasons.insert(reason) } else { reasons.remove(reason) }
    }
}
