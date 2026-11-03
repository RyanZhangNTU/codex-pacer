#if os(Windows)
import Foundation
import PacerCore

/// Emergency engine-exit cleanup cannot wait for a monitor or pipe consumer.
enum WindowsOwnedProcesses {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var exiting = false
        var actions: [UUID: @Sendable () -> Void] = [:]
    }
    private static let state = State()
    static var isExiting: Bool { state.lock.lock(); defer { state.lock.unlock() }; return state.exiting }
    static func register(_ id: UUID, terminate: @escaping @Sendable () -> Void) {
        state.lock.lock()
        let exiting = state.exiting
        if !exiting { state.actions[id] = terminate }
        state.lock.unlock()
        if exiting { terminate() }
    }
    static func remove(_ id: UUID) { state.lock.lock(); state.actions[id] = nil; state.lock.unlock() }
    static func terminateForEngineExit() {
        state.lock.lock(); state.exiting = true
        let actions = Array(state.actions.values)
        state.lock.unlock()
        actions.forEach { $0() }
    }
}
#endif
