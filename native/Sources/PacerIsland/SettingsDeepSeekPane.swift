import PacerMacSupport
import AppKit
import PacerCore
import SwiftUI

/// Balance or budget mode and the budgets. Amounts of zero or less are off;
/// in balance mode they are kept but do not count.
struct DeepSeekBudgetSettings: Equatable {
    var budgetMode: Bool
    var daily: Double?
    var weekly: Double?
    var ringPeriod: DeepSeekBudgetPeriod.Kind
    var active: DeepSeekBudgets { budgetMode ? DeepSeekBudgets(daily: daily, weekly: weekly) : DeepSeekBudgets() }
    var isEmpty: Bool { active.isEmpty }
    /// Switching to budgets with no amount fills in the suggestion; earlier amounts come back as they were.
    mutating func setBudgetMode(_ on: Bool, suggestion: DeepSeekBudgets) {
        budgetMode = on
        guard on, DeepSeekBudgets(daily: daily, weekly: weekly).isEmpty else { return }
        daily = suggestion.daily; weekly = suggestion.weekly
    }
    /// A positive amount, whether stored as a number or given as launch-argument text.
    static func amount(_ key: String, in defaults: UserDefaults) -> Double? {
        guard defaults.object(forKey: key) != nil else { return nil }
        let value = defaults.double(forKey: key)
        return value.isFinite && value > 0 ? value : nil
    }
    static func load(from defaults: UserDefaults = .standard) -> Self {
        let budgets = DeepSeekBudgets(daily: amount(IslandModel.deepseekDailyBudgetKey, in: defaults),
            weekly: amount(IslandModel.deepseekWeeklyBudgetKey, in: defaults))
        return Self(budgetMode: defaults.string(forKey: IslandModel.deepseekModeKey) == "budget", daily: budgets.daily, weekly: budgets.weekly,
            ringPeriod: defaults.string(forKey: IslandModel.deepseekRingPeriodKey).flatMap(DeepSeekBudgetPeriod.Kind.init(rawValue:)) ?? .day)
    }
    func save(to defaults: UserDefaults) {
        let budgets = DeepSeekBudgets(daily: daily, weekly: weekly)
        for (key, value) in [(IslandModel.deepseekDailyBudgetKey, budgets.daily), (IslandModel.deepseekWeeklyBudgetKey, budgets.weekly)] {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        defaults.set(ringPeriod.rawValue, forKey: IslandModel.deepseekRingPeriodKey)
        defaults.set(budgetMode ? "budget" : "balance", forKey: IslandModel.deepseekModeKey)
    }
}

/// DeepSeek's page below the shared header, as the draft lays it out: the
/// balance and its connection, the dial's mode and budgets, what task rows
/// show, prices, then where sessions are read from. A connected wallet shows
/// only its state and time, never the account.
struct SettingsDeepSeekSections: View {
    @ObservedObject var model: IslandModel
    @Binding var balanceSource: DeepSeekBalanceSource
    @Binding var budgets: DeepSeekBudgetSettings
    @Binding var showsTurnCost: Bool
    @Binding var speedSource: String
    /// The collapsed ring showing DeepSeek's budget, if any, and the way to choose one.
    let ringSlot: QuotaRingSlot?
    let openCollapsedBar: () -> Void
    let openHistory: () -> Void
    @Binding var home: String
    let homeIssue: String?
    let commitHome: () -> Void
    let chooseHome: () -> Void
    @State private var key = ""
    @State private var keyIssue: String?
    @State private var showsLocation = !(UserDefaults.standard.string(forKey: "deepseekHome") ?? "").isEmpty

