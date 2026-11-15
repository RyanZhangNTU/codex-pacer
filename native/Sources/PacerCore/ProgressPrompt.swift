import Foundation

/// The one way Pacer asks an agent for its progress estimate, in every module:
/// Claude's per-request line, each reporter's tool description and server
/// instructions (Claude, Codex, DeepSeek, WorkBuddy) and WorkBuddy's rule.
/// The Python and JavaScript reporters and the Claude hook hold copies of
/// this text, checked word for word by `ProgressPromptTests`; change it here
/// and in every copy together.
///
/// It asks only for the number, with a concrete rhythm: the first tool
/// calls, every change and at least every five tool calls, and before
/// stopping to wait, in the same batch as the other calls. Wording such as
/// "at milestones" got one report at the start and one at the end.
package enum ProgressPrompt {
    package static let template = "The user turned on Pacer's progress ring and asks you to report your best estimate of how much of their current request is done with {tool}: with your first tool calls, again {when}, and before you stop to wait for background work or for the user. Send each report in the same batch as your other tool calls. Always give a whole number from 0 to 100, and lower it if the work turns out larger. Skip replies that need no tools."
    /// Where the tool may load only on demand: Claude's line and WorkBuddy's rule.
    package static let deferredTemplate = " If {tool} is deferred, find it with tool search first."
    package static let everyStep = "whenever the estimate changes and at least every 5 tool calls while you work"
    /// Claude's ring can ask for a report only after a change of some points.
    package static func pointsStep(_ points: Int) -> String { "after it moves \(points) points or more" }
    /// Claude's marker mode asks for the estimate at the start of each message instead.
    package static let markerTemplate = "The user turned on Pacer's progress ring and asks that every message you write start with {marker}, your best estimate of how much of their current request is done. Always give a whole number from 0 to 100, and lower it if the work turns out larger."

    package static func ask(tool: String, when: String = everyStep, deferred: Bool = true) -> String {
        (template + (deferred ? deferredTemplate : "")).replacingOccurrences(of: "{tool}", with: tool)
            .replacingOccurrences(of: "{when}", with: when)
    }

    /// A reporter's own tool description and server instructions.
    package static let toolDescription = ask(tool: "this tool", deferred: false)
}
