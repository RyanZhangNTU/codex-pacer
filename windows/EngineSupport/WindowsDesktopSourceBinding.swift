#if os(Windows)
import Foundation
import PacerCore

/// One binding per collector/home. A registered global IPC server alone is
/// insufficient: the selected rollout must be held for writing by that exact
/// process instance or a live descendant, inside the selected physical home.
final class WindowsDesktopSourceBinding {
    struct Proof: Equatable, Sendable {
        let thread: String
        let file: URL
        let writer: WindowsProcessIdentity
        let peer: WindowsProcessIdentity
        let stamp: WindowsSourceFileIdentity
    }
    let home: URL
    let peer: WindowsProcessIdentity
    private let metadata: (String) -> CodexRolloutMetadata?
    private let writers: (URL, URL) -> [WindowsProcessIdentity]?
    private let related: (WindowsProcessIdentity, WindowsProcessIdentity) -> Bool
    init(home: URL, peer: WindowsProcessIdentity, metadata: ((String) -> CodexRolloutMetadata?)? = nil,
         writers: @escaping (URL, URL) -> [WindowsProcessIdentity]? = { WindowsProcessOwnership.writers(of: $0, within: $1) },
         related: @escaping (WindowsProcessIdentity, WindowsProcessIdentity) -> Bool = { WindowsProcessOwnership.isDescendant($0, of: $1) }) {
        self.home = home; self.peer = peer; self.writers = writers; self.related = related
        let lookup = CodexOriginLookup(home: home)
        self.metadata = metadata ?? { lookup.lookup($0) }
    }
    func authorize(_ thread: String) -> Proof? {
        guard let id = UUID(uuidString: thread), home.isFileURL, peer.started != 0,
              let row = metadata(id.uuidString.lowercased()), !row.origin.ignored,
              let stamp = WindowsProcessOwnership.stamp(row.url, within: home),
              let fresh = CodexRolloutMetadata.read(row.url, threadID: id.uuidString.lowercased()),
              fresh.parentThreadID == row.parentThreadID,
              fresh.parentThreadID != nil || fresh.origin == row.origin,
              let holders = writers(row.url, home), let writer = holders.first(where: { related($0, peer) }),
              WindowsProcessOwnership.stamp(row.url, within: home) == stamp,
              metadata(id.uuidString.lowercased())?.origin.ignored == false else { return nil }
        return .init(thread: id.uuidString.lowercased(), file: row.url, writer: writer, peer: peer, stamp: stamp)
    }
    func isCurrent(_ proof: Proof) -> Bool {
        currentMetadata(proof) != nil
    }
    func currentMetadata(_ proof: Proof) -> CodexRolloutMetadata? {
        guard proof.peer == peer, WindowsProcessOwnership.alive(proof.peer), WindowsProcessOwnership.alive(proof.writer),
              WindowsProcessOwnership.stamp(proof.file, within: home) == proof.stamp,
              let row = metadata(proof.thread), !row.origin.ignored,
              WindowsProcessOwnership.stamp(row.url, within: home) == proof.stamp else { return nil }
        return row
    }
}
#endif
