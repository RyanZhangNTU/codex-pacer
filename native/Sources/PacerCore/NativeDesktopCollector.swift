import Foundation

/// The same handshake, retry, heartbeat, batching and EOF rules serve both IO
/// drivers. A host waits for bytes, cancellation or `nextServiceDate`.
public struct DesktopCollectionSession {
    public enum Failure: Error { case handshakeTimedOut }
    private var session: NativeDesktopSession
    private let opened: Date
    private var interval: TimeInterval
    private var lastFlush = Date.distantPast
    private var nextStatus = Date.distantPast
    private var iterations = 0
    public init(hosts: Set<String>, localRuntime: Bool = true, batchInterval: TimeInterval = 5,
                at now: Date = Date(), localOrigin: @escaping (String) -> CodexRolloutMetadata? = { _ in nil },
                send: @escaping ([String: Any]) throws -> Void) throws {
        session = try NativeDesktopSession(hosts: hosts, localRuntime: localRuntime, send: send)
        session.localOrigin = localOrigin; opened = now
        interval = min(5, max(0.1, batchInterval))
    }
    public var observedTurnIDs: Set<String> { session.observedTurnIDs }
    public var hosts: Set<String> { session.hosts }
    public mutating func setHosts(_ hosts: Set<String>, resetting removed: Set<String> = [], at now: Date = Date()) throws {
        try session.setHosts(hosts, resetting: removed, at: now)
    }
    public mutating func setBatchInterval(_ value: TimeInterval, flushPending: Bool = false, at now: Date = Date()) throws {
        interval = min(5, max(0.1, value))
        if flushPending, session.hasEvents { try session.publishEvents(); lastFlush = now }
    }
    public mutating func discover(_ keys: [NativeDesktopSession.Key]) throws { try session.discover(keys) }
    public mutating func setDurableCatalog(_ catalog: DurableActivityCatalog?, at now: Date = Date()) throws {
        try session.setDurableCatalog(catalog, at: now)
    }
    package var durableIPCObservations: [String: Date] { session.durableIPCObservations }
    package mutating func observeDurableHistory(_ observations: [DurableTurnHistory], scope: String, at now: Date) throws {
        try session.observeDurableHistory(observations, scope: scope, at: now)
    }
    public mutating func receive(_ bytes: Data) throws { try session.receive(bytes, projectedItems: true) }
    public mutating func service(at now: Date = Date(), discovering keys: [NativeDesktopSession.Key] = [], flushPending: Bool = false) throws {
        iterations += 1
        try session.service(at: now)
        if !keys.isEmpty { try session.discover(keys) }
        if !session.ready && now.timeIntervalSince(opened) > 5 { throw Failure.handshakeTimedOut }
        if session.hasEvents && (flushPending || now >= lastFlush.addingTimeInterval(interval)) {
            try session.publishEvents(); lastFlush = now
        }
        if now >= nextStatus { try session.status(loopIterations: iterations); nextStatus = now.addingTimeInterval(15) }
    }
    public var nextServiceDate: Date {
        var next = nextStatus
        if !session.ready { next = min(next, opened.addingTimeInterval(5)) }
        if session.hasEvents { next = min(next, lastFlush.addingTimeInterval(interval)) }
        if let service = session.nextServiceDate { next = min(next, service) }
        return next
    }
    public mutating func takeFrames() -> [Data] { session.takeFrames() }
    public mutating func finish(flush: Bool) -> [Data] {
        if flush { try? session.publishEvents() }
        let frames = session.takeFrames(); session.close(); return flush ? frames : []
    }
}
