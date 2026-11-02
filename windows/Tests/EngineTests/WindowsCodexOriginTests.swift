#if os(Windows)
import Foundation
import XCTest
@testable import PacerCore

final class WindowsCodexOriginTests: XCTestCase {
    func testWindowsBackgroundPathsRespectSeparatorsCaseAndOfficialClients() {
        let paths = [#"C:\Demo\zotero-chat\translate"#, #"C:\DEMO\ZOTERO-CHAT\TRANSLATE\"#,
            #"\\server\share\zotero-chat\translate"#, #"C:\Demo/zotero-chat\translate"#,
            #"C:\Demo\zotero-chat-catalog.synthetic"#, "C:/Demo/zotero-chat/translate"]
        for path in paths {
            let embedded = CodexSessionOrigin.classify(originator: "@agentclientprotocol/codex-acp", cwd: path)
            XCTAssertEqual(embedded, .init(embedded: true, ignored: true), path)
            for client in CodexSessionOrigin.officialClients {
                XCTAssertEqual(CodexSessionOrigin.classify(originator: client, cwd: path), .init(embedded: false, ignored: false), client)
            }
        }
        for path in [#"C:\Demo\Zotero-Agent"#, #"C:\Demo\translate"#, #"C:\Demo\zotero-chat\translate-session"#] {
            XCTAssertEqual(CodexSessionOrigin.classify(originator: "@agentclientprotocol/codex-acp", cwd: path), .init(embedded: true, ignored: false), path)
        }
        XCTAssertEqual(CodexSessionOrigin.classify(originator: "@agentclientprotocol/codex-acp", cwd: "/tmp/ZOTERO-CHAT/TRANSLATE"),
            .init(embedded: true, ignored: false), "Remote POSIX paths must retain the original case-sensitive policy")
    }

    func testWindowsBackgroundRolloutsDoNotConsumeReaderSlotsOrWatches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-win-origin-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(), formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"
        let folder = root.appendingPathComponent("sessions/" + formatter.string(from: now))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func write(_ number: Int, client: String, cwd: String) throws -> URL {
            let id = String(format: "019a0000-0000-7000-8000-%012d", number)
            let row: [String: Any] = ["type": "session_meta", "timestamp": ISO8601DateFormatter().string(from: now),
                "payload": ["id": id, "originator": client, "cwd": cwd, "source": "cli"]]
            let file = folder.appendingPathComponent("rollout-" + id + ".jsonl")
            var data = try JSONSerialization.data(withJSONObject: row); data.append(10); try data.write(to: file); return file
        }
        var ignored: Set<URL> = []
        for number in 1...40 {
            ignored.insert(try write(number, client: "@agentclientprotocol/codex-acp", cwd:
                number.isMultiple(of: 2) ? #"C:\Demo\zotero-chat\translate"# : #"\\server\share\ZOTERO-CHAT-CATALOG.synthetic"#))
        }
        let official = try write(99, client: "codex-tui", cwd: #"C:\Demo\zotero-chat\translate"#)
        let reader = LocalActivityReader(), result = await reader.read(home: root, now: now)
        XCTAssertEqual(result.activities.count, 1)
        XCTAssertEqual(result.activities.first?.threadID, "019a0000-0000-7000-8000-000000000099")
        XCTAssertFalse(result.activities.first?.isIgnoredCodexSession ?? true)
        XCTAssertTrue(ignored.isDisjoint(with: Set(result.watchURLs)))
        XCTAssertTrue(result.watchURLs.contains(official)); XCTAssertEqual(result.excludedIDs.count, ignored.count)
    }
}
#endif
