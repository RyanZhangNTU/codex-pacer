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
        // The black bar at a hardware notch draws the dark tone even under light glass. The
        // tokens are read as views draw, so a change of tone redraws them all.
        .id(model.lightTone)
        .environment(\.colorScheme, model.lightTone ? .light : .dark)
        .foregroundStyle(PacerPalette.primary)
        .modifier(IslandSurface(appearance: model.appearance, attached: attached, flatEdge: model.dockedEdge,
            expanded: model.expanded, progress: presentation.expansion, collapsedRadius: model.collapsedCornerRadius,
            notchBlack: model.atHardwareNotch ? presentation.blackOpacity : 0))
        .onHover { model.hover($0) }
        .onExitCommand { model.close() }
        // Light glass turns the island's system material light.
        .preferredColorScheme(model.appearance.isLight ? .light : .dark)
        .environment(\.locale, L10n.locale)
    }

    /// The bar holds the window's top edge, or its bottom edge when the island
    /// opens upward; the panel unfolds on the other side.
    private var centered: some View {
        let edge: Alignment = model.opensUp ? .bottom : .top, away: CGFloat = model.opensUp ? -1 : 1
        return VStack(spacing: 0) {
            CompactIslandHeader(model: model,
                baseHeight: model.baseHeaderHeight, notchWidth: model.notchWidth)
                .modifier(IslandMoveGesture(model: model))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge)
        .overlay(alignment: edge) {
            // Retire invisible content before the spring settles, so the final
            // capsule frame only stops motion rather than changing its subtree.
            if model.expanded || presentation.contentVisibility > 0 {
                revealed(IslandExpandedContent(model: model)
                    .frame(width: max(0, presentation.canvas.width - 2 * IslandMetrics.edgeInset),
                           height: max(0, presentation.canvas.height - model.topHeight), alignment: edge)
                    .padding(.horizontal, IslandMetrics.edgeInset)
                    .offset(y: away * (model.topHeight + (1 - presentation.contentVisibility) * 8)))
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
        let strip = model.stripWidth, inward: CGFloat = side == .left ? 1 : -1
        return CompactIslandStrip(model: model)
            .modifier(IslandMoveGesture(model: model))
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
        .onPreferenceChange(ExpandedContentIdealWidth.self) { width in
            DispatchQueue.main.async { model.updateMeasuredContentWidth(width > 0 ? width + 2 * IslandMetrics.edgeInset : 0) }
        }
    }

    private var content: some View {
        let sections = drawnSections
        let errorHolder = sections.first?.id
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                if index > 0 {
                    if Self.joins(section, after: sections[index - 1]) {
                        Color.clear.frame(height: 14)
                    } else {
                        Hairline().padding(.horizontal, IslandMetrics.rowInset).padding(.vertical, 10)
                    }
                }
                IslandPanelSection(model: model, section: section, showsNavigationError: section.id == errorHolder)
            }
            if model.enabledProviders.isEmpty {
                Hairline().padding(.horizontal, IslandMetrics.rowInset).padding(.vertical, 10)
                HStack(spacing: 12) {
                    Text(L10n.text("provider.none_enabled")).font(.system(size: 12)).foregroundStyle(PacerPalette.secondary)
                    Spacer(minLength: 8)
                    Button(L10n.text("common.open_settings")) { model.onSettings?() }
                        .font(.system(size: 12, weight: .medium)).buttonStyle(.plain).foregroundStyle(PacerPalette.primary)
                }
                .padding(.horizontal, IslandMetrics.rowInset).padding(.vertical, 8)
            }
        }
        .padding(.top, topInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: ExpandedContentHeight.self, value: geometry.size.height)
        })
    }

    /// DeepSeek's spend and week leave the panel when they have nothing to
    /// show, hairline and all, unless they carry the panel's buttons.
    private var drawnSections: [ExpandedPanelPresentation.Section] {
        let sections = model.panelSections
        guard sections.contains(where: { $0.kind == .deepseekSpend || $0.kind == .deepseekWeek }) else { return sections }
        let deepseek = model.deepseekSoloPresentation
        return sections.filter { section in
            switch section.kind {
            case .deepseekSpend: section.actions || deepseek.distribution != nil
            case .deepseekWeek: section.actions || deepseek.week != nil
            case .tasks, .quota: true
            }
        }
    }

    /// A joined section continues DeepSeek's blocks with a gap; after a
    /// section that was left out, it starts with a hairline as usual.
    static func joins(_ section: ExpandedPanelPresentation.Section, after previous: ExpandedPanelPresentation.Section) -> Bool {
        guard section.joined else { return false }
        switch previous.kind {
        case .deepseekSpend, .deepseekWeek: return true
        case .quota: return previous.providers.contains(.deepseek)
        case .tasks: return false
        }
    }
}

