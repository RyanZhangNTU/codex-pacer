import Foundation
import XCTest
@testable import PacerCore

/// Every module asks for progress in the same words: the copies in the
/// Python and JavaScript resources match `ProgressPrompt` word for word.
final class ProgressPromptTests: XCTestCase {
    private func resource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PacerCore/Resources/" + name)
        return try String(contentsOf: url, encoding: .utf8)
    }
    private func quoted(_ text: String) -> String { "\"" + text + "\"" }

    func testEveryModuleUsesTheSameWords() throws {
        // Codex (and WorkBuddy on Windows), Claude's plugin tool and DeepSeek describe their tool alike
        // and answer each accepted report with the same nudge for the next one.
        let description = quoted(ProgressPrompt.toolDescription), accepted = quoted(ProgressPrompt.acknowledgement)
        for name in ["codex_progress_mcp.py", "claude_progress_mcp.py", "deepseek-progress.mjs"] {
            let source = try resource(name)
            XCTAssertTrue(source.contains(description), name)
            XCTAssertTrue(source.contains(accepted), name)
        }
        // Claude's hook builds its line from the same parts.
        let hook = try resource("claude_hook.py")
        for part in [ProgressPrompt.template, ProgressPrompt.deferredTemplate] {
            XCTAssertTrue(hook.contains(quoted(part)), part)
        }
        // Pacer reads the receipt from agents' records; both acknowledgements count.
        XCTAssertTrue(try resource("../SessionLogProbe.swift").contains("ACKS=('" + CodexProgressEvidence.receipt + "','" + ProgressPrompt.acknowledgement + "')"))
        XCTAssertTrue(CodexProgressEvidence.isReceipt(CodexProgressEvidence.receipt))
        XCTAssertTrue(CodexProgressEvidence.isReceipt(ProgressPrompt.acknowledgement))
        XCTAssertFalse(CodexProgressEvidence.isReceipt(CodexProgressEvidence.receipt + "."), "Only the exact replies count")
        // WorkBuddy's rule names its tool, which may load on demand.
        XCTAssertTrue(String(decoding: LocalHarnessProgressSetup.rule, as: UTF8.self)
            .contains(ProgressPrompt.ask(tool: "`mcp__pacer_progress__report_progress`") + "\n"))
    }

    func testTheWordsAskOnlyForTheNumberInAConcreteRhythm() {
        let line = ProgressPrompt.ask(tool: "mcp__plugin_pacer_pacer__report_progress")
        // The first report comes before or with the first other call, so the ring shows at once.
        XCTAssertTrue(line.contains("done with mcp__plugin_pacer_pacer__report_progress: first, before or with your first other tool call, even if the estimate is still low; again whenever you make progress; and before you stop to wait"))
        XCTAssertTrue(line.hasSuffix(" If mcp__plugin_pacer_pacer__report_progress is deferred, find it with tool search first."))
        XCTAssertTrue(ProgressPrompt.toolDescription.contains("with this tool: first, before or with your first other tool call"))
        XCTAssertFalse(ProgressPrompt.toolDescription.contains("deferred"), "A tool reading its own description is loaded")
        XCTAssertFalse(line.contains("{"))
        // "At milestones" got one report at the start and one at the end, and a
        // count of tool calls read as the only reason to report (11/15).
        XCTAssertFalse((line + ProgressPrompt.toolDescription).lowercased().contains("milestone"))
        XCTAssertFalse((line + ProgressPrompt.toolDescription).contains("tool calls while"))
        // Each accepted report asks for the next one; Pacer still finds its receipt at the start.
        XCTAssertTrue(ProgressPrompt.acknowledgement.hasPrefix(CodexProgressEvidence.receipt + ". "))
        XCTAssertTrue(ProgressPrompt.acknowledgement.hasSuffix("Report again as soon as you make more progress."))
    }
}
