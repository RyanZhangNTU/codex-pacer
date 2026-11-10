import Foundation

/// The original solo dashboard's readings and chart scale. Task identifiers
/// never leave this projection; hidden names are removed before encoding.
public struct DeepSeekSoloPresentation: Codable, Equatable, Sendable {
    public struct Speed: Codable, Equatable, Sendable {
        public let label: String
        public let fractions: [Double]
        public let lineFraction: Double?
        public let rateText: String
        public let spiking: Bool
        public let help: String
        public let accessibilityLabel: String
    }
    public struct Part: Codable, Equatable, Sendable {
        public let title: String
        public let amountText: String
        public let fraction: Double
        public let opacity: Double
        public let elsewhere: Bool
        public let help: String
    }
    public struct Distribution: Codable, Equatable, Sendable {
        public let title: String
        public let parts: [Part]
        public let usageTitle: String
        public let usageHelp: String
    }
    public struct Day: Codable, Equatable, Sendable {
        public let timestamp: Double
        public let label: String
        public let today: Bool
        public let withinFraction: Double
        public let overFraction: Double
        public let help: String
    }
    public struct Week: Codable, Equatable, Sendable {
        public let title: String
        public let lineText: String?
        public let lineFraction: Double?
        public let days: [Day]
        public let accessibilityLabel: String
    }
    public struct Budget: Codable, Equatable, Sendable {
        public let kind: String
        public let label: String
        public let fraction: Double
        public let timeFraction: Double?
        public let pacePercent: Double?
        public let paceText: String
        public let verdict: QuotaDashboardPresentation.Verdict?
        public let verdictText: String?
        public let exceeded: Bool
        public let pressing: Bool
        public let whole: String
        public let cents: String
        public let countdown: String
        public let resetText: String
        public let projectionText: String?
        public let projectionWarns: Bool
        public let help: String
        public let spentText: String
    }
    public let todayLabel: String
    public let todayText: String
    public let todayHelp: String
    public let peakUntil: String?
    public let speed: Speed?
    public let distribution: Distribution?
    public let week: Week?
    public let budgets: [Budget]

