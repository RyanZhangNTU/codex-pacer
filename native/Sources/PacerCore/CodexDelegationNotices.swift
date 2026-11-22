import Foundation

/// Codex for Claude's own notices, besides the Claude task's ending:
/// - a run that fails or times out (on by default), with why;
/// - a run still going after the chosen number of minutes (off by default);
/// - the first run that ever finishes, once, pointing to the Collaboration page.
/// The first look at the ledger is a baseline and announces nothing.
public struct CodexDelegationNoticePolicy: Sendable {
    private var statuses: [String: ClaudeCodexDelegation.Status]?
    private var longRuns: Set<String> = []
    public init() {}

    /// `titles` maps Claude activity IDs to their task titles; `firstRun` is
    /// true when the statistics hold exactly one finished run, this one.
    public mutating func notices(_ runs: [ClaudeCodexDelegation.Run], titles: [String: String], failures: Bool,
                                 longRunMinutes: Int?, firstRunFinished: Bool, at now: Date) -> [IslandNotice] {
        let current = Dictionary(runs.map { ($0.directory.path, $0.status) }, uniquingKeysWith: { _, new in new })
        defer {
            statuses = current
            longRuns = longRuns.intersection(Set(current.keys))
        }
        guard let previous = statuses else { return [] }
        var notices: [IslandNotice] = []
        for run in runs {
            let key = run.directory.path, before = previous[key]
            let title = run.label ?? titles[run.parentID] ?? L10n.text("delegation.mode." + run.mode.rawValue)
            let ended = before == nil || before == .running
            if failures, ended, [.failed, .timedOut].contains(run.status) {
                let reason = run.status == .timedOut ? "timeout" : CodexDelegationStatistics.reasonKey(run.reason)
                notices.append(IslandNotice(id: "delegation:" + key + ":failed", kind: .interrupted, title: L10n.text("delegation.notice.failed"),
                    detail: title + " · " + L10n.text("delegation.reason." + reason)))
            }
            if firstRunFinished, before == .running, run.status == .ok {
                notices.append(IslandNotice(id: "delegation:first", kind: .completed, title: L10n.text("delegation.notice.first"),
                    detail: L10n.text("delegation.notice.first_detail")))
            }
            if let minutes = longRunMinutes, run.status == .running, now.timeIntervalSince(run.created) >= Double(minutes * 60),
               longRuns.insert(key).inserted {
                notices.append(IslandNotice(id: "delegation:" + key + ":long", kind: .interrupted,
                    title: L10n.text("delegation.notice.long", minutes), detail: title))
            }
        }
        return notices
    }
}
