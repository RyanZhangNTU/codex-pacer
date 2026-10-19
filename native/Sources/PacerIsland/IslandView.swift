import SwiftUI
import PacerCore

struct IslandView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var presentation: IslandPresentation
    private var attached: Bool { model.isAttached }

    var body: some View {
        Group {
            if let dock = model.sideDock, let side = dock.side { docked(dock, side: side) } else { centered }
        }
        .foregroundStyle(PacerPalette.primary)
        .modifier(IslandSurface(appearance: model.appearance, attached: attached, flatSide: model.sideDock?.side,
            expanded: model.expanded, progress: presentation.expansion))
        .onHover { model.hover($0) }
        .onExitCommand { model.close() }
        .preferredColorScheme(.dark)
        .environment(\.locale, L10n.locale)
    }

    private var centered: some View {
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
                revealed(IslandExpandedContent(model: model)
                    .frame(width: max(0, presentation.canvas.width - 2 * IslandMetrics.edgeInset),
                           height: max(0, presentation.canvas.height - model.topHeight), alignment: .top)
                    .padding(.horizontal, IslandMetrics.edgeInset)
                    .offset(y: model.topHeight + (1 - presentation.contentVisibility) * 8))
            }
        }
    }

    /// The strip keeps its screen-side corner under the pointer; the panel
    /// opens beside it, toward the center of the screen, at its full size so
    /// the growing window reveals it rather than reflowing it.
    private func docked(_ dock: IslandPosition, side: IslandPosition.Side) -> some View {
        let corner: Alignment = switch (dock.isBottom, side) {
        case (false, .left): .topLeading
        case (false, .right): .topTrailing
        case (true, .left): .bottomLeading
        case (true, .right): .bottomTrailing
        }
        let strip = IslandGeometry.stripWidth, inward: CGFloat = side == .left ? 1 : -1
        return CompactIslandStrip(model: model, layout: model.compactLayout)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner)
            .overlay(alignment: corner) {
                if model.expanded || presentation.contentVisibility > 0 {
                    revealed(IslandExpandedContent(model: model, topInset: 10)
                        .frame(width: max(0, presentation.canvas.width - strip - 2 * IslandMetrics.edgeInset),
                               height: max(0, presentation.canvas.height), alignment: dock.isBottom ? .bottom : .top)
                        .padding(.horizontal, IslandMetrics.edgeInset)
                        .offset(x: inward * (strip + (1 - presentation.contentVisibility) * 8)))
                }
            }
    }

    private func revealed(_ content: some View) -> some View {
        content
            .opacity(presentation.contentVisibility)
            .allowsHitTesting(model.expanded && presentation.contentVisibility > 0.95)
            .accessibilityHidden(!model.expanded || presentation.contentVisibility < 0.95)
    }
}

private struct IslandExpandedContent: View {
    @ObservedObject var model: IslandModel
    /// Below the header there is little room to leave; beside a strip the
    /// panel's own top edge needs some.
    var topInset: CGFloat = 4

    /// Room below the last section now that panel actions sit in the task header.
    private static let bottomInset: CGFloat = 14

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView(.vertical) {
                content.background(CompactScrollbarStyle())
            }
            .scrollIndicators(.visible)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(ExpandedContentHeight.self) { height in
            guard height > 0 else { return }
            DispatchQueue.main.async { model.updateMeasuredContentHeight(height + Self.bottomInset) }
        }
        .onPreferenceChange(TaskRowIdealWidth.self) { width in
            DispatchQueue.main.async { model.updateMeasuredContentWidth(width > 0 ? width + 2 * IslandMetrics.edgeInset : 0) }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            taskContent
            Hairline().padding(.horizontal, IslandMetrics.rowInset).padding(.vertical, 10)
            quotaContent
        }
        .padding(.top, topInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: ExpandedContentHeight.self, value: geometry.size.height)
        })
    }

    @ViewBuilder private var taskContent: some View {
        if model.visibleActivities.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                IslandSectionHeader(title: L10n.text("layout.group.tasks"), detail: "0") { IslandPanelControls(model: model) }
                HStack(spacing: 12) {
                    StatusTile(symbol: StatusSymbols.idle, tint: PacerPalette.secondary)
                    Text(L10n.text("activity.no_tasks")).font(.system(size: 12, weight: .medium)).foregroundStyle(PacerPalette.secondary)
                }
                .padding(.horizontal, IslandMetrics.rowInset).padding(.vertical, 8)
            }
        } else {
            TaskPagerView(model: model)
        }
        if let error = model.navigationError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11)).foregroundStyle(PacerPalette.attention)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, IslandMetrics.rowInset).padding(.top, 6)
        }
    }

    private var quotaContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            let single = model.enabledProviders.count == 1 ? model.enabledProviders.first : nil
            IslandSectionHeader(title: L10n.text("layout.group.quota"), detail: single?.displayName,
                detailColor: single?.tint ?? PacerPalette.tertiary)
            if model.enabledProviders.isEmpty {
                HStack(spacing: 12) {
                    Text(L10n.text("provider.none_enabled")).font(.system(size: 12)).foregroundStyle(PacerPalette.secondary)
                    Spacer(minLength: 8)
                    Button(L10n.text("common.open_settings")) { model.onSettings?() }
                        .font(.system(size: 12, weight: .medium)).buttonStyle(.plain).foregroundStyle(PacerPalette.primary)
                }
                .padding(.horizontal, IslandMetrics.rowInset).padding(.vertical, 8)
            } else {
                QuotaDashboardView(model: model)
            }
        }
    }
}

/// Panel actions sit at the right of the task header. Read, Pin and Settings stay
/// one click away; refresh and quit are rare and share one menu. Collapsing
/// needs no control: moving away, Escape or unpinning closes the panel.
struct IslandPanelControls: View {
    @ObservedObject var model: IslandModel
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 0) {
            if model.isDemo {
                Text(L10n.text("demo.label")).font(.system(size: 10, weight: .semibold)).foregroundStyle(PacerPalette.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(PacerPalette.fill, in: Capsule())
                    .fixedSize().padding(.trailing, 4)
            }
            IslandIconButton(symbol: "checkmark.rectangle.stack", title: L10n.text("activity.mark_all_read")) { model.markAllRead() }
                .disabled(!model.canMarkAllRead)
            IslandIconButton(symbol: model.pinned ? "pin.fill" : "pin",
                title: model.pinned ? L10n.text("common.unpin") : L10n.text("common.pin"), active: model.pinned) { model.togglePin() }
            IslandIconButton(symbol: "gearshape", title: L10n.text("common.settings")) { model.onSettings?() }
            Menu {
                Button(L10n.text("common.refresh")) { model.refreshQuota(); model.refreshTaskSources() }
                    .disabled(model.enabledProviders.allSatisfy { model.providerRefreshing($0) })
                Divider()
                Button(L10n.text("common.quit")) { model.onQuit?() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hovered ? PacerPalette.primary : PacerPalette.secondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(hovered ? PacerPalette.hover : .clear))
                    .contentShape(Circle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .onHover { hovered = $0 }
            .help(L10n.text("common.more")).accessibilityLabel(L10n.text("common.more"))
        }
    }
}

private struct ExpandedContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
