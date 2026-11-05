import Foundation

/// Foundation on Windows reports GMT as the current zone. The host passes the
/// user's IANA zone (or, without one, its current UTC offset) at launch, so
/// local days and times match the Mac engine.
enum EngineStartupTimeZone {
    static func parse(_ arguments: [String]) -> TimeZone? {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        if let name = value("--time-zone"), name.utf8.count <= 64, let zone = TimeZone(identifier: name) { return zone }
        if let text = value("--time-zone-offset"), let seconds = Int(text), abs(seconds) <= 18 * 3600 { return TimeZone(secondsFromGMT: seconds) }
        return nil
    }
}
