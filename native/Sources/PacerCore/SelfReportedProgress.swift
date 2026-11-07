import Foundation

/// A completion estimate the agent wrote at the start of one of its messages,
/// e.g. `⟦62%⟧`. It belongs to one turn; a new turn starts without one.
public struct SelfReportedProgress: Equatable, Sendable {
    public let percent: Int
    public let reportedAt: Date
    public let turnID: String
    public init?(percent: Int, reportedAt: Date, turnID: String) {
        guard (0...100).contains(percent) else { return nil }
        self.percent = percent; self.reportedAt = reportedAt; self.turnID = turnID
    }
}

/// Reads the marker from the first characters of a message. Only the leading
/// marker is examined; no other text is kept.
public enum ProgressMarker {
    /// Bytes of a JSON string literal examined for the marker, enough for a
    /// few leading spaces and an escaped `⟦100%⟧`.
    static let prefixBytes = 48
    public static func percent(leading text: String) -> Int? {
        let open: Unicode.Scalar = "\u{27E6}", close: Unicode.Scalar = "\u{27E7}", sign: Unicode.Scalar = "%", space: Unicode.Scalar = " "
        var scalars = text.unicodeScalars.prefix(64).drop { CharacterSet.whitespacesAndNewlines.contains($0) }
        guard scalars.first == open else { return nil }
        scalars = scalars.dropFirst().drop { $0 == space }
        let digits = scalars.prefix { $0.value >= 48 && $0.value <= 57 }
        guard (1...3).contains(digits.count), let value = Int(String(String.UnicodeScalarView(digits))), value <= 100 else { return nil }
        scalars = scalars.dropFirst(digits.count).drop { $0 == space }
        guard scalars.first == sign else { return nil }
        scalars = scalars.dropFirst().drop { $0 == space }
        return scalars.first == close ? value : nil
    }
}

/// The ring a task row draws around its status icon while the user has the
/// progress ring switched on for that task's provider.
public struct TaskProgressRing: Equatable, Sendable {
    public enum State: String, Sendable { case pending, reported }
    /// Where the request is in its lifecycle; it sets the ring's style.
    public enum Mode: String, Sendable {
        /// Working: the only mode whose number moves and whose ring can fade.
        case working
        /// One tool has run for `longStepInterval`, e.g. a build or a test run.
        case longStep
        /// Waiting for the user: an approval, a question or a plan.
        case attention
        /// The turn stopped for background work that will wake the request.
        case waiting
        /// A verified Codex goal is paused or limited between attempts.
        case paused
        /// The turn ended normally with no background work left: the request
        /// is done, so the ring is full whatever the last estimate was.
        case done
        case interrupted, failed
    }
    /// Without a new estimate for this long, a working task's ring fades.
    public static let staleInterval: TimeInterval = 120
    /// A tool still running after this long makes a long step.
    public static let longStepInterval: TimeInterval = 30
    public let state: State
    public let mode: Mode
    /// 0...1; zero while pending.
    public let fraction: Double
    public let percent: Int?
    public let stale: Bool
    public let reportedAt: Date?
    /// The request runs in a Claude cloud Project, where Pacer's plugin cannot
    /// run: it never reports, so its ring stays dashed until it ends.
    public private(set) var cloud = false

