import SwiftUI
import PacerCore

/// Both display modes have only left and right content. A real camera needs
/// equal wings; floating headers use each side's natural width.
struct CompactRowLayout: Layout {
    var notchWidth: CGFloat = 0
    private var cameraGap: CGFloat { notchWidth > 0 ? notchWidth + 8 : 0 }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        guard sizes.count == 2 else { return .zero }
        let left = sizes[0].width, right = sizes[1].width
        let natural = cameraGap > 0 ? cameraGap + 2 * max(left, right) + 16 :
            left + right + (left > 0 && right > 0 ? 10 : 0)
        return CGSize(width: proposal.width ?? natural, height: sizes.map(\.height).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let gap = cameraGap > 0 ? cameraGap + 16 : (sizes[0].width > 0 && sizes[1].width > 0 ? 10 : 0)
        let available = max(0, bounds.width - gap)
        let total = max(1, sizes[0].width + sizes[1].width)
        let slots = cameraGap > 0 ? [available / 2, available / 2] :
            [available * sizes[0].width / total, available * sizes[1].width / total]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: slots[index], height: bounds.height))
            let x = index == 0 ? bounds.minX : bounds.maxX - size.width
            subviews[index].place(at: CGPoint(x: x, y: bounds.midY - size.height / 2), proposal: ProposedViewSize(size))
        }
    }
}

struct CompactIslandHeader: View {
    @ObservedObject var model: IslandModel
    let layout: CompactIslandLayout
    let baseHeight: CGFloat
    let notchWidth: CGFloat

    var body: some View {
        rowView
            .padding(.horizontal, IslandMetrics.headerInset)
            .frame(height: baseHeight)
            .background {
                rowView.fixedSize().background(GeometryReader { geometry in
                    Color.clear.preference(key: CompactHeaderIdealWidth.self, value: geometry.size.width + 2 * IslandMetrics.headerInset)
                }).environment(\.islandLayoutProbe, true).hidden().allowsHitTesting(false).accessibilityHidden(true)
            }
        .onPreferenceChange(CompactHeaderIdealWidth.self) { width in
            DispatchQueue.main.async { model.updateMeasuredCompactWidth(width) }
        }
        .contentShape(Rectangle())
        .background(Color.clear.contentShape(Rectangle()).onTapGesture { model.togglePin() })
        .contextMenu {
            Button(L10n.text("common.settings")) { model.onSettings?() }
            Button(L10n.text("common.quit")) { model.onQuit?() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("layout.collapsed"))
    }

    private var rowView: some View {
        CompactRowLayout(notchWidth: notchWidth) {
            lane(layout.leading, alignment: .leading)
            lane(layout.trailing, alignment: .trailing)
        }
    }
    private func lane(_ components: [CompactIslandLayout.Component], alignment: Alignment) -> some View {
        HStack(spacing: model.isAttached ? 6 : 8) {
            ForEach(components.filter { CompactIslandComponent.isVisible($0, model: model,
                showsStatus: layout.components.contains(.status)) }) { component in
                CompactIslandComponent(model: model, component: component)
            }
        }.fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: alignment).clipped()
    }
}

/// The collapsed bar on its side for a docked corner: the left lane stacks
/// above the right lane, one component per row, in a column whose height
/// follows them. Both sides keep this order, so a layout reads the same. The
/// lanes hold the column's top and bottom edges, so opening the panel draws
/// them apart with the window and closing brings them back together.
struct CompactIslandStrip: View {
    @ObservedObject var model: IslandModel
    let layout: CompactIslandLayout
    /// Values stay within the activity badge's width.
    static let valueWidth: CGFloat = 20

    var body: some View {
        column
            .frame(width: IslandGeometry.stripWidth)
            .frame(maxHeight: .infinity)
            .background {
                column.fixedSize().background(GeometryReader { geometry in
                    Color.clear.preference(key: CompactStripIdealHeight.self, value: geometry.size.height)
                }).environment(\.islandLayoutProbe, true).hidden().allowsHitTesting(false).accessibilityHidden(true)
            }
            .onPreferenceChange(CompactStripIdealHeight.self) { height in
                DispatchQueue.main.async { model.updateMeasuredStripHeight(height) }
            }
            .contentShape(Rectangle())
            .background(Color.clear.contentShape(Rectangle()).onTapGesture { model.togglePin() })
            .contextMenu {
                Button(L10n.text("common.settings")) { model.onSettings?() }
                Button(L10n.text("common.quit")) { model.onQuit?() }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.text("layout.collapsed"))
    }

