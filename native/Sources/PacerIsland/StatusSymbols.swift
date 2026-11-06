import PacerCore

/// One outline family for every state. Shapes stay distinct without color:
/// work states are open glyphs, attention uses a bubble or hand and endings a
/// circled mark. Quota warnings are drawn 5h capsules. Starting avoids a bare
/// circle, which reads as an empty control inside tiles and the badge ring.
enum StatusSymbols {
    static let thinking = "sparkle"
    static let tool = "terminal"
    static let replying = "text.bubble"
    static let starting = "hourglass"
    static let cloudWork = "cloud"
    static let coordinating = "arrow.triangle.branch"
    /// A turn paused while its background work runs; it resumes on the wake.
    static let backgroundWait = "zzz"
    static let idle = "moon"
    static let input = "ellipsis.bubble"
    static let approval = "hand.raised"
    static let complete = "checkmark.circle"
    static let interrupted = "pause.circle"
    static let failed = "xmark.circle"
    static let freshness = "clock.arrow.circlepath"
    static let sshWarning = "network.slash"

    /// A glyph drawn inside a badge drops its own outer circle.
    static func enclosed(_ name: String) -> String {
        name.hasSuffix(".circle") ? String(name.dropLast(".circle".count)) : name
    }

    static func symbol(for activity: SessionActivity, attention: PendingAttentionRequest.Kind? = nil) -> String {
        symbol(TaskSymbol.symbol(for: activity, attention: attention))
    }
    static func symbol(_ kind: TaskSymbol) -> String {
        switch kind {
        case .thinking: thinking
        case .tool: tool
        case .responding: replying
        case .starting: starting
        case .working: cloudWork
        case .coordinating: coordinating
        case .background: backgroundWait
        case .approval: approval
        case .input: input
        case .completed: complete
        case .interrupted: interrupted
        case .failed: failed
        case .unknown: idle
        }
    }
}
