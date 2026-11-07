import AppKit
import PacerCore
import SwiftUI

/// Something on Overview that needs the user, with the one action that fixes it.
struct OverviewAttention: Identifiable {
    let id: String
    let title: String
    let detail: String
    let action: String
    let perform: () -> Void
}

/// What is happening now: anything that needs the user, a card per service
/// with the island's own ring and details beside it, then the task rows. The
/// rings and rows are the island's components, so they read exactly as on the
/// island and follow the same style settings.
struct OverviewPane: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var updater: AppUpdater
    let attention: [OverviewAttention]
    let open: (SettingsPane) -> Void
    private static let maximumRows = 8

    var body: some View {
        MainPage(maxWidth: 900) {
            PageHeader(title: SettingsPane.overview.title, subtitle: subtitle) {
                Button { model.refreshQuota(); model.refreshTaskSources() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.main).help(L10n.text("common.refresh")).accessibilityLabel(L10n.text("common.refresh"))
            }
            UpdateBanner(updater: updater)
            if !attention.isEmpty { attentionCard }
            if model.enabledProviders.isEmpty {
                MainCard {
                    CardRow(title: L10n.text("provider.none_enabled"))
                }
            } else {
                VStack(spacing: 12) {
                    ForEach(serviceRows, id: \.self) { row in
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(row, id: \.self) { serviceCard($0) }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            tasksCard
        }
    }

    /// A service with both a 5-hour and a weekly window needs the island's
    /// full width for its details, so it gets a row of its own; the others
    /// share rows two at a time above them.
    private var serviceRows: [[AgentProvider]] {
        let wide = model.enabledProviders.filter { provider in
            guard provider != .deepseek, let snapshot = model.providerQuota(provider) else { return false }
            return [QuotaDashboardPresentation.Period.fiveHour, .weekly].allSatisfy {
                QuotaDashboardPresentation.window(provider: provider, snapshot: snapshot, period: $0) != nil
            }
        }
        let narrow = model.enabledProviders.filter { !wide.contains($0) }
        let pairs = stride(from: 0, to: narrow.count, by: 2).map { Array(narrow[$0 ..< min($0 + 2, narrow.count)]) }
        return pairs + wide.map { [$0] }
    }

    private var subtitle: String {
        let date = model.now.formatted(.dateTime.month().day().weekday(.wide).locale(L10n.locale))
        let count = model.visibleActivities.count
        return date + " · " + (count == 0 ? L10n.text("main.overview.no_tasks") : L10n.text(count == 1 ? "main.overview.tasks_one" : "main.overview.tasks", count))
    }

    private var attentionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(attention.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Rectangle().fill(MainPalette.attention.opacity(0.16)).frame(height: 1) }
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 16, weight: .medium))
                        .foregroundStyle(MainPalette.attention).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.system(size: 13, weight: .semibold))
                        Text(item.detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(item.action, action: item.perform).buttonStyle(.main)
                }
                .padding(.vertical, 11)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 16)
        .background(MainPalette.attention.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(MainPalette.attention.opacity(0.25)))
    }

    /// The service's tile and name, a link to its page, and the island's own
    /// quota view for it alone in the chosen style.
    private func serviceCard(_ provider: AgentProvider) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SettingsIconTile(symbol: provider.glyph, tint: provider.tint, glyph: Color.black.opacity(0.72))
                Text(provider.displayName).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(PacerPalette.primary)
                Spacer(minLength: 8)
                Button(L10n.text("main.overview.details")) { open(SettingsPane(provider: provider)) }
                    .buttonStyle(.link).font(.system(size: 12))
            }
            if provider == .deepseek { deepseekContent } else { QuotaDashboardView(model: model, providers: [provider]) }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .islandSurface()
    }

    /// The dial as the island draws it, with today or the budgets and the speed beside it.
    private var deepseekContent: some View {
        let wallet = model.deepseekWallet
        return HStack(alignment: .center, spacing: 18) {
            DeepSeekDialCell(model: model, size: 104, showsName: false).frame(width: 118)
            VStack(alignment: .leading, spacing: 12) {
                if model.deepseekShowsBudgetDial {
                    DeepSeekBudgetDetails(wallet: wallet, now: model.now)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.deepseekSoloPresentation.todayLabel).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(PacerPalette.tertiary)
                        Text(model.deepseekSoloPresentation.todayText).font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundStyle(PacerPalette.primary).monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(model.deepseekSoloPresentation.todayHelp)
                }
                DeepSeekSpeedRow(wallet: wallet)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var tasksCard: some View {
        let rows = Array(model.taskPresentation.rows.prefix(Self.maximumRows))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L10n.text("main.overview.running")).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(PacerPalette.primary)
                Text(model.taskPresentation.taskCountText).font(.system(size: 12)).foregroundStyle(PacerPalette.secondary).monospacedDigit()
                Spacer(minLength: 8)
            }
            .padding(.horizontal, IslandMetrics.rowInset).padding(.bottom, 2)
            if rows.isEmpty {
                HStack(spacing: 10) {
                    StatusGlyph(symbol: StatusSymbols.idle, tint: PacerPalette.secondary)
                    Text(L10n.text("activity.no_tasks")).font(.system(size: 12, weight: .medium)).foregroundStyle(PacerPalette.secondary)
                }
                .padding(.horizontal, IslandMetrics.rowInset).padding(.vertical, 8)
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.activity.id) { index, row in
                    if index > 0 { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.horizontal, IslandMetrics.rowInset) }
                    let activity = row.activity
                    TaskRowView(presentation: row, group: model.taskGroup(for: activity), now: model.now,
                        enabled: model.canOpen(activity), accent: model.taskAccent,
                        costDetail: model.deepseekCostDetail(activity)) {
                            model.open(activity)
                        }
                        .frame(height: 54)
                }
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .islandSurface()
    }
}

