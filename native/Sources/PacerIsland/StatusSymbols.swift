import PacerCore

/// One outline family for every state. Shapes stay distinct without color:
/// work states are open glyphs, attention uses a bubble or hand, endings a
/// circled mark, and quota uses a gauge rather than a battery. Starting avoids
/// a bare circle, which reads as an empty control inside tiles and the badge ring.
enum StatusSymbols {
    static let thinking = "sparkle"
    static let tool = "terminal"
    static let replying = "text.bubble"
    static let starting = "hourglass"
    static let idle = "moon"
    static let input = "ellipsis.bubble"
    static let approval = "hand.raised"
    static let complete = "checkmark.circle"
    static let interrupted = "pause.circle"
    static let failed = "xmark.circle"
    static let low = "gauge.with.dots.needle.33percent"
    static let empty = "gauge.with.dots.needle.0percent"
    static let freshness = "clock.arrow.circlepath"
    static let sshWarning = "network.slash"

    static func symbol(for activity: SessionActivity, attention: PendingAttentionRequest.Kind? = nil) -> String {
        if let attention { return attention == .approval ? approval : input }
        switch activity.phase {
        case .waitingForInput: return activity.waitingForApproval ? approval : input
        case .completed: return complete
        case .interrupted: return activity.turnFailed ? failed : interrupted
        case .unknown: return idle
        case .running:
            switch activity.stage {
            case .thinking: return thinking
            case .tool: return tool
            case .responding: return replying
            case .starting: return starting
            }
        }
    }
}
