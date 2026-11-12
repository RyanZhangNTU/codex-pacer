import Foundation

/// Claude Code registers each running process as `<home>/sessions/<pid>.json`.
/// Pacer reads it only to find the app that started a session: the first
/// regular application above that process.
public enum ClaudeLiveSessionRegistry {
    private struct Record: Decodable {
        let pid: Int32
        let sessionId: String
        let kind: String?
        let procStart: String?
        let parkedJobId: String?
    }

    private static let recordLimit = 64 * 1024

    public static func holder(for sessionID: String, claudeHome: URL, currentProcess: Int32,
                              files: any PlatformFileSystem, processStart: (Int32) -> Date?) -> Int32? {
        guard sessionID.count == 36, let session = UUID(uuidString: sessionID) else { return nil }
        return holders(sessions: [session.uuidString.lowercased()], claudeHome: claudeHome, currentProcess: currentProcess,
                       files: files, processStart: processStart)[session.uuidString.lowercased()]
    }

    /// Verified live holders, optionally restricted to the requested session UUIDs.
    /// A resumed session can have two live records while the old process exits.
    /// Prefer the newest verified process, breaking ties by file name.
    /// A record needs a kind, and a parked interactive record does not hold its session.
    /// `procStart` must match the live process, so a stale record whose PID was
    /// reused is never trusted.
    public static func holders(sessions: Set<String>? = nil, claudeHome: URL, currentProcess: Int32,
                               files: any PlatformFileSystem, processStart: (Int32) -> Date?) -> [String: Int32] {
        guard claudeHome.isFileURL, sessions?.isEmpty != true else { return [:] }
        let requested = sessions.map { Set($0.map { $0.lowercased() }) }
        var result: [String: (pid: Int32, started: Date)] = [:]
        let directory = claudeHome.appendingPathComponent("sessions", isDirectory: true)
        let candidates = ((try? files.entries(in: directory)) ?? [])
            .filter { $0.pathExtension == "json" && $0.deletingPathExtension().lastPathComponent.range(
                of: #"^[1-9][0-9]{0,9}\z"#, options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(256)
        for file in candidates {
            guard let metadata = files.metadata(file), metadata.isRegularFile, metadata.size <= recordLimit,
                  let data = try? files.read(file, offset: 0, maximumBytes: recordLimit + 1), data.count <= recordLimit,
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  String(record.pid) == file.deletingPathExtension().lastPathComponent, record.pid != currentProcess,
                  record.sessionId.count == 36, let session = UUID(uuidString: record.sessionId)?.uuidString.lowercased(),
                  requested?.contains(session) != false, record.kind?.isEmpty == false,
                  !(record.kind == "interactive" && record.parkedJobId != nil),
                  let recorded = record.procStart.flatMap(startDate(lstart:)),
                  let started = processStart(record.pid), abs(started.timeIntervalSince(recorded)) <= 1 else { continue }
            if let previous = result[session], previous.started >= started { continue }
            result[session] = (record.pid, started)
        }
        return result.mapValues { $0.pid }
    }

    /// The CLI records `ps -o lstart=` with `LC_ALL=C TZ=UTC`, e.g.
    /// `Mon Oct  5 07:50:29 2026`.
    static func startDate(lstart: String) -> Date? {
        let fields = lstart.split(whereSeparator: \.isWhitespace)
        guard lstart.utf8.count <= 64, fields.count == 5 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: fields.joined(separator: " "))
    }

}