/// One block of the expanded panel. The first carries the panel's buttons
/// in its header.
private struct IslandPanelSection: View {
    @ObservedObject var model: IslandModel
    let section: ExpandedPanelPresentation.Section
    /// A failed open explains itself under the first block, beside the panel's buttons.
    let showsNavigationError: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch section.kind {
            case .tasks: tasks
            case .quota: IslandQuotaSection(model: model, section: section)
            case .deepseekSpend: spend
            case .deepseekWeek: week
            }
            if showsNavigationError, let error = model.navigationError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(PacerPalette.attention)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, IslandMetrics.rowInset).padding(.top, 6)
            }
        }
    }

    @ViewBuilder private var tasks: some View {
        if model.visibleActivities.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                IslandSectionHeader(title: L10n.text("layout.group.tasks"), detail: "0") {
                    if section.actions { IslandPanelControls(model: model) }
                }
                HStack(spacing: 10) {
                    StatusGlyph(symbol: StatusSymbols.idle, tint: PacerPalette.secondary)
                    Text(L10n.text("activity.no_tasks")).font(.system(size: 12, weight: .medium)).foregroundStyle(PacerPalette.secondary)
                }
                .padding(.horizontal, IslandMetrics.rowInset).padding(.vertical, 8)
            }
        } else {
            TaskPagerView(model: model, actions: section.actions)
        }
    }

    private var header: ExpandedPanelPresentation.Header {
        ExpandedPanelPresentation.header(section, budgetDial: model.deepseekShowsBudgetDial)
    }

    /// Spend and week draw their own small title, unless they open the panel
    /// and carry its buttons in a section header instead.
    private var spend: some View {
        let wallet = model.deepseekWallet
        return VStack(alignment: .leading, spacing: 8) {
            if section.showsHeader {
                IslandSectionHeader(title: header.title, detail: nil) {
                    if section.actions { IslandPanelControls(model: model) }
                }
            }
            if model.deepseekSoloPresentation.distribution != nil {
                DeepSeekWhereItWent(model: model, wallet: wallet, showsTitle: !section.showsHeader)
                    .padding(.horizontal, IslandMetrics.rowInset)
            }
        }
        .padding(.bottom, 4)
    }

    private var week: some View {
        let wallet = model.deepseekWallet, line = model.panelOptions.weekLine
        return VStack(alignment: .leading, spacing: 8) {
            if section.showsHeader {
                IslandSectionHeader(title: header.title, detail: DeepSeekSoloPresentation.week(wallet, line: line)?.lineText) {
                    if section.actions { IslandPanelControls(model: model) }
                }
            }
            DeepSeekWeekChart(wallet: wallet, now: model.now, line: line, showsTitle: !section.showsHeader)
                .padding(.horizontal, IslandMetrics.rowInset)
        }
        .padding(.bottom, 4)
    }
}

/// One quota block: a service, or several side by side, under the title the
/// panel gives them.
struct IslandQuotaSection: View {
    @ObservedObject var model: IslandModel
    let section: ExpandedPanelPresentation.Section

