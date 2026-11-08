import Foundation

/// One polling pass. A project missing from `threads` was not read this time,
/// so its earlier state stands.
public struct ClaudeCloudSnapshot: Sendable {
    public var projects: [ClaudeCloudProject]
    public var threads: [String: [ClaudeCloudThread]]
    public var sessions: [String: ClaudeCloudSession]
    /// Cloud IDs of sessions Claude Desktop runs on this Mac, which the local reader already follows.
    public var localSessionIDs: Set<String>
    public init(projects: [ClaudeCloudProject], threads: [String: [ClaudeCloudThread]], sessions: [String: ClaudeCloudSession] = [:],
                localSessionIDs: Set<String> = []) {
        self.projects = projects; self.threads = threads; self.sessions = sessions; self.localSessionIDs = localSessionIDs
    }
}

/// Turns polled project state into the shared activity model. A thread row reads
/// idle within seconds of a run starting, so while it runs only the bound session
/// can say so. Polls can also miss a short run, so an ending is recognized from a
/// newer reply too. Only what a poll shows decides a state: no live stage, and an
/// ending cannot say more than the thread's status and its turn's numbers. A
/// stream adds only an estimated speed while a thread writes.
public struct ClaudeCloudProjectState: Sendable {
    public static let sourceID = "claude-cloud"
    /// `has_unread` turns on some time after an ending, so an ending that stays
    /// read past this was read as it happened.
    static let readGrace: TimeInterval = 90
    /// `idle` can come just before `resolved` for the same run.
    static let settlingTime: TimeInterval = 300
    private static let baselineAge: TimeInterval = 7 * 24 * 3600
    private static let maximumSettledQuestions = 1024
    /// A late first look can find a new question, but a long absence cannot make an old reply new.
    private static let freshQuestionAge: TimeInterval = 180
    private static let questionPollOverlap: TimeInterval = 60
    /// A notice needs a recent ending; a late look reports when it was noticed.
    private static let exactEndingAge: TimeInterval = 45
    /// Sessions cost a request each, so only a thread this recent gets one for moving.
    private static let recentThreadAge: TimeInterval = 24 * 3600
    /// Answering an idle thread moves nothing on its row until the first reply.
    private static let idleRecheckInterval: TimeInterval = 120
    /// The summary that words an ending arrives seconds after the turn stops.
    private static let summaryWait: TimeInterval = 60
    /// How long confirmed work stands when its session cannot be read.
    private static let unconfirmedWorkTime: TimeInterval = 300
    /// A coordinator reports on a thread right after it ends, and a poll can see the two either way round.
    private static let threadReportWindow: TimeInterval = 120
    private static let delegationWindow: TimeInterval = 60
    /// A turn's result can land after its thread reads as ended.
    private static let resultAttempts = 3
    /// Server time against the local clock that dated the run's start.
    private static let serverClockMargin: TimeInterval = 30

    private struct PlainQuestion: Sendable {
        let detectedAt: Date
        var evidenceAt: Date
        var sawUnread: Bool
    }
    private struct SettledQuestion: Sendable {
        let through: Date
        let settledAt: Date
    }
    private struct Tracked: Sendable {
        let projectID: String
        var activity: SessionActivity?
        var mark: Date?
        var lastEndKey: String?
        var sawUnread = false
        var lastUnread: Bool?
        var request: PendingAttentionRequest?
        var signature: String?
        var sessionReadAt: Date?
        var confirmedAt: Date?
        var observedRun = false
        var awaitsReply = false
        var plainQuestion: PlainQuestion?
        /// The session whose result would date and time the ending shown.
        var resultSession: String?
        var resultLooks = 0
        var lastResultID: String?
        var replyMeter = ClaudeCloudReplyMeter()
    }
    private var tracked: [String: Tracked] = [:]
    /// Kept even if the thread falls off the current page. The monitor resets this with its account scope.
    private var settledQuestions: [String: SettledQuestion] = [:]
    private var projectMarks: [String: Date] = [:]
    private var lastPass: Date?
    private var sessionReadAttempts: [String: UInt64] = [:]
    private var nextReadAttempt: UInt64 = 0

    public init() {}

