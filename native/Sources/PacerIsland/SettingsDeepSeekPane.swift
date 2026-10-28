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

/// The balance and how long it lasts beside the module switch, with the price clock.
struct DeepSeekSettingsSummary: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let wallet = model.deepseekWallet
        HStack(spacing: 8) {
            PriceClockGlyph(hourly: wallet.hourly, peaks: wallet.peakToday.map { wallet.angle(of: $0.start)...wallet.angle(of: $0.end) },
                now: wallet.angle(of: model.now), dimmed: model.deepseekWalletDimmed, side: 24)
                .padding(4).background(Color.black, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            if let balance = wallet.balance {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(DeepSeekDayDial.amount(balance.total)).font(.system(size: 14, weight: .semibold, design: .rounded))
                    if let days = wallet.runwayDays {
                        Text(days >= 365 ? L10n.text("deepseek.runway_year") : L10n.text("deepseek.runway_short", max(1, Int(days.rounded(.down)))))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// DeepSeek's module page below the shared header: the balance connection,
/// balance or budget mode, how spending shows, the price list and sessions
/// found on this Mac. The mode is always offered; the budget amounts appear in
/// budget mode, filled in from recent spend. The balance source sits in the
/// connection's menu. A connected wallet shows only its state and time, never
/// the account.
struct SettingsDeepSeekSections: View {
    @ObservedObject var model: IslandModel
    @Binding var balanceSource: DeepSeekBalanceSource
    @Binding var budgets: DeepSeekBudgetSettings
    @Binding var showsTurnCost: Bool
    @Binding var speedSource: String
    /// The collapsed ring showing DeepSeek's budget, if any, and the way to choose one.
    let ringSlot: QuotaRingSlot?
    let openCollapsedBar: () -> Void
    @Binding var home: String
    let homeIssue: String?
    let commitHome: () -> Void
    let chooseHome: () -> Void
    @State private var key = ""
    @State private var keyIssue: String?
    @State private var showsLocation = !(UserDefaults.standard.string(forKey: "deepseekHome") ?? "").isEmpty

    var body: some View {
        balanceSection
        Section {
            let average = model.deepseekWallet.averageDaily.flatMap { $0 >= 0.01 ? $0 : nil }
            Picker(L10n.text("deepseek.mode"), selection: Binding(get: { budgets.budgetMode }, set: {
                budgets.setBudgetMode($0, suggestion: DeepSeekBudgets.suggested(averageDaily: average))
            })) {
                Text(L10n.text("deepseek.mode.balance")).tag(false)
                Text(L10n.text("deepseek.mode.budget")).tag(true)
            }
            .pickerStyle(.segmented)
            if budgets.budgetMode {
                HStack(spacing: 4) {
                    Text(L10n.text(ringSlot == .outer ? "deepseek.ring_hint.outer" : ringSlot == .inner ? "deepseek.ring_hint.inner" : "deepseek.ring_hint.none"))
                        .foregroundStyle(.secondary)
                    Button(L10n.text(ringSlot == nil ? "deepseek.ring_hint.choose" : "deepseek.ring_hint.change"), action: openCollapsedBar)
                        .buttonStyle(.link)
                }
                .font(.system(size: 11))
                // The recent average beside each field shows where the filled-in amounts came from.
                LabeledContent(L10n.text("deepseek.budget.daily")) {
                    budgetField($budgets.daily, label: L10n.text("deepseek.budget.daily"),
                        reference: average.map { L10n.text("deepseek.budget.average_day", DeepSeekWallet.compactSpend($0)) })
                }
                LabeledContent(L10n.text("deepseek.budget.weekly")) {
                    budgetField($budgets.weekly, label: L10n.text("deepseek.budget.weekly"),
                        reference: average.map { L10n.text("deepseek.budget.average_week", DeepSeekWallet.compactSpend($0 * 7)) })
                }
                if budgets.daily != nil, budgets.weekly != nil {
                    Picker(L10n.text("deepseek.budget.ring"), selection: $budgets.ringPeriod) {
                        Text(L10n.text("deepseek.budget.day")).tag(DeepSeekBudgetPeriod.Kind.day)
                        Text(L10n.text("deepseek.budget.week")).tag(DeepSeekBudgetPeriod.Kind.week)
                    }
                    .pickerStyle(.segmented)
                }
                caption(L10n.text("deepseek.budget.help"))
            } else {
                caption(L10n.text("deepseek.mode.balance_help"))
            }
        } header: {
            Text(L10n.text("deepseek.section.mode"))
        }
        Section {
            Picker(L10n.text("deepseek.speed_basis"), selection: $speedSource) {
                Text(L10n.text("deepseek.speed_source.local")).tag(DeepSeekSpeedSource.local.rawValue)
                Text(L10n.text("deepseek.speed_source.account")).tag(DeepSeekSpeedSource.account.rawValue)
            }
            .pickerStyle(.segmented)
            caption(L10n.text("deepseek.speed_basis_help"))
        } header: {
            Text(L10n.text("deepseek.speed"))
        }
        Section {
            Toggle(isOn: $showsTurnCost) {
                Text(L10n.text("deepseek.turn_cost"))
                Text(L10n.text("deepseek.turn_cost_help"))
            }
        } header: {
            Text(L10n.text("deepseek.section.display"))
        }
        Section {
            DeepSeekPeakTimeline(now: model.now)
            caption(L10n.text("deepseek.pricing_note"))
            Link(L10n.text("deepseek.price_list"), destination: IslandModel.deepseekPricingURL).font(.system(size: 12))
        } header: {
            Text(L10n.text("deepseek.section.pricing"))
        }
        Section(L10n.text("provider.section.local")) {
            let status = model.providerStreamStatuses(.deepseek)["local"]
            row(L10n.text("deepseek.sessions"), state: L10n.text(status?.connected == true ? "provider.state.found" : "provider.state.no_home"),
                tint: status?.connected == true ? .green : .secondary)
            DisclosureGroup(L10n.text("provider.custom_locations"), isExpanded: $showsLocation) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField(L10n.text("deepseek.home"), text: $home, prompt: Text("~/.dsh")).onSubmit(commitHome)
                        Button(L10n.text("common.choose"), action: chooseHome)
                    }
                    if let homeIssue { caption(homeIssue).foregroundStyle(.orange) }
                }.padding(.top, 6)
            }
        }
    }

    @ViewBuilder private var balanceSection: some View {
        Section {
            connectionRow
            // How the source was found matters while signing in or after choosing one by hand.
            if balanceSource != .automatic || model.deepseekBalance == nil { caption(detectionText) }
            if model.deepseekBalanceMode == .apiKey { keyEditor }
        } header: {
            Text(L10n.text("deepseek.section.balance"))
        }
    }

    private func budgetField(_ value: Binding<Double?>, label: String, reference: String?) -> some View {
        HStack(spacing: 4) {
            if let reference { Text(reference).font(.system(size: 11)).foregroundStyle(.secondary).padding(.trailing, 6) }
            Text("¥").foregroundStyle(.secondary)
            TextField(label, value: value, format: .number.precision(.fractionLength(0...2)), prompt: Text(L10n.text("deepseek.budget.off")))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 64).labelsHidden()
        }
    }

    private var detectionText: String {
        let detected = model.deepseekDetectedMode
        let found = detected.map { L10n.text($0 == .account ? "deepseek.detected.account" : "deepseek.detected.api") } ?? L10n.text("deepseek.detected.unknown")
        return balanceSource == .automatic ? found : L10n.text("deepseek.detected.overridden", found)
    }

    @ViewBuilder private var connectionRow: some View {
        let web = model.deepseekBalanceMode != .apiKey
        let connected = model.deepseekBalance != nil && !model.deepseekConnectionNeeded
        let (tint, state): (Color, String) =
            connected ? (.green, L10n.text("deepseek.connected", model.deepseekBalanceFreshness)) :
            model.deepseekRefreshing ? (.secondary, L10n.text("claude.account.checking")) :
            model.deepseekConnectionNeeded || model.deepseekBalanceError == nil ? (.orange, L10n.text(web ? "deepseek.signed_out" : "deepseek.no_key")) :
            (.orange, model.deepseekBalanceError?.errorDescription ?? L10n.text("deepseek.balance.unavailable"))
        row(L10n.text(web ? "deepseek.platform_account" : "deepseek.api_key"), state: state, tint: tint) {
            if web, !connected {
                Button(L10n.text("deepseek.sign_in")) { model.connectDeepSeek() }
            } else if !web, model.deepseekBalanceError != nil || connected {
                Button(L10n.text("common.refresh")) { model.refreshDeepSeekBalance(force: true) }.disabled(model.deepseekRefreshing)
            }
            Menu {
                Picker(L10n.text("deepseek.balance_source"), selection: $balanceSource) {
                    Text(L10n.text("deepseek.source.automatic")).tag(DeepSeekBalanceSource.automatic)
                    Text(L10n.text("deepseek.source.web_short")).tag(DeepSeekBalanceSource.web)
                    Text(L10n.text("deepseek.source.api_short")).tag(DeepSeekBalanceSource.apiKey)
                }
                .pickerStyle(.inline)
                if web, connected {
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
        HStack {
            SecureField(L10n.text("deepseek.paste_key"), text: $key, prompt: Text("sk-…")).onSubmit(saveKey)
            Button(L10n.text("common.save"), action: saveKey).disabled(key.isEmpty)
            if DeepSeekAPIKeyStore.exists { Button(L10n.text("deepseek.remove_key")) { model.removeDeepSeekConnection() } }
        }
        caption(keyIssue ?? L10n.text("deepseek.key_help")).foregroundStyle(keyIssue == nil ? Color.secondary : Color.orange)
    }
    private func saveKey() {
        // The field clears either way; a key never stays in view state.
        defer { key = "" }
        keyIssue = model.saveDeepSeekAPIKey(key) ? nil : L10n.text("deepseek.key_invalid")
    }

    private func row<Action: View>(_ title: String, state: String, tint: Color, @ViewBuilder action: () -> Action = { EmptyView() }) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            Circle().fill(tint).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(state).foregroundStyle(tint == .orange ? Color.orange : Color.secondary)
            action()
        }
    }
    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
