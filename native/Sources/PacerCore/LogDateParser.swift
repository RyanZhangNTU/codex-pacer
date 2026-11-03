import Foundation

/// Shared formatters avoid constructing two ICU parsers for every appended record.
final class LogDateParser: @unchecked Sendable {
    private let lock = NSLock()
    private let fractional = ISO8601DateFormatter()
    private let whole = ISO8601DateFormatter()
    init() { fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }
    func parse(_ value: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return fractional.date(from: value) ?? whole.date(from: value)
    }
}