    private var column: some View {
        let leading = visible(layout.leading), trailing = visible(layout.trailing)
        let divided = !leading.isEmpty && !trailing.isEmpty
        return VStack(spacing: 0) {
            lane(leading)
            Spacer(minLength: divided ? 6 : 0)
            if divided {
                Rectangle().fill(PacerPalette.hairline).frame(width: 16, height: 1).padding(.bottom, 6).accessibilityHidden(true)
            }
            lane(trailing)
        }
        .padding(.vertical, 12)
    }

    private func visible(_ components: [CompactIslandLayout.Component]) -> [CompactIslandLayout.Component] {
        components.filter { $0.showsInStrip && CompactIslandComponent.isVisible($0, model: model, showsStatus: false) }
    }

    private func lane(_ components: [CompactIslandLayout.Component]) -> some View {
        VStack(spacing: 4) {
            ForEach(components) { component in
                CompactIslandComponent(model: model, component: component, vertical: true)
            }
        }
    }
}

struct CompactIslandComponent: View {
    @ObservedObject var model: IslandModel
    let component: CompactIslandLayout.Component
    /// Stacked for the docked strip: values sit above their units, multiple
    /// providers one above another.
    var vertical = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.islandLayoutProbe) private var layoutProbe
    private var providers: [AgentProvider] { model.enabledProviders }
    /// Time remaining describes quota windows, which DeepSeek's wallet lacks.
    private var percentageProviders: [AgentProvider] { providers.filter { $0 != .deepseek } }
    /// Expanded rings repeat these values in more detail, so the header quiets
    /// them instead of moving the row.
    static func dimsWhenExpanded(_ component: CompactIslandLayout.Component) -> Bool {
        [.quota, .quotaGauge, .quotaLabel, .timeRemaining, .priceClock].contains(component)
    }
    private var dimmed: Bool { model.expanded && Self.dimsWhenExpanded(component) }

    static func isVisible(_ component: CompactIslandLayout.Component, model: IslandModel, showsStatus: Bool = true) -> Bool {
        guard component.isAvailable(for: Set(model.enabledProviders)) else { return false }
        switch component {
        case .tps: return model.showsRate && model.rate != nil && (!showsStatus || !model.hidesHeaderRate)
        case .warnings: return !activeWarnings(model).isEmpty
        case .quotaGauge: return !model.compactRingProviders.isEmpty || model.compactGaugeShowsPriceClock
        default: return true
        }
    }
    /// Alternation skips providers without a value, so an unavailable service
    /// never spends half the time as a dash; with none known, the first shows one.
    static func alternatingProviders(_ model: IslandModel) -> [AgentProvider] {
        let providers = model.enabledProviders
        let known = providers.filter {
            $0 == .deepseek ? model.deepseekBalance != nil || model.deepseekValueShowsBudget : model.compactQuotaValue($0) != nil
        }
        return known.isEmpty ? Array(providers.prefix(1)) : known
    }
    /// Enabled warnings whose condition holds now, in display order. DeepSeek
    /// shows only its most urgent alert; an empty wallet shows even when its
    /// reminder is off.
    static func activeWarnings(_ model: IslandModel) -> [CompactIslandLayout.Warning] {
        let enabled = model.compactLayout.warnings
        var result = CompactIslandLayout.Warning.allCases.filter { warning in
            guard enabled.contains(warning) else { return false }
            switch warning {
            case .fiveHour: return !fiveHourAlerts(model).isEmpty
            case .ssh: return model.hasSSHConnectionIssue
            case .quotaDelay: return !delayedQuotaProviders(model).isEmpty
            case .lowBalance, .spendSpike, .budget: return false
            }
        }
        switch model.deepseekAlert {
        case nil: break
        case .exhausted?, .lowBalance?: result.append(.lowBalance)
        case .spike?: result.append(.spendSpike)
        case .overBudget?, .nearingBudget?: result.append(.budget)
        }
        return result
    }
    static func fiveHourAlerts(_ model: IslandModel) -> [(provider: AgentProvider, alert: FiveHourQuotaAlert)] {
        model.enabledProviders.compactMap { provider in
            model.fiveHourAlert(provider).map { (provider, $0) }
        }
    }
    /// A late DeepSeek balance dims its ring and value instead of adding a mark.
    private static func delayedQuotaProviders(_ model: IslandModel) -> [AgentProvider] {
        model.enabledProviders.filter { provider in
            guard provider != .deepseek else { return false }
            return model.providerQuotaError(provider) != nil ||
                model.providerQuota(provider)?.isStale(at: model.now) == true ||
                model.providerSelectedWindow(provider)?.resetsAt.map({ $0 <= model.now }) == true
        }
    }
    var body: some View {
        Button(action: action) {
            Group { if vertical { stripContent } else { content } }
                .padding(.vertical, vertical ? 2 : 4).frame(maxWidth: vertical ? .infinity : nil).contentShape(Rectangle())
        }
            .buttonStyle(.plain)
            .lineLimit(1)
            .help(help)
            .opacity(dimmed ? 0.3 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: dimmed)
    }
    @ViewBuilder private var content: some View {
        switch component {
        case .activity:
            ActivityBadge(activity: model.headerActivity())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(activitySummary)
        case .status:
            Text(model.headerDisplayStatus).font(.system(size: 12, weight: .medium)).foregroundStyle(PacerPalette.primary)
        case .tps:
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(model.headerRateText ?? "—").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(model.rateIsFresh ? PacerPalette.primary : PacerPalette.secondary)
                Text("t/s").font(.system(size: 9, weight: .medium)).foregroundStyle(PacerPalette.tertiary)
            }.fixedSize(horizontal: true, vertical: false)
        case .firstOutput:
            Text(model.latestFirstOutputLatency.map { String(format: "%.2f s", $0) } ?? "—")
                .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(PacerPalette.secondary)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel(L10n.text("performance.first_output", model.latestFirstOutputLatency.map { String(format: "%.2f s", $0) } ?? "—"))
        case .warnings:
            HStack(spacing: 4) { warningGlyphs }
                .accessibilityElement(children: .ignore).accessibilityLabel(warningSummary)
        case .quota:
            let shown = Self.alternatingProviders(model)
            Group {
                if shown.count > 1 {
                    AlternatingQuotaText(entries: shown.map { .init(text: quotaText($0), color: valueColor($0)) },
                        animates: !layoutProbe)
                } else if let provider = shown.first {
                    Text(quotaText(provider)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(nsColor: valueColor(provider)))
                        .monospacedDigit().fixedSize(horizontal: true, vertical: false)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(providers.map { L10n.text("provider.compact_quota", $0.displayName, quotaText($0)) }.joined(separator: ", "))
        case .quotaGauge:
            if model.compactGaugeShowsPriceClock { priceClock } else {
                QuotaRingsGlyph(rings: model.compactRingProviders.map { provider in
                    if provider == .deepseek {
                        let budget = model.deepseekWallet.ringBudget(prefer: model.deepseekRingPeriod)
                        return .init(tint: provider.tint, remaining: budget.map { max(0, $0.remaining) / $0.limit * 100 },
                            stale: model.deepseekWalletDimmed)
                    }
                    let window = model.providerSelectedWindow(provider)
                    return .init(tint: provider.tint, remaining: model.providerQuotaError(provider) == nil ? window?.remainingPercent : nil,
                        stale: model.providerQuotaIsStale(provider))
                })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(gaugeSummary)
            }
        case .priceClock:
            priceClock
        case .quotaLabel:
            Text(model.compactMetricLabel)
                .font(.system(size: 10, weight: .medium)).foregroundStyle(PacerPalette.tertiary)
        case .timeRemaining:
            HStack(spacing: 4) {
                Image(systemName: "hourglass").font(.system(size: 9, weight: .semibold)).foregroundStyle(PacerPalette.tertiary)
                providerValues(percentageProviders, spacing: 7) { provider in
                    Text(timeText(provider)).font(.system(size: 11, weight: .medium)).foregroundStyle(provider.tint.opacity(0.85))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(L10n.text("provider.compact_time", provider.displayName, timeText(provider)))
                }
            }.monospacedDigit().fixedSize(horizontal: true, vertical: false)
        }
    }
    private var priceClock: some View {
        let wallet = model.deepseekWallet
        return PriceClockGlyph(hourly: wallet.hourly, peaks: wallet.peakToday.map { wallet.angle(of: $0.start)...wallet.angle(of: $0.end) },
            now: wallet.angle(of: model.now), dimmed: model.deepseekWalletDimmed)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("deepseek.clock_accessibility", L10n.text(wallet.peakNow ? "deepseek.now.peak" : "deepseek.now.offpeak"),
                DeepSeekDayDial.amount(wallet.todayTotal)))
    }
    /// Values keep their service's color; an unread DeepSeek wallet dims instead.
    private func valueColor(_ provider: AgentProvider) -> NSColor {
        NSColor(provider.tint).withAlphaComponent(provider == .deepseek && model.deepseekWalletDimmed ? 0.45 : 1)
    }
    /// Provider values stay color-coded without names; a hairline separates them.
    @ViewBuilder private var warningGlyphs: some View {
        ForEach(Self.activeWarnings(model), id: \.self) { warning in
            switch warning {
            case .fiveHour:
                ForEach(Self.fiveHourAlerts(model), id: \.provider) { item in
                    FiveHourAlertGlyph(alert: item.alert, tint: item.provider.tint)
                }
            case .ssh:
                Image(systemName: StatusSymbols.sshWarning).font(.system(size: 11, weight: .semibold)).foregroundStyle(PacerPalette.attention)
            case .quotaDelay:
                Image(systemName: StatusSymbols.freshness).font(.system(size: 11, weight: .semibold)).foregroundStyle(PacerPalette.attention)
            case .lowBalance, .spendSpike, .budget:
                if let alert = model.deepseekAlert { DeepSeekAlertGlyph(alert: alert) }
            }
        }
    }
    /// The strip's stacked forms: each number sits above its unit at a size
    /// that keeps three digits within the badge's width; longer values shrink.
    /// The badge and rings are already that narrow.
    @ViewBuilder private var stripContent: some View {
        switch component {
        case .tps:
            VStack(spacing: 0) {
                stripNumber(model.headerRateText ?? "—", color: model.rateIsFresh ? PacerPalette.primary : PacerPalette.secondary)
                stripUnit("t/s")
            }
        case .firstOutput:
            VStack(spacing: 0) {
                stripNumber(model.latestFirstOutputLatency.map { String(format: $0 < 10 ? "%.1f" : "%.0f", $0) } ?? "—",
                    color: PacerPalette.secondary)
                stripUnit("s")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("performance.first_output", model.latestFirstOutputLatency.map { String(format: "%.2f s", $0) } ?? "—"))
        case .quota:
            let shown = Self.alternatingProviders(model)
            VStack(spacing: 0) {
                // A wallet value carries its own sign, so a mixed column drops the shared unit.
                let wallet = shown.contains(.deepseek)
                let text = { (provider: AgentProvider) in provider == .deepseek ? model.compactStripWalletText : (model.compactQuotaNumber(provider).map { wallet ? $0 + "%" : $0 } ?? "—") }
                if shown.count > 1 {
                    AlternatingQuotaText(entries: shown.map { .init(text: text($0), color: valueColor($0)) },
                        animates: !layoutProbe, font: .monospacedDigitSystemFont(ofSize: Self.stripNumberSize, weight: .semibold))
                } else if let provider = shown.first {
                    stripNumber(text(provider), color: Color(nsColor: valueColor(provider)))
                }
                if !wallet { stripUnit("%") }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(providers.map { L10n.text("provider.compact_quota", $0.displayName, quotaText($0)) }.joined(separator: ", "))
        case .timeRemaining:
            VStack(spacing: 1) {
                Image(systemName: "hourglass").font(.system(size: 9, weight: .semibold)).foregroundStyle(PacerPalette.tertiary)
                ForEach(percentageProviders, id: \.rawValue) { provider in
                    stripNumber(model.compactTimeRemainingNumber(provider) ?? "—", color: provider.tint.opacity(0.85))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(L10n.text("provider.compact_time", provider.displayName, timeText(provider)))
                }
                stripUnit("%")
            }
        case .warnings:
            VStack(spacing: 4) { warningGlyphs }
                .accessibilityElement(children: .ignore).accessibilityLabel(warningSummary)
        default:
            content
        }
    }
    private static let stripNumberSize: CGFloat = 10
    private func stripNumber(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: Self.stripNumberSize, weight: .semibold)).monospacedDigit().foregroundStyle(color)
            .lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: CompactIslandStrip.valueWidth)
    }
    private func stripUnit(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .medium)).foregroundStyle(PacerPalette.tertiary)
    }
    private func providerValues<Value: View>(_ shown: [AgentProvider], spacing: CGFloat, @ViewBuilder value: @escaping (AgentProvider) -> Value) -> some View {
        HStack(spacing: spacing) {
            ForEach(Array(shown.enumerated()), id: \.element.rawValue) { index, provider in
                if index > 0 { Rectangle().fill(PacerPalette.hairline).frame(width: 1, height: 10).accessibilityHidden(true) }
                value(provider)
            }
        }
    }
    private var fiveHourSummary: String {
        Self.fiveHourAlerts(model).map { item in
            switch item.alert {
            case .low(let remaining): L10n.text("quota.five_hour_low", item.provider.displayName, "\(Int(remaining.rounded()))%")
            case .exhausted: L10n.text("quota.five_hour_exhausted", item.provider.displayName)
            }
        }.joined(separator: " · ")
    }
    private var warningSummary: String {
        Self.activeWarnings(model).map { warning in
            switch warning {
            case .fiveHour: fiveHourSummary
            case .ssh: L10n.text("source.ssh_retrying")
            case .quotaDelay: Self.delayedQuotaProviders(model).map(\.displayName).joined(separator: " · ")
                + " · " + warning.label
            case .lowBalance, .spendSpike, .budget: deepseekAlertSummary
            }
        }.joined(separator: "\n")
    }
    private var deepseekAlertSummary: String {
        let wallet = model.deepseekWallet
        switch model.deepseekAlert {
        case .exhausted?: return "DeepSeek · " + L10n.text("deepseek.notice.exhausted")
        case .lowBalance?: return "DeepSeek · " + L10n.text("deepseek.notice.low")
        case .spike?: return "DeepSeek · " + L10n.text("deepseek.notice.spike")
        case .overBudget(let kind)?: return "DeepSeek · " + L10n.text(kind == .day ? "deepseek.notice.day_over" : "deepseek.notice.week_over")
        case .nearingBudget(let kind)?:
            let used = Int(((wallet.budget(kind)?.usedFraction ?? 0.8) * 100).rounded())
            return "DeepSeek · " + L10n.text(kind == .day ? "deepseek.alert.day_used" : "deepseek.alert.week_used", used)
        case nil: return ""
        }
    }
    private var gaugeSummary: String {
        model.compactRingProviders.map { provider in
            if provider == .deepseek {
                let budget = model.deepseekWallet.ringBudget(prefer: model.deepseekRingPeriod)
                return L10n.text("provider.compact_quota", provider.displayName, budget.map { DeepSeekWallet.compactRemaining($0.remaining) } ?? "—")
            }
            let remaining = model.providerSelectedWindow(provider)?.remainingPercent
            return L10n.text("provider.compact_quota", provider.displayName, remaining.map { "\(Int(min(100, max(0, $0)).rounded()))%" } ?? "—")
        }.joined(separator: " · ")
    }
    /// The count and the most urgent state, without repeating a count-only status.
    private var activitySummary: String {
        let count = model.running.count + model.waiting.count
        let tasks = count == 0 ? nil : L10n.text(count == 1 ? "activity.task_count_compact_singular" : "activity.task_count_compact",
            count > 99 ? "99+" : String(count))
        return [tasks, model.headerStatus].compactMap { $0 }.reduce(into: [String]()) { parts, part in
            if !parts.contains(part) { parts.append(part) }
        }.joined(separator: " · ")
    }
    private var help: String {
        switch component {
        case .activity, .status:
            return L10n.text(model.pendingInputRequests.isEmpty && model.pendingCompletions.isEmpty ? "activity.header_pin" : "activity.header_open",
                component == .activity ? activitySummary : model.headerStatus)
        case .tps: return model.rateHelp
        case .firstOutput: return L10n.text("layout.latest_ttft_help")
        case .warnings: return warningSummary
        case .quotaGauge: return model.compactGaugeShowsPriceClock ? "" : gaugeSummary + "\n" + L10n.text("layout.gauge_help")
        case .priceClock: return ""
        case .timeRemaining:
            return percentageProviders.map { L10n.text("provider.compact_time", $0.displayName, timeText($0)) }
                .joined(separator: " · ") + "\n" + L10n.text("layout.time_remaining_help")
        case .quota, .quotaLabel:
            return providers.map { L10n.text("provider.compact_quota", $0.displayName, quotaText($0)) }
                .joined(separator: " · ") + "\n" + L10n.text("layout.metric_help")
        }
    }
    private func quotaText(_ provider: AgentProvider) -> String {
        model.compactQuotaText(provider)
    }
    private func timeText(_ provider: AgentProvider) -> String {
        model.compactTimeRemainingText(provider)
    }
    private func action() {
        switch component {
        case .activity, .status: model.openCompletionOrPin()
        default: model.togglePin()
        }
    }
}

struct CompactStripIdealHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct CompactHeaderIdealWidth: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
