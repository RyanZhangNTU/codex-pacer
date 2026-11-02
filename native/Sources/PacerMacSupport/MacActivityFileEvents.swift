import Darwin
import Foundation
import PacerCore

public struct MacActivityFileEvents: ActivityFileEvents {
    public init() {}
    public func watch(_ url: URL, isDirectory: Bool,
                      changed: @escaping @Sendable (ActivityFileEvent) -> Void) -> (any ActivityFileWatch)? {
        MacActivityFileWatch(url, isDirectory: isDirectory, changed: changed)
    }
}

private final class MacActivityFileWatch: ActivityFileWatch, @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject
    init?(_ url: URL, isDirectory: Bool, changed: @escaping @Sendable (ActivityFileEvent) -> Void) {
        let fd = Darwin.open(url.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
            queue: DispatchQueue(label: "pacer.file-events", qos: .utility))
        self.source = source
        source.setCancelHandler { Darwin.close(fd) }
        source.setEventHandler { [weak source] in
            guard let source else { return }
            changed(ActivityFileEvent(requiresDiscovery: isDirectory, invalidated: !source.data.intersection([.rename, .delete]).isEmpty))
        }
        source.resume()
    }
    func stop() { source.cancel() }
    deinit { source.cancel() }
}

extension ActivityLogWatcher {
    public convenience init(interval: TimeInterval = 5, maximumDirectoryWatches: Int = 4,
                            changed: @escaping @Sendable (Bool) -> Void) {
        self.init(files: MacFileSystem(), events: MacActivityFileEvents(), interval: interval,
            maximumDirectoryWatches: maximumDirectoryWatches, changed: changed)
    }
}