    var body: some View {
        balanceCard
        modeCard
        MainCard(title: L10n.text("deepseek.section.display"), footer: L10n.text("main.deepseek.estimate_note")) {
            CardRow(title: L10n.text("main.deepseek.speed_basis"), info: L10n.text("main.info.speed")) {
                MainSegmented(options: [(DeepSeekSpeedSource.local.rawValue, L10n.text("deepseek.speed_source.local")),
                                        (DeepSeekSpeedSource.account.rawValue, L10n.text("deepseek.speed_source.account"))],
                              selection: $speedSource, label: L10n.text("main.deepseek.speed_basis"))
            }
            CardToggle(title: L10n.text("deepseek.turn_cost"), info: L10n.text("deepseek.turn_cost_help"), isOn: $showsTurnCost)
        }
        MainCard(title: L10n.text("deepseek.section.pricing")) {
            DeepSeekPeakTimeline(now: model.now).padding(.vertical, 4)
            CardRow(title: L10n.text("main.deepseek.estimate"), info: L10n.text("deepseek.pricing_note")) {
                Link(L10n.text("deepseek.price_list"), destination: IslandModel.deepseekPricingURL).font(.system(size: 12.5))
            }
        }
        MainCard {
            let status = model.providerStreamStatuses(.deepseek)["local"]
            CardDisclosure(title: L10n.text("provider.custom_locations"),
                summary: home.isEmpty ? L10n.text(status?.connected == true ? "provider.state.found" : "provider.state.no_home") : L10n.text("main.location.custom"),
                isExpanded: $showsLocation)
            if showsLocation {
                CardStatusRow(title: L10n.text("deepseek.sessions"),
                    state: L10n.text(status?.connected == true ? "provider.state.found" : "provider.state.no_home"),
                    tint: status?.connected == true ? MainPalette.positive : .secondary)
                CardPathField(title: L10n.text("deepseek.home"), text: $home, prompt: "~/.dsh", issue: homeIssue,
                    commit: commitHome, choose: chooseHome)
            }
        }
    }

    private var balanceCard: some View {
        MainCard(title: L10n.text("deepseek.section.balance")) {
            if let balance = model.deepseekWallet.balance {
                CardRow(title: L10n.text("deepseek.section.balance")) {
                    Text(DeepSeekDayDial.amount(balance.total)).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                    if let days = model.deepseekWallet.runwayDays {
                        Text(days >= 365 ? L10n.text("deepseek.runway_year") : L10n.text("deepseek.runway_short", max(1, Int(days.rounded(.down)))))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Button(L10n.text("main.quota.trend"), action: openHistory).buttonStyle(.link).font(.system(size: 12.5))
                }
            }
            connectionRow
            // How the source was found matters while signing in or after choosing one by hand.
            if connection.showDetection { CardRow(title: connection.detectedText) }
            if connection.keyEditor { keyEditor }
        }
    }

    private var modeCard: some View {
        let average = model.deepseekWallet.averageDaily.flatMap { $0 >= 0.01 ? $0 : nil }
        return MainCard(title: L10n.text("deepseek.section.mode"),
                        footer: L10n.text(budgets.budgetMode ? "main.deepseek.budget_note" : "main.deepseek.balance_note")) {
            CardRow(title: L10n.text("deepseek.mode")) {
                MainSegmented(options: [(false, L10n.text("deepseek.mode.balance")), (true, L10n.text("deepseek.mode.budget"))],
                    selection: Binding(get: { budgets.budgetMode }, set: {
                        budgets.setBudgetMode($0, suggestion: DeepSeekBudgets.suggested(averageDaily: average))
                    }), label: L10n.text("deepseek.mode"))
            }
            if budgets.budgetMode {
                // The recent average beside each field shows where the filled-in amounts came from.
                CardRow(title: L10n.text("deepseek.budget.daily")) {
                    budgetField($budgets.daily, label: L10n.text("deepseek.budget.daily"),
                        reference: average.map { L10n.text("deepseek.budget.average_day", DeepSeekWallet.compactSpend($0)) })
                }
                CardRow(title: L10n.text("deepseek.budget.weekly")) {
                    budgetField($budgets.weekly, label: L10n.text("deepseek.budget.weekly"),
                        reference: average.map { L10n.text("deepseek.budget.average_week", DeepSeekWallet.compactSpend($0 * 7)) })
                }
                if budgets.daily != nil, budgets.weekly != nil {
                    CardRow(title: L10n.text("deepseek.budget.ring")) {
                        MainSegmented(options: [(DeepSeekBudgetPeriod.Kind.day, L10n.text("deepseek.budget.day")),
                                                (.week, L10n.text("deepseek.budget.week"))],
                                      selection: $budgets.ringPeriod, label: L10n.text("deepseek.budget.ring"))
                    }
                }
                CardRow(title: L10n.text(ringSlot == .outer ? "deepseek.ring_hint.outer" : ringSlot == .inner ? "deepseek.ring_hint.inner" : "deepseek.ring_hint.none")) {
                    Button(L10n.text(ringSlot == nil ? "deepseek.ring_hint.choose" : "deepseek.ring_hint.change"), action: openCollapsedBar)
                        .buttonStyle(.link).font(.system(size: 12.5))
                }
            }
        }
    }

    private func budgetField(_ value: Binding<Double?>, label: String, reference: String?) -> some View {
        HStack(spacing: 4) {
            if let reference { Text(reference).font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.trailing, 6) }
            Text("¥").foregroundStyle(.secondary)
            TextField(label, value: value, format: .number.precision(.fractionLength(0...2)), prompt: Text(L10n.text("deepseek.budget.off")))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 72).labelsHidden()
        }
        .font(.system(size: 12.5))
    }

