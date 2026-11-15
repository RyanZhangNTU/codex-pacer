import Foundation

/// The progress ring card for a module whose app must trust Pacer's tool
/// (WorkBuddy and WorkBuddy AI), worded once so the Mac and Windows draw the
/// same steps. Only the user can trust the tool, in the app itself; the card
/// takes them there and confirms the result on its own.
///
/// The app reads its MCP file only when it starts, so an app running since
/// before Pacer added the tool must be reopened before it lists the tool.
public struct HarnessProgressGuide: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable {
        case adding, reopen, launch, trust, retrust, firstTask, ready, turnedOff, toolOff, openApp, conflict, failed, missing, unknown, cleanupFailed
    }
    public enum Tone: String, Codable, Sendable { case neutral, attention, info, success, error }
    public enum StepState: String, Codable, Sendable { case done, current, pending }
    public enum Action: String, Codable, Sendable { case openConnectors, openApp, retry }

    /// Whether the app runs, and since when, as the host sees it.
    public enum AppPresence: Equatable, Sendable {
        case notRunning
        case running(since: Date)
    }

    public struct Step: Codable, Equatable, Sendable {
        public let title: String
        public let state: StepState
    }

    public let stage: Stage
    public let chip: String
    public let tone: Tone
    /// The four steps while setting up; empty once ready or for a problem.
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
    /// What the card says while it waits.
    public let waitingText: String?
    /// Draw the app's trust card beside the current step.
    public let showsTrustCard: Bool
    /// The ⓘ text.
    public let info: String

    /// - Parameters:
    ///   - ringOn: the module and its ring are both on.
    ///   - name: the app's own name, such as "WorkBuddy AI".
    ///   - addedAt: when Pacer last wrote its entry; nil when unknown.
    ///   - app: whether the app runs and since when; nil when the host can't tell.
    package init?(setup: LocalHarnessProgressStatus?, connection: LocalHarnessProgressConnection?, reported: Bool,
                  ringOn: Bool, name: String, addedAt: Date? = nil, app: AppPresence? = nil, language: AppLanguage? = nil) {
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
                case .needsTrust, .retrust:
                    switch app {
                    case .notRunning?: stage = .launch
                    case .running(let since)? where addedAt.map({ since < $0 }) ?? false: stage = .reopen
                    default: stage = connection == .retrust ? .retrust : .trust
                    }
                case .trusted: stage = reported ? .ready : .firstTask
                case .disabled: stage = .turnedOff
                case .toolDisabled: stage = .toolOff
                case .missing: stage = .missing
                case .unknown, nil: stage = reported ? .ready : .unknown
                }
            }
        }
        self.stage = stage
        let again = connection == .retrust
        let added = Step(title: text("step.added"), state: stage == .adding ? .current : .done)
        let load: Step = switch stage {
        case .reopen: .init(title: text("step.reopen", name), state: .current)
        case .launch: .init(title: text("step.launch", name), state: .current)
        case .adding: .init(title: text("step.launch", name), state: .pending)
        default: .init(title: text("step.loaded", name), state: .done)
        }
        let trustTitle = text(again ? "step.retrust" : "step.trust", name)
        let trust: Step = switch stage {
        case .trust, .retrust: .init(title: trustTitle, state: .current)
        case .firstTask: .init(title: text("step.trusted", name), state: .done)
        default: .init(title: trustTitle, state: .pending)
        }
        let firstTask = Step(title: text("step.first_task"), state: stage == .firstTask ? .current : .pending)
        steps = [.adding, .reopen, .launch, .trust, .retrust, .firstTask].contains(stage) ? [added, load, trust, firstTask] : []
        // The steps the user still has to take, not counting the new task.
        let left = steps.dropLast().filter { $0.state != .done }.count
        switch stage {
        case .adding: chip = text("chip.adding"); tone = .neutral
        case .reopen, .launch, .trust:
            chip = again ? text("chip.retrust") : left == 1 ? text("chip.trust") : text("chip.steps_left", left); tone = .attention
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
        case .launch, .trust, .retrust, .turnedOff, .toolOff, .unknown: action = .openConnectors; actionTitle = text("action.open_connectors", name)
        case .openApp: action = .openApp; actionTitle = text("action.open_app", name)
        case .conflict, .failed, .missing, .cleanupFailed: action = .retry; actionTitle = text("action.retry")
        // Only the user can quit the app; Pacer then sees it start again.
        default: action = nil; actionTitle = nil
        }
        attention = [.reopen, .launch, .trust, .retrust, .turnedOff, .toolOff, .openApp, .conflict, .failed, .missing].contains(stage)
        switch stage {
        case .reopen, .launch, .trust: summary = again ? text("summary.retrust") : left == 1 ? text("summary.trust") : text("summary.steps_left", left)
        case .retrust: summary = text("summary.retrust")
        case .turnedOff, .toolOff: summary = text("summary.turned_off", name)
        case .openApp: summary = text("summary.open_app", name)
        case .conflict, .failed, .missing: summary = text("summary.failed")
        default: summary = nil
        }
        waiting = [.reopen, .launch, .trust, .retrust, .turnedOff, .toolOff, .openApp, .unknown].contains(stage)
        waitingText = stage == .reopen ? text("waiting.reopen", name) : waiting ? text("waiting") : nil
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