    public struct Wording: Sendable {
        public var todayHelpKey: String, localSpeedKey: String, elsewhereKey: String, elsewhereHelpKey: String
        public init(todayHelpKey: String = "deepseek.today_help", localSpeedKey: String = "deepseek.speed_source.local",
                    elsewhereKey: String = "deepseek.elsewhere", elsewhereHelpKey: String = "deepseek.elsewhere_help") {
            self.todayHelpKey = todayHelpKey; self.localSpeedKey = localSpeedKey
            self.elsewhereKey = elsewhereKey; self.elsewhereHelpKey = elsewhereHelpKey
        }
    }
    /// `panel` carries the expanded panel's choices for the spend bar and the week chart.
    public init(wallet: DeepSeekWallet, at now: Date, hideProjects: Bool = false, wording: Wording = .init(),
                panel: ExpandedPanelOptions = .init(),
                taskTitle: (String) -> String = { _ in L10n.text("deepseek.task_untitled") }) {
        func amount(_ value: Double) -> String { DeepSeekDialPresentation.amount(value) }
        todayLabel = L10n.text("deepseek.group.today"); todayText = amount(wallet.todayTotal)
        let todayHelpKey = wording.todayHelpKey
        todayHelp = L10n.text(todayHelpKey, amount(wallet.today), amount(wallet.elsewhereToday))
        peakUntil = wallet.peakNow ? wallet.nextPriceChange.map { L10n.text("deepseek.peak_until", L10n.moment($0, relativeTo: now)) } : nil
        speed = Self.speed(wallet, wording: wording)
        distribution = Self.distribution(wallet, hideProjects: hideProjects, wording: wording, taskTitle: taskTitle,
            tasks: panel.spendTasks, elsewhere: panel.spendElsewhere)
        week = Self.week(wallet, line: panel.weekLine)
        budgets = [wallet.daily, wallet.weekly].compactMap { $0 }.map { Self.budget($0, at: now) }
    }
    public static func speed(_ wallet: DeepSeekWallet, wording: Wording = .init()) -> Speed? {
        func amount(_ value: Double) -> String { DeepSeekDialPresentation.amount(value) }
        let localKey = wording.localSpeedKey
        if wallet.speed.contains(where: { $0 >= 0.005 }) {
            let largest = wallet.speed.max() ?? 0, limit = wallet.spikeLimit
            let top = max(0.01, largest * 1.3, limit > 0 && limit <= largest * 3 ? limit * 1.1 : 0)
            let rate = L10n.text("deepseek.rate", amount(wallet.ratePerMinute))
            return Speed(label: L10n.text("deepseek.speed"), fractions: wallet.speed.map { $0 / top },
                lineFraction: limit > 0 && limit <= top ? limit / top : nil, rateText: rate, spiking: wallet.spiking,
                help: L10n.text("deepseek.speed_help", L10n.text(wallet.speedSource == .local ? localKey : "deepseek.speed_source.account"), amount(limit)),
                accessibilityLabel: L10n.text("deepseek.speed") + " " + rate)
        } else { return nil }
    }
    /// The largest `tasks` tasks by name, the rest, and, when `elsewhere`,
    /// what the account was charged with no task on this computer.
    public static func distribution(_ wallet: DeepSeekWallet, hideProjects: Bool = false, wording: Wording = .init(),
                                    taskTitle: (String) -> String = { _ in L10n.text("deepseek.task_untitled") },
                                    tasks limit: Int = 2, elsewhere: Bool = true) -> Distribution? {
        func amount(_ value: Double) -> String { DeepSeekDialPresentation.amount(value) }
        let elsewhereKey = wording.elsewhereKey, elsewhereHelpKey = wording.elsewhereHelpKey
        if wallet.todayTotal >= 0.005 {
            let tasks = wallet.tasks.filter { $0.total >= 0.005 }, limit = max(1, limit)
            let opacities = limit <= 2 ? [0.9, 0.6] : [0.9, 0.72, 0.56, 0.44]
            var parts: [(String, Double, Double, Bool)] = tasks.prefix(limit).enumerated().map { index, task in
                (hideProjects ? L10n.text("activity.hidden_name") : taskTitle(task.task), task.total,
                 opacities[min(index, opacities.count - 1)], false)
            }
            let rest = tasks.dropFirst(limit).reduce(0) { $0 + $1.total } + max(0, wallet.today - tasks.reduce(0) { $0 + $1.total })
            if rest >= 0.005 { parts.append((L10n.text("deepseek.others"), rest, 0.32, false)) }
            if elsewhere, wallet.elsewhereToday >= 0.005 { parts.append((L10n.text(elsewhereKey), wallet.elsewhereToday, 0, true)) }
            guard !parts.isEmpty else { return nil }
            let total = max(0.01, parts.reduce(0) { $0 + $1.1 }), explanation = L10n.text(elsewhereHelpKey)
            return Distribution(title: L10n.text("deepseek.where"), parts: parts.map { title, value, opacity, elsewhere in
                Part(title: title, amountText: amount(value), fraction: value / total, opacity: opacity, elsewhere: elsewhere,
                    help: title + " · " + amount(value) + (elsewhere ? "\n" + explanation : ""))
            }, usageTitle: L10n.text("deepseek.usage_link"), usageHelp: explanation + "\n" + L10n.text("deepseek.usage_link"))
        } else { return nil }
    }
    /// Without `line` the dashed reference and its label are left out; the
    /// part of a day over its budget still turns red.
    public static func week(_ wallet: DeepSeekWallet, line showsLine: Bool = true) -> Week? {
        func amount(_ value: Double) -> String { DeepSeekDialPresentation.amount(value) }

        if wallet.dayTotals.dropLast().filter({ $0 >= 0.005 }).count >= 2 {
            let budget = wallet.daily?.limit
            let line = showsLine ? budget ?? wallet.averageDaily.flatMap { $0 >= 0.005 ? $0 : nil } : nil
            let top = max(0.01, wallet.dayTotals.max() ?? 0, (line ?? 0) * 1.15)
            let days = zip(wallet.days, wallet.dayTotals).enumerated().map { index, pair -> Day in
                let day = pair.0, total = pair.1, today = index == wallet.days.count - 1
                let within = budget.map { min(total, $0) } ?? total, over = budget.map { max(0, total - $0) } ?? 0
                var help = day.start.formatted(Date.FormatStyle().weekday(.abbreviated).month(.defaultDigits).day().locale(L10n.locale)) + " · " + amount(total)
                if over >= 0.005 { help += "\n" + L10n.text("deepseek.day_over", amount(over)) }
                return Day(timestamp: day.start.timeIntervalSince1970,
                    label: today ? L10n.text("deepseek.today_label") : day.start.formatted(Date.FormatStyle().weekday(.narrow).locale(L10n.locale)),
                    today: today, withinFraction: within / top, overFraction: over / top, help: help)
            }
            return Week(title: L10n.text("deepseek.week_title"), lineText: line.map { L10n.text(budget != nil ? "deepseek.daily_budget_line" : "deepseek.daily_average", amount($0)) },
                lineFraction: line.map { $0 / top }, days: days,
                accessibilityLabel: L10n.text("deepseek.week_accessibility_total", amount(wallet.dayTotals.reduce(0, +))))
        } else { return nil }
    }
    public static func budget(_ period: DeepSeekBudgetPeriod, at now: Date) -> Budget {
        func amount(_ value: Double) -> String { DeepSeekDialPresentation.amount(value) }
            let pace = period.window.pacePercent(at: now), verdict = period.exceeded ? nil : pace.map(QuotaDashboardPresentation.Verdict.init(pace:))
            let pressing = !period.exceeded && (period.remaining / period.limit <= 0.15 || verdict == .fast)
            let parts = String(format: "%.2f", abs(period.remaining)).split(separator: ".")
            let countdown = Self.duration(max(0, period.interval.end.timeIntervalSince(now)))
            let label = L10n.text(period.kind == .day ? "deepseek.budget.day" : "deepseek.budget.week")
            var projection: String?, warns = false
            if period.exceeded { projection = L10n.text("deepseek.over_by", amount(-period.remaining)); warns = true }
            else {
                switch period.window.projection(at: now) {
                case nil: break
                case .tooEarly?: projection = L10n.text("dashboard.projection_early")
                case .remainingAtReset(let left)?: projection = L10n.text("deepseek.projection_left", amount(left / 100 * period.limit))
                case .runsOut(let seconds)?: projection = L10n.text("deepseek.projection_out", L10n.moment(now.addingTimeInterval(seconds), relativeTo: now)); warns = true
                }
            }
            return Budget(kind: period.kind.rawValue, label: label, fraction: min(1, max(0, period.remaining / period.limit)),
                timeFraction: period.window.remainingTimePercent(at: now).map { $0 / 100 }, pacePercent: pace, paceText: pace.map { "\(Int($0.rounded()))%" } ?? "—",
                verdict: verdict, verdictText: verdict?.label, exceeded: period.exceeded, pressing: pressing,
                whole: (period.exceeded && abs(period.remaining) >= 0.005 ? "−¥" : "¥") + String(parts.first ?? "0"), cents: "." + String(parts.last ?? "00"),
                countdown: countdown, resetText: L10n.text(period.kind == .day ? "deepseek.reset_day" : "deepseek.reset_week"), projectionText: projection, projectionWarns: warns,
                help: [label, L10n.text("deepseek.resets_in", countdown), projection].compactMap { $0 }.joined(separator: "\n"),
                spentText: amount(period.spent) + " / " + DeepSeekWallet.compactSpend(period.limit))
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else { return L10n.text("dashboard.countdown_soon") }
        let seconds = max(0, seconds), days = Int(seconds) / 86400, hours = Int(seconds) % 86400 / 3600, minutes = Int(seconds) % 3600 / 60
        if days > 0 { return L10n.text("dashboard.countdown_days", days, hours) }
        if hours > 0 { return L10n.text("dashboard.countdown_hours", hours, minutes) }
        return L10n.text("dashboard.countdown_minutes", minutes)
    }
}
