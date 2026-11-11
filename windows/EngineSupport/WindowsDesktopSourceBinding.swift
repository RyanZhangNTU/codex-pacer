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
    private let alive: (WindowsProcessIdentity) -> Bool
    private let stamp: (URL, URL) -> WindowsSourceFileIdentity?
    init(home: URL, peer: WindowsProcessIdentity, metadata: ((String) -> CodexRolloutMetadata?)? = nil,
         writers: @escaping (URL, URL) -> [WindowsProcessIdentity]? = { WindowsProcessOwnership.writers(of: $0, within: $1) },
         related: @escaping (WindowsProcessIdentity, WindowsProcessIdentity) -> Bool = { WindowsProcessOwnership.isDescendant($0, of: $1) },
         alive: @escaping (WindowsProcessIdentity) -> Bool = WindowsProcessOwnership.alive,
         stamp: @escaping (URL, URL) -> WindowsSourceFileIdentity? = WindowsProcessOwnership.stamp(_:within:)) {
        self.home = home; self.peer = peer; self.writers = writers; self.related = related
        self.alive = alive; self.stamp = stamp
        let lookup = CodexOriginLookup(home: home)
        self.metadata = metadata ?? { lookup.lookup($0) }
    }
    func authorize(_ thread: String) -> Proof? {
        guard let id = UUID(uuidString: thread), home.isFileURL, peer.started != 0,
              let row = metadata(id.uuidString.lowercased()), !row.origin.ignored,
              let stamp = stamp(row.url, home),
              let fresh = CodexRolloutMetadata.read(row.url, threadID: id.uuidString.lowercased()),
              fresh.parentThreadID == row.parentThreadID,
              fresh.parentThreadID != nil || fresh.origin == row.origin,
              let holders = writers(row.url, home), let writer = holders.first(where: { related($0, peer) }),
              self.stamp(row.url, home) == stamp,
              metadata(id.uuidString.lowercased())?.origin.ignored == false else { return nil }
        return .init(thread: id.uuidString.lowercased(), file: row.url, writer: writer, peer: peer, stamp: stamp)
    }
    func isCurrent(_ proof: Proof) -> Bool {
        currentMetadata(proof) != nil
    }
    func currentMetadata(_ proof: Proof) -> CodexRolloutMetadata? {
        var pass = Validation()
        return currentMetadata(proof, pass: &pass)
    }

    /// Facts are shared only within one synchronous validation pass.
    func allCurrent(_ proofs: some Sequence<Proof>) -> Bool {
        var pass = Validation()
        return proofs.allSatisfy { currentMetadata($0, pass: &pass) != nil }
    }

    private struct Validation {
        var live: Set<WindowsProcessIdentity> = []
        var stamps: [[UInt16]: WindowsSourceFileIdentity] = [:]
    }

    private func currentMetadata(_ proof: Proof, pass: inout Validation) -> CodexRolloutMetadata? {
        guard proof.peer == peer else { return nil }
        for process in [proof.peer, proof.writer] where !pass.live.contains(process) {
            guard alive(process) else { return nil }
            pass.live.insert(process)
        }
        guard let row = metadata(proof.thread), !row.origin.ignored else { return nil }
        for file in [proof.file, row.url] {
            guard file.isFileURL else { return nil }
            // Use exact UTF-16 names. A case-sensitive directory can contain both paths.
            let path = Array(WindowsCodexExecutableDiscovery.path(file.standardizedFileURL).utf16)
            guard let observed = pass.stamps[path] ?? stamp(file, home), observed == proof.stamp else { return nil }
            pass.stamps[path] = observed
        }
        return row
    }
}
#endif
