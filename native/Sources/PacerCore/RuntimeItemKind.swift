import Foundation

/// Both Desktop IPC and app-server notifications reach the same state machine.
enum RuntimeItemKind {
    static func normalized(_ kind: String) -> String {
        kind == "collabAgentToolCall" ? "collabToolCall" : kind
    }
    static func isTool(_ kind: String) -> Bool {
        ["commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "collabToolCall", "webSearch", "imageView"]
            .contains(normalized(kind))
    }
}