    /// An active request without an estimate shows the dashed ring. A normal
    /// ending fills it: a turn paused for background work keeps running, so a
    /// completed turn means the request is done. An interrupted or failed one
    /// keeps its last estimate, and shows no ring without one. A cloud run is
    /// known only by its status until it ends, so it needs no turn ID to run.
    public static func make(_ activity: SessionActivity, phase: ActivityPhase, enabled: Bool, at now: Date,
                            hasAttention: Bool = false, waitingForDependents: Bool = false) -> Self? {
        let cloud = activity.provider == .claude && activity.sourceHostID == ClaudeCloudProjectState.sourceID
        let codex = activity.provider == .codex
        guard enabled, activity.turnID != nil || (cloud || codex && activity.hasLiveEvidence) && [.running, .waitingForInput].contains(phase) else { return nil }
        let progress = cloud ? nil : activity.currentProgress, mode: Mode
        switch phase {
        case .running, .waitingForInput:
            if (codex || activity.provider == .deepseek) && (hasAttention || phase == .waitingForInput) { mode = .attention }
            else if codex && activity.codexGoalPause != nil { mode = .paused }
            else if activity.currentBackgroundWait != nil || codex && waitingForDependents { mode = .waiting }
            else if phase == .waitingForInput { mode = .attention }
            else if let since = activity.toolWaitStartedAt, now.timeIntervalSince(since) >= longStepInterval { mode = .longStep }
            else { mode = .working }
        case .completed:
            return .init(state: .reported, mode: .done, fraction: 1, percent: 100, stale: false, reportedAt: progress?.reportedAt)
        case .interrupted: mode = activity.turnFailed ? .failed : .interrupted
        default: return nil
        }
        if let progress {
            let stale = mode == .working && now.timeIntervalSince(progress.reportedAt) > staleInterval
            return .init(state: .reported, mode: mode, fraction: Double(progress.percent) / 100, percent: progress.percent,
                stale: stale, reportedAt: progress.reportedAt)
        }
        guard [.working, .longStep, .attention, .waiting, .paused].contains(mode) else { return nil }
        return .init(state: .pending, mode: mode, fraction: 0, percent: nil, stale: false, reportedAt: nil, cloud: cloud)
    }

    public var accessibilityText: String {
        guard let percent else {
            return L10n.text(cloud ? "activity.progress_cloud" : mode == .waiting ? "activity.progress_waiting_pending" :
                mode == .paused ? "activity.progress_paused_pending" : "activity.progress_pending")
        }
        switch mode {
        case .working: return L10n.text("activity.progress_reported", percent)
        case .longStep: return L10n.text("activity.progress_long_step", percent)
        case .attention: return L10n.text("activity.progress_attention", percent)
        case .waiting: return L10n.text("activity.progress_waiting", percent)
        case .paused: return L10n.text("activity.progress_paused", percent)
        case .done: return L10n.text("activity.progress_done")
        case .interrupted: return L10n.text("activity.progress_interrupted", percent)
        case .failed: return L10n.text("activity.progress_failed", percent)
        }
    }
}

/// Pacer's switch for the injected progress line: the hook adapter adds it
/// while `pacer/progress-ring` exists in the Claude home.
public enum ClaudeProgressRingSwitch {
    public static func flagURL(home: URL) -> URL { home.appendingPathComponent("pacer/progress-ring") }

    /// Writes nothing until Pacer's hook folder exists, and never follows a
    /// symbolic link. Returns whether the file now matches `enabled`.
    @discardableResult
    public static func apply(enabled: Bool, home: URL, fileManager: FileManager = .default) -> Bool {
        let folder = home.appendingPathComponent("pacer"), flag = flagURL(home: home)
        if !enabled {
            guard (try? fileManager.attributesOfItem(atPath: flag.path)) != nil else { return true }
            return (try? fileManager.removeItem(at: flag)) != nil
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: folder.path),
              attributes[.type] as? FileAttributeType == .typeDirectory else { return false }
        if let existing = try? fileManager.attributesOfItem(atPath: flag.path) {
            guard existing[.type] as? FileAttributeType == .typeRegular else { return false }
            // A switch from before Pacer's plugin asked for leading markers; it now asks for the tool.
            if fileManager.contents(atPath: flag.path) == Data("on\n".utf8) {
                return (try? Data(enabledContents.utf8).write(to: flag, options: .atomic)) != nil
            }
            return true
        }
        return fileManager.createFile(atPath: flag.path, contents: Data(enabledContents.utf8))
    }
    /// Estimates come through Pacer's plugin tool; other modes are written by hand.
    static let enabledContents = "tool\n"
}