/// History: the current quota cycle of one service at a time, picked with
/// chips, then DeepSeek's recent days. Longer ranges arrive with the task record.
struct HistoryPane: View {
    @ObservedObject var model: IslandModel
    @State private var chosen: AgentProvider?
    @State private var showsDetails = false
    @State private var showsResetExpiryDetails = false
    private var quotaProviders: [AgentProvider] { [AgentProvider.codex, .claude].filter { model.enabledProviders.contains($0) } }

    var body: some View {
        MainPage(maxWidth: 900) {
            PageHeader(title: SettingsPane.history.title, subtitle: L10n.text("main.history.subtitle"))
            if let provider = chosen.flatMap({ quotaProviders.contains($0) ? $0 : nil }) ?? quotaProviders.first {
                quotaCard(provider)
            }
            if model.enabledProviders.contains(.deepseek) { deepseekCard }
            if model.enabledProviders.isEmpty {
                MainCard { CardRow(title: L10n.text("provider.none_enabled")) }
            }
        }
    }

    private func chip(_ provider: AgentProvider, selected: Bool) -> some View {
        Button { chosen = provider; showsDetails = false } label: {
            HStack(spacing: 6) {
                Circle().fill(provider.tint).frame(width: 8, height: 8)
                Text(provider.displayName).font(.system(size: 12))
            }
            .padding(.horizontal, 10).frame(height: 24)
            .background(selected ? MainPalette.selectedFill : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? MainPalette.cardBorder : MainPalette.separator))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func quotaCard(_ provider: AgentProvider) -> some View {
        let presentation = model.quotaHistoryPresentation(provider)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(presentation.title).font(.system(size: 13.5, weight: .semibold))
                Spacer(minLength: 8)
                if quotaProviders.count > 1 {
                    HStack(spacing: 6) { ForEach(quotaProviders, id: \.self) { chip($0, selected: $0 == provider) } }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let source = presentation.sourceText { Text(source) }
                Spacer(minLength: 8)
                if presentation.notUpdated {
                    Label(L10n.text("common.not_updated"), systemImage: StatusSymbols.freshness).foregroundStyle(MainPalette.attention)
                }
                Text(presentation.freshnessText)
                Button(presentation.refreshTitle) { model.retryQuotaConnection(for: provider) }
                    .buttonStyle(.main).disabled(presentation.refreshing)
            }
            .font(.system(size: 11.5)).foregroundStyle(.secondary)
            if let error = presentation.errorText {
                Text(error).font(.system(size: 12)).foregroundStyle(MainPalette.attention).fixedSize(horizontal: false, vertical: true)
            }
            if let snapshot = model.providerQuota(provider) {
                if let cycle = model.providerCurrentCycle(provider) {
                    QuotaCycleChart(data: QuotaChartData(cycle: cycle, resetCredits: snapshot.resetCredits, now: model.now),
                        accent: provider.tint, referenceColor: .primary).equatable().padding(.vertical, 4)
                } else if let placeholder = presentation.placeholder {
                    Text(placeholder).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if presentation.account != nil {
                    Rectangle().fill(MainPalette.separator).frame(height: 1)
                    AccountUsageView(snapshot: snapshot, now: model.now, showsExpiryDetails: $showsResetExpiryDetails)
                }
                if !presentation.buckets.isEmpty {
                    Rectangle().fill(MainPalette.separator).frame(height: 1)
                    CardDisclosure(title: L10n.text("settings.quota_details"), isExpanded: $showsDetails)
                    if showsDetails {
                        ForEach(presentation.buckets, id: \.id) { bucket in
                            VStack(alignment: .leading, spacing: 12) {
                                if let title = bucket.title {
                                    Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                                }
                                ForEach(bucket.windows, id: \.id) { window in
                                    QuotaWindowView(reading: window, accent: provider.tint, secondary: .secondary, referenceColor: .primary)
                                }
                            }
                        }
                    }
                }
            } else {
                Text(presentation.placeholder ?? "").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let warning = presentation.warning {
                Label(L10n.text("quota.chart_warning"), systemImage: "exclamationmark.circle")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).help(warning)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mainCardSurface(radius: 14)
    }

    /// The island's week chart on its dark card.
    private var deepseekCard: some View {
        let wallet = model.deepseekWallet
        return VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("main.history.deepseek_week")).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(PacerPalette.primary)
            if DeepSeekWeekChart.hasHistory(wallet) {
                DeepSeekWeekChart(wallet: wallet, now: model.now)
            } else {
                Text(L10n.text("main.history.deepseek_empty")).font(.system(size: 12)).foregroundStyle(PacerPalette.secondary)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .islandSurface()
    }
}

/// A service's quota in one line: what is left in each window, or the error
/// with a retry. Its trend lives on History.
struct ProviderQuotaRow: View {
    @ObservedObject var model: IslandModel
    let provider: AgentProvider
    let openHistory: () -> Void

    var body: some View {
        let error = model.providerQuotaError(provider)
        CardRow(title: L10n.text("main.quota")) {
            if let error {
                Text(error).font(.system(size: 12.5)).foregroundStyle(MainPalette.attention).lineLimit(1).truncationMode(.tail).help(error)
                Button(L10n.text("connections.retry")) { model.retryQuotaConnection(for: provider) }
                    .buttonStyle(.main).disabled(model.providerRefreshing(provider))
            } else {
                Text(summary).font(.system(size: 12.5)).foregroundStyle(.secondary).monospacedDigit()
                Button(L10n.text("main.quota.trend"), action: openHistory).buttonStyle(.link).font(.system(size: 12.5))
            }
        }
    }

    private var summary: String {
        let parts = [QuotaDashboardPresentation.Period.fiveHour, .weekly].compactMap { period -> String? in
            let reading = model.dashboardQuota(provider: provider, period: period).at(model.now)
            guard reading.fraction != nil else { return nil }
            return L10n.text(period == .fiveHour ? "main.quota.left_5h" : "main.quota.left_7d", reading.valueText)
        }
        return parts.isEmpty ? model.providerFreshnessText(provider) : parts.joined(separator: " · ")
    }
}

/// Each event in a row, with where it reminds you in two columns. The
/// collapsed bar's warnings are chosen here. System notifications still follow
/// their one switch (and DeepSeek's, its warning), so that column only shows
/// the result until per-event notifications exist.
struct SettingsNotificationsPane: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var notificationPreference: SystemNotificationPreference
    @Binding var layout: CompactIslandLayout
    @Binding var retention: Int
    @Binding var lowBalance: Double?
    @Binding var spikeLimit: Double?
    let providers: [AgentProvider]
    let openDeepSeek: () -> Void
    private static let column: CGFloat = 76

    private enum Cell {
        case always, none
        case choice(Binding<Bool>, String)
        case follows(Bool, String)
    }

    private var system: Bool { notificationPreference.enabled }
    private var quotaModules: Bool { providers.contains { $0 != .deepseek } }

    var body: some View {
        MainCard {
            CardToggle(title: L10n.text("settings.system_notifications"), isOn: Binding(get: { notificationPreference.enabled },
                set: { notificationPreference.setEnabled($0) }))
            if notificationPreference.denied {
                Text(L10n.text("settings.notification_denied")).font(.system(size: 12)).foregroundStyle(MainPalette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        MainCard(title: L10n.text("main.notify.group.tasks"), titleTrailing: AnyView(columns)) {
            row(L10n.text("main.notify.reply"), bar: .always, system: .follows(system, L10n.text("main.notify.reply")))
            row(L10n.text("main.notify.end"), bar: .always, system: .follows(system, L10n.text("main.notify.end")))
        }
        if quotaModules {
            MainCard(title: L10n.text("main.notify.group.quota")) {
                row(CompactIslandLayout.Warning.fiveHour.label, note: L10n.text("main.notify.low_quota_note"),
                    bar: choice(.fiveHour), system: .follows(system, CompactIslandLayout.Warning.fiveHour.label))
                row(CompactIslandLayout.Warning.quotaDelay.label, bar: choice(.quotaDelay), system: .none)
            }
            MainCard(title: L10n.text("main.pane.remote")) {
                row(CompactIslandLayout.Warning.ssh.label, bar: choice(.ssh), system: .none)
            }
        }
        if providers.contains(.deepseek) {
            MainCard(title: AgentProvider.deepseek.displayName, footer: L10n.text("main.notify.deepseek_one")) {
                row(L10n.text("main.notify.low_balance"),
                    field: amountField($lowBalance, label: L10n.text("reminders.low_balance"), automatic: model.deepseekAutomaticLowLine),
                    bar: choice(.lowBalance), system: follows(.lowBalance))
                row(L10n.text("main.notify.spike"),
                    field: amountField($spikeLimit, label: L10n.text("reminders.spike"), automatic: model.deepseekAutomaticSpikeLimit),
                    bar: choice(.spendSpike), system: follows(.spendSpike))
                row(L10n.text("main.notify.budget"),
                    field: Button(L10n.text("main.notify.budget_link"), action: openDeepSeek).buttonStyle(.link).font(.system(size: 12.5)),
                    bar: choice(.budget), system: follows(.budget))
            }
        }
        MainCard {
            CardPicker(title: L10n.text("reminders.retention"), selection: $retention) {
                Text(L10n.text("settings.five_minutes")).tag(5)
                Text(L10n.text("settings.fifteen_minutes")).tag(15)
                Text(L10n.text("settings.thirty_minutes")).tag(30)
                Text(L10n.text("settings.one_hour")).tag(60)
                Text(L10n.text("settings.four_hours")).tag(240)
                Text(L10n.text("settings.until_clicked")).tag(0)
            }
        }
    }

    private var columns: some View {
        HStack(spacing: 0) {
            Text(L10n.text("main.notify.bar")).frame(width: Self.column)
            Text(L10n.text("settings.system_notifications")).frame(width: Self.column)
        }
        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
    }

    private func row(_ title: String, note: String? = nil, bar: Cell, system: Cell) -> some View {
        row(title, note: note, field: EmptyView(), bar: bar, system: system)
    }

    private func row<Field: View>(_ title: String, note: String? = nil, field: Field, bar: Cell, system: Cell) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 13))
                if let note { Text(note).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                field
            }
            Spacer(minLength: 8)
            cell(bar).frame(width: Self.column)
            cell(system).frame(width: Self.column)
        }
    }

    @ViewBuilder private func cell(_ cell: Cell) -> some View {
        switch cell {
        case .always:
            Text(L10n.text("main.notify.always")).font(.system(size: 12)).foregroundStyle(.secondary)
        case .none:
            Text("—").foregroundStyle(.tertiary).accessibilityLabel(L10n.text("main.notify.unavailable"))
        case .choice(let binding, let label):
            Toggle(label, isOn: binding).labelsHidden().toggleStyle(.checkbox)
        case .follows(let on, let label):
            Toggle(label, isOn: .constant(on)).labelsHidden().toggleStyle(.checkbox).disabled(true)
                .help(L10n.text("main.notify.follows"))
        }
    }

    private func choice(_ warning: CompactIslandLayout.Warning) -> Cell {
        .choice(warningBinding(warning), warning.label + " · " + L10n.text("main.notify.bar"))
    }

    /// DeepSeek's notifications go out only while its collapsed-bar warning is on.
    private func follows(_ warning: CompactIslandLayout.Warning) -> Cell {
        .follows(system && warningBinding(warning).wrappedValue, warning.label + " · " + L10n.text("settings.system_notifications"))
    }

    /// Turning a warning on also brings the warnings slot back if it was removed
    /// from the bar, so this checkbox alone decides what shows.
    private func warningBinding(_ warning: CompactIslandLayout.Warning) -> Binding<Bool> {
        Binding(get: { layout.warnings.contains(warning) && layout.components.contains(.warnings) },
            set: { on in
                if on, !layout.components.contains(.warnings) {
                    // A removed slot comes back with only the warning just chosen.
                    layout.warnings = [warning]
                    layout.move(.warnings, to: .trailing, before: layout.trailing.first)
                } else if on { layout.warnings.insert(warning) }
                else { layout.warnings.remove(warning) }
            })
    }

    /// An empty field follows the rules; its placeholder shows the amount they give now.
    private func amountField(_ value: Binding<Double?>, label: String, automatic: Double) -> some View {
        let shown = automatic.rounded() == automatic || automatic >= 100 ? String(Int(automatic.rounded())) : String(format: "%.1f", automatic)
        return HStack(spacing: 3) {
            Text("¥").foregroundStyle(.secondary)
            TextField(label, value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }),
                      format: .number.precision(.fractionLength(0...2)), prompt: Text(L10n.text("reminders.amount_auto", shown)))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 76).labelsHidden()
        }
        .font(.system(size: 12))
    }
}

/// About Pacer: the version card with updates, then What's New or Help.
struct SettingsAboutPane: View {
    @ObservedObject var updater: AppUpdater
    @Binding var automaticallyChecks: Bool
    @ObservedObject var launchAtLogin: LaunchAtLoginPreference
    let module: AgentProvider
    let onShowWelcome: () -> Void
    @State private var tab = AboutTab.load()

    var body: some View {
        UpdateSettingsView(updater: updater, automaticallyChecks: $automaticallyChecks)
        MainSegmented(options: AboutTab.allCases.map { ($0, $0.title) }, selection: $tab, label: L10n.text("main.pane.about"), expands: true)
            .onChange(of: tab) { _, value in UserDefaults.standard.set(value.rawValue, forKey: AboutTab.defaultsKey) }
        switch tab {
        case .whatsNew: SettingsWhatsNewPane(launchAtLogin: launchAtLogin)
        case .help: SettingsHelpPane(module: module, onShowWelcome: onShowWelcome)
        }
    }
}
