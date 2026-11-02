import Foundation
import Darwin
import PacerCore

extension RuntimeDiagnostics {
    private static let sink = MacRuntimeDiagnosticSink()
    public static var enabled: Bool { sink.enabled }
    public static var observer: RuntimeDiagnosticObserver {
        RuntimeDiagnosticObserver(enabled: { enabled }, write: { sink.write($0) })
    }
    public static func record(_ stage: String, source: String, frame: [String: Any]? = nil,
                              activities: [SessionActivity] = [], status: RuntimeStreamStatus? = nil) {
        observer.record(stage, source: source, frame: frame, activities: activities, status: status)
    }
}
private final class MacRuntimeDiagnosticSink: @unchecked Sendable {
    let enabled = UserDefaults.standard.bool(forKey: "pacerLocalRuntimeTrace")
    private let lock = NSLock()
    private var handle: FileHandle?
    private var written = 0
    init() {
        guard enabled else { return }
        let fd = Darwin.open("/private/tmp/pacer-runtime-trace-\(getpid()).jsonl", O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
        if fd >= 0 { handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true) }
    }
    func write(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard let current = handle else { return }
        guard written + data.count <= 1024 * 1024 else { try? current.close(); handle = nil; return }
        do { try current.write(contentsOf: data); written += data.count }
        catch { try? current.close(); handle = nil }
    }
}
