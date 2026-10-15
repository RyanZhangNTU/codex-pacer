import Darwin
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

    public static func holder(for sessionID: String, claudeHome: URL, currentProcess: pid_t = getpid(),
                              processStart: (pid_t) -> Date? = processStartDate) -> pid_t? {
        guard sessionID.count == 36, let session = UUID(uuidString: sessionID) else { return nil }
        return holders(claudeHome: claudeHome, currentProcess: currentProcess,
                       processStart: processStart)[session.uuidString.lowercased()]
    }

    /// Every verified live holder, keyed by lowercase session UUID; the first
    /// record by file name wins. Mirrors the CLI's holder rule: a record needs a
    /// kind, and a parked interactive record does not hold its session.
    /// `procStart` must match the live process, so a stale record whose PID was
    /// reused is never trusted.
    public static func holders(claudeHome: URL, currentProcess: pid_t = getpid(),
                               processStart: (pid_t) -> Date? = processStartDate) -> [String: pid_t] {
        guard claudeHome.isFileURL, claudeHome.path.hasPrefix("/") else { return [:] }
        var result: [String: pid_t] = [:]
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let directory = claudeHome.appendingPathComponent("sessions", isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys),
                                                                   options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "json" && $0.deletingPathExtension().lastPathComponent.range(
                of: #"^[1-9][0-9]{0,9}\z"#, options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(256)
        for file in files {
            guard let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? .max) <= recordLimit,
                  let data = try? Data(contentsOf: file), data.count <= recordLimit,
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  String(record.pid) == file.deletingPathExtension().lastPathComponent, record.pid != currentProcess,
                  record.sessionId.count == 36, let session = UUID(uuidString: record.sessionId)?.uuidString.lowercased(),
                  result[session] == nil, record.kind?.isEmpty == false,
                  !(record.kind == "interactive" && record.parkedJobId != nil),
                  let recorded = record.procStart.flatMap(startDate(lstart:)),
                  let started = processStart(record.pid), abs(started.timeIntervalSince(recorded)) <= 1 else { continue }
            result[session] = record.pid
        }
        return result
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

    /// Walks up from the holder to the first process `isApplication` accepts:
    /// the terminal, editor or app that embeds Claude Code and shows the session.
    public static func owner(of pid: pid_t, currentProcess: pid_t = getpid(), isApplication: (pid_t) -> Bool,
                             parent: (pid_t) -> pid_t? = parentProcess) -> pid_t? {
        var current = pid, visited = Set<pid_t>()
        for _ in 0..<32 {
            guard current > 1, current != currentProcess, visited.insert(current).inserted else { return nil }
            if isApplication(current) { return current }
            guard let next = parent(current) else { return nil }
            current = next
        }
        return nil
    }

    public static func processStartDate(_ pid: pid_t) -> Date? {
        information(pid).map { Date(timeIntervalSince1970: TimeInterval($0.kp_proc.p_starttime.tv_sec)) }
    }

    public static func parentProcess(_ pid: pid_t) -> pid_t? {
        information(pid).map { $0.kp_eproc.e_ppid }
    }

    /// `proc_pidinfo` is denied for the root-owned `login` that Terminal and
    /// iTerm place above each shell; the process table is readable.
    private static func information(_ pid: pid_t) -> kinfo_proc? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.stride,
              info.kp_proc.p_pid == pid else { return nil }
        return info
    }
}
