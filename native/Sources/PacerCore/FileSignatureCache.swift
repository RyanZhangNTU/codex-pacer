import Foundation

/// Reuses a value derived from one file until its identity, size or
/// modification time changes. Polling paths call this instead of reparsing.
final class FileSignatureCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (signature: [Double], value: Value)] = [:]

    func value(for file: URL, compute: () -> Value) -> Value {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let signature = [(attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1,
                         (attributes?[.size] as? NSNumber)?.doubleValue ?? -1,
                         (attributes?[.systemFileNumber] as? NSNumber)?.doubleValue ?? -1]
        lock.lock()
        if let entry = entries[file.path], entry.signature == signature { lock.unlock(); return entry.value }
        lock.unlock()
        let value = compute()
        lock.lock(); if entries.count >= 16 { entries.removeAll() }; entries[file.path] = (signature, value); lock.unlock()
        return value
    }
}
