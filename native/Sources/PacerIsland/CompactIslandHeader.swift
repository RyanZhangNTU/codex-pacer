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
    var measuresLayout = true

    var body: some View {
        rowView
            .padding(.horizontal, 15)
            .frame(height: baseHeight)
            .background {
                rowView.fixedSize().background(GeometryReader { geometry in
                    Color.clear.preference(key: CompactHeaderIdealWidth.self, value: geometry.size.width + 30)
                }).hidden().allowsHitTesting(false).accessibilityHidden(true)
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
        HStack(spacing: model.isAttached ? 4 : 6) {
            ForEach(components.filter { CompactIslandComponent.isVisible($0, model: model,
                showsStatus: layout.components.contains(.status)) }) { component in
                CompactIslandComponent(model: model, component: component)
            }
        }.fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: alignment).clipped()
    }
}

struct CompactIslandComponent: View {
    @ObservedObject var model: IslandModel
    let component: CompactIslandLayout.Component
    private let secondary = Color(red: 0.67, green: 0.69, blue: 0.73)

    static func isVisible(_ component: CompactIslandLayout.Component, model: IslandModel, showsStatus: Bool = true) -> Bool {
        switch component {
        case .tps: return model.showsRate && model.rate != nil && (!showsStatus || !model.hidesHeaderRate)
        case .lowQuotaWarning: return !lowQuotaProviders(model).isEmpty
        case .quotaDelayWarning: return !delayedQuotaProviders(model).isEmpty
        case .sshWarning: return model.hasSSHConnectionIssue
        case .quotaMetric, .quotaLabel, .timeRemaining: return !model.enabledProviders.isEmpty
        default: return true
        }
    }
    private static func lowQuotaProviders(_ model: IslandModel) -> [AgentProvider] {
        model.enabledProviders.filter { provider in
            guard model.providerQuotaError(provider) == nil,
                  let snapshot = model.providerQuota(provider), !snapshot.isStale(at: model.now),
                  let window = model.providerSelectedWindow(provider),
                  window.resetsAt.map({ $0 > model.now }) ?? true,
                  let remaining = window.remainingPercent else { return false }
            return remaining <= 15
        }
    }
    private static func delayedQuotaProviders(_ model: IslandModel) -> [AgentProvider] {
        model.enabledProviders.filter { provider in
            model.providerQuotaError(provider) != nil ||
                model.providerQuota(provider)?.isStale(at: model.now) == true ||
                model.providerSelectedWindow(provider)?.resetsAt.map({ $0 <= model.now }) == true
        }
    }
    var body: some View {
        Button(action: action) { content.padding(.vertical, 4).contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .lineLimit(1)
            .help(help)
    }
    @ViewBuilder private var content: some View {
        switch component {
        case .statusIcon:
            Image(systemName: model.headerSymbol).font(.system(size: 12)).foregroundStyle(model.headerTint)
                .accessibilityLabel(component.label)
        case .status:
            Text(model.headerDisplayStatus).fontWeight(.medium)
        case .tps:
            HStack(spacing: 4) {
                Text(model.headerRateText ?? "—").monospacedDigit()
                    .foregroundStyle(model.rateIsFresh ? Color.white : secondary)
                Text("t/s").font(.system(size: 9)).foregroundStyle(secondary)
            }.font(.system(size: 10)).fixedSize(horizontal: true, vertical: false)
        case .taskCount:
            let count = model.running.count + model.waiting.count
            Text(count > 99 ? "99+" : String(count)).font(.system(size: 10, weight: .semibold)).monospacedDigit()
                .frame(minWidth: 16, minHeight: 16).padding(.horizontal, count < 10 ? 0 : 2)
                .background(Color.white.opacity(0.08), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.6))
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel(L10n.text(count == 1 ? "activity.task_count_compact_singular" : "activity.task_count_compact", String(count)))
        case .firstOutput:
            Text(model.latestFirstOutputLatency.map { String(format: "%.2f s", $0) } ?? "—").monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel(L10n.text("performance.first_output", model.latestFirstOutputLatency.map { String(format: "%.2f s", $0) } ?? "—"))
        case .lowQuotaWarning:
            let exhausted = Self.lowQuotaProviders(model).contains { (model.providerSelectedWindow($0)?.remainingPercent ?? 100) <= 0 }
            Image(systemName: exhausted ? StatusSymbols.empty : StatusSymbols.low)
                .foregroundStyle(exhausted ? Color.red : Color.orange)
                .accessibilityLabel(L10n.text(exhausted ? "quota.exhausted" : "notice.low_quota"))
        case .quotaMetric:
            HStack(spacing: 8) {
                ForEach(model.enabledProviders, id: \.rawValue) { provider in
                    Text(quotaText(provider)).foregroundStyle(provider.tint)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.text("provider.compact_quota", provider.displayName, quotaText(provider)))
                }
            }.font(.system(size: 12, weight: .medium)).monospacedDigit().fixedSize(horizontal: true, vertical: false)
        case .quotaLabel:
            Text(model.compactMetricLabel).font(.system(size: 10)).foregroundStyle(secondary)
        case .timeRemaining:
            HStack(spacing: model.enabledProviders.count > 1 ? 8 : 3) {
                Image(systemName: "hourglass").font(.system(size: 9))
                ForEach(model.enabledProviders, id: \.rawValue) { provider in
                    Text(timeText(provider)).monospacedDigit().foregroundStyle(provider.tint)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.text("provider.compact_time", provider.displayName, timeText(provider)))
                }
            }.foregroundStyle(secondary).fixedSize(horizontal: true, vertical: false)
        case .quotaDelayWarning:
            Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange)
                .accessibilityLabel(component.label)
        case .sshWarning:
            Image(systemName: "wifi.slash").foregroundStyle(.orange).accessibilityLabel(component.label)
        }
    }
    private var help: String {
        switch component {
        case .statusIcon, .status:
            return L10n.text(model.pendingInputRequests.isEmpty && model.pendingCompletions.isEmpty ? "activity.header_pin" : "activity.header_open", model.headerStatus)
        case .tps: return model.rateHelp
        case .firstOutput: return L10n.text("layout.latest_ttft_help")
        case .lowQuotaWarning: return Self.lowQuotaProviders(model).map(\.displayName).joined(separator: " · ") + " · " + component.label
        case .quotaDelayWarning: return Self.delayedQuotaProviders(model).map(\.displayName).joined(separator: " · ") + " · " + component.label
        case .timeRemaining:
            return model.enabledProviders.map { L10n.text("provider.compact_time", $0.displayName, timeText($0)) }
                .joined(separator: " · ") + "\n" + L10n.text("layout.time_remaining_help")
        case .quotaMetric, .quotaLabel:
            return model.enabledProviders.map { L10n.text("provider.compact_quota", $0.displayName, quotaText($0)) }
                .joined(separator: " · ") + "\n" + L10n.text("layout.metric_help")
        case .sshWarning: return L10n.text("source.ssh_retrying")
        default: return component.label
        }
    }
    private func quotaText(_ provider: AgentProvider) -> String { model.compactQuotaText(provider) }
    private func timeText(_ provider: AgentProvider) -> String { model.compactTimeRemainingText(provider) }
    private func action() {
        switch component {
        case .statusIcon, .status: model.openCompletionOrPin()
        default: model.togglePin()
        }
    }
}

struct CompactHeaderIdealWidth: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
