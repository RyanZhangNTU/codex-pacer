import Foundation

/// Reads the one line WorkBuddy logs when its custom connectors open: it
/// lists its MCP servers (`wb:mcp:list`). Pacer reads only those lines' times,
/// from the end of the log, so the guide's Custom Connector step ticks as soon
/// as the list shows, without reading WorkBuddy's window.
///
/// Each line is a JSON object with an ISO 8601 `timestamp`, on Windows and
/// the Mac alike; Windows ends lines with CRLF. WorkBuddy also lists its
/// servers once as it starts, two to thirty-odd seconds in, so the first
/// listing within a minute of its start doesn't count. It writes a few hundred
/// KB more as it starts, so the log is read back to the app's start.
package enum HarnessAppLog {
    /// How much of the log's end to read first, and at most.
    package static let tail = 256 * 1024
    package static let longestTail = 8 * 1024 * 1024
    /// How long after the app starts its own listing may come.
    package static let startupListing: TimeInterval = 60
    /// How long the guide waits for the app to show its connectors when its
    /// log doesn't say.
    package static let connectorsWait: TimeInterval = 30

    /// The page the app shows since the card opened its connectors: its custom
    /// connectors once it lists its servers, its connector market once it lists
    /// that (or after `connectorsWait` without a word), and nil while the app
    /// is still on its way there, which takes a few seconds as it starts.
    package static func view(in data: Data?, opened: Date, appStarted: Date?, now: Date) -> HarnessProgressGuide.AppView? {
        if let data, listedConnectors(in: data, after: opened, appStarted: appStarted) { return .customConnectors }
        if let data, shownMarket(in: data, after: opened) { return .connectors }
        return now.timeIntervalSince(opened) > connectorsWait ? .connectors : nil
    }

    /// Whether the app listed its connector market after `date`.
    package static func shownMarket(in data: Data, after date: Date) -> Bool {
        lines(data).contains { line in
            line.contains("[MethodCh] begin #") && line.contains(" wb:connectors:listMarket") && (time(of: line).map { $0 > date } ?? false)
        }
    }

    /// Whether the app listed its MCP servers after `date`, apart from the
    /// listing it makes as it starts.
    package static func listedConnectors(in data: Data, after date: Date, appStarted: Date? = nil) -> Bool {
        let floor = appStarted.map { min(date, $0) } ?? date
        var times: [Date] = []
        for line in lines(data) where line.contains("[MethodCh] begin #") && line.contains(" wb:mcp:list") {
            guard let time = time(of: line), time > floor else { continue }
            times.append(time)
        }
        if let appStarted, let first = times.first, first.timeIntervalSince(appStarted) < startupListing { times.removeFirst() }
        return times.contains { $0 > date }
    }

    /// The end of the app's log, or nil when it can't be read. With `since`, it
    /// reaches back to that time: from the last 256 KB, doubling while its
    /// first line is later, up to 8 MB. As WorkBuddy starts, its chatter can
    /// push its own listing out of the last 256 KB, and the user's click would
    /// then pass for it.
    package static func read(_ file: URL, since: Date? = nil) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        var length = UInt64(tail)
        while true {
            let start = size > length ? size - length : 0
            guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
            guard start > 0, length < UInt64(longestTail), let since,
                  let first = lines(data.prefix(64 * 1024)).dropFirst().lazy.compactMap(time(of:)).first, first > since else { return data }
            length *= 2
        }
    }

    // Windows lines end in CRLF, which Swift reads as one character, not "\n".
    private static func lines(_ data: Data) -> [Substring] {
        String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
    }

    private static func time(of line: Substring) -> Date? {
        guard let start = line.range(of: "\"timestamp\":\""), let end = line[start.upperBound...].firstIndex(of: "\"") else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: String(line[start.upperBound..<end]))
    }
}
