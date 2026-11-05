import Foundation

/// Hosted CI runners are much slower than a desktop, and their timers are
/// coarse. A wait for something to happen costs time only when it never
/// happens, so these waits share one generous limit. A wait that bounds how
/// long something may take keeps its own limit.
enum TestWait {
    static let limit: TimeInterval = 20

    /// Polls until `condition` holds or the limit passes, and returns the last result.
    /// It runs on the caller's actor, so a condition that holds is still true
    /// on the caller's next line: no other work on that actor runs in between.
    @discardableResult
    static func until(isolation: isolated (any Actor)? = #isolation,
                      _ condition: () async throws -> Bool) async throws -> Bool {
        let end = ProcessInfo.processInfo.systemUptime + limit
        while true {
            if try await condition() { return true }
            if ProcessInfo.processInfo.systemUptime >= end { return false }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
