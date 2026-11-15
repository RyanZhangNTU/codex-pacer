import Foundation

/// Reads the one line WorkBuddy logs when its custom connectors open: it
/// lists its MCP servers (`wb:mcp:list`). Pacer reads only those lines' times,
/// from the end of the log, so the guide's Custom Connector step ticks as soon
/// as the list shows, without reading WorkBuddy's window.
///
/// Each line is a JSON object with an ISO 8601 `timestamp`, on Windows and
/// the Mac alike; Windows ends lines with CRLF. WorkBuddy also lists its servers once as it starts, two to
/// thirty-odd seconds in, so the first listing within a minute of its start
/// doesn't count.
package enum HarnessAppLog {
    /// How much of the log's end to read.
    package static let tail = 256 * 1024
    /// How long after the app starts its own listing may come.
    package static let startupListing: TimeInterval = 60

    /// Whether the app listed its MCP servers after `date`, apart from the
    /// listing it makes as it starts.
    package static func listedConnectors(in data: Data, after date: Date, appStarted: Date? = nil) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let floor = appStarted.map { min(date, $0) } ?? date
        var times: [Date] = []
        // Windows lines end in CRLF, which Swift reads as one character, not "\n".
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        where line.contains("[MethodCh] begin #") && line.contains(" wb:mcp:list") {
            guard let start = line.range(of: "\"timestamp\":\""),
                  let end = line[start.upperBound...].firstIndex(of: "\""),
                  let time = formatter.date(from: String(line[start.upperBound..<end])), time > floor else { continue }
            times.append(time)
        }
        if let appStarted, let first = times.first, first.timeIntervalSince(appStarted) < startupListing { times.removeFirst() }
        return times.contains { $0 > date }
    }

    /// The end of the app's log, or nil when it can't be read.
    package static func read(_ file: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > UInt64(tail) ? size - UInt64(tail) : 0)
        return try? handle.readToEnd()
    }
}
