import Foundation

/// Each provider owns its work, while sharing scan cancellation and caching.
@MainActor
final class HostApplicationTracking {
    var attempts: Set<String> = []
    var scannedAt = Date.distantPast
    var scan: Task<Void, Never>?
    var scanID: UUID?
    var retry: Task<Void, Never>?
    func cancel() {
        scan?.cancel(); scan = nil; scanID = nil
        retry?.cancel(); retry = nil
        attempts = []; scannedAt = .distantPast
    }
}
