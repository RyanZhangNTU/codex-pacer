import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Listens to Claude's message streams for what a poll cannot see. A stream only
/// carries replies that start after it connects, so each recent project's stream
/// announces a run early enough to open that thread's stream in time. Polling
/// still decides every state: losing a stream only loses a speed.
public actor ClaudeCloudReplyStreams {
    public typealias Lines = @Sendable (URLRequest) -> AsyncThrowingStream<Data, Error>
    typealias Requests = @Sendable (String) async -> URLRequest?
    typealias Handler = @Sendable (ClaudeCloudStreamEvent, _ project: String) async -> Void

    /// An idle stream sends only a keepalive, so a project costs little to follow.
    static let maximumProjects = 4
    /// A running thread's stream repeats its whole reply about twice a second.
    static let maximumThreads = 6
    /// A thread can run again right after it stops.
    private static let linger: TimeInterval = 90
    /// Long enough to tell a working stream from one that keeps being refused.
    private static let steadyConnection: TimeInterval = 30

    private struct Connection { let task: Task<Void, Never>; var until: Date }
    private let lines: Lines
    private let requests: Requests
    private let now: @Sendable () -> Date
    private var handler: Handler?
    private var projects: [String: Task<Void, Never>] = [:]
    private var threads: [String: Connection] = [:]

    init(lines: @escaping Lines, requests: @escaping Requests, now: @escaping @Sendable () -> Date = { Date() }) {
        self.lines = lines; self.requests = requests; self.now = now
    }

    func follow(projects wanted: [String], threads running: [(project: String, thread: String)], handler: @escaping Handler) {
        self.handler = handler
        let date = now(), keep = Set(wanted.prefix(Self.maximumProjects))
        for (id, task) in projects where !keep.contains(id) { task.cancel(); projects[id] = nil }
        for id in keep where projects[id] == nil {
            projects[id] = connect(Self.projectPath(id), project: id, thread: nil)
        }
        for (id, connection) in threads where connection.until <= date && !running.contains(where: { $0.thread == id }) {
            connection.task.cancel(); threads[id] = nil
        }
        for item in running { listen(to: item.thread, in: item.project) }
    }

    func listen(to thread: String, in project: String) {
        let until = now().addingTimeInterval(Self.linger)
        if threads[thread] != nil { threads[thread]?.until = until; return }
        guard threads.count < Self.maximumThreads else { return }
        threads[thread] = Connection(task: connect(Self.threadPath(thread, project: project), project: project, thread: thread), until: until)
    }

    func stop() {
        projects.values.forEach { $0.cancel() }; projects = [:]
        threads.values.forEach { $0.task.cancel() }; threads = [:]
    }

    /// Open connections, for tests and diagnostics.
    var openCount: (projects: Int, threads: Int) { (projects.count, threads.count) }

    /// `from=tail` skips the project's history on every reconnect.
    static func projectPath(_ project: String) -> String { "/v1/code/channels/\(project)/messages/stream?from=tail&caught_up=true" }
    static func threadPath(_ thread: String, project: String) -> String {
        "/v1/code/channels/\(project)/messages/stream?scope=thread&thread_id=\(thread)&from=tail&caught_up=true"
    }

    private func connect(_ path: String, project: String, thread: String?) -> Task<Void, Never> {
        let lines = lines, requests = requests, now = now, handler = handler
        return Task.detached(priority: .utility) {
            var failures = 0
            while !Task.isCancelled {
                var failure: ClaudeCloudFailure?
                var lived: TimeInterval = 0
                if let request = await requests(path) {
                    let opened = now()
                    var parser = ClaudeCloudStreamParser(thread: thread)
                    do {
                        for try await line in lines(request) {
                            if let event = parser.consume(line) { await handler?(event, project) }
                        }
                    } catch { failure = error as? ClaudeCloudFailure ?? .connection }
                    lived = now().timeIntervalSince(opened)
                } else { failure = .signedOut }
                guard !Task.isCancelled else { return }
                failures = lived >= Self.steadyConnection ? 0 : failures + 1
                let delay = Self.retryDelay(after: failure, failures: failures, at: now())
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// A stream the server ended comes straight back; one that is refused stays
    /// quiet for as long as a poll would, since the poll reports what is wrong.
    static func retryDelay(after failure: ClaudeCloudFailure?, failures: Int, at date: Date) -> TimeInterval {
        switch failure {
        case .signedOut, .denied, .challenge, .notEnabled: return 900
        case .throttled(let until): return max(60, min(3600, until?.timeIntervalSince(date) ?? 60))
        default: return failures == 0 ? 2 : min(300, 5 * pow(2, Double(min(failures, 8) - 1)))
        }
    }
}
