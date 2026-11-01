import Foundation

/// Read-only polling of Claude's cloud Projects with Pacer's own claude.ai
/// session. These endpoints are private and version sensitive. The account's
/// session watch is not enabled for web sessions, so a poll decides every state;
/// the projects' message streams only add a run's early start and estimated speed.
public actor ClaudeCloudProjectMonitor {
    /// A nil status means this account is not offered Projects, which is nothing to report.
    public typealias Update = @Sendable (_ activities: [SessionActivity], _ status: RuntimeStreamStatus?,
                                         _ attention: [PendingAttentionRequest]) async -> Void
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    public typealias LocalSessions = @Sendable () -> Set<String>

    /// Each project costs a request per pass, so only the most recent are followed.
    private static let maximumProjects = 16
    private static let quietProjectAge: TimeInterval = 3 * 24 * 3600
    private static let quietProjectInterval: TimeInterval = 600
    private let cookieProvider: ClaudeWebQuotaClient.CookieProvider
    private let selectedOrganization: @Sendable () -> String?
    private let localSessions: LocalSessions
    private let transport: Transport
    private let session: URLSession?
    private let streamSession: URLSession?
    private let streams: ClaudeCloudReplyStreams?
    private let streamLines: ClaudeCloudReplyStreams.Lines?
    private let now: @Sendable () -> Date
    private var state = ClaudeCloudProjectState()
    private var lastStatus: RuntimeStreamStatus?
    private var speedPublish: Task<Void, Never>?
    private var signalWake: Task<Void, Never>?
    private var scope: String?
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

    public init(cookieProvider: @escaping ClaudeWebQuotaClient.CookieProvider,
                selectedOrganization: @escaping @Sendable () -> String? = { nil },
                localSessions: @escaping LocalSessions = { ClaudeApplicationResolver.desktopCloudSessionIDs() }, timeout: TimeInterval = 12) {
        self.cookieProvider = cookieProvider; self.selectedOrganization = selectedOrganization; self.localSessions = localSessions
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = min(30, max(1, timeout))
        configuration.timeoutIntervalForResource = min(35, max(2, timeout + 3))
        let session = URLSession(configuration: configuration, delegate: ClaudeCloudRedirectDelegate(), delegateQueue: nil)
        self.session = session
        transport = { request in
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw ClaudeCloudFailure.invalidReply }
            return (data, response)
        }
        now = { Date() }
        // A stream sends a keepalive about every 14 seconds, and otherwise lasts until it is closed.
        let streaming = URLSessionConfiguration.ephemeral
        streaming.httpCookieStorage = nil; streaming.urlCache = nil; streaming.httpShouldSetCookies = false
        streaming.timeoutIntervalForRequest = 60; streaming.timeoutIntervalForResource = 24 * 3600
        let streamSession = URLSession(configuration: streaming, delegate: ClaudeCloudRedirectDelegate(), delegateQueue: nil)
        self.streamSession = streamSession
        let lines = ClaudeCloudReplyStreams.lines(session: streamSession)
        streamLines = lines
        streams = ClaudeCloudReplyStreams(lines: lines, requests: Self.streamRequests(cookieProvider, selectedOrganization))
    }

    init(cookieProvider: @escaping ClaudeWebQuotaClient.CookieProvider, selectedOrganization: @escaping @Sendable () -> String? = { nil },
         localSessions: @escaping LocalSessions = { [] }, transport: @escaping Transport, streamLines: ClaudeCloudReplyStreams.Lines? = nil,
         now: @escaping @Sendable () -> Date) {
        self.cookieProvider = cookieProvider; self.selectedOrganization = selectedOrganization; self.localSessions = localSessions
        self.transport = transport; self.now = now; session = nil; streamSession = nil
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
        let task = Task<Void, Never> { try? await Task.sleep(nanoseconds: UInt64(max(1, delay) * 1_000_000_000)) }
        sleeper = task
        await task.value
    }
    public func setExpanded(_ value: Bool) {
        let opened = value && !expanded
        expanded = value
        if opened, now().timeIntervalSince(lastPoll) >= 5 { sleeper?.cancel() }
    }
    public func refresh() { sleeper?.cancel() }
    /// Stops looking but remembers what was running, to report how it ended.
    public func suspend() async {
        loop?.cancel(); loop = nil; sleeper?.cancel(); sleeper = nil
        speedPublish?.cancel(); speedPublish = nil; signalWake?.cancel(); signalWake = nil
        await streams?.stop()
    }
    public func shutdown() async {
        await suspend(); callback = nil
        session?.invalidateAndCancel(); streamSession?.invalidateAndCancel()
    }

    /// Returns the delay before the next look.
    @discardableResult func pollOnce() async -> TimeInterval {
        let date = now(); lastPoll = date
        if let retryAt, retryAt > date { return retryAt.timeIntervalSince(date) }
        retryAt = nil
        guard let cookies = await cookieProvider(), ClaudeWebQuotaDecoder.sessionKey(cookies) != nil else {
            await reset(); await publish(status: Self.signedOut); return 60
        }
        // A rejected session stays rejected until the user signs in again.
        if rejectedSession == cookies.sessionHash { await publish(status: Self.signedOut); return 60 }
        rejectedSession = nil
        guard let organization = ClaudeWebQuotaDecoder.uuid(selectedOrganization() ?? cookies.organizationID) else {
            await reset(); await publish(status: Self.signedOut); return 120
        }
        let currentScope = ClaudeQuotaDecoder.digest(cookies.sessionHash + "|" + organization)
        if scope != currentScope { await reset(); scope = currentScope }
        do {
            let snapshot = try await read(cookies: cookies, organization: organization, at: date)
            guard !Task.isCancelled else { return 1 }
            state.apply(snapshot, at: date); failures = 0
            await readTurnResults(cookies, organization, at: date)
            await followStreams(snapshot, at: date)
            let isFresh: (Date?) -> Bool = { $0.map { date.timeIntervalSince($0) < 180 } ?? false }
            recentlyActive = snapshot.projects.contains { isFresh($0.lastActivityAt) } || snapshot.threads.values.contains { $0.contains { isFresh($0.lastReplyAt) } }
            var status = RuntimeStreamStatus()
            status.connected = true; status.watchingLogs = false
            status.attachedThreads = state.openWorkCount
            await publish(status: status)
            return ClaudeCloudPolling.delay(running: state.hasRunningWork, waiting: state.hasOpenWork, recentlyActive: recentlyActive, expanded: expanded, failures: 0)
        } catch is CancellationError { return 1 }
        catch { return await failed(error as? ClaudeCloudFailure ?? .connection, cookies: cookies, at: date) }
    }

    private func failed(_ failure: ClaudeCloudFailure, cookies: ClaudeWebSession, at date: Date) async -> TimeInterval {
        switch failure {
        case .signedOut:
            rejectedSession = cookies.sessionHash; await reset()
            await publish(status: Self.signedOut); return 60
        case .notEnabled:
            // Not offered to this account. Nothing is wrong, so nothing is shown.
            await reset(); retryAt = date.addingTimeInterval(1800)
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

    private func reset() async {
        state = ClaudeCloudProjectState(); scope = nil; failures = 0; localIDs = []; localIDsReadAt = .distantPast; threadsReadAt = [:]
        await streams?.stop()
    }

    private static var signedOut: RuntimeStreamStatus {
        var status = RuntimeStreamStatus(); status.sourceAvailable = false
        return status
    }

    private func publish(status: RuntimeStreamStatus?) async {
        lastStatus = status
        await callback?(state.activities, status, state.attention)
    }

    private func followStreams(_ snapshot: ClaudeCloudSnapshot, at date: Date) async {
        guard let streams, !Task.isCancelled else { return }
        // Sorted by activity, so a busy account follows the projects in use.
        let recent = snapshot.projects.filter { project in
            state.hasOpenWork(inProject: project.id) || project.lastActivityAt.map { date.timeIntervalSince($0) < Self.quietProjectAge } == true
        }
        await streams.follow(projects: recent.map(\.id), threads: state.runningThreads) { [weak self] event, project in
            await self?.received(event, project: project)
        }
    }

    func received(_ event: ClaudeCloudStreamEvent, project: String) async {
        switch event {
        case let .threadStarting(thread, session):
            // A session Desktop runs here is already a local task, with its speed.
            if let session, localIDs.contains(ClaudeCloudProjectState.bareID(session)) { return }
            await streams?.listen(to: thread, in: project)
            if !state.isRunning(thread: thread) { pollSoon() }
        case let .partialReply(thread, block, tokens, sentAt):
            if state.applyReplyProgress(thread: thread, block: block, tokens: tokens, sentAt: sentAt, at: now()) { publishSpeedSoon() }
        }
    }

    /// A run just started, so its row need not wait for the next look.
    private func pollSoon() {
        guard loop != nil, failures == 0, signalWake == nil else { return }
        let wait = Self.soonestPoll - now().timeIntervalSince(lastPoll)
        guard wait > 0 else { sleeper?.cancel(); return }
        signalWake = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            await self?.wakeForSignal()
        }
    }
    private func wakeForSignal() { signalWake = nil; sleeper?.cancel() }
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
        await publish(status: lastStatus)
    }

    /// A project quiet for days is looked at less often, so one busy account's
    /// old projects do not cost a request every pass.
    private func wantsThreads(_ project: ClaudeCloudProject, at date: Date) -> Bool {
        if state.hasOpenWork(inProject: project.id) { return true }
        if let activity = project.lastActivityAt, date.timeIntervalSince(activity) < Self.quietProjectAge { return true }
        return date.timeIntervalSince(threadsReadAt[project.id] ?? .distantPast) >= Self.quietProjectInterval
    }

    private func read(cookies: ClaudeWebSession, organization: String, at date: Date) async throws -> ClaudeCloudSnapshot {
        let projects = try ClaudeCloudDecoder.projects(try await get("/v1/code/channels?limit=50&scope=joined", cookies, organization))
            .sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
        let selected = Array(projects.prefix(Self.maximumProjects))
        var threads: [String: [ClaudeCloudThread]] = [:]
        for project in selected where wantsThreads(project, at: date) {
            try Task.checkCancellation()
            do {
                threads[project.id] = try ClaudeCloudDecoder.threads(try await get("/v1/code/channels/\(project.id)/threads?limit=20", cookies, organization), projectID: project.id)
                threadsReadAt[project.id] = date
            }
            catch ClaudeCloudFailure.denied, ClaudeCloudFailure.notEnabled, ClaudeCloudFailure.invalidReply { continue }
        }
        if date.timeIntervalSince(localIDsReadAt) >= 300 {
            localIDsReadAt = date
            let read = localSessions
            localIDs = await Task.detached(priority: .utility) { read() }.value
        }
        var sessions: [String: ClaudeCloudSession] = [:]
        for id in state.sessionsToRead(projects: selected, threads: threads, at: date, local: localIDs) {
            try Task.checkCancellation()
            do { let value = try ClaudeCloudDecoder.session(try await get("/v1/code/sessions/\(id)", cookies, organization)); sessions[id] = value }
            catch ClaudeCloudFailure.denied, ClaudeCloudFailure.notEnabled, ClaudeCloudFailure.invalidReply { continue }
        }
        return ClaudeCloudSnapshot(projects: selected, threads: threads, sessions: sessions, localSessionIDs: localIDs)
    }

    /// A speed is a bonus on an ending that is already known, so failing to read
    /// one fails nothing else. A connection problem leaves it for the next pass.
    private func readTurnResults(_ cookies: ClaudeWebSession, _ organization: String, at date: Date) async {
        for wanted in state.turnResultsToRead() {
            do {
                try Task.checkCancellation()
                let result = try ClaudeCloudDecoder.turnResult(try await get(Self.eventsPath(wanted.session), cookies, organization))
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

    private func get(_ path: String, _ cookies: ClaudeWebSession, _ organization: String) async throws -> Data {
        guard let request = Self.request(path, accept: "application/json", cookies, organization) else { throw ClaudeCloudFailure.invalidReply }
        let (data, response): (Data, HTTPURLResponse)
        do { (data, response) = try await transport(request) }
        catch let failure as ClaudeCloudFailure { throw failure }
        catch is CancellationError { throw CancellationError() }
        catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw ClaudeCloudFailure.connection
        }
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
            let snapshot = try await read(cookies: cookies, organization: organization, at: now())
            let threads = snapshot.threads.values.flatMap { $0 }
            let counts = Dictionary(grouping: threads, by: \.status.rawValue).mapValues(\.count).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            let recent = threads.sorted { ($0.lastReplyAt ?? .distantPast) > ($1.lastReplyAt ?? .distantPast) }.compactMap(\.sessionIDs.first).prefix(3)
            var speeds = 0
            for id in recent {
                if let data = try? await get(Self.eventsPath(id), cookies, organization), (try? ClaudeCloudDecoder.turnResult(data)) != nil { speeds += 1 }
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

final class ClaudeCloudRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
