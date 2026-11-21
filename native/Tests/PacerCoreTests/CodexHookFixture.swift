import Foundation
@testable import PacerCore

/// Names rollouts in Pacer's hook spool, as Codex's hooks do when a turn starts,
/// so `LocalActivityReader` follows them. Rows carry only identifiers and paths.
enum CodexHookFixture {
    static func announce(_ rollouts: [URL], home: URL, event: String = "UserPromptSubmit", turn: String? = nil,
                         approval: String? = nil, at date: Date = Date()) throws {
        let folder = CodexHookSpool.folder(home: home)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var data = (try? Data(contentsOf: CodexHookSpool.current(home: home))) ?? Data()
        for url in rollouts {
            let row: [String: Any] = ["v": 1, "hook": 1, "at": date.timeIntervalSince1970, "event": event, "thread": thread(of: url),
                                      "turn": turn ?? NSNull(), "agent": NSNull(), "agentType": NSNull(), "transcript": url.path,
                                      "agentTranscript": NSNull(), "approval": approval ?? NSNull(), "reason": NSNull()]
            data += try JSONSerialization.data(withJSONObject: row) + Data([10])
        }
        try data.write(to: CodexHookSpool.current(home: home))
    }

    /// Every rollout under the home's sessions tree.
    static func announceAll(home: URL, at date: Date = Date()) throws {
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        let files = (FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "jsonl" }
        try announce(files, home: home, at: date)
    }

    /// The rollout's thread ID, or its name reduced to the hook's identifier grammar.
    static func thread(of url: URL) -> String {
        if let thread = CodexRolloutName.threadID(of: url) { return thread }
        let name = String(url.deletingPathExtension().lastPathComponent.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) }.map(Character.init))
        return name.first.map { $0.isLetter || $0.isNumber } == true ? String(name.prefix(256)) : "t" + String(name.prefix(255))
    }
}
