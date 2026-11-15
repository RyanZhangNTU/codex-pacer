import Foundation

/// The progress ring card for a module whose app must trust Pacer's tool
/// (WorkBuddy and WorkBuddy AI), worded once so the Mac and Windows draw the
/// same steps. Only the user can trust the tool, in the app itself; the card
/// takes them there and confirms the result on its own.
public struct HarnessProgressGuide: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable {
        case adding, trust, retrust, firstTask, ready, turnedOff, toolOff, openApp, conflict, failed, missing, unknown, cleanupFailed
    }
    public enum Tone: String, Codable, Sendable { case neutral, attention, info, success, error }
    public enum StepState: String, Codable, Sendable { case done, current, pending }
    public enum Action: String, Codable, Sendable { case openConnectors, openApp, retry }

    public struct Step: Codable, Equatable, Sendable {
        public let title: String
        public let state: StepState
    }

    public let stage: Stage
    public let chip: String
    public let tone: Tone
    /// The three steps while setting up; empty once ready or for a problem.
    public let steps: [Step]
    /// One short line for a problem.
    public let line: String?
    public let action: Action?
    public let actionTitle: String?
    /// The user has something to do: the sidebar dot, the Overview line, the
    /// onboarding note and the panel hint show `summary`.
    public let attention: Bool
    public let summary: String?
    /// The card is waiting on the app: hosts check again while it's on screen.
    public let waiting: Bool
    /// Draw the app's trust card beside the current step.
    public let showsTrustCard: Bool
    /// The ⓘ text.
    public let info: String

    /// - Parameters:
    ///   - ringOn: the module and its ring are both on.
    ///   - name: the app's own name, such as "WorkBuddy AI".
    package init?(setup: LocalHarnessProgressStatus?, connection: LocalHarnessProgressConnection?, reported: Bool,
                 ringOn: Bool, name: String, language: AppLanguage? = nil) {
        func text(_ key: String, _ arguments: CVarArg...) -> String { L10n.text("progress_guide." + key, arguments: arguments, language: language) }
        info = text("info", name, name, name)
        let stage: Stage
        if !ringOn {
            guard setup == .failed else { return nil }
            stage = .cleanupFailed
        } else {
            switch setup {
            case nil: return nil
            case .settingUp: stage = .adding
            case .missingHome: stage = .openApp
            case .conflict: stage = .conflict
            case .failed: stage = .failed
            case .configured:
                switch connection {
                case .needsTrust: stage = .trust
                case .retrust: stage = .retrust
                case .trusted: stage = reported ? .ready : .firstTask
                case .disabled: stage = .turnedOff
                case .toolDisabled: stage = .toolOff
                case .missing: stage = .missing
                case .unknown, nil: stage = reported ? .ready : .unknown
                }
            }
        }
        self.stage = stage
        let added = Step(title: text("step.added"), state: stage == .adding ? .current : .done)
        let trustTitle = text(stage == .retrust ? "step.retrust" : "step.trust", name)
        let firstTask = Step(title: text("step.first_task"), state: stage == .firstTask ? .current : .pending)
        switch stage {
        case .adding:
            steps = [added, .init(title: trustTitle, state: .pending), firstTask]
        case .trust, .retrust:
            steps = [added, .init(title: trustTitle, state: .current), firstTask]
        case .firstTask:
            steps = [added, .init(title: text("step.trusted", name), state: .done), firstTask]
        default:
            steps = []
        }
        switch stage {
        case .adding: chip = text("chip.adding"); tone = .neutral
        case .trust: chip = text("chip.trust"); tone = .attention
        case .retrust: chip = text("chip.retrust"); tone = .attention
        case .firstTask: chip = text("chip.first_task"); tone = .info
        case .ready: chip = text("chip.ready"); tone = .success
        case .turnedOff, .toolOff: chip = text("chip.turned_off", name); tone = .attention
        case .openApp: chip = text("chip.open_app", name); tone = .attention
        case .conflict, .failed, .missing, .cleanupFailed: chip = text("chip.failed"); tone = .error
        case .unknown: chip = text("chip.unknown"); tone = .neutral
        }
        switch stage {
        case .turnedOff: line = text("line.turned_off", name)
        case .toolOff: line = text("line.tool_off", name)
        case .conflict: line = text("line.conflict", name)
        case .failed: line = text("line.failed", name)
        case .missing: line = text("line.missing", name)
        case .unknown: line = text("line.unknown", name)
        case .cleanupFailed: line = text("line.cleanup_failed")
        default: line = nil
        }
        switch stage {
        case .trust, .retrust, .turnedOff, .toolOff, .unknown: action = .openConnectors; actionTitle = text("action.open_connectors", name)
        case .openApp: action = .openApp; actionTitle = text("action.open_app", name)
        case .conflict, .failed, .missing, .cleanupFailed: action = .retry; actionTitle = text("action.retry")
        default: action = nil; actionTitle = nil
        }
        attention = [.trust, .retrust, .turnedOff, .toolOff, .openApp, .conflict, .failed, .missing].contains(stage)
        switch stage {
        case .trust: summary = text("summary.trust")
        case .retrust: summary = text("summary.retrust")
        case .turnedOff, .toolOff: summary = text("summary.turned_off", name)
        case .openApp: summary = text("summary.open_app", name)
        case .conflict, .failed, .missing: summary = text("summary.failed")
        default: summary = nil
        }
        waiting = [.trust, .retrust, .turnedOff, .toolOff, .openApp, .unknown].contains(stage)
        showsTrustCard = stage == .trust || stage == .retrust
    }

    /// The note under the onboarding ring switch, for the apps that still
    /// need a step; nil when none do.
    public static func onboardingNote(names: [String], language: AppLanguage? = nil) -> String? {
        guard let first = names.first else { return nil }
        if names.count == 1 { return L10n.text("progress_guide.onboarding.one", first, language: language) }
        let joined = names.joined(separator: L10n.text("progress_guide.onboarding.separator", language: language))
        return L10n.text("progress_guide.onboarding.many", joined, language: language)
    }
}
