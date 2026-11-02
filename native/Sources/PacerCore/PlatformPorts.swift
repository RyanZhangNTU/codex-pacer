import Foundation

/// System facts and IO only. Callers retain limits, validation and lifecycle policy.
public protocol PlatformFileSystem: Sendable {
    func metadata(_ url: URL, followingSymbolicLinks: Bool) -> PlatformFileMetadata?
    func read(_ url: URL, offset: UInt64, maximumBytes: Int) throws -> Data
    func replace(_ url: URL, with data: Data) -> Bool
}

extension PlatformFileSystem {
    /// Describes the directory entry itself, including a symbolic link.
    public func metadata(_ url: URL) -> PlatformFileMetadata? {
        metadata(url, followingSymbolicLinks: false)
    }
}

public struct PlatformFileMetadata: Equatable, Sendable {
    public let identity: String
    public let size: UInt64
    public let modified: Date
    public let created: Date?
    public let isRegularFile: Bool
    public init(identity: String, size: UInt64, modified: Date, created: Date?, isRegularFile: Bool) {
        self.identity = identity; self.size = size; self.modified = modified
        self.created = created; self.isRegularFile = isRegularFile
    }
}

public protocol PlatformCredentialStore: Sendable {
    func read() -> Data?
    var exists: Bool { get }
    func save(_ data: Data) -> Bool
    func remove()
}

public protocol ProviderInstallationProbe: Sendable {
    func detect() -> ProviderInstallationDetection
}

public protocol ApplicationCatalog: Sendable {
    func locations(for provider: AgentProvider, userHome: URL) -> [URL]
    func isApplication(_ url: URL, provider: AgentProvider) -> Bool
}

public struct ExecutableSearchPath: Sendable {
    public let url: URL
    public let source: String
    public init(url: URL, source: String) { self.url = url; self.source = source }
}

public enum ExecutableSelectionKind: Equatable, Sendable { case file, directory }

public protocol LocalPathRules: Sendable {
    func normalize(_ input: String, userHome: URL) -> String
    func isAbsolutePath(_ path: String) -> Bool
}

public protocol ExecutablePlatform: LocalPathRules {
    func searchPaths(environment: [String: String], userHome: URL,
                     applicationURLs: [URL]?, systemBinDirectories: [String]?) -> [ExecutableSearchPath]
    func isExecutableFile(_ url: URL) -> Bool
    func executableIdentity(_ url: URL) -> String
    func selectionKind(_ url: URL) -> ExecutableSelectionKind?
    func selectionURLs(_ url: URL, isDirectory: Bool) -> [URL]
    func launchEnvironment(for executable: URL, inherited: [String: String], userHome: URL) -> [String: String]
}

public struct ChildProcessRequest: Sendable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public init(executable: URL, arguments: [String], environment: [String: String]) {
        self.executable = executable; self.arguments = arguments; self.environment = environment
    }
}

public protocol ChildProcessConnection: AnyObject, Sendable {
    func write(_ data: Data) throws
    var isRunning: Bool { get }
    var terminationStatus: Int32? { get }
    func errorMessage() -> String
    var exited: ShutdownSignal { get }
    var ioClosed: ShutdownSignal { get }
    /// Stops IO and terminates only the owned child. Repeated closes are harmless.
    func close()
    /// Escalates only the owned child, independently of blocked IO cleanup.
    func terminateImmediately()
}

extension ChildProcessConnection {
    @discardableResult public func waitForExit(until deadline: ShutdownDeadline = ShutdownDeadline()) async -> Bool {
        await exited.wait(until: deadline)
    }
}

public protocol ChildProcessLauncher: Sendable {
    func launch(_ request: ChildProcessRequest, output: @escaping @Sendable (Data) -> Void,
                ended: @escaping @Sendable () -> Void) throws -> any ChildProcessConnection
}

/// Cancellation and descriptor access are serialized by the platform reader.
public final class PipeChunkReader: @unchecked Sendable {
    private let readBytes: @Sendable () -> Data?
    private let stopReading: @Sendable () -> Void
    public init(read: @escaping @Sendable () -> Data?, stop: @escaping @Sendable () -> Void) {
        readBytes = read; stopReading = stop
    }
    public func read() -> Data? { readBytes() }
    public func stop() { stopReading() }
    public func pausingHandler(_ continuation: AsyncStream<Data>.Continuation) -> @Sendable (FileHandle) -> Void {
        { [self] handle in
            guard let data = read() else { return }
            handle.readabilityHandler = nil
            if data.isEmpty { continuation.finish() }
            else if case .dropped = continuation.yield(data) { continuation.finish() }
        }
    }
}

/// Bounded stderr collection is shared; the platform supplies byte reads.
public final class ProcessErrorCollector: @unchecked Sendable {
    private let reader: PipeChunkReader
    private let lock = NSLock()
    private var tail = Data()
    public init(reader: PipeChunkReader) { self.reader = reader }
    @discardableResult public func drain() -> Bool {
        for _ in 0..<4 {
            guard let data = reader.read() else { return true }
            guard !data.isEmpty else { return false }
            lock.lock(); tail.append(data)
            if tail.count > 8192 { tail = Data(tail.suffix(8192)) }
            lock.unlock()
        }
        return true
    }
    public func message() -> String {
        drain()
        lock.lock(); defer { lock.unlock() }
        let sanitized = CodexDiagnosticText.sanitized(String(decoding: tail, as: UTF8.self), limit: 32768)
        return sanitized.count > 1200 ? L10n.text("diagnostic.older_omitted", String(sanitized.suffix(1200))) : sanitized
    }
    public func stop() { reader.stop() }
}
