import Foundation
@testable import PacerCore

/// Names rollouts in Pacer's hook spool, as Codex's hooks do, so the engine's
/// `LocalActivityReader` follows them; the same rows as Core's test fixture.
/// Rows carry only identifiers and paths.
enum CodexHookFixture {
    static func announce(_ rollouts: [URL], home: URL, event: String = "UserPromptSubmit", turn: String? = nil, at date: Date = Date()) throws {
        try append(rollouts.map { url in
            ["v": 1, "hook": 1, "at": date.timeIntervalSince1970, "event": event, "thread": thread(of: url),
             "turn": turn ?? NSNull(), "transcript": url.path]
        }, home: home)
    }

    /// A row naming the rollout exactly as `transcript` spells it, as Codex may.
    static func announce(transcript: String, thread: String, home: URL, event: String = "UserPromptSubmit", turn: String? = nil,
                         at date: Date = Date()) throws {
        try append([["v": 1, "hook": 1, "at": date.timeIntervalSince1970, "event": event, "thread": thread,
                     "turn": turn ?? NSNull(), "transcript": transcript]], home: home)
    }

    /// A subagent row: the parent's thread names the child, whose rollout is found next to the parent's.
    static func subagent(_ child: URL, parent: URL, home: URL, event: String = "SubagentStart", at date: Date = Date()) throws {
        try append([["v": 1, "hook": 1, "at": date.timeIntervalSince1970, "event": event, "thread": thread(of: parent),
                     "agent": thread(of: child), "agentTranscript": event == "SubagentStop" ? child.path : NSNull()]], home: home)
    }

    /// Every rollout under the home's sessions tree.
    static func announceAll(home: URL, at date: Date = Date()) throws {
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        let files = (FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "jsonl" }
        try announce(files, home: home, at: date)
    }

    /// Appends to the spool in place, as the hook does under its lock.
    private static func append(_ rows: [[String: Any]], home: URL) throws {
        try FileManager.default.createDirectory(at: CodexHookSpool.folder(home: home), withIntermediateDirectories: true)
        var data = Data()
        for row in rows { data += try JSONSerialization.data(withJSONObject: row) + Data([10]) }
        let spool = CodexHookSpool.current(home: home)
        guard let handle = try? FileHandle(forWritingTo: spool) else { return try data.write(to: spool) }
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }

    private static func thread(of url: URL) -> String { CodexRolloutName.threadID(of: url) ?? url.deletingPathExtension().lastPathComponent }
}
