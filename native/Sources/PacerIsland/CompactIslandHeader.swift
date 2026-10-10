import SwiftUI
import PacerCore

/// Unsaved Settings choices affect the preview without changing live collectors or preferences.
struct CompactQuotaPreview {
    let providers: [AgentProvider]
    let metric: String
    let windowIDs: [AgentProvider: String]
    var singleTask: ActivityBadgeSingleTask? = nil
}

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
    var measuresLayout = true
    var quotaPreview: CompactQuotaPreview? = nil

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
            guard measuresLayout else { return }
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
                showsStatus: layout.components.contains(.status), quotaPreview: quotaPreview) }) { component in
                CompactIslandComponent(model: model, component: component, quotaPreview: quotaPreview)
            }
        }.fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: alignment).clipped()
    }
}

struct CompactIslandComponent: View {
    @ObservedObject var model: IslandModel
    let component: CompactIslandLayout.Component
    var quotaPreview: CompactQuotaPreview? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.islandLayoutProbe) private var layoutProbe
    private var providers: [AgentProvider] { quotaPreview?.providers ?? model.enabledProviders }
    /// Expanded rings repeat these values in more detail, so the header quiets
    /// them instead of moving the row; Settings previews keep them at full strength.
    static func dimsWhenExpanded(_ component: CompactIslandLayout.Component) -> Bool {
        [.quota, .quotaGauge, .quotaLabel, .timeRemaining].contains(component)
    }
    private var dimmed: Bool { quotaPreview == nil && model.expanded && Self.dimsWhenExpanded(component) }

    static func isVisible(_ component: CompactIslandLayout.Component, model: IslandModel, showsStatus: Bool = true,
                          quotaPreview: CompactQuotaPreview? = nil) -> Bool {
        guard component.isAvailable(for: Set(quotaPreview?.providers ?? model.enabledProviders)) else { return false }
        switch component {
        case .tps: return model.showsRate && model.rate != nil && (!showsStatus || !model.hidesHeaderRate)
        case .lowQuotaWarning: return !fiveHourAlerts(model, quotaPreview: quotaPreview).isEmpty
        case .quotaDelayWarning: return !delayedQuotaProviders(model, quotaPreview: quotaPreview).isEmpty
        case .sshWarning: return model.hasSSHConnectionIssue
        default: return true
        }
    }
    /// Alternation skips providers without a value, so an unavailable service
    /// never spends half the time as a dash; with none known, the first shows one.
    static func alternatingProviders(_ model: IslandModel, quotaPreview: CompactQuotaPreview? = nil) -> [AgentProvider] {
        let providers = quotaPreview?.providers ?? model.enabledProviders
        let known = providers.filter {
            model.compactQuotaValue($0, metric: quotaPreview?.metric, selection: quotaPreview?.windowIDs[$0]) != nil
        }
        return known.isEmpty ? Array(providers.prefix(1)) : known
    }
    static func fiveHourAlerts(_ model: IslandModel, quotaPreview: CompactQuotaPreview? = nil) -> [(provider: AgentProvider, alert: FiveHourQuotaAlert)] {
        (quotaPreview?.providers ?? model.enabledProviders).compactMap { provider in
            model.fiveHourAlert(provider).map { (provider, $0) }
        }
    }
    private static func delayedQuotaProviders(_ model: IslandModel, quotaPreview: CompactQuotaPreview? = nil) -> [AgentProvider] {
        (quotaPreview?.providers ?? model.enabledProviders).filter { provider in
            model.providerQuotaError(provider) != nil ||
                model.providerQuota(provider)?.isStale(at: model.now) == true ||
                model.providerSelectedWindow(provider, selection: quotaPreview?.windowIDs[provider])?.resetsAt.map({ $0 <= model.now }) == true
        }
    }
    var body: some View {
        Button(action: action) { content.padding(.vertical, 4).contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .lineLimit(1)
            .help(help)
            .opacity(dimmed ? 0.3 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: dimmed)
    }
    @ViewBuilder private var content: some View {
        switch component {
        case .activity:
            ActivityBadge(activity: model.headerActivity(singleTask: quotaPreview?.singleTask))
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
        case .lowQuotaWarning:
            HStack(spacing: 3) {
                ForEach(Self.fiveHourAlerts(model, quotaPreview: quotaPreview), id: \.provider) { item in
                    FiveHourAlertGlyph(alert: item.alert, tint: item.provider.tint)
                }
            }
            .accessibilityElement(children: .ignore).accessibilityLabel(fiveHourSummary)
        case .quota:
            let shown = Self.alternatingProviders(model, quotaPreview: quotaPreview)
            Group {
                if shown.count > 1 {
                    AlternatingQuotaText(entries: shown.map { .init(text: quotaText($0), color: NSColor($0.tint)) },
                        animates: !layoutProbe)
                } else if let provider = shown.first {
                    Text(quotaText(provider)).font(.system(size: 12, weight: .semibold)).foregroundStyle(provider.tint)
                        .monospacedDigit().fixedSize(horizontal: true, vertical: false)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(providers.map { L10n.text("provider.compact_quota", $0.displayName, quotaText($0)) }.joined(separator: ", "))
        case .quotaGauge:
            QuotaRingsGlyph(rings: providers.map { provider in
                let window = model.providerSelectedWindow(provider, selection: quotaPreview?.windowIDs[provider])
                return .init(tint: provider.tint, remaining: model.providerQuotaError(provider) == nil ? window?.remainingPercent : nil,
                    stale: model.providerQuotaIsStale(provider))
            })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(gaugeSummary)
        case .quotaLabel:
            Text(quotaPreview.map { L10n.text($0.metric == "pace" ? "quota.pace" : "layout.quota_label") } ?? model.compactMetricLabel)
                .font(.system(size: 10, weight: .medium)).foregroundStyle(PacerPalette.tertiary)
        case .timeRemaining:
            HStack(spacing: 4) {
                Image(systemName: "hourglass").font(.system(size: 9, weight: .semibold)).foregroundStyle(PacerPalette.tertiary)
                providerValues(spacing: 7) { provider in
                    Text(timeText(provider)).font(.system(size: 11, weight: .medium)).foregroundStyle(provider.tint.opacity(0.85))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(L10n.text("provider.compact_time", provider.displayName, timeText(provider)))
                }
            }.monospacedDigit().fixedSize(horizontal: true, vertical: false)
        case .quotaDelayWarning:
            Image(systemName: StatusSymbols.freshness).font(.system(size: 11, weight: .semibold)).foregroundStyle(PacerPalette.attention)
                .accessibilityLabel(component.label)
        case .sshWarning:
            Image(systemName: StatusSymbols.sshWarning).font(.system(size: 11, weight: .semibold)).foregroundStyle(PacerPalette.attention)
                .accessibilityLabel(component.label)
        }
    }
    /// Provider values stay color-coded without names; a hairline separates them.
    private func providerValues<Value: View>(spacing: CGFloat, @ViewBuilder value: @escaping (AgentProvider) -> Value) -> some View {
        HStack(spacing: spacing) {
            ForEach(Array(providers.enumerated()), id: \.element.rawValue) { index, provider in
                if index > 0 { Rectangle().fill(PacerPalette.hairline).frame(width: 1, height: 10).accessibilityHidden(true) }
                value(provider)
            }
        }
    }
    private var fiveHourSummary: String {
        Self.fiveHourAlerts(model, quotaPreview: quotaPreview).map { item in
            switch item.alert {
            case .low(let remaining): L10n.text("quota.five_hour_low", item.provider.displayName, "\(Int(remaining.rounded()))%")
            case .exhausted: L10n.text("quota.five_hour_exhausted", item.provider.displayName)
            }
        }.joined(separator: " · ")
    }
    private var gaugeSummary: String {
        providers.map { provider in
            let remaining = model.providerSelectedWindow(provider, selection: quotaPreview?.windowIDs[provider])?.remainingPercent
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
        case .lowQuotaWarning: return fiveHourSummary
        case .quotaGauge: return gaugeSummary + "\n" + L10n.text("layout.gauge_help")
        case .quotaDelayWarning: return Self.delayedQuotaProviders(model, quotaPreview: quotaPreview).map(\.displayName).joined(separator: " · ") + " · " + component.label
        case .timeRemaining:
            return providers.map { L10n.text("provider.compact_time", $0.displayName, timeText($0)) }
                .joined(separator: " · ") + "\n" + L10n.text("layout.time_remaining_help")
        case .quota, .quotaLabel:
            return providers.map { L10n.text("provider.compact_quota", $0.displayName, quotaText($0)) }
                .joined(separator: " · ") + "\n" + L10n.text("layout.metric_help")
        case .sshWarning: return L10n.text("source.ssh_retrying")
        }
    }
    private func quotaText(_ provider: AgentProvider) -> String {
        model.compactQuotaText(provider, metric: quotaPreview?.metric, selection: quotaPreview?.windowIDs[provider])
    }
    private func timeText(_ provider: AgentProvider) -> String {
        model.compactTimeRemainingText(provider, selection: quotaPreview?.windowIDs[provider])
    }
    private func action() {
        switch component {
        case .activity, .status: model.openCompletionOrPin()
        default: model.togglePin()
        }
    }
}

struct CompactHeaderIdealWidth: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
