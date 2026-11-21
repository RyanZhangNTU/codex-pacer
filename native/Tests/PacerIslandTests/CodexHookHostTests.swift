import XCTest
@testable import PacerCore
@testable import PacerIsland
import PacerTestSupport

/// The Mac host around Pacer's Codex hooks: which rollouts it watches, when it
/// recomputes the hooks' status, and which Codex home it installs them in.
@MainActor
final class CodexHookHostTests: XCTestCase {
    private let first = "019a0000-0000-7000-8000-0000000000a1"
    private let resumed = "019a0000-0000-7000-8000-0000000000a2"

    private func temporaryHome(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-\(label)-" + UUID().uuidString, isDirectory: true)
        let home = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return home
    }

    private func model(home: URL) throws -> IslandModel {
        let domain = testDefaultsName("CodexHookHostTests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        addTeardownBlock { removeTestDefaults(domain) }
        ProviderModules(codexMode: .enabled, claudeMode: .disabled, deepseekMode: .disabled).save(to: defaults)
        defaults.set(home.path, forKey: "codexHome")
        defaults.set(false, forKey: "monitorSSH"); defaults.set(false, forKey: IslandModel.monitorsDurableKey)
        defaults.set(false, forKey: "systemNotifications")
        let model = IslandModel(demo: false, defaults: defaults, installation: .init(codexInstalled: true, claudeInstalled: false),
            completionDismissalStore: CompletionDismissalStore(fileURL: home.deletingLastPathComponent().appendingPathComponent("dismissals.json")))
        model.hostApplicationResolver = { _, _, _ in [:] }
        addTeardownBlock { await model.shutdown() }
        return model
    }

    private func line(_ type: String, _ payload: [String: Any], at date: Date) throws -> Data {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": formatter.string(from: date), "payload": payload]) + Data([10])
    }

    /// A rollout with a running turn in the given day folder.
    private func rollout(_ thread: String, day: String, home: URL, at date: Date) throws -> URL {
        let folder = home.appendingPathComponent("sessions/" + day, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("rollout-2026-11-21T10-00-00-\(thread).jsonl")
        try (line("session_meta", ["id": thread, "originator": "Codex Desktop", "cwd": "/fixture"], at: date)
            + line("event_msg", ["type": "task_started", "turn_id": "turn-1"], at: date)).write(to: file)
        return file
    }

    /// Appends one UserPromptSubmit row naming `rollout`, as Pacer's hook does.
    private func announce(_ rollout: URL, thread: String, home: URL, at date: Date) throws {
        let spool = CodexHookSpool.current(home: home)
        try FileManager.default.createDirectory(at: spool.deletingLastPathComponent(), withIntermediateDirectories: true)
        let row: [String: Any] = ["v": 1, "hook": 1, "at": date.timeIntervalSince1970, "event": "UserPromptSubmit", "thread": thread,
                                  "turn": "turn-1", "agent": NSNull(), "agentType": NSNull(), "transcript": rollout.path,
                                  "agentTranscript": NSNull(), "approval": NSNull(), "reason": NSNull()]
        let data = try JSONSerialization.data(withJSONObject: row) + Data([10])
        if let handle = try? FileHandle(forWritingTo: spool) {
            try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.close()
        } else {
            try data.write(to: spool)
        }
    }

    private func append(_ data: Data, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.close()
    }

    func testARolloutAHookNamesInASpoolAppendIsWatchedForItsNextWrite() async throws {
        let home = try temporaryHome("codex-watch")
        let model = try model(home: home)
        let start = Date().addingTimeInterval(-30)
        let today = try rollout(first, day: "2026/11/21", home: home, at: start)
        try announce(today, thread: first, home: home, at: start)
        model.refreshActivity()
        try await TestWait.until { model.activities.contains { $0.threadID == self.first } }
        XCTAssertTrue(model.watchedLogURLs.contains(CodexHookSpool.current(home: home)))

        // A week-old conversation continues: only the spool's append names its rollout,
        // and the read that append causes is a metrics read.
        let older = try rollout(resumed, day: "2026/11/14", home: home, at: start.addingTimeInterval(1))
        try announce(older, thread: resumed, home: home, at: start.addingTimeInterval(1))
        model.refreshActivity(metricsOnly: true)
        try await TestWait.until { model.activities.contains { $0.threadID == self.resumed } }
        let watched = try await TestWait.until { model.watchedLogURLs.contains(older.standardizedFileURL) || model.watchedLogURLs.contains(older) }
        XCTAssertTrue(watched, "The rollout found by the metrics read is watched")

        // Only that rollout changes now: Codex asks the user a question. No hook row, no panel.
        let question = #"{"questions":[{"title":"PRIVATE question","options":["PRIVATE option"]}]}"#
        try append(line("response_item", ["type": "function_call", "name": "request_user_input_async", "call_id": "call-1", "arguments": question],
                        at: start.addingTimeInterval(2))
                   + line("response_item", ["type": "function_call_output", "call_id": "call-1", "output": #"{"accepted":true}"#],
                          at: start.addingTimeInterval(3)), to: older)
        let asked = try await TestWait.until { model.pendingInputRequests.contains { $0.threadID == self.resumed } }
        XCTAssertTrue(asked, "The question shows from the rollout's own file event")
    }
}
