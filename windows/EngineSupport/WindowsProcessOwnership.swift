#if os(Windows)
import Foundation
import CWindowsSupport

struct WindowsProcessIdentity: Hashable, Sendable {
    let pid: UInt32
    let started: UInt64
}
struct WindowsProcessRecord: Equatable, Sendable {
    let identity: WindowsProcessIdentity
    let parent: UInt32
    let executable: URL
}
struct WindowsSourceFileIdentity: Equatable, Sendable {
    let fileVolume: UInt64, fileLow: UInt64, fileHigh: UInt64
    let rootVolume: UInt64, rootLow: UInt64, rootHigh: UInt64
}
enum WindowsProcessOwnership {
    typealias Lookup = (UInt32, UInt64) -> WindowsProcessRecord?
    static func inspect(_ pid: UInt32, started: UInt64 = 0) -> WindowsProcessRecord? {
        var identity = pacer_process_identity(), image = [UInt16](repeating: 0, count: 32768)
        guard pacer_process_details(pid, started, &identity, &image, image.count) != 0 else { return nil }
        let path = String(decoding: image.prefix { $0 != 0 }, as: UTF16.self)
        guard identity.pid == pid, identity.started != 0, WindowsCodexExecutableDiscovery.absolute(path) else { return nil }
        return .init(identity: .init(pid: pid, started: identity.started), parent: identity.parent, executable: URL(fileURLWithPath: path))
    }
    static func alive(_ identity: WindowsProcessIdentity) -> Bool { pacer_process_alive(identity.pid, identity.started) != 0 }
    static func stamp(_ file: URL, within home: URL) -> WindowsSourceFileIdentity? {
        guard file.isFileURL, home.isFileURL else { return nil }
        let path = WindowsCodexExecutableDiscovery.path(file.standardizedFileURL), root = WindowsCodexExecutableDiscovery.path(home.standardizedFileURL)
        guard [path, root].allSatisfy({ $0.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil && $0.utf16.count < 32768
            && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else { return nil }
        var value = pacer_source_file_identity()
        guard pacer_source_file_stamp(Array(root.utf16) + [0], Array(path.utf16) + [0], &value) != 0 else { return nil }
        return .init(fileVolume: value.file_volume, fileLow: value.file_low, fileHigh: value.file_high,
                     rootVolume: value.root_volume, rootLow: value.root_low, rootHigh: value.root_high)
    }
    /// Both endpoints must still denote the original process instances. A
    /// reused parent PID cannot make an unrelated writer a child of Desktop.
    static func isDescendant(_ child: WindowsProcessIdentity, of ancestor: WindowsProcessIdentity,
                             lookup: Lookup = { inspect($0, started: $1) }) -> Bool {
        guard child.started != 0, ancestor.started != 0 else { return false }
        var expected = child, visited = Set<WindowsProcessIdentity>()
        for _ in 0..<32 {
            guard visited.insert(expected).inserted, let current = lookup(expected.pid, expected.started), current.identity == expected else { return false }
            if expected == ancestor { return lookup(child.pid, child.started)?.identity == child && lookup(ancestor.pid, ancestor.started)?.identity == ancestor }
            guard current.parent != 0, let parent = lookup(current.parent, 0), parent.identity.pid == current.parent,
                  parent.identity.started != 0, parent.identity.started <= current.identity.started else { return false }
            expected = parent.identity
        }
        return false
    }
    /// Reads file IDs, process identities and granted handle access. Never
    /// reads file content, command lines, environment variables or memory pages.
    static func writers(of file: URL, within home: URL? = nil) -> [WindowsProcessIdentity]? {
        guard file.isFileURL else { return nil }
        let path = WindowsCodexExecutableDiscovery.path(file.standardizedFileURL)
        guard path.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil, path.utf16.count < 32768,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        var values = [pacer_process_identity](repeating: .init(), count: 64)
        let count: Int32
        if let home {
            guard home.isFileURL else { return nil }
            let root = WindowsCodexExecutableDiscovery.path(home.standardizedFileURL)
            guard root.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil, root.utf16.count < 32768,
                  !root.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            count = pacer_scoped_file_writers(Array(root.utf16) + [0], Array(path.utf16) + [0], &values, values.count)
        } else { count = pacer_file_writers(Array(path.utf16) + [0], &values, values.count) }
        guard count >= 0, count <= values.count else { return nil }
        return Array(Set(values.prefix(Int(count)).filter { $0.pid != 0 && $0.started != 0 }
            .map { WindowsProcessIdentity(pid: $0.pid, started: $0.started) })).sorted { $0.pid < $1.pid }
    }
}
#endif
