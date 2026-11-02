import Foundation

public struct RuntimeStreamStatus: Equatable, Sendable {
    public var connected = false
    public var sourceName: String?
    public var remoteHostOnline: Bool?
    /// Nil means no source-availability evidence. False distinguishes a
    /// reachable host with a missing provider home from a transport failure.
    public var sourceAvailable: Bool?
    /// The Desktop observer is ready, but this Remote Control host has no
    /// loaded runtime session. This is idle, not a failed connection.
    public var waitingForSession = false
    public var hasConnectionFailure: Bool { !connected && !waitingForSession && sourceAvailable != false && remoteHostOnline != false }
    public var attachedThreads = 0
    public var notifications = 0
    public var fallbackScans = 0
    public var watchingLogs = false
    public var helperCpuSeconds = 0.0
    public var helperLoopIterations = 0
    public init() {}
}
