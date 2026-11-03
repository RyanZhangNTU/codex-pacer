import Foundation
import CWindowsSupport

/// ReadDirectoryChangesW facts only. Core owns limits, debounce and lifecycle.
struct WindowsActivityLogWatcher: ActivityFileEvents {
    private final class Signal: @unchecked Sendable {
        let changed: @Sendable (ActivityFileEvent) -> Void
        init(_ changed: @escaping @Sendable (ActivityFileEvent) -> Void) { self.changed = changed }
    }
    private final class Watch: ActivityFileWatch, @unchecked Sendable {
        private let lock = NSLock()
        private var handle: UnsafeMutableRawPointer?
        init(_ handle: UnsafeMutableRawPointer) { self.handle = handle }
        func stop() {
            lock.lock(); let value = handle; handle = nil; lock.unlock()
            if let value { pacer_close_directory_watch(value) }
        }
        deinit { stop() }
    }
    func watch(_ url: URL, isDirectory: Bool,
               changed: @escaping @Sendable (ActivityFileEvent) -> Void) -> (any ActivityFileWatch)? {
        let context = Unmanaged.passRetained(Signal(changed))
        let path = WindowsFiles.wide(url)
        let handle = path.withUnsafeBufferPointer {
            pacer_watch_directory($0.baseAddress, isDirectory ? 1 : 0, context.toOpaque(), { pointer, flags in
                guard let pointer else { return }
                Unmanaged<Signal>.fromOpaque(pointer).takeUnretainedValue().changed(
                    ActivityFileEvent(requiresDiscovery: flags & 2 != 0, invalidated: flags & 1 != 0))
            }, { pointer in
                if let pointer { Unmanaged<Signal>.fromOpaque(pointer).release() }
            })
        }
        guard let handle else { context.release(); return nil }
        return Watch(handle)
    }
}

extension ActivityLogWatcher {
    convenience init(interval: TimeInterval = 5, maximumDirectoryWatches: Int = 4,
                     changed: @escaping @Sendable (Bool) -> Void) {
        self.init(files: WindowsFileSystem(), events: WindowsActivityLogWatcher(), interval: interval,
            maximumDirectoryWatches: maximumDirectoryWatches, changed: changed)
    }
}