    public var activities: [SessionActivity] { tracked.values.compactMap(\.activity) }
    public var attention: [PendingAttentionRequest] { tracked.values.compactMap(\.request) }
    private func isOpen(_ activity: SessionActivity?) -> Bool { activity.map { [.running, .waitingForInput].contains($0.phase) } ?? false }
    public var hasRunningWork: Bool { tracked.values.contains { $0.activity?.phase == .running } }
    public var hasOpenWork: Bool { tracked.values.contains { isOpen($0.activity) } }
    public var openWorkCount: Int { tracked.values.filter { isOpen($0.activity) }.count }
    public func hasOpenWork(inProject id: String) -> Bool {
        tracked.values.contains { isOpen($0.activity) && $0.projectID == id }
    }
    func isRunning(thread id: String) -> Bool { tracked[id]?.activity?.phase == .running }
    /// The threads worth a stream, most recently started first.
    var runningThreads: [(project: String, thread: String)] {
        let running = tracked.compactMap { id, entry -> (id: String, project: String, started: Date)? in
            guard let activity = entry.activity, activity.phase == .running, let context = activity.claudeCloud, context.role == .thread else { return nil }
            return (id, context.projectID, activity.phaseChangedAt ?? .distantPast)
        }
        return running.sorted { $0.started > $1.started }.map { (project: $0.project, thread: $0.id) }
    }

    /// Returns whether the row's speed changed. A coordinator's replies are too
    /// short to measure, and a waiting or ended thread is not writing.
    @discardableResult
    mutating func applyReplyProgress(thread id: String, block: String, tokens: Double, sentAt: Date?, at now: Date) -> Bool {
        guard var entry = tracked[id], var activity = entry.activity, activity.phase == .running, activity.claudeCloud?.role == .thread else { return false }
        entry.replyMeter.observe(block: block, tokens: tokens, at: sentAt ?? now)
        defer { tracked[id] = entry }
        guard let rate = entry.replyMeter.tokensPerSecond else { return false }
        activity.setCloudReplyRate(OutputEstimate(value: rate, reportedAt: now, isFresh: true))
        entry.activity = activity
        return true
    }