    var body: some View {
        let header = ExpandedPanelPresentation.header(section, budgetDial: model.deepseekShowsBudgetDial)
        VStack(alignment: .leading, spacing: 8) {
            IslandSectionHeader(title: header.title, detail: header.detail,
                detailColor: header.provider?.tint ?? PacerPalette.tertiary) {
                HStack(spacing: 8) {
                    if header.provider == .deepseek { DeepSeekSectionStatus(model: model) }
                    if section.actions { IslandPanelControls(model: model) }
                }
            }
            QuotaDashboardView(model: model, section: section)
        }
    }
}

/// The panel's buttons in its first block's header: a button for each
/// enabled module's desktop app, then Mark All as Read, Keep Expanded and
/// Settings as chosen. What is not in the header waits in the More menu with
/// Refresh and Quit. Collapsing needs no control: moving away, Escape or
/// unpinning closes the panel.
struct IslandPanelControls: View {
    @ObservedObject var model: IslandModel
    var language: AppLanguage = L10n.language
    @State private var hovered = false

    var body: some View {
        let actions = model.panelOptions.headerActions
        HStack(spacing: 0) {
            if model.isDemo {
                Text(L10n.text("demo.label", language: language)).font(.system(size: 10, weight: .semibold)).foregroundStyle(PacerPalette.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(PacerPalette.fill, in: Capsule())
                    .fixedSize().padding(.trailing, 4)
            }
            let apps = model.appButtonProviders
            if !apps.isEmpty {
                ForEach(apps, id: \.self) { provider in
                    IslandIconButton(symbol: provider.glyph, title: L10n.text("activity.open_app", provider.displayName, language: language),
                        provider: provider) { model.openDesktopApplication(provider) }
                }
                Rectangle().fill(PacerPalette.hairline).frame(width: 1, height: 14).padding(.horizontal, 4).accessibilityHidden(true)
            }
            if actions.contains(.markRead) {
                IslandIconButton(symbol: "checkmark.rectangle.stack", title: L10n.text("activity.mark_all_read", language: language)) { model.markAllRead() }
                    .disabled(!model.canMarkAllRead)
            }
            if actions.contains(.pin) {
                IslandIconButton(symbol: model.pinned ? "pin.fill" : "pin", title: pinTitle, active: model.pinned) { model.togglePin() }
            }
            if actions.contains(.settings) {
                IslandIconButton(symbol: "gearshape", title: L10n.text("common.settings", language: language)) { model.onSettings?() }
            }
            Menu { menu(actions) } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hovered ? PacerPalette.primary : PacerPalette.secondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(hovered ? PacerPalette.hover : .clear))
                    .contentShape(Circle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .onHover { hovered = $0 }
            .help(L10n.text("common.more", language: language)).accessibilityLabel(L10n.text("common.more", language: language))
        }
    }

    private var pinTitle: String { L10n.text(model.pinned ? "common.unpin" : "common.pin", language: language) }

    /// The buttons left out of the header, then Refresh, then Quit.
    @ViewBuilder private func menu(_ actions: Set<ExpandedPanelOptions.HeaderAction>) -> some View {
        let apps = model.showsAppButtons ? [] : model.desktopAppProviders
        ForEach(apps, id: \.self) { provider in
            Button { model.openDesktopApplication(provider) } label: {
                Label {
                    Text(L10n.text("activity.open_app", provider.displayName, language: language))
                } icon: {
                    ProviderAppIcon(provider: provider, size: 14, outline: true)
                }
            }
        }
        if !actions.contains(.markRead) {
            Button(L10n.text("activity.mark_all_read", language: language)) { model.markAllRead() }.disabled(!model.canMarkAllRead)
        }
        if !actions.contains(.pin) { Button(pinTitle) { model.togglePin() } }
        if !actions.contains(.settings) { Button(L10n.text("common.settings", language: language)) { model.onSettings?() } }
        if !apps.isEmpty || actions.count < ExpandedPanelOptions.HeaderAction.allCases.count { Divider() }
        Button(L10n.text("common.refresh", language: language)) { model.refreshQuota(); model.refreshTaskSources() }
            .disabled(model.enabledProviders.allSatisfy { model.providerRefreshing($0) })
        Divider()
        Button(L10n.text("common.quit", language: language)) { model.onQuit?() }
    }
}

private struct ExpandedContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
