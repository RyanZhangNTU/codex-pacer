import SwiftUI
import PacerCore

struct IslandView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var presentation: IslandPresentation
    private var attached: Bool { model.isAttached }

    var body: some View {
        VStack(spacing: 0) {
            CompactIslandHeader(model: model, layout: model.compactLayout,
                baseHeight: model.baseHeaderHeight, notchWidth: model.notchWidth)
                .background(attached && model.appearance == .liquidGlass
                    ? Color.black.opacity(presentation.blackOpacity) : Color.clear)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .top) {
            // Retire invisible content before the spring settles, so the final
            // capsule frame only stops motion rather than changing its subtree.
            if model.expanded || presentation.contentVisibility > 0 {
                IslandExpandedContent(model: model)
                    .frame(width: max(0, presentation.canvas.width - 46),
                           height: max(0, presentation.canvas.height - model.topHeight), alignment: .top)
                    .padding(.horizontal, 23)
                    .opacity(presentation.contentVisibility)
                    .offset(y: model.topHeight + (1 - presentation.contentVisibility) * 8)
                    .allowsHitTesting(model.expanded && presentation.contentVisibility > 0.95)
                    .accessibilityHidden(!model.expanded || presentation.contentVisibility < 0.95)
            }
        }
        .foregroundStyle(Color(red: 0.95, green: 0.96, blue: 0.97))
        .modifier(IslandSurface(appearance: model.appearance, attached: attached, expanded: model.expanded,
            progress: presentation.expansion))
        .onHover { model.hover($0) }
        .onExitCommand { model.close() }
        .preferredColorScheme(.dark)
        .environment(\.locale, L10n.locale)
    }
}

