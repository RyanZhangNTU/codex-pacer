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
        .foregroundStyle(PacerPalette.primary)
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
            if let notice = model.notice, !notice.id.hasPrefix("request:") {
                HStack(spacing: 8) {
                    Image(systemName: "bell.fill").font(.system(size: 11)).foregroundStyle(PacerPalette.attention)
                    Text(L10n.text("notice.body", notice.title, notice.detail))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(PacerPalette.primary).lineLimit(2)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PacerPalette.attention.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.bottom, 8)
            }
            taskContent
            Hairline().padding(.horizontal, 10).padding(.vertical, 12)
            quotaContent
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: ExpandedContentHeight.self,
                value: .init(content: geometry.size.height))
        })
    }

    @ViewBuilder private var taskContent: some View {
        if model.visibleActivities.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                IslandSectionHeader(title: L10n.text("layout.group.tasks"), detail: "0")
                HStack(spacing: 12) {
                    StatusTile(symbol: StatusSymbols.idle, tint: PacerPalette.secondary)
                    Text(L10n.text("activity.no_tasks")).font(.system(size: 12, weight: .medium)).foregroundStyle(PacerPalette.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
        } else {
            TaskPagerView(model: model)
        }
        if let error = model.navigationError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11)).foregroundStyle(PacerPalette.attention)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.top, 6)
        }
    }

    private var quotaContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            let single = model.enabledProviders.count == 1 ? model.enabledProviders.first : nil
            IslandSectionHeader(title: L10n.text("layout.group.quota"), detail: single?.displayName,
                detailColor: single?.tint ?? PacerPalette.tertiary) {
                if model.enabledProviders.count > 1 {
                    IslandSegmentedControl(options: QuotaDashboardPeriod.allCases, selection: model.dashboardPeriod,
                        label: \.rawValue, accessibilityLabel: \.accessibilityLabel) { model.selectDashboardPeriod($0) }
                        .help(L10n.text("dashboard.period_help"))
                }
            }
            if model.enabledProviders.isEmpty {
                HStack(spacing: 12) {
                    Text(L10n.text("provider.none_enabled")).font(.system(size: 12)).foregroundStyle(PacerPalette.secondary)
                    Spacer(minLength: 8)
                    Button(L10n.text("common.open_settings")) { model.onSettings?() }
                        .font(.system(size: 12, weight: .medium)).buttonStyle(.plain).foregroundStyle(PacerPalette.primary)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            } else {
                QuotaDashboardView(model: model)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 2) {
            if model.isDemo {
                Text(L10n.text("demo.label")).font(.system(size: 10, weight: .semibold)).foregroundStyle(PacerPalette.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(PacerPalette.fill, in: Capsule())
                    .padding(.leading, 6)
            }
            Spacer(minLength: 4)
            IslandIconButton(symbol: model.pinned ? "pin.fill" : "pin",
                title: model.pinned ? L10n.text("common.unpin") : L10n.text("common.pin"), active: model.pinned) { model.togglePin() }
            IslandIconButton(symbol: "arrow.clockwise", title: L10n.text("common.refresh"),
                help: L10n.text("quota.refresh_help", model.enabledProviders.map { $0.displayName + ": " + model.providerFreshnessText($0) }.joined(separator: "\n"))) {
                model.refreshQuota(); model.refreshActivity()
            }
            .disabled(model.enabledProviders.allSatisfy { model.providerRefreshing($0) })
            IslandIconButton(symbol: "gearshape", title: L10n.text("common.settings")) { model.onSettings?() }
            IslandIconButton(symbol: "power", title: L10n.text("common.quit")) { model.onQuit?() }
            IslandIconButton(symbol: "chevron.up", title: L10n.text("common.collapse")) { model.close() }
        }
        .padding(.top, 6).padding(.bottom, 10)
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
