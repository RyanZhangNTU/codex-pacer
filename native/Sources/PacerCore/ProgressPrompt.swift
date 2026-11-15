import Foundation

/// The one way Pacer asks an agent for its progress estimate, in every module:
/// Claude's per-request line, each reporter's tool description and server
/// instructions (Claude, Codex, DeepSeek, WorkBuddy) and WorkBuddy's rule.
/// The Python and JavaScript reporters and the Claude hook hold copies of
/// this text, checked word for word by `ProgressPromptTests`; change it here
/// and in every copy together.
///
/// It asks only for the number: first, before or with the first other tool
/// call even while the estimate is low, so the ring shows at once; then
/// whenever the agent makes progress; and before it stops to wait, in the
/// same batch as its other calls. Each accepted report's reply asks for the
/// next one. Wording such as "at milestones" got one report at the start and
/// one at the end; "with your first tool calls" let the first report come
/// late; "whenever the estimate changes" read as a re-estimate.
package enum ProgressPrompt {
    package static let template = "The user turned on Pacer's progress ring and asks you to report your best estimate of how much of their current request is done with {tool}: first, before or with your first other tool call, even if the estimate is still low; again whenever you make progress; and before you stop to wait for background work or for the user. Send each report in the same batch as your other tool calls. Always give a whole number from 0 to 100, and lower it if the work turns out larger. Skip replies that need no tools."
    /// Where the tool may load only on demand: Claude's line and WorkBuddy's rule.
    package static let deferredTemplate = " If {tool} is deferred, find it with tool search first."
    /// Every reporter's reply to an accepted estimate. It starts with the
    /// receipt Pacer reads in the agent's records, `CodexProgressEvidence.receipt`.
    package static let acknowledgement = "pacer-progress:accepted. Report again as soon as you make more progress."

    package static func ask(tool: String, deferred: Bool = true) -> String {
        (template + (deferred ? deferredTemplate : "")).replacingOccurrences(of: "{tool}", with: tool)
    }

    /// A reporter's own tool description and server instructions.
    package static let toolDescription = ask(tool: "this tool", deferred: false)
}
