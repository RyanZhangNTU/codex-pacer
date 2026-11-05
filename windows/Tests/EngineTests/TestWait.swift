import Foundation

/// Hosted CI runners are much slower than a desktop, and their timers are
/// coarse. A wait for something to happen costs time only when it never
/// happens, so these waits share one generous limit. A wait that bounds how
/// long something may take keeps its own limit.
enum TestWait {
    static let limit: TimeInterval = 20

    /// Polls until `condition` holds or the limit passes, and returns the last result.
    @discardableResult
    static func until(_ condition: () async throws -> Bool) async throws -> Bool {
        let end = ProcessInfo.processInfo.systemUptime + limit
        while true {
            if try await condition() { return true }
            if ProcessInfo.processInfo.systemUptime >= end { return false }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// The synchronous form, for a child process that must exit.
    static func whileRunning(_ process: Process) {
        let end = ProcessInfo.processInfo.systemUptime + limit
        while process.isRunning, ProcessInfo.processInfo.systemUptime < end { Thread.sleep(forTimeInterval: 0.01) }
    }
}
