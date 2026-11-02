import Foundation

/// Ownership comes from an open rollout, never from task text, argv or a cwd
/// guess. Zotero's codex-acp app-server kept its rollout open in all 60 idle
/// samples after a synthetic request on macOS (Codex 0.159.3 adapter).
public enum CodexRolloutOwners {
    public static func holders(rollouts: [String: URL], currentProcess: Int32, processes: () -> [Int32],
                               files: (Int32) -> [URL],
                               processStart: (Int32) -> Date?) -> [String: Int32] {
        let paths = Dictionary(rollouts.filter { $0.value.isFileURL }.map {
            ($0.value.standardizedFileURL.resolvingSymlinksInPath().path, $0.key)
        }, uniquingKeysWith: { first, _ in first })
        guard !paths.isEmpty else { return [:] }
        var result: [String: Int32] = [:]
        for pid in processes().prefix(2048) where pid > 1 && pid != currentProcess {
            guard let started = processStart(pid) else { continue }
            let matching = files(pid).prefix(4096).compactMap { paths[$0.standardizedFileURL.path] }
            guard processStart(pid) == started else { continue }
            for session in matching where result[session] == nil { result[session] = pid }
            if result.count == paths.count { break }
        }
        return result
    }
    public static func holders(sessions: Set<String>, home: URL, currentProcess: Int32,
                               processes: () -> [Int32], files: (Int32) -> [URL],
                               processStart: (Int32) -> Date?) -> [String: Int32] {
        let lookup = CodexOriginLookup(home: home)
        let paths = Dictionary(sessions.compactMap { session -> (String, URL)? in
            guard let record = lookup.lookup(session), record.origin.embedded, !record.origin.ignored else { return nil }
            return (session, record.url)
        }, uniquingKeysWith: { first, _ in first })
        return holders(rollouts: paths, currentProcess: currentProcess, processes: processes, files: files, processStart: processStart)
    }
}
