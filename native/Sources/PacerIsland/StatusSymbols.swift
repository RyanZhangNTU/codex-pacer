import PacerCore

/// Native symbols selected in the local design review.
enum StatusSymbols {
    static let thinking = "brain.head.profile"
    static let tool = "hammer.fill"
    static let replying = "text.bubble.fill"
    static let starting = "play.circle"
    static let idle = "moon.zzz"
    static let input = "questionmark.bubble.fill"
    static let approval = "lock.shield"
    static let complete = "checkmark.seal.fill"
    static let interrupted = "pause.circle.fill"
    static let failed = "xmark.circle.fill"
    static let low = "battery.25percent"
    static let empty = "battery.0percent"
    static let freshness = "clock.badge.exclamationmark"

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
