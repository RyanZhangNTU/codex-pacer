import Foundation
import PacerCore
import CWindowsSupport

final class WindowsWSLRegistrationWatch: ActivityFileWatch, @unchecked Sendable {
    private final class Callback {
        let changed: @Sendable (Bool) -> Void
        init(_ changed: @escaping @Sendable (Bool) -> Void) { self.changed = changed }
    }
    private let lock = NSLock()
    private var handle: UnsafeMutableRawPointer?
    private init(_ handle: UnsafeMutableRawPointer) { self.handle = handle }

    static func start(_ changed: @escaping @Sendable (Bool) -> Void) -> WindowsWSLRegistrationWatch? {
        let context = Unmanaged.passRetained(Callback(changed))
        let handle = pacer_watch_wsl_registrations(context.toOpaque(), { pointer, armed in
            if let pointer { Unmanaged<Callback>.fromOpaque(pointer).takeUnretainedValue().changed(armed != 0) }
        }, { pointer in
            if let pointer { Unmanaged<Callback>.fromOpaque(pointer).release() }
        })
        guard let handle else { context.release(); return nil }
        return WindowsWSLRegistrationWatch(handle)
    }
    func stop() {
        lock.lock(); let value = handle; handle = nil; lock.unlock()
        if let value { pacer_close_wsl_registration_watch(value) }
    }
    deinit { stop() }
}
