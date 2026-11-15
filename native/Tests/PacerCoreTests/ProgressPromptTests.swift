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
        // Codex (and WorkBuddy on Windows), Claude's plugin tool and DeepSeek describe their tool alike.
        let description = quoted(ProgressPrompt.toolDescription)
        for name in ["codex_progress_mcp.py", "claude_progress_mcp.py", "deepseek-progress.mjs"] {
            XCTAssertTrue(try resource(name).contains(description), name)
        }
        // Claude's hook builds its line from the same parts.
        let hook = try resource("claude_hook.py")
        for part in [ProgressPrompt.template, ProgressPrompt.deferredTemplate, ProgressPrompt.everyStep, ProgressPrompt.markerTemplate] {
            XCTAssertTrue(hook.contains(quoted(part)), part)
        }
        XCTAssertTrue(hook.contains("'after it moves '+mode[5:]+' points or more'"))
        XCTAssertEqual(ProgressPrompt.pointsStep(15), "after it moves 15 points or more")
        // WorkBuddy's rule names its tool, which may load on demand.
        XCTAssertTrue(String(decoding: LocalHarnessProgressSetup.rule, as: UTF8.self)
            .contains(ProgressPrompt.ask(tool: "`mcp__pacer_progress__report_progress`") + "\n"))
    }

    func testTheWordsAskOnlyForTheNumberInAConcreteRhythm() {
        let line = ProgressPrompt.ask(tool: "mcp__plugin_pacer_pacer__report_progress")
        // The first report comes before or with the first other call, so the ring shows at once.
        XCTAssertTrue(line.contains("done with mcp__plugin_pacer_pacer__report_progress: first, before or with your first other tool call, even if the estimate is still low; again whenever the estimate changes and at least every 5 tool calls while you work; and before you stop to wait"))
        XCTAssertTrue(line.hasSuffix(" If mcp__plugin_pacer_pacer__report_progress is deferred, find it with tool search first."))
        XCTAssertTrue(ProgressPrompt.toolDescription.contains("with this tool: first, before or with your first other tool call"))
        XCTAssertTrue(ProgressPrompt.ask(tool: "x", when: ProgressPrompt.pointsStep(15)).contains("low; again after it moves 15 points or more; and before"))
        XCTAssertFalse(ProgressPrompt.toolDescription.contains("deferred"), "A tool reading its own description is loaded")
        XCTAssertFalse(line.contains("{"))
        // "At milestones" got one report at the start and one at the end (11/15).
        XCTAssertFalse((line + ProgressPrompt.toolDescription).lowercased().contains("milestone"))
    }
}