    private var connection: DeepSeekConnectionPresentation {
        .init(source: balanceSource, detected: model.deepseekDetectedMode, balance: model.deepseekBalance,
            error: model.deepseekBalanceError, refreshing: model.deepseekRefreshing, now: model.now)
    }

    @ViewBuilder private var connectionRow: some View {
        let presentation = connection
        let tint: Color = switch presentation.color {
        case .green: MainPalette.positive
        case .orange: MainPalette.attention
        case .secondary: .secondary
        }
        CardStatusRow(title: presentation.title, state: presentation.text, tint: tint) {
            switch presentation.action {
            case .signIn:
                Button(presentation.actionLabel ?? "") { model.connectDeepSeek() }.buttonStyle(.mainProminent)
            case .refresh:
                Button(presentation.actionLabel ?? "") { model.refreshDeepSeekBalance(force: true) }.buttonStyle(.main)
                    .disabled(model.deepseekRefreshing)
            case nil: EmptyView()
            }
            Menu {
                Picker(L10n.text("deepseek.balance_source"), selection: $balanceSource) {
                    Text(L10n.text("deepseek.source.automatic")).tag(DeepSeekBalanceSource.automatic)
                    Text(L10n.text("deepseek.source.web_short")).tag(DeepSeekBalanceSource.web)
                    Text(L10n.text("deepseek.source.api_short")).tag(DeepSeekBalanceSource.apiKey)
                }
                .pickerStyle(.inline)
                if !presentation.keyEditor, presentation.connected {
                    Divider()
                    Button(L10n.text("claude.account.switch")) { model.connectDeepSeek() }
                    Button(L10n.text("deepseek.sign_out")) { model.removeDeepSeekConnection() }
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(L10n.text("claude.account.options"))
        }
    }

    @ViewBuilder private var keyEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SecureField(L10n.text("deepseek.paste_key"), text: $key, prompt: Text("sk-…")).textFieldStyle(.roundedBorder)
                    .labelsHidden().onSubmit(saveKey)
                Button(L10n.text("common.save"), action: saveKey).buttonStyle(.mainProminent).disabled(key.isEmpty)
                if DeepSeekAPIKeyStore.exists {
                    Button(L10n.text("deepseek.remove_key")) { model.removeDeepSeekConnection() }.buttonStyle(.main)
                }
            }
            Text(keyIssue ?? L10n.text("deepseek.key_help")).font(.system(size: 11.5))
                .foregroundStyle(keyIssue == nil ? Color.secondary : MainPalette.attention).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func saveKey() {
        // The field clears either way; a key never stays in view state.
        defer { key = "" }
        keyIssue = model.saveDeepSeekAPIKey(key) ? nil : L10n.text("deepseek.key_invalid")
    }
}

/// The next working day on a 24-hour bar in local time, the doubled-price hours in amber.
struct DeepSeekPeakTimeline: View {
    let now: Date

    private var day: (interval: DateInterval, peaks: [DateInterval])? {
        let calendar = Calendar.current
        for offset in 0..<10 {
            guard let start = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)),
                  let interval = calendar.dateInterval(of: .day, for: start) else { continue }
            let peaks = DeepSeekPricing.peakIntervals(overlapping: interval)
            if !peaks.isEmpty { return (interval, peaks) }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(AgentProvider.deepseek.tint.opacity(0.35))
                    if let day {
                        ForEach(Array(day.peaks.enumerated()), id: \.offset) { _, peak in
                            let start = peak.start.timeIntervalSince(day.interval.start) / day.interval.duration
                            RoundedRectangle(cornerRadius: 3).fill(PacerPalette.attention)
                                .frame(width: proxy.size.width * peak.duration / day.interval.duration)
                                .offset(x: proxy.size.width * start)
                        }
                    }
                }
            }.frame(height: 8)
            HStack {
                ForEach(["0:00", "6:00", "12:00", "18:00", "24:00"], id: \.self) { label in
                    Text(label)
                    if label != "24:00" { Spacer(minLength: 0) }
                }
            }
            .font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
            HStack(spacing: 12) {
                legend(AgentProvider.deepseek.tint.opacity(0.35), L10n.text("deepseek.offpeak_hours"))
                legend(PacerPalette.attention, L10n.text("deepseek.peak_hours_x2"))
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("deepseek.peak_hours_help"))
    }
    private func legend(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8); Text(title) }
    }
}