    /// Sessions worth a request in this pass: a run in progress, a thread that
    /// waits or just moved, an idle thread that may have been answered, the first
    /// look at each coordinator, and one that may be working because its project
    /// just changed or whose ending may have been read.
    public mutating func sessionsToRead(projects: [ClaudeCloudProject], threads: [String: [ClaudeCloudThread]], at now: Date,
                               local: Set<String> = [], limit: Int = 16, hintedThreads: Set<String> = []) -> [String] {
        var hinted: [String] = [], urgent: [String] = [], coordinators: [String] = [], later: [String] = []
        for project in projects {
            for thread in threads[project.id] ?? [] where thread.status != .archived && !isLocal(thread, local) {
                let entry = tracked[thread.id]
                let firstLook = entry == nil && thread.status == .needsInput
                if hintedThreads.contains(thread.id) {
                    hinted += thread.sessionIDs
                } else if isOpen(entry?.activity) || entry?.activity?.phase == .unknown || thread.isActive || thread.openDecisions > 0 || firstLook {
                    urgent += thread.sessionIDs
                } else if isRecent(thread, at: now), entry?.signature != thread.signature || wantsAnotherLook(entry, thread, at: now) {
                    later += thread.sessionIDs
                }
            }
            guard let coordinator = project.coordinatorSessionID else { continue }
            let changed = project.lastActivityAt != projectMarks[project.id]
            let recent = project.lastActivityAt.map { now.timeIntervalSince($0) < 600 } ?? false
            let activity = tracked[coordinator]?.activity
            let unreadEnding = activity.map { [.completed, .interrupted].contains($0.phase) && $0.claudeCloud?.readInClaude != true } ?? false
            if isOpen(activity) { urgent.append(coordinator) }
            else if lastPass == nil || changed || recent || unreadEnding { coordinators.append(coordinator) }
        }
        var seen = Set<String>()
        let candidates = (hinted + urgent + coordinators + later).filter { seen.insert($0).inserted }
        // Priority breaks ties, but a recently read session cannot permanently
        // occupy a slot ahead of work that the bounded pass has not checked.
        let ordered = candidates.enumerated().sorted {
            let left = sessionReadAttempts[$0.element] ?? 0, right = sessionReadAttempts[$1.element] ?? 0
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
        // A few stream hints can bypass the idle interval without taking every slot.
        let budget = max(0, limit), hintedIDs = Set(hinted)
        let preferred = Array(ordered.lazy.filter { hintedIDs.contains($0) }.prefix(min(budget, 4)))
        let preferredIDs = Set(preferred)
        let selected = preferred + ordered.lazy.filter { !preferredIDs.contains($0) }.prefix(budget - preferred.count)
        sessionReadAttempts = sessionReadAttempts.filter { seen.contains($0.key) }
        for id in selected { nextReadAttempt &+= 1; sessionReadAttempts[id] = nextReadAttempt }
        return selected
    }

    /// Endings still without a speed, the ones that can still remind first.
    public func turnResultsToRead(limit: Int = 4) -> [(thread: String, session: String)] {
        let waiting = tracked.compactMap { key, entry -> (key: String, session: String, activity: SessionActivity)? in
            guard let session = entry.resultSession, let activity = entry.activity else { return nil }
            return (key, session, activity)
        }
        return waiting.sorted {
            if $0.activity.isHistoricalCompletion != $1.activity.isHistoricalCompletion { return $1.activity.isHistoricalCompletion }
            return ($0.activity.phaseChangedAt ?? .distantPast) > ($1.activity.phaseChangedAt ?? .distantPast)
        }.prefix(limit).map { (thread: $0.key, session: $0.session) }
    }

    /// Without a result for this turn, the next pass looks again a few times.
    public mutating func applyTurnResult(_ result: ClaudeCloudTurnResult?, thread id: String, at now: Date) {
        guard var entry = tracked[id], entry.resultSession != nil, var activity = entry.activity, let turn = activity.turnID else { return }
        defer { tracked[id] = entry }
        guard let result, result.id != entry.lastResultID, let started = activity.turnStartedAt,
              result.completedAt >= started.addingTimeInterval(-Self.serverClockMargin) else {
            entry.resultLooks += 1
            if entry.resultLooks >= Self.resultAttempts { entry.resultSession = nil }
            return
        }
        let end = min(result.completedAt, now)
        let sample = ResponsePerformance(responseID: result.id, turnID: turn, outputTokens: result.outputTokens,
            startedAt: end.addingTimeInterval(-result.streaming), completedAt: end, source: .requestUsage)
        SessionPerformanceUpdate(id: activity.canonicalized().id, turnID: turn, response: sample, firstTokenLatency: result.firstOutput,
            firstTokenReportedAt: nil)?.apply(to: &activity)
        entry.activity = activity; entry.lastResultID = result.id; entry.resultSession = nil
    }

    private func isLocal(_ thread: ClaudeCloudThread, _ local: Set<String>) -> Bool {
        !thread.sessionIDs.isEmpty && thread.sessionIDs.allSatisfy { local.contains(Self.bareID($0)) }
    }
    private func isRecent(_ thread: ClaudeCloudThread, at now: Date) -> Bool {
        (thread.lastReplyAt ?? thread.createdAt).map { now.timeIntervalSince($0) < Self.recentThreadAge } ?? false
    }
    private func wantsAnotherLook(_ entry: Tracked?, _ thread: ClaudeCloudThread, at now: Date) -> Bool {
        guard thread.status == .idle || thread.status == .needsInput else { return false }
        if let ended = entry?.activity?.phaseChangedAt, entry?.activity?.phase == .completed, now.timeIntervalSince(ended) < Self.summaryWait { return true }
        return now.timeIntervalSince(entry?.sessionReadAt ?? .distantPast) >= Self.idleRecheckInterval
    }

    public mutating func apply(_ snapshot: ClaudeCloudSnapshot, at now: Date) {
        settledQuestions = settledQuestions.filter { now.timeIntervalSince($0.value.settledAt) < Self.baselineAge }
        var seen = Set<String>()
        for project in snapshot.projects {
            projectMarks[project.id] = project.lastActivityAt
            let threads = snapshot.threads[project.id]
            if let threads {
                for thread in threads {
                    // A session Desktop runs here is already a local task, with its speed.
                    if isLocal(thread, snapshot.localSessionIDs) || thread.status == .archived { continue }
                    seen.insert(thread.id)
                    applyThread(thread, project: project, sessions: thread.sessionIDs.compactMap { snapshot.sessions[$0] }, at: now)
                }
            } else {
                seen.formUnion(tracked.keys.filter { tracked[$0]?.projectID == project.id })
            }
            // After the threads, because what they did decides whether its turn is news.
            if let coordinator = project.coordinatorSessionID {
                seen.insert(coordinator)
                applyCoordinator(coordinator, project: project, session: snapshot.sessions[coordinator], threads: threads, at: now)
            }
        }
        tracked = tracked.filter { seen.contains($0.key) }
        projectMarks = projectMarks.filter { mark in snapshot.projects.contains { $0.id == mark.key } }
        lastPass = now
    }

    /// Reading failed for a while: what was running can no longer be vouched for.
    public mutating func markUnavailable() {
        for key in tracked.keys where isOpen(tracked[key]?.activity) {
            tracked[key]?.activity?.markSourceUnavailable(); tracked[key]?.request = nil
        }
    }

    static func bareID(_ id: String) -> String {
        id.replacingOccurrences(of: #"^(?:cse|session)_"#, with: "", options: .regularExpression)
    }

    private mutating func applyThread(_ thread: ClaudeCloudThread, project: ClaudeCloudProject, sessions: [ClaudeCloudSession], at now: Date) {
        var entry = tracked[thread.id] ?? Tracked(projectID: project.id)
        let isNew = tracked[thread.id] == nil
        let pending = sessions.lazy.compactMap(\.pending).first
        let attention: PendingAttentionRequest.Kind? = thread.openDecisions > 0 ? .decision : pending
        let failed = thread.status == .failed
        let confirmed = thread.isActive || sessions.contains(where: \.isRunning)
        if confirmed {
            entry.observedRun = true
            settledQuestions[thread.id] = nil
        }
        // A partial read cannot replace the last known run or explicit request.
        let missingSession = !thread.sessionIDs.allSatisfy { id in sessions.contains { $0.id == id } }
        let idleWork = thread.status == .idle && (isOpen(entry.activity) || entry.activity?.phase == .unknown)
        let sessionWait = entry.request.map { $0.kind != .decision } == true && entry.plainQuestion == nil
        let unconfirmed = missingSession && (idleWork || (thread.status == .needsInput && sessionWait))
        if !sessions.isEmpty { entry.sessionReadAt = now; entry.signature = thread.signature }
        else if !isRecent(thread, at: now) { entry.signature = thread.signature }
        if thread.status != .idle { entry.awaitsReply = false }
        else if !sessions.isEmpty { entry.awaitsReply = sessions.contains(where: \.awaitsReply) }
        let endKey = entry.lastEndKey

        if confirmed || attention != nil {
            if entry.plainQuestion != nil { entry.request = nil }
            entry.plainQuestion = nil; entry.confirmedAt = now
            open(&entry, id: thread.id, project: project, role: .thread, attention: attention, at: now)
        } else if unconfirmed {
            // The thread can clear a decision even while its sessions are unavailable.
            if entry.request?.kind == .decision || now.timeIntervalSince(entry.confirmedAt ?? .distantPast) >= Self.unconfirmedWorkTime {
                entry.activity?.markSourceUnavailable(); entry.request = nil
            }
        } else if thread.status == .needsInput {
            applyPlainQuestion(thread, project: project, entry: &entry, at: now)
        } else if isOpen(entry.activity) || entry.activity?.phase == .unknown {
            let newerReply = datedReply(thread, at: now).map { reply in entry.mark.map { reply > $0 } ?? false } ?? false
            // A plain question already represented the end of this run.
            let knownEnding = entry.plainQuestion == nil && (entry.observedRun || thread.status == .resolved || failed)
            if knownEnding || newerReply || hasFreshReply(thread, entry, at: now) {
                finish(&entry, id: thread.id, project: project, failed: failed, mark: thread.lastReplyAt, at: now)
            } else {
                if entry.plainQuestion != nil { rememberSettled(thread, at: now) }
                clearWork(&entry)
            }
        } else if lastPass == nil {
            // Only Claude's unread flag can vouch for an old ending, and an idle thread never raises it.
            if thread.hasUnread, let reply = thread.lastReplyAt, now.timeIntervalSince(reply) < Self.baselineAge {
                finish(&entry, id: thread.id, project: project, failed: failed, mark: reply, historical: true, at: now)
            }
        } else if thread.hasUnread || (thread.status == .idle && !sessions.isEmpty), !settling(entry, into: thread.status, at: now), let reply = thread.lastReplyAt {
            // The whole run fell between two polls. A thread that only just
            // entered the bounded list is not news unless its reply is.
            let newer = reply > (entry.mark ?? .distantFuture)
            let appeared = isNew && reply >= (lastPass ?? now).addingTimeInterval(-60)
            if newer || appeared { finish(&entry, id: thread.id, project: project, failed: failed, mark: reply, at: now) }
        }
        if entry.lastEndKey != endKey {
            entry.resultLooks = 0
            entry.resultSession = sessions.max { ($0.lastEventAt ?? .distantPast) < ($1.lastEventAt ?? .distantPast) }?.id ?? thread.sessionIDs.first
        }
        entry.mark = [entry.mark, thread.lastReplyAt].compactMap { $0 }.max()
        update(&entry, id: thread.id, project: project, title: thread.title, session: sessions.first, role: .thread, status: thread.status,
               workers: sessions.isEmpty ? thread.workingSessions : sessions.filter(\.isRunning).count, unread: thread.hasUnread, at: now)
        tracked[thread.id] = entry
    }

    private func datedReply(_ thread: ClaudeCloudThread, at now: Date) -> Date? {
        thread.lastReplyAt.flatMap { $0 <= now.addingTimeInterval(Self.serverClockMargin) ? $0 : nil }
    }

    private func hasFreshReply(_ thread: ClaudeCloudThread, _ entry: Tracked, at now: Date) -> Bool {
        guard let reply = datedReply(thread, at: now), let lastPass, reply > (entry.mark ?? .distantPast) else { return false }
        return reply >= max(lastPass.addingTimeInterval(-Self.questionPollOverlap), now.addingTimeInterval(-Self.freshQuestionAge))
    }

    private mutating func applyPlainQuestion(_ thread: ClaudeCloudThread, project: ClaudeCloudProject, entry: inout Tracked, at now: Date) {
        let previous = entry.plainQuestion
        let fresh = entry.activity?.phase == .running || hasFreshReply(thread, entry, at: now)
        let reply = datedReply(thread, at: now)
        let evidence = max(previous?.evidenceAt ?? .distantPast, min(reply ?? .distantPast, now), fresh ? now : .distantPast)
        let read = previous.map { !thread.hasUnread && ($0.sawUnread || now.timeIntervalSince($0.detectedAt) >= Self.readGrace) } ?? false
        let settled = settledQuestions[thread.id].map { (reply ?? .distantPast) <= $0.through } ?? false
        if settled || read ||
            now.timeIntervalSince(evidence) >= Self.baselineAge || (previous == nil && !fresh && !thread.hasUnread) {
            rememberSettled(thread, at: now)
            clearWork(&entry)
            return
        }
        // An old, still-unread question may be useful in the list, but it is not a new alert.
        let question = PlainQuestion(detectedAt: previous?.detectedAt ?? now, evidenceAt: evidence, sawUnread: thread.hasUnread || previous?.sawUnread == true)
        if previous == nil { entry.request = nil }
        entry.plainQuestion = question; entry.confirmedAt = now
        open(&entry, id: thread.id, project: project, role: .thread, attention: .input, at: now,
             detectedAt: question.detectedAt, suppressesNotice: previous != nil || !fresh)
    }

    private mutating func rememberSettled(_ thread: ClaudeCloudThread, at now: Date) {
        let through = datedReply(thread, at: now) ?? now
        if let old = settledQuestions[thread.id], through <= old.through { return }
        settledQuestions[thread.id] = SettledQuestion(through: through, settledAt: now)
        if settledQuestions.count > Self.maximumSettledQuestions,
           let oldest = settledQuestions.min(by: { $0.value.settledAt < $1.value.settledAt })?.key {
            settledQuestions[oldest] = nil
        }
    }

    private func clearWork(_ entry: inout Tracked) {
        entry.activity = nil; entry.request = nil; entry.plainQuestion = nil
        entry.confirmedAt = nil; entry.observedRun = false; entry.resultSession = nil
    }

    private func settling(_ entry: Tracked, into status: ClaudeCloudThreadStatus, at now: Date) -> Bool {
        guard let activity = entry.activity, activity.phase == .completed, activity.claudeCloud?.status == .idle, status != .idle,
              let ended = activity.phaseChangedAt else { return false }
        return now.timeIntervalSince(ended) < Self.settlingTime
    }

    private mutating func applyCoordinator(_ id: String, project: ClaudeCloudProject, session: ClaudeCloudSession?, threads: [ClaudeCloudThread]?, at now: Date) {
        var entry = tracked[id] ?? Tracked(projectID: project.id)
        let isNew = tracked[id] == nil
        // Not read this time: a quiet project keeps what is known.
        guard let session else { tracked[id] = entry; return }
        entry.awaitsReply = session.awaitsReply
        let attention = session.pending
        if session.isRunning || attention != nil {
            open(&entry, id: id, project: project, role: .coordinator, attention: attention, at: now)
        } else if isOpen(entry.activity) || entry.activity?.phase == .unknown {
            let start = entry.activity?.phaseChangedAt ?? lastPass ?? now
            if isAboutThreads(session, project: project.id, threads: threads, since: start) { entry.activity = nil; entry.request = nil }
            else { finish(&entry, id: id, project: project, failed: session.isFailed, mark: session.lastEventAt, at: now) }
        } else if lastPass != nil, session.hasUnread, isNew || entry.lastUnread == false,
                  !isAboutThreads(session, project: project.id, threads: threads, since: lastPass ?? now) {
            // Its events do not separate runs, and it can run between polls.
            finish(&entry, id: id, project: project, failed: session.isFailed, mark: session.lastEventAt, at: now)
        }
        entry.lastUnread = session.hasUnread
        update(&entry, id: id, project: project, title: L10n.text("claude.cloud.coordinator"), session: session, role: .coordinator, status: nil,
               workers: 0, unread: session.hasUnread, at: now)
        tracked[id] = entry
    }

    /// Handing work to threads, or reporting on one that just ended, is not an
    /// answer of its own: the threads' rows and cards already say it.
    private func isAboutThreads(_ session: ClaudeCloudSession, project: String, threads: [ClaudeCloudThread]?, since start: Date) -> Bool {
        if threads?.contains(where: { ($0.createdAt ?? .distantPast) >= start.addingTimeInterval(-Self.delegationWindow) }) == true { return true }
        return tracked.values.contains { entry in
            guard let activity = entry.activity, let context = activity.claudeCloud, context.role == .thread, context.projectID == project else { return false }
            if isOpen(activity) { return true }
            return [.completed, .interrupted].contains(activity.phase) && (activity.phaseChangedAt ?? .distantPast) >= start.addingTimeInterval(-Self.threadReportWindow)
        }
    }

    private func newActivity(id: String, project: ClaudeCloudProject) -> SessionActivity {
        SessionActivity(id: AgentProvider.claude.activityID(sessionID: id, sourceHostID: Self.sourceID), project: project.name,
            sourceHost: project.name, sourceHostID: Self.sourceID, provider: .claude, sessionID: id)
    }

    private func open(_ entry: inout Tracked, id: String, project: ClaudeCloudProject, role: ClaudeCloudContext.Role,
                      attention: PendingAttentionRequest.Kind?, at now: Date, detectedAt: Date? = nil, suppressesNotice: Bool = false) {
        var activity = entry.activity ?? newActivity(id: id, project: project)
        if !isOpen(entry.activity) { entry.sawUnread = false; entry.resultSession = nil }
        // A new run starts measuring afresh, so an earlier speed cannot read as live.
        if activity.phase != .running { entry.replyMeter = ClaudeCloudReplyMeter(); activity.setCloudReplyRate(nil) }
        let flags = attention.map { $0 == .approval ? ["waitingOnApproval"] : ["waitingOnUserInput"] } ?? []
        // A poll cannot date a run's start, so a row's elapsed time starts when it was first seen.
        activity.applyRuntime(["method": "thread/observed", "threadId": id, "status": "active", "flags": flags, "at": now.timeIntervalSince1970])
        entry.activity = activity
        guard let attention else { entry.request = nil; return }
        if entry.request?.kind != attention {
            entry.request = PendingAttentionRequest(id: Self.sourceID + ":" + id, threadID: id, sourceHostID: Self.sourceID,
                sourceName: project.name, kind: attention, detectedAt: detectedAt ?? now, provider: .claude,
                claudeCloud: ClaudeCloudContext(projectID: project.id, projectName: project.name, role: role), suppressesNotice: suppressesNotice)
        }
    }

    private func finish(_ entry: inout Tracked, id: String, project: ClaudeCloudProject, failed: Bool, mark: Date?,
                        historical: Bool = false, at now: Date) {
        var activity = entry.activity ?? newActivity(id: id, project: project)
        let reply = mark.map { min($0, now) }
        let ended = reply.flatMap { historical || now.timeIntervalSince($0) < Self.exactEndingAge ? $0 : nil } ?? now
        // Observing first lets one poll carry a whole run, and revives a task
        // whose source was unavailable while it ended.
        if !isOpen(activity) {
            activity.applyRuntime(["method": "thread/observed", "threadId": id, "status": "active", "at": min(reply ?? ended, ended).timeIntervalSince1970])
        }
        // An ending keeps the identity it would have after a relaunch, unless
        // the same reply already ended an earlier run.
        var key = "cloud-" + String(Int64((mark ?? now).timeIntervalSince1970 * 1000))
        if key == entry.lastEndKey { key += "-" + String(Int64(now.timeIntervalSince1970 * 1000)) }
        activity.applyRuntime(["method": "turn/completed", "threadId": id, "turnId": key, "status": failed ? "failed" : "completed",
                               "at": ended.timeIntervalSince1970])
        if historical { activity.suppressHistoricalCompletionNotifications() }
        entry.plainQuestion = nil; entry.observedRun = false; entry.confirmedAt = nil
        entry.lastEndKey = key; entry.sawUnread = false; entry.request = nil; entry.activity = activity
    }

    private func update(_ entry: inout Tracked, id: String, project: ClaudeCloudProject, title: String?, session: ClaudeCloudSession?,
                        role: ClaudeCloudContext.Role, status: ClaudeCloudThreadStatus?, workers: Int, unread: Bool, at now: Date) {
        guard var activity = entry.activity else { return }
        if unread { entry.sawUnread = true }
        var details: [String: Any] = ["method": "metadata", "threadId": id, "at": now.timeIntervalSince1970]
        if let title { details["name"] = title }
        if let model = session?.modelName {
            details["model"] = model
            if let effort = session?.effort { details["reasoningEffort"] = effort }
        }
        activity.applyRuntime(details)
        let ended = [.completed, .interrupted].contains(activity.phase)
        let graceOver = now.timeIntervalSince(activity.phaseChangedAt ?? now) >= Self.readGrace
        // An idle thread never raises the unread flag, so its silence says nothing about being read.
        let canSettleUnseen = status != .idle
        activity.setClaudeCloud(ClaudeCloudContext(projectID: project.id, projectName: project.name, role: role,
            status: status ?? activity.claudeCloud?.status, additionalWorkers: max(0, workers - 1),
            readInClaude: ended && !unread && (entry.sawUnread || (graceOver && canSettleUnseen)), awaitsReply: ended && entry.awaitsReply,
            completionMark: ended ? entry.mark : nil))
        entry.activity = activity
    }
}

/// How long until the next look. Only a poll reveals a run, so this trades
/// reaction time for requests: fast while something runs, slow while nothing does.
public enum ClaudeCloudPolling {
    public static func delay(running: Bool, waiting: Bool, recentlyActive: Bool, expanded: Bool, failures: Int) -> TimeInterval {
        if failures > 0 { return min(900, 30 * pow(2, Double(min(failures, 6) - 1))) }
        if running { return 20 }
        if expanded || recentlyActive { return 30 }
        return waiting ? 60 : 120
    }
}
