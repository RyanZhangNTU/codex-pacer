import Foundation

/// Shared process ancestry and PID-reuse checks for both provider adapters.
public enum ProcessOwnership {
    /// Walks up from the holder to the first process `isApplication` accepts:
    /// the terminal, editor or app that embeds the provider and shows the session.
    public static func findOwner(of pid: Int32, currentProcess: Int32, isApplication: (Int32) -> Bool,
                             parent: (Int32) -> Int32?) -> Int32? {
        var current = pid, visited = Set<Int32>()
        for _ in 0..<32 {
            guard current > 1, current != currentProcess, visited.insert(current).inserted else { return nil }
            if isApplication(current) { return current }
            guard let next = parent(current) else { return nil }
            current = next
        }
        return nil
    }

    public static func isDescendant(_ child: ProcessInstance, of ancestor: ProcessInstance,
                                    lookup: (UInt32, UInt64) -> ProcessInstanceRecord?) -> Bool {
        guard child.started != 0, ancestor.started != 0 else { return false }
        var expected = child, visited = Set<ProcessInstance>()
        for _ in 0..<32 {
            guard visited.insert(expected).inserted, let current = lookup(expected.pid, expected.started), current.identity == expected else { return false }
            if expected == ancestor { return lookup(child.pid, child.started)?.identity == child && lookup(ancestor.pid, ancestor.started)?.identity == ancestor }
            guard current.parent != 0, let parent = lookup(current.parent, 0), parent.identity.pid == current.parent,
                  parent.identity.started != 0, parent.identity.started <= current.identity.started else { return false }
            expected = parent.identity
        }
        return false
    }
}

/// A PID alone never identifies a live process instance. Hosts return facts
/// scoped to their current user/session and reject inaccessible processes.
public struct ProcessInstance: Hashable, Sendable {
    public let pid: UInt32
    public let started: UInt64
    public init(pid: UInt32, started: UInt64) { self.pid = pid; self.started = started }
}
public struct ProcessInstanceRecord: Equatable, Sendable {
    public let identity: ProcessInstance
    public let parent: UInt32
    public let executable: URL
    public init(identity: ProcessInstance, parent: UInt32, executable: URL) {
        self.identity = identity; self.parent = parent; self.executable = executable
    }
}
