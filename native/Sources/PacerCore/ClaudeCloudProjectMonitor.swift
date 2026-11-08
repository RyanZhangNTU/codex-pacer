import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Read-only polling of Claude's cloud Projects with Pacer's own claude.ai
/// session. These endpoints are private and version sensitive. The account's
/// session watch is not enabled for web sessions, so a poll decides every state;
/// the projects' message streams can bring a read forward and estimate reply speed.
public actor ClaudeCloudProjectMonitor {
    /// A nil status means this account is not offered Projects, which is nothing to report.
    public typealias Update = @Sendable (_ activities: [SessionActivity], _ status: RuntimeStreamStatus?,
                                         _ attention: [PendingAttentionRequest]) async -> Void
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    public typealias LocalSessions = @Sendable () -> Set<String>

    /// Each project costs a request per pass, so only the most recent are followed.
    private static let maximumProjects = 16
    private static let quietProjectAge: TimeInterval = 3 * 24 * 3600
    private static let quietProjectInterval: TimeInterval = 600
    private struct ReadBinding: Sendable {
        let cookies: ClaudeWebSession
        let organization: String
        let revision: UInt64
    }
    private enum ReadCancelled: Error { case superseded }
    private let cookieProvider: ClaudeWebQuotaClient.CookieProvider
    private let selectedOrganization: @Sendable () -> String?
    private let localSessions: LocalSessions
    private let transport: Transport
    private let invalidateTransport: @Sendable () -> Void
    private let streams: ClaudeCloudReplyStreams?
    private let streamLines: ClaudeCloudReplyStreams.Lines?
    private let now: @Sendable () -> Date
    private var state = ClaudeCloudProjectState()
    private var lastStatus: RuntimeStreamStatus?
    private var speedPublish: Task<Void, Never>?
    private var pollRequested = false
    private var threadHints: [String: String] = [:]
    private var scope: String?
    private var revision: UInt64 = 0
    private var activeBinding: ReadBinding?
    private var rejectedSession: String?
    private var failures = 0
    private var retryAt: Date?
    private var localIDs: Set<String> = []
    private var localIDsReadAt = Date.distantPast
    private var recentlyActive = false
    private var expanded = false
    private var lastPoll = Date.distantPast
    private var threadsReadAt: [String: Date] = [:]
    private var callback: Update?
    private var loop: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var scopeObserver: (@Sendable (String?) async -> Bool)?

    public func setScopeObserver(_ observer: @escaping @Sendable (String?) async -> Bool) { scopeObserver = observer }

    public init(cookieProvider: @escaping ClaudeWebQuotaClient.CookieProvider, selectedOrganization: @escaping @Sendable () -> String? = { nil },
         localSessions: @escaping LocalSessions = { [] }, transport: @escaping Transport, streamLines: ClaudeCloudReplyStreams.Lines? = nil,
         now: @escaping @Sendable () -> Date,
         invalidateTransport: @escaping @Sendable () -> Void = {}) {
        self.cookieProvider = cookieProvider; self.selectedOrganization = selectedOrganization; self.localSessions = localSessions
        self.transport = transport; self.now = now; self.invalidateTransport = invalidateTransport
        self.streamLines = streamLines
        streams = streamLines.map { ClaudeCloudReplyStreams(lines: $0, requests: Self.streamRequests(cookieProvider, selectedOrganization), now: now) }
    }

    /// Each connection reads the session again, since a long-lived one can outlast a cookie.
    private static func streamRequests(_ cookieProvider: @escaping ClaudeWebQuotaClient.CookieProvider,
                                       _ selectedOrganization: @escaping @Sendable () -> String?) -> ClaudeCloudReplyStreams.Requests {
        { path in
            guard let cookies = await cookieProvider(), ClaudeWebQuotaDecoder.sessionKey(cookies) != nil,
                  let organization = ClaudeWebQuotaDecoder.uuid(selectedOrganization() ?? cookies.organizationID) else { return nil }
            return request(path, accept: "text/event-stream", cookies, organization)
        }
    }

    /// Receives updates without starting the loop, so a test sets the pace.
    func observe(_ update: @escaping Update) { callback = update }

    public func start(expanded: Bool, update: @escaping Update) {
        self.expanded = expanded; callback = update
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.pollOnce(), !Task.isCancelled else { return }
                await self?.wait(delay)
            }
        }
    }
    private func wait(_ delay: TimeInterval) async {
        let regular = now().addingTimeInterval(max(1, delay)), waitingRevision = revision
        while !Task.isCancelled {
            let deadline = pollRequested && failures == 0 && retryAt == nil
                ? min(regular, lastPoll.addingTimeInterval(Self.soonestPoll)) : regular
            let seconds = deadline.timeIntervalSince(now())
            guard seconds > 0 else { return }
            let task = Task<Void, Never> { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            sleeper = task
            await task.value
            guard task.isCancelled, revision == waitingRevision else { return }
        }
    }
    public func setExpanded(_ value: Bool) {
        let opened = value && !expanded
        expanded = value
        if opened { pollSoon() }
    }
    public func refresh() async {
        revision &+= 1; activeBinding = nil; retryAt = nil
        speedPublish?.cancel(); speedPublish = nil; clearPollHints()
        await streams?.stop()
        sleeper?.cancel()
    }
    /// Stops looking but remembers what was running, to report how it ended.
    public func suspend() async {
        revision &+= 1; activeBinding = nil
        loop?.cancel(); loop = nil; sleeper?.cancel(); sleeper = nil
        speedPublish?.cancel(); speedPublish = nil; clearPollHints()
        await streams?.stop()
    }
    public func shutdown() async {
        await suspend(); callback = nil
        invalidateTransport()
    }

    /// Returns the delay before the next look.
    @discardableResult func pollOnce() async -> TimeInterval {
        let date = now(); lastPoll = date
        pollRequested = false
        let startedRevision = revision
        guard let cookies = await cookieProvider(), ClaudeWebQuotaDecoder.sessionKey(cookies) != nil else {
            guard revision == startedRevision, !Task.isCancelled else { return 1 }
            if let scopeObserver, !(await scopeObserver(nil)) { return 1 }
            guard revision == startedRevision, !Task.isCancelled else { return 1 }
            await reset(); await publish(status: Self.signedOut); return 60
        }
        guard revision == startedRevision, !Task.isCancelled else { return 1 }
        // A rejected session stays rejected until the user signs in again.
        if rejectedSession == cookies.sessionHash {
            if let scopeObserver, !(await scopeObserver(nil)) { return 1 }
            guard revision == startedRevision, !Task.isCancelled else { return 1 }
            await publish(status: Self.signedOut); return 60
        }
        rejectedSession = nil
        guard let organization = ClaudeWebQuotaDecoder.uuid(selectedOrganization() ?? cookies.organizationID) else {
            if let scopeObserver, !(await scopeObserver(nil)) { return 1 }
            guard revision == startedRevision, !Task.isCancelled else { return 1 }
            await reset(); await publish(status: Self.signedOut); return 120
        }
        let currentScope = ClaudeQuotaDecoder.digest(cookies.sessionHash + "|" + organization)
        if let scopeObserver, !(await scopeObserver(currentScope)) { return 1 }
        guard revision == startedRevision, !Task.isCancelled else { return 1 }
        if scope != currentScope {
            let cleared = await reset()
            guard revision == cleared, !Task.isCancelled else { return 1 }
            scope = currentScope
        }
        if let retryAt, retryAt > date { return retryAt.timeIntervalSince(date) }
        retryAt = nil
        let binding = ReadBinding(cookies: cookies, organization: organization, revision: revision)
        activeBinding = binding
        let hints = threadHints; threadHints.removeAll(keepingCapacity: true)
        do {
            let snapshot = try await read(binding: binding, at: date, hints: hints)
            try await checkBinding(binding)
            state.apply(snapshot, at: date); failures = 0
            await readTurnResults(binding, at: date)
            try await checkBinding(binding)
            await followStreams(snapshot, binding: binding, at: date)
            try await checkBinding(binding)
            let isFresh: (Date?) -> Bool = { $0.map { date.timeIntervalSince($0) < 180 } ?? false }
            recentlyActive = snapshot.projects.contains { isFresh($0.lastActivityAt) } || snapshot.threads.values.contains { $0.contains { isFresh($0.lastReplyAt) } }
            var status = RuntimeStreamStatus()
            status.connected = true; status.watchingLogs = false
            status.attachedThreads = state.openWorkCount
            await publish(status: status)
            return ClaudeCloudPolling.delay(running: state.hasRunningWork, waiting: state.hasOpenWork, recentlyActive: recentlyActive, expanded: expanded, failures: 0)
        } catch is CancellationError { return 1 }
        catch is ReadCancelled { return 1 }
        catch {
            do { try await checkBinding(binding) } catch { return 1 }
            return await failed(error as? ClaudeCloudFailure ?? .connection, binding: binding, at: date)
        }
    }

    private func failed(_ failure: ClaudeCloudFailure, binding: ReadBinding, at date: Date) async -> TimeInterval {
        switch failure {
        case .signedOut:
            if let scopeObserver, !(await scopeObserver(nil)) { return 1 }
            rejectedSession = binding.cookies.sessionHash; await reset()
            await publish(status: Self.signedOut); return 60
        case .notEnabled:
            // Not offered to this account. Nothing is wrong, so nothing is shown.
            await reset(); retryAt = date.addingTimeInterval(1800)
            scope = ClaudeQuotaDecoder.digest(binding.cookies.sessionHash + "|" + binding.organization)
            await publish(status: nil); return 1800
        default: break
        }
        failures += 1
        var status = RuntimeStreamStatus(); status.connected = false
        if failures >= 3 { state.markUnavailable() }
        await publish(status: status)
        var delay = ClaudeCloudPolling.delay(running: false, waiting: false, recentlyActive: false, expanded: expanded, failures: failures)
        if case .throttled(let until?) = failure { delay = max(delay, min(3600, until.timeIntervalSince(date))) }
        if failure == .denied || failure == .challenge { delay = max(delay, 900) }
        return delay
    }

    @discardableResult private func reset() async -> UInt64 {
        revision &+= 1; activeBinding = nil; retryAt = nil
        let cleared = revision
        state = ClaudeCloudProjectState(); scope = nil; failures = 0; localIDs = []; localIDsReadAt = .distantPast; threadsReadAt = [:]
        speedPublish?.cancel(); speedPublish = nil; clearPollHints()
        await streams?.stop()
        return cleared
    }

    /// A cookie read and every network suspension can outlive sign-in,
    /// organization selection, refresh or suspension of this monitor.
    private func checkBinding(_ binding: ReadBinding) async throws {
        try Task.checkCancellation()
        guard revision == binding.revision else { throw ReadCancelled.superseded }
        let current = await cookieProvider()
        try Task.checkCancellation()
        guard revision == binding.revision else { throw ReadCancelled.superseded }
        if let current, ClaudeWebQuotaDecoder.sessionKey(current) != nil,
           current.sessionHash == binding.cookies.sessionHash,
           ClaudeWebQuotaDecoder.uuid(selectedOrganization() ?? current.organizationID) == binding.organization { return }
        let cleared = await reset()
        if revision == cleared, !Task.isCancelled, let scopeObserver {
            let nextScope = current.flatMap { cookies -> String? in
                guard ClaudeWebQuotaDecoder.sessionKey(cookies) != nil,
                      let organization = ClaudeWebQuotaDecoder.uuid(selectedOrganization() ?? cookies.organizationID) else { return nil }
                return ClaudeQuotaDecoder.digest(cookies.sessionHash + "|" + organization)
            }
            guard await scopeObserver(nextScope) else { throw ReadCancelled.superseded }
        }
        if revision == cleared, !Task.isCancelled { await publish(status: Self.signedOut) }
        throw ReadCancelled.superseded
    }

    private static var signedOut: RuntimeStreamStatus {
        var status = RuntimeStreamStatus(); status.sourceAvailable = false
        return status
    }

    private func publish(status: RuntimeStreamStatus?) async {
        lastStatus = status
        await callback?(state.activities, status, state.attention)
    }

    private func followStreams(_ snapshot: ClaudeCloudSnapshot, binding: ReadBinding, at date: Date) async {
        guard let streams, !Task.isCancelled else { return }
        // Sorted by activity, so a busy account follows the projects in use.
        let recent = snapshot.projects.filter { project in
            state.hasOpenWork(inProject: project.id) || project.lastActivityAt.map { date.timeIntervalSince($0) < Self.quietProjectAge } == true
        }
        await streams.follow(projects: recent.map(\.id), threads: state.runningThreads) { [weak self] event, project in
            await self?.received(event, project: project, revision: binding.revision)
        }
    }

    private func received(_ event: ClaudeCloudStreamEvent, project: String, revision: UInt64) async {
        guard revision == self.revision else { return }
        await received(event, project: project)
    }

    func received(_ event: ClaudeCloudStreamEvent, project: String) async {
        switch event {
        case let .threadStarting(thread, session):
            // A session Desktop runs here is already a local task, with its speed.
            if let session, localIDs.contains(ClaudeCloudProjectState.bareID(session)) { return }
            if !state.isRunning(thread: thread) { requestThreadRead(thread, project: project) }
            await streams?.listen(to: thread, in: project)
        case let .threadStopped(thread, session):
            if let session, localIDs.contains(ClaudeCloudProjectState.bareID(session)) { return }
            if state.isRunning(thread: thread) { requestThreadRead(thread, project: project) }
        case let .partialReply(thread, block, tokens, sentAt):
            if state.applyReplyProgress(thread: thread, block: block, tokens: tokens, sentAt: sentAt, at: now()) { publishSpeedSoon() }
        }
    }

    private func requestThreadRead(_ thread: String, project: String) {
        guard failures == 0, retryAt == nil else { return }
        if threadHints.count < 16 { threadHints[thread] = project }
        pollSoon()
    }

    /// Keep a signal that arrived mid-read for the next pass, even if there is no sleeper yet.
    private func pollSoon() {
        guard loop != nil, failures == 0, retryAt == nil, !pollRequested else { return }
        pollRequested = true
        sleeper?.cancel()
    }
    private func clearPollHints() { pollRequested = false; threadHints.removeAll() }
    private static let soonestPoll: TimeInterval = 5

    /// The same pace as local rows: one second with the panel open, five otherwise.
    private func publishSpeedSoon() {
        guard speedPublish == nil else { return }
        let delay: UInt64 = expanded ? 1_000_000_000 : 5_000_000_000
        speedPublish = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.publishSpeed()
        }
    }
    func publishSpeed() async {
        speedPublish = nil
        guard let binding = activeBinding else { return }
        do { try await checkBinding(binding) } catch { return }
        await publish(status: lastStatus)
    }

    /// A project quiet for days is looked at less often, so one busy account's
    /// old projects do not cost a request every pass.
    private func wantsThreads(_ project: ClaudeCloudProject, at date: Date) -> Bool {
        if state.hasOpenWork(inProject: project.id) { return true }
        if let activity = project.lastActivityAt, date.timeIntervalSince(activity) < Self.quietProjectAge { return true }
        return date.timeIntervalSince(threadsReadAt[project.id] ?? .distantPast) >= Self.quietProjectInterval
    }

    private func read(binding: ReadBinding, at date: Date, hints: [String: String] = [:]) async throws -> ClaudeCloudSnapshot {
        let projects = try ClaudeCloudDecoder.projects(try await get("/v1/code/channels?limit=50&scope=joined", binding))
            .sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
        let selected = Array(projects.prefix(Self.maximumProjects))
        let hintedProjects = Set(hints.values)
        var threads: [String: [ClaudeCloudThread]] = [:]
        for project in selected where hintedProjects.contains(project.id) || wantsThreads(project, at: date) {
            try Task.checkCancellation()
            do {
                threads[project.id] = try ClaudeCloudDecoder.threads(try await get("/v1/code/channels/\(project.id)/threads?limit=20", binding), projectID: project.id)
                threadsReadAt[project.id] = date
            }
            catch ClaudeCloudFailure.denied, ClaudeCloudFailure.notEnabled, ClaudeCloudFailure.invalidReply { continue }
        }
        if date.timeIntervalSince(localIDsReadAt) >= 300 {
            localIDsReadAt = date
            let read = localSessions
            localIDs = await Task.detached(priority: .utility) { read() }.value
            try await checkBinding(binding)
        }
        var sessions: [String: ClaudeCloudSession] = [:]
        for id in state.sessionsToRead(projects: selected, threads: threads, at: date, local: localIDs, hintedThreads: Set(hints.keys)) {
            try Task.checkCancellation()
            do { let value = try ClaudeCloudDecoder.session(try await get("/v1/code/sessions/\(id)", binding)); sessions[id] = value }
            catch ClaudeCloudFailure.denied, ClaudeCloudFailure.notEnabled, ClaudeCloudFailure.invalidReply { continue }
        }
        return ClaudeCloudSnapshot(projects: selected, threads: threads, sessions: sessions, localSessionIDs: localIDs)
    }

    /// A speed is a bonus on an ending that is already known, so failing to read
    /// one fails nothing else. A connection problem leaves it for the next pass.
    private func readTurnResults(_ binding: ReadBinding, at date: Date) async {
        for wanted in state.turnResultsToRead() {
            do {
                try Task.checkCancellation()
                let result = try ClaudeCloudDecoder.turnResult(try await get(Self.eventsPath(wanted.session), binding))
                state.applyTurnResult(result, thread: wanted.thread, at: date)
            } catch ClaudeCloudFailure.denied, ClaudeCloudFailure.notEnabled, ClaudeCloudFailure.invalidReply {
                state.applyTurnResult(nil, thread: wanted.thread, at: date)
            } catch { return }
        }
    }
    /// Newest first, and a turn's result is among the last events it writes.
    private static func eventsPath(_ session: String) -> String { "/v1/code/sessions/\(session)/events?limit=8" }

    private static func request(_ path: String, accept: String, _ cookies: ClaudeWebSession, _ organization: String) -> URLRequest? {
        guard path.hasPrefix("/v1/code/"), path.utf8.count <= 256, let url = URL(string: "https://claude.ai" + path) else { return nil }
        var request = URLRequest(url: url); request.httpMethod = "GET"; request.httpShouldHandleCookies = false
        request.setValue(cookies.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("ccr-byoc-2025-07-29", forHTTPHeaderField: "anthropic-beta")
        request.setValue("ccr", forHTTPHeaderField: "anthropic-client-feature")
        request.setValue(organization, forHTTPHeaderField: "x-organization-uuid")
        if let agent = cookies.userAgent { request.setValue(agent, forHTTPHeaderField: "User-Agent") }
        return request
    }

    private func get(_ path: String, _ binding: ReadBinding) async throws -> Data {
        try await checkBinding(binding)
        guard let request = Self.request(path, accept: "application/json", binding.cookies, binding.organization) else { throw ClaudeCloudFailure.invalidReply }
        let (data, response): (Data, HTTPURLResponse)
        do { (data, response) = try await transport(request) }
        catch let failure as ClaudeCloudFailure { throw failure }
        catch is CancellationError { throw CancellationError() }
        catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw ClaudeCloudFailure.connection
        }
        try await checkBinding(binding)
        guard response.url?.scheme == "https", response.url?.host == "claude.ai", data.count <= 4 * 1024 * 1024 else { throw ClaudeCloudFailure.invalidReply }
        if ClaudeWebQuotaDecoder.isChallenge(data, response: response) { throw ClaudeCloudFailure.challenge }
        if let failure = ClaudeCloudFailure(response: response, at: now()) { throw failure }
        return data
    }

    /// Numeric status for `--diagnose-claude-cloud`: no names, titles or identifiers.
    public func diagnostics() async -> [String] {
        guard let cookies = await cookieProvider(), ClaudeWebQuotaDecoder.sessionKey(cookies) != nil else { return ["Web session: none (connect claude.ai in Settings)"] }
        guard let organization = ClaudeWebQuotaDecoder.uuid(selectedOrganization() ?? cookies.organizationID) else { return ["Web session: present", "Organization: not selected"] }
        do {
            let binding = ReadBinding(cookies: cookies, organization: organization, revision: revision)
            let snapshot = try await read(binding: binding, at: now())
            let threads = snapshot.threads.values.flatMap { $0 }
            let counts = Dictionary(grouping: threads, by: \.status.rawValue).mapValues(\.count).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            let recent = threads.sorted { ($0.lastReplyAt ?? .distantPast) > ($1.lastReplyAt ?? .distantPast) }.compactMap(\.sessionIDs.first).prefix(3)
            var speeds = 0
            for id in recent {
                if let data = try? await get(Self.eventsPath(id), binding), (try? ClaudeCloudDecoder.turnResult(data)) != nil { speeds += 1 }
            }
            return ["Web session: present", "Projects: \(snapshot.projects.count); threads read for \(snapshot.threads.count)",
                    "Threads: \(counts.joined(separator: " "))", "Working: \(threads.filter(\.isActive).count); unread: \(threads.filter(\.hasUnread).count); open decisions: \(threads.reduce(0) { $0 + $1.openDecisions })",
                    "Sessions read: \(snapshot.sessions.count); running: \(snapshot.sessions.values.filter(\.isRunning).count); waiting: \(snapshot.sessions.values.filter { $0.pending != nil }.count)",
                    "Turn speed: \(speeds) of \(recent.count) recent threads report one",
                    "Message stream: \(await streamCheck(snapshot.projects.first, cookies, organization))"]
        } catch { return ["Web session: present", "Projects: unavailable (\(error))"] }
    }

    /// Stops at the first line, which arrives as soon as the server accepts the stream.
    private func streamCheck(_ project: ClaudeCloudProject?, _ cookies: ClaudeWebSession, _ organization: String) async -> String {
        guard let project, let streamLines,
              let request = Self.request(ClaudeCloudReplyStreams.projectPath(project.id), accept: "text/event-stream", cookies, organization) else { return "not checked" }
        do {
            for try await _ in streamLines(request) { return "open" }
            return "closed"
        } catch { return "unavailable (\(error))" }
    }
}
