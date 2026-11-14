import Foundation

/// Claude and DeepSeek snapshots and the presentation clock skip their own
/// projection while a collect runs, because the collect replaces that state.
/// The collect then has to publish for them, even when it would otherwise hold
/// Codex metrics for the collapsed batch. A snapshot that arrives after the
/// collect read the local sources would be replaced by the older copy, so it
/// needs one more collect that publishes at once.
struct EngineCollectHandoff {
    private var localSnapshotsRead = false
    private var publicationPending = false

    mutating func readLocalSnapshots() { localSnapshotsRead = true }
    mutating func endCollect() { localSnapshotsRead = false }

    /// Records a projection skipped during a collect. Returns true when the
    /// running collect already holds an older local snapshot and must run again.
    mutating func skippedProjection(localSnapshot: Bool) -> Bool {
        if localSnapshot, localSnapshotsRead { return true }
        publicationPending = true
        return false
    }

    /// Whether the collect must publish now. Clears the handed-over projection.
    mutating func takePublication() -> Bool {
        defer { publicationPending = false }
        return publicationPending
    }
}