private struct IslandExpandedContent: View {
    @ObservedObject var model: IslandModel
    // Both ViewThatFits candidates share disclosure state when height changes.
    @State private var showsResetExpiryDetails = false
    private let secondary = Color(red: 0.67, green: 0.69, blue: 0.73)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .vertical) {
                content
                ScrollView(.vertical) {
                    content.background(CompactScrollbarStyle())
                }
                .scrollIndicators(.visible)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: ExpandedContentHeight.self,
                        value: .init(footer: geometry.size.height))
                })
        }
        .onPreferenceChange(ExpandedContentHeight.self) { measurement in
            guard measurement.content > 0, measurement.footer > 0 else { return }
            DispatchQueue.main.async {
                model.updateMeasuredContentHeight(measurement.content + measurement.footer)
            }
        }
        .onPreferenceChange(TaskRowIdealWidth.self) { width in
            DispatchQueue.main.async { model.updateMeasuredContentWidth(width > 0 ? width + 46 : 0) }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.isDemo {
                Text(L10n.text("demo.label")).font(.system(size: 12)).foregroundStyle(secondary).padding(.top, 10)
            }

            VStack(alignment: .leading, spacing: 0) {
                if let notice = model.notice, !notice.id.hasPrefix("request:") {
                    Label(L10n.text("notice.body", notice.title, notice.detail), systemImage: "bell")
                        .font(.system(size: 12)).foregroundStyle(model.accent).padding(.bottom, 8)
                }
                taskContent
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.vertical, 16)
                quotaContent
            }
            .padding(.top, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: ExpandedContentHeight.self,
                value: .init(content: geometry.size.height))
        })
    }

    @ViewBuilder private var taskContent: some View {
        if model.visibleActivities.isEmpty {
            Text(L10n.text("activity.no_tasks")).font(.system(size: 13)).foregroundStyle(secondary).padding(.vertical, 12)
        } else {
            TaskPagerView(model: model)
        }
        if let error = model.navigationError {
            Text(error).font(.system(size: 12)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
        }
    }

    @ViewBuilder private var quotaContent: some View {
        if let message = model.errorMessage {
            QuotaErrorView(message: message, cliPath: model.quotaCLI?.url.path, homePath: model.home.path,
                cachedAt: model.quota.flatMap { $0.windows.isEmpty ? nil : $0.capturedAt },
                refreshing: model.refreshing, onRetry: { model.retryQuotaConnection() },
                onSettings: { model.onSettings?() })
                .padding(.bottom, 12)
        }
        if let quota = model.quota, !quota.buckets.isEmpty || quota.resetCredits != nil {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(quota.buckets) { bucket in
                    VStack(alignment: .leading, spacing: 18) {
                        if quota.buckets.count > 1 {
                            Text(bucket.name ?? bucket.id).font(.system(size: 13, weight: .medium)).foregroundStyle(secondary)
                        }
                        ForEach(bucket.windows) { window in
                            QuotaWindowView(window: window, now: model.now,
                                allowPace: !model.stale && model.errorMessage == nil, accent: model.accent, secondary: secondary)
                        }
                    }
                }
            }
            if let cycle = model.currentCycle {
                QuotaCycleChart(data: QuotaChartData(cycle: cycle, resetCredits: quota.resetCredits, now: model.now),
                    accent: model.accent).equatable().padding(.top, 22)
            } else if model.weeklyWindow != nil {
                Text(L10n.text("quota.waiting_sample")).font(.system(size: 12)).foregroundStyle(secondary).padding(.top, 18)
            }
            AccountUsageView(snapshot: quota, now: model.now, showsExpiryDetails: $showsResetExpiryDetails).padding(.top, 20)
            if let warning = model.historyWarning {
                Label(L10n.text("quota.chart_warning"), systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(secondary).help(warning).padding(.top, 10)
            }
        } else if model.errorMessage == nil {
            Text(model.refreshing ? L10n.text("quota.loading") : L10n.text("quota.not_connected")).font(.system(size: 13))
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.stale || model.errorMessage != nil {
                Label(L10n.text("common.not_updated"), systemImage: StatusSymbols.freshness).font(.system(size: 12)).help(model.freshnessText)
            }
            Spacer(minLength: 4)
            Button { model.togglePin() } label: { Image(systemName: model.pinned ? "pin.fill" : "pin").frame(width: 24, height: 26) }
                .help(model.pinned ? L10n.text("common.unpin") : L10n.text("common.pin")).accessibilityLabel(model.pinned ? L10n.text("common.unpin") : L10n.text("common.pin"))
            Button { model.refreshQuota(); model.refreshActivity() } label: { Image(systemName: "arrow.clockwise").frame(width: 24, height: 26) }
                .disabled(model.refreshing).help(L10n.text("quota.refresh_help", model.freshnessText)).accessibilityLabel(L10n.text("common.refresh"))
            Button { model.onSettings?() } label: { Image(systemName: "gearshape").frame(width: 24, height: 26) }
                .help(L10n.text("common.settings")).accessibilityLabel(L10n.text("common.settings"))
            Button { model.onQuit?() } label: { Image(systemName: "power").frame(width: 24, height: 26) }
                .help(L10n.text("common.quit")).accessibilityLabel(L10n.text("common.quit"))
            Button { model.close() } label: { Image(systemName: "chevron.up").frame(width: 24, height: 26) }
                .help(L10n.text("common.collapse")).accessibilityLabel(L10n.text("common.collapse"))
        }
        .font(.system(size: 13)).buttonStyle(.plain).foregroundStyle(secondary)
        .padding(.top, 8).padding(.bottom, 12)
    }
}

private struct ExpandedContentMeasurement: Equatable {
    var content: CGFloat = 0
    var footer: CGFloat = 0
}

private struct ExpandedContentHeight: PreferenceKey {
    static var defaultValue = ExpandedContentMeasurement()
    static func reduce(value: inout ExpandedContentMeasurement, nextValue: () -> ExpandedContentMeasurement) {
        let next = nextValue()
        value.content = max(value.content, next.content)
        value.footer = max(value.footer, next.footer)
    }
}
