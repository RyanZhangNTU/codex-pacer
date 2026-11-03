import Foundation
import PacerCore

struct EngineWallet: Codable, Equatable {
    struct Span: Codable, Equatable { let start: Double; let end: Double }
    let state: String
    let balance: Double?
    let whole: String
    let cents: String
    let subtitle: String
    let compact: String?
    let hourly: [Double]
    let peak: [Span]
    let angle: Double
    let peakNow: Bool
    let today: Double
    let elsewhere: Double
    let averageDaily: Double?
    let runwayDays: Double?
    let dial: DeepSeekDialPresentation?
    let solo: DeepSeekSoloPresentation?
    let settings: EngineDeepSeekSettingsReading?
    let alert: DeepSeekAlertPresentation?
    var reminders: EngineReminderReading?

    init(_ wallet: DeepSeekWallet, at now: Date, hideProjects: Bool = false, compactBudget: DeepSeekBudgetPeriod? = nil,
         reminders: EngineReminderSettings = .init(), connection: DeepSeekBalanceState? = nil,
         taskTitle: (String) -> String = { _ in L10n.text("deepseek.task_untitled") }) {
        let presentation = DeepSeekDialPresentation(wallet: wallet, at: now, refreshing: connection?.refreshing ?? false,
            needsConnection: connection.map { $0.error?.needsConnection == true || $0.mode == nil } ?? true,
            apiKey: connection?.mode == .apiKey)
        dial = presentation
        solo = .init(wallet: wallet, at: now, hideProjects: hideProjects, taskTitle: taskTitle)
        settings = .init(wallet: wallet, compactBudget: compactBudget, freshness: presentation.freshness, now: now)
        alert = .init(wallet: wallet, lowBalance: reminders.contains(.lowBalance), spike: reminders.contains(.spendSpike), budget: reminders.contains(.budget))
        switch wallet.state {
        case .normal: state = "normal"
        case .low: state = "low"
        case .exhausted: state = "exhausted"
        case .stale: state = "stale"
        case .disconnected: state = "disconnected"
        }
        balance = wallet.balance?.total
        let parts = String(format: "%.2f", max(0, balance ?? 0)).split(separator: ".")
        whole = balance == nil ? "—" : String(parts.first ?? "0")
        cents = balance == nil ? "" : "." + String(parts.last ?? "00")
        compact = compactBudget.map { DeepSeekWallet.compactRemaining($0.remaining) } ?? balance.map(DeepSeekWallet.compactAmount)
        subtitle = presentation.subtitle
        hourly = wallet.hourly
        func angle(_ date: Date) -> Double {
            wallet.day.duration > 0 ? min(360, max(0, date.timeIntervalSince(wallet.day.start) / wallet.day.duration * 360)) : 0
        }
        self.angle = angle(now)
        peak = wallet.peakToday.map { Span(start: angle($0.start), end: angle($0.end)) }
        peakNow = wallet.peakNow; today = wallet.today; elsewhere = wallet.elsewhereToday
        averageDaily = wallet.averageDaily; runwayDays = wallet.runwayDays
    }

    static func demo(at now: Date, hideProjects: Bool = false) -> Self {
        EngineWalletSource.demo(at: now).presentation(at: now, hideProjects: hideProjects)
    }
}

/// Retain inputs between source reads. The display clock projects this value
/// without reopening logs, so quiet clocks, pricing boundaries and local-day
/// rollovers stay current even when the account is disconnected.
struct EngineWalletSource {
    var balance: DeepSeekBalance?
    var connected: Bool
    var ledger: DeepSeekSpendLedger
    var history = DeepSeekBalanceHistory()
    var titles: [String: String]

    func wallet(at now: Date, configuration: EngineDeepSeekSettings = .init(), reminders: EngineReminderSettings = .init()) -> DeepSeekWallet {
        DeepSeekWallet(balance: balance, connected: connected, ledger: ledger, now: now, lowLine: reminders.lowLine, history: history,
            budgets: configuration.budgets, spikeLimit: reminders.spikeLine, speedSource: DeepSeekSpeedSource(rawValue: configuration.speedSource) ?? .local)
    }
    func presentation(at now: Date, hideProjects: Bool, configuration: EngineDeepSeekSettings = .init(), compactUsesBudget: Bool = false) -> EngineWallet {
        presentation(wallet: wallet(at: now, configuration: configuration), at: now, hideProjects: hideProjects, configuration: configuration, compactUsesBudget: compactUsesBudget)
    }
    func presentation(wallet: DeepSeekWallet, at now: Date, hideProjects: Bool, configuration: EngineDeepSeekSettings,
                      compactUsesBudget: Bool, reminders: EngineReminderSettings = .init(), connection: DeepSeekBalanceState? = nil) -> EngineWallet {
        let budget = compactUsesBudget ? wallet.ringBudget(prefer: .init(rawValue: configuration.ringPeriod) ?? .day) : nil
        var result = EngineWallet(wallet, at: now, hideProjects: hideProjects, compactBudget: budget, reminders: reminders, connection: connection,
            taskTitle: { titles[$0] ?? L10n.text("deepseek.task_untitled") })
        result.reminders = .init(low: DeepSeekWallet.automaticLowLine(balance), spike: ledger.automaticSpikeLimit(before: wallet.day.start))
        return result
    }
    static func demo(at now: Date) -> Self {
        let usage = DemoScenario.deepseekUsage(at: now)
        let balance = DeepSeekBalance(total: 86.4, granted: 6.4, tokenEstimation: 21_600_000, capturedAt: now, source: .web)
        let start = min(now, Calendar.current.startOfDay(for: now).addingTimeInterval(60))
        let local = usage.ledger.total(in: DateInterval(start: start, end: now)).total
        var history = DeepSeekBalanceHistory()
        history.record(total: 86.4 + local + 2.1, at: start, source: "web")
        history.record(total: 86.4, at: now, source: "web")
        return Self(balance: balance, connected: true, ledger: usage.ledger, history: history, titles: usage.titles)
    }
}
