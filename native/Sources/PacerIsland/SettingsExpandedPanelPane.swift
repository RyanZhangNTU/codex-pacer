import AppKit
import PacerCore
import SwiftUI

/// What the Expanded Panel page's settings card describes: a block, or the
/// panel's buttons, which always sit in the first block's header.
enum ExpandedPanelSelection: Hashable {
    case block(ExpandedPanelLayout.Block)
    case actions
}

/// The Expanded Panel page: on the left the panel's outline to click and
/// drag, with every block by group to add or remove; on the right the
/// selected block's settings. Each change is saved at once and reaches the
/// real panel; explanations sit behind ⓘ.
struct SettingsExpandedPanelPane: View {
    @Environment(\.pacerAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme
    /// The saved blocks; nil follows the enabled services.
    @Binding var savedLayout: ExpandedPanelLayout?
    @Binding var options: ExpandedPanelOptions
    @Binding var selection: ExpandedPanelSelection?
    @Binding var quotaStyle: ExpandedQuotaStyle
    @Binding var retention: Int
    @Binding var showsAppButtons: Bool
    let providers: [AgentProvider]
    /// DeepSeek's former Content choice, which the automatic blocks follow.
    let deepseekDetailed: Bool
    let openGeneral: () -> Void
    let openDeepSeek: () -> Void
    /// Where a dragged block would land; SwiftUI reports no cancelled drag,
    /// so nothing else about the drag is kept.
    @State private var dropTarget: DropTarget?

    private enum DropTarget: Hashable { case block(ExpandedPanelLayout.Block), end }

    private var providerSet: Set<AgentProvider> { Set(providers) }
    var layout: ExpandedPanelLayout {
        .resolved(saved: savedLayout, providers: providerSet, deepseekDetailed: deepseekDetailed)
    }
    private var visible: [ExpandedPanelLayout.Block] { layout.visibleBlocks(providers: providerSet) }

    /// The chosen block, or the first one in the panel, so the settings card
    /// always describes something.
    var selected: ExpandedPanelSelection {
        if let selection {
            if case .block(let block) = selection, !block.isAvailable(for: providerSet), !layout.blocks.contains(block) {
                return visible.first.map(ExpandedPanelSelection.block) ?? .actions
            }
            return selection
        }
        return visible.first.map(ExpandedPanelSelection.block) ?? .actions
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 16) {
                outline
                library
            }
            .frame(width: 270)
            inspector.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Edits

    /// Applies one edit; the first one saves the blocks as they then appeared.
    func edit(_ change: (inout ExpandedPanelLayout) -> Void) {
        let current = layout
        var next = current
        change(&next)
        if next != current { savedLayout = next }
    }

    func toggle(_ block: ExpandedPanelLayout.Block) { edit { $0.toggle(block, providers: providerSet) } }
    func shift(_ block: ExpandedPanelLayout.Block, by offset: Int) { edit { $0.shift(block, by: offset, providers: providerSet) } }
    func move(_ block: ExpandedPanelLayout.Block, before: ExpandedPanelLayout.Block?) { edit { $0.move(block, before: before) } }

    /// The outline's sections: adjacent quota blocks share one while paired.
    static func rows(_ blocks: [ExpandedPanelLayout.Block], arrange: ExpandedPanelOptions.Arrange) -> [[ExpandedPanelLayout.Block]] {
        var rows: [[ExpandedPanelLayout.Block]] = []
        for block in blocks {
            if arrange == .pair, block.isQuota, let last = rows.last?.last, last.isQuota {
                rows[rows.count - 1].append(block)
            } else {
                rows.append([block])
            }
        }
        return rows
    }

    /// The short line under a block's name in the outline.
    static func summary(_ block: ExpandedPanelLayout.Block, options: ExpandedPanelOptions) -> String {
        switch block {
        case .tasks:
            "\(L10n.text("main.panel.page_size")) \(options.pageSize) · "
                + L10n.text(options.rowStyle == .oneLine ? "main.panel.row_one" : "main.panel.row_two")
        case .codex, .claude:
            periodsLabel(options.periods(for: block.provider ?? .codex))
        case .deepseek:
            L10n.text("main.panel.dial") + " · " + L10n.text(options.deepseekDial == .budget ? "main.panel.dial_budget" : "main.panel.dial_day")
        case .deepseekSpend:
            L10n.text("main.panel.spend_tasks") + " · " + L10n.text("main.panel.spend_count", options.spendTasks)
        case .deepseekWeek:
            L10n.text("main.panel.week_line") + " · " + L10n.text(options.weekLine ? "main.panel.show" : "main.panel.hide")
        }
    }

    private static func periodsLabel(_ periods: ExpandedPanelOptions.Periods) -> String {
        switch periods {
        case .both: L10n.text("main.panel.periods_both")
        case .weekly: L10n.text("main.panel.periods_weekly")
        case .fiveHour: L10n.text("main.panel.periods_five")
        }
    }

    // MARK: Outline

    private enum Outline {
        static let face = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
        static let block = Color(red: 36 / 255, green: 36 / 255, blue: 40 / 255)
        static let selectedBlock = Color(red: 44 / 255, green: 44 / 255, blue: 48 / 255)
        static let label = Color(red: 245 / 255, green: 245 / 255, blue: 247 / 255)
        static let secondary = Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)
        static let grip = Color(red: 99 / 255, green: 99 / 255, blue: 102 / 255)
        static let icon = Color(red: 174 / 255, green: 174 / 255, blue: 178 / 255)
    }

    /// The panel as a dark outline of its sections, in the order it shows them.
    private var outline: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("panel.group.panel")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Text(L10n.text(savedLayout == nil ? "main.panel.automatic_short" : "main.panel.custom"))
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 6) {
                let rows = Self.rows(visible, arrange: options.quotaArrange)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 {
                        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                            .padding(.horizontal, 8).padding(.vertical, 2).accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(sectionTitle(row)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Outline.secondary)
                                .lineLimit(1).accessibilityAddTraits(.isHeader)
                            Spacer(minLength: 4)
                            if index == 0 { actionsChip }
                        }
                        .padding(.leading, 8).padding(.trailing, 4).frame(height: 22)
                        HStack(spacing: 6) {
                            ForEach(row) { outlineBlock($0, paired: row.count > 1) }
                        }
                    }
                }
                endZone
            }
            .padding(10)
            .background(Outline.face, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.black.opacity(0.2)))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
            .environment(\.colorScheme, .dark)
        }
    }

    private func sectionTitle(_ row: [ExpandedPanelLayout.Block]) -> String {
        guard let first = row.first else { return "" }
        switch first {
        case .tasks:
            return ExpandedPanelPresentation.header(.init(kind: .tasks), budgetDial: false).title
        case .codex, .claude, .deepseek:
            return ExpandedPanelPresentation.header(.init(kind: .quota, providers: row.compactMap(\.provider)), budgetDial: false).title
        case .deepseekSpend, .deepseekWeek:
            return first.label
        }
    }

    /// A paired block names only its service, so the name fits.
    private func outlineBlock(_ block: ExpandedPanelLayout.Block, paired: Bool) -> some View {
        let isSelected = selected == .block(block)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let summary = Self.summary(block, options: options)
        let grip = Image(systemName: "circle.grid.2x3.fill").font(.system(size: 7)).foregroundStyle(Outline.grip)
        let dot = Circle().fill(block.provider?.shade(light: false) ?? Outline.secondary).frame(width: 8, height: 8)
        return Group {
            if paired {
                // Three to a row leave no room beside the dot, so the name takes its own line.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 0) { dot; Spacer(minLength: 4); grip }
                    Text(block.provider?.displayName ?? block.label).font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Outline.label).lineLimit(1).minimumScaleFactor(0.8)
                }
                .padding(.horizontal, 9)
            } else {
                HStack(spacing: 6) {
                    grip.frame(width: 10)
                    dot
                    VStack(alignment: .leading, spacing: 1) {
                        Text(block.label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Outline.label).lineLimit(1)
                        Text(summary).font(.system(size: 11)).foregroundStyle(Outline.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 6).padding(.trailing, 10)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: block == .tasks ? 58 : 46, alignment: .leading)
        .background(isSelected ? Outline.selectedBlock : Outline.block, in: shape)
        .overlay(shape.strokeBorder(isSelected ? accent : Color.white.opacity(0.06), lineWidth: isSelected ? 2 : 1))
        .overlay(alignment: .top) {
            if dropTarget == .block(block) { Capsule().fill(accent).frame(height: 3).offset(y: -4.5).accessibilityHidden(true) }
        }
        .contentShape(shape)
        .onTapGesture { selection = .block(block) }
        .draggable(block.rawValue) {
            Label(block.label, systemImage: block.symbol).font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(accent, in: Capsule()).foregroundStyle(.white)
        }
        .dropDestination(for: String.self) { items, _ in
            drop(items, before: block)
        } isTargeted: { hovering in
            if hovering { dropTarget = .block(block) } else if dropTarget == .block(block) { dropTarget = nil }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(block.label)
        .accessibilityValue(summary)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { selection = .block(block) }
        .accessibilityAction(named: L10n.text("main.panel.move_up")) { shift(block, by: -1) }
        .accessibilityAction(named: L10n.text("main.panel.move_down")) { shift(block, by: 1) }
    }

    /// The panel's buttons ride in the first section's header, as in the panel.
    private var actionsChip: some View {
        let isSelected = selected == .actions
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        var symbols: [String] = showsAppButtons ? ["square.grid.2x2"] : []
        if options.headerActions.contains(.markRead) { symbols.append("checkmark.rectangle.stack") }
        if options.headerActions.contains(.pin) { symbols.append("pin") }
        if options.headerActions.contains(.settings) { symbols.append("gearshape") }
        symbols.append("ellipsis")
        return Button { selection = .actions } label: {
            HStack(spacing: 7) {
                ForEach(symbols, id: \.self) { Image(systemName: $0).font(.system(size: 10, weight: .medium)) }
            }
            .foregroundStyle(Outline.icon)
            .padding(.horizontal, 7).frame(height: 22)
            .background(isSelected ? accent.opacity(0.22) : Color.white.opacity(0.06), in: shape)
            .overlay(shape.strokeBorder(isSelected ? accent : .clear, lineWidth: 1.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(L10n.text("panel.block.actions"))
        .accessibilityLabel(L10n.text("panel.block.actions"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Dropping below the last block moves a block to the end.
    private var endZone: some View {
        Color.clear.frame(height: 10)
            .overlay(alignment: .top) {
                if dropTarget == .end { Capsule().fill(accent).frame(height: 3).accessibilityHidden(true) }
            }
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                drop(items, before: nil)
            } isTargeted: { hovering in
                if hovering { dropTarget = .end } else if dropTarget == .end { dropTarget = nil }
            }
            .accessibilityHidden(true)
    }

    private func drop(_ items: [String], before: ExpandedPanelLayout.Block?) -> Bool {
        defer { dropTarget = nil }
        guard let block = items.first.flatMap(ExpandedPanelLayout.Block.init(rawValue:)), block != before else { return false }
        move(block, before: before)
        selection = .block(block)
        return true
    }

    // MARK: Library

    private var library: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("main.panel.blocks")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.leading, 4).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(ExpandedPanelLayout.Group.allCases, id: \.self) { group in
                    // A block of a service that is off stays listed while placed.
                    let blocks = group.blocks.filter { $0.isAvailable(for: providerSet) || layout.blocks.contains($0) }
                    if !blocks.isEmpty {
                        libraryGroup(group.label) { ForEach(blocks) { blockTile($0) } }
                    }
                }
                libraryGroup(L10n.text("panel.group.panel")) {
                    LibraryTile(label: L10n.text("panel.block.actions"), symbol: "ellipsis", placed: true,
                                selected: selected == .actions, always: L10n.text("main.panel.always"),
                                select: { selection = .actions })
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .mainCardSurface(radius: 14)
        }
    }

    private func libraryGroup<Tiles: View>(_ title: String, @ViewBuilder tiles: () -> Tiles) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 4).accessibilityAddTraits(.isHeader)
            tiles()
        }
    }

    /// Clicking selects; the round button adds or removes.
    private func blockTile(_ block: ExpandedPanelLayout.Block) -> some View {
        LibraryTile(label: block.label, symbol: block.symbol, placed: layout.blocks.contains(block),
                    selected: selected == .block(block), tint: tint(block),
                    faint: !block.isAvailable(for: providerSet), locked: locked(.block(block)),
                    addLabel: L10n.text("main.library.add_to_panel", block.label),
                    removeLabel: L10n.text("main.library.remove_from_panel", block.label),
                    lockedHelp: L10n.text("main.panel.last"),
                    select: { selection = .block(block) }, toggle: { toggle(block) })
    }

    private func tint(_ block: ExpandedPanelLayout.Block?) -> Color? {
        block?.provider?.shade(light: colorScheme == .light)
    }

    // MARK: Selected block

    private var inspector: some View {
        let item = selected
        let block: ExpandedPanelLayout.Block? = if case .block(let block) = item { block } else { nil }
        return PanelBlockInspector(item: item, placed: placed(item), locked: locked(item), tint: tint(block),
                                   note: note(item), toggle: { if let block { toggle(block) } }) {
            settings(item)
        }
    }

    private func placed(_ item: ExpandedPanelSelection) -> Bool {
        if case .block(let block) = item { return layout.blocks.contains(block) }
        return true
    }

    private func locked(_ item: ExpandedPanelSelection) -> Bool {
        if case .block(let block) = item { return layout.blocks.contains(block) && layout.isLastVisible(block, providers: providerSet) }
        return false
    }

    /// The state line above the options, when there is something to say:
    /// kept as the last block, waiting for its service, or not added yet.
    private func note(_ item: ExpandedPanelSelection) -> (text: String, neutral: Bool)? {
        guard case .block(let block) = item else { return nil }
        if locked(item) { return (L10n.text("main.panel.last"), true) }
        if !block.isAvailable(for: providerSet), let provider = block.provider {
            return (L10n.text("main.panel.unavailable", provider.displayName), true)
        }
        if !placed(item) { return (L10n.text("main.library.not_added"), false) }
        return nil
    }

    /// Only what changes the selected block. Style, arrangement, details and
    /// the pace tick are shared by every quota.
    @ViewBuilder private func settings(_ item: ExpandedPanelSelection) -> some View {
        switch item {
        case .block(.tasks):
            segments(L10n.text("main.panel.page_size"), help: L10n.text("main.panel.page_size_help"),
                     selection: $options.pageSize, options: ExpandedPanelOptions.pageSizes.map { ($0, "\($0)") })
            segments(L10n.text("main.panel.row_style"), help: L10n.text("main.panel.row_style_help"),
                     selection: $options.rowStyle, options: [(.twoLine, L10n.text("main.panel.row_two")),
                                                             (.oneLine, L10n.text("main.panel.row_one"))])
            PanelRow(title: L10n.text("main.panel.fields"), stacked: true) { RowFieldsEditor(options: $options) }
            PanelRow(title: L10n.text("reminders.retention")) {
                OutlineMenu(title: L10n.text("reminders.retention"), selection: $retention, options: [
                    (5, L10n.text("settings.five_minutes")), (15, L10n.text("settings.fifteen_minutes")),
                    (30, L10n.text("settings.thirty_minutes")), (60, L10n.text("settings.one_hour")),
                    (240, L10n.text("settings.four_hours")), (0, L10n.text("settings.until_clicked"))])
            }
            link(L10n.text("settings.hide_projects"), to: L10n.text("main.panel.in_general"), action: openGeneral)
        case .block(.codex), .block(.claude):
            if case .block(let block) = item, let provider = block.provider { quota(provider) }
        case .block(.deepseek):
            segments(L10n.text("main.panel.dial"), help: L10n.text("main.panel.dial_help"),
                     selection: $options.deepseekDial, options: [(.budget, L10n.text("main.panel.dial_budget")),
                                                                 (.day, L10n.text("main.panel.dial_day"))])
            switchRow(L10n.text("main.panel.peak"), help: L10n.text("main.panel.peak_help"), isOn: $options.deepseekPeak)
            link(L10n.text("main.panel.budget_link"), to: L10n.text("main.panel.in_deepseek"), action: openDeepSeek)
        case .block(.deepseekSpend):
            segments(L10n.text("main.panel.spend_tasks"), help: L10n.text("main.panel.spend_tasks_help"),
                     selection: $options.spendTasks,
                     options: ExpandedPanelOptions.spendTaskChoices.map { ($0, L10n.text("main.panel.spend_count", $0)) })
            switchRow(L10n.text("main.panel.elsewhere"), help: L10n.text("main.panel.elsewhere_help"), isOn: $options.spendElsewhere)
        case .block(.deepseekWeek):
            switchRow(L10n.text("main.panel.week_line"), help: L10n.text("main.panel.week_line_help"), isOn: $options.weekLine)
        case .actions:
            switchRow(L10n.text("panel.action.apps"), isOn: $showsAppButtons)
            switchRow(L10n.text("panel.action.markRead"), isOn: action(.markRead))
            switchRow(L10n.text("panel.action.pin"), isOn: action(.pin))
            switchRow(L10n.text("panel.action.settings"), isOn: action(.settings))
        }
    }

    @ViewBuilder private func quota(_ provider: AgentProvider) -> some View {
        segments(L10n.text("main.panel.periods"), stacked: true,
                 selection: Binding(get: { options.periods(for: provider) }, set: { options.setPeriods($0, for: provider) }),
                 options: [(.both, L10n.text("main.panel.periods_both")), (.weekly, L10n.text("main.panel.periods_weekly")),
                           (.fiveHour, L10n.text("main.panel.periods_five"))])
        segments(L10n.text("main.panel.style"), selection: $quotaStyle, options: ExpandedQuotaStyle.allCases.map { ($0, $0.label) })
        if providers.filter({ ExpandedPanelLayout.Block.quotaBlock(for: $0) != nil }).count > 1 {
            segments(L10n.text("main.panel.arrange"), selection: $options.quotaArrange,
                     options: [(.pair, L10n.text("main.panel.arrange_pair")), (.stack, L10n.text("main.panel.arrange_stack"))])
        }
        switchRow(L10n.text("main.panel.details"), help: L10n.text("main.panel.details_help"), isOn: $options.quotaDetails)
        switchRow(L10n.text("main.panel.pace_tick"), help: L10n.text("main.panel.pace_tick_help"), isOn: $options.paceTick)
    }

    private func segments<Value: Hashable>(_ title: String, help: String? = nil, stacked: Bool = false,
                                           selection: Binding<Value>, options: [(Value, String)]) -> some View {
        PanelRow(title: title, help: help, stacked: stacked) {
            MainSegmented(options: options.map { (value: $0.0, title: $0.1) }, selection: selection, label: title)
        }
    }

    private func switchRow(_ title: String, help: String? = nil, isOn: Binding<Bool>) -> some View {
        PanelRow(title: title, help: help) { Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch) }
    }

    /// A setting kept on another page, with the way there.
    private func link(_ title: String, to page: String, action: @escaping () -> Void) -> some View {
        PanelRow(title: title) {
            Button(action: action) {
                HStack(spacing: 4) {
                    Text(page).font(.system(size: 12.5))
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(accent).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title + ", " + page)
        }
    }

    private func action(_ action: ExpandedPanelOptions.HeaderAction) -> Binding<Bool> {
        Binding(get: { options.headerActions.contains(action) }, set: { on in
            if on { options.headerActions.insert(action) } else { options.headerActions.remove(action) }
        })
    }
}

extension ExpandedPanelLayout.Block {
    /// A service's own quota block.
    static func quotaBlock(for provider: AgentProvider) -> Self? {
        switch provider {
        case .codex: .codex
        case .claude: .claude
        case .deepseek: .deepseek
        }
    }
}

/// The selected block's card: a tinted tile, its name with ⓘ and Add or
/// Remove, a state line when needed, then one row per option.
private struct PanelBlockInspector<Rows: View>: View {
    let item: ExpandedPanelSelection
    let placed: Bool
    let locked: Bool
    let tint: Color?
    let note: (text: String, neutral: Bool)?
    let toggle: () -> Void
    @ViewBuilder let rows: () -> Rows
    @State private var showsInfo = false

    private var block: ExpandedPanelLayout.Block? { if case .block(let block) = item { block } else { nil } }
    private var name: String { block?.label ?? L10n.text("panel.block.actions") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("main.panel.selected")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.leading, 4).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: block?.symbol ?? "ellipsis").font(.system(size: 15, weight: .regular))
                        .foregroundStyle(tint ?? Color.secondary)
                        .frame(width: 34, height: 34)
                        .background((tint ?? Color.secondary).opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .accessibilityHidden(true)
                    HStack(spacing: 2) {
                        Text(name).font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
                            .accessibilityAddTraits(.isHeader)
                        PanelInfoButton(title: name, isOn: $showsInfo, large: true)
                    }
                    Spacer(minLength: 8)
                    if block != nil {
                        if placed {
                            Button(L10n.text("main.collapsed.remove"), action: toggle).buttonStyle(MainButtonStyle(height: 26)).disabled(locked)
                        } else {
                            Button(L10n.text("main.collapsed.add"), action: toggle).buttonStyle(MainButtonStyle(prominent: true, height: 26))
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 14)
                if showsInfo {
                    InfoBox(text: block?.detail ?? L10n.text("panel.block_detail.actions")).padding(.horizontal, 16).padding(.bottom, 12)
                }
                if let note { LibraryNote(text: note.text, neutral: note.neutral).padding(.horizontal, 16).padding(.bottom, 12) }
                _VariadicView.Tree(InspectorRows()) { rows() }
                    .padding(.horizontal, 16).padding(.bottom, 4)
                    .id(item)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .mainCardSurface(radius: 14)
        }
        .onChange(of: item) { _, _ in showsInfo = false }
    }
}

/// Each option row under a hairline.
private struct InspectorRows: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(children) { child in
                Rectangle().fill(MainPalette.separator).frame(height: 1)
                child.padding(.vertical, 10)
            }
        }
    }
}

/// One option: its label with an optional ⓘ, and the control at the end or
/// under the label.
private struct PanelRow<Control: View>: View {
    let title: String
    var help: String? = nil
    var stacked = false
    @ViewBuilder let control: Control
    @State private var showsInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if stacked {
                label
                control
            } else {
                HStack(spacing: 12) {
                    label
                    Spacer(minLength: 8)
                    control
                }
            }
            if showsInfo, let help { InfoBox(text: help) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var label: some View {
        HStack(spacing: 2) {
            Text(title).font(.system(size: 13)).lineLimit(1)
            if help != nil { PanelInfoButton(title: title, isOn: $showsInfo) }
        }
        .frame(minHeight: 24)
    }
}

/// A round ⓘ that tints while its explanation is open.
private struct PanelInfoButton: View {
    @Environment(\.pacerAccent) private var accent
    let title: String
    @Binding var isOn: Bool
    var large = false

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() }
        } label: {
            Image(systemName: "info.circle").font(.system(size: large ? 14 : 13))
                .foregroundStyle(isOn ? accent : Color.secondary)
                .frame(width: large ? 22 : 20, height: large ? 22 : 20)
                .background(isOn ? accent.opacity(0.14) : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text("main.info", title))
        .accessibilityValue(L10n.text(isOn ? "main.info_shown" : "main.info_hidden"))
    }
}

/// The task row's readings: a live sample row, then one chip per reading. A
/// one-line row has no room for the second line's readings, so those chips
/// rest.
private struct RowFieldsEditor: View {
    @Environment(\.pacerAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme
    @Binding var options: ExpandedPanelOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RowPreview(options: options)
            FlowRow(spacing: 6, lineSpacing: 6) {
                ForEach(ExpandedPanelOptions.RowField.allCases, id: \.self) { chip($0) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.text("main.panel.fields"))
        }
    }

    static func symbol(_ field: ExpandedPanelOptions.RowField) -> String {
        switch field {
        case .rate: "speedometer"
        case .turnTime: "timer"
        case .model: "cpu"
        case .source: "server.rack"
        case .subagents: "person.2"
        case .cost: "yensign.circle"
        }
    }

    private func chip(_ field: ExpandedPanelOptions.RowField) -> some View {
        let usable = options.rowStyle == .twoLine || field.showsInOneLine
        let on = usable && options.rowFields.contains(field)
        let light = colorScheme == .light
        let onInk = light ? Color(nsColor: NSColor(accent).blended(withFraction: 0.25, of: .black) ?? NSColor(accent)) : accent
        return Button {
            if options.rowFields.contains(field) { options.rowFields.remove(field) } else { options.rowFields.insert(field) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: Self.symbol(field)).font(.system(size: 11, weight: .medium))
                Text(L10n.text("panel.chip." + field.rawValue)).font(.system(size: 12.5, weight: on ? .semibold : .medium))
            }
            .foregroundStyle(on ? onInk : Color.primary.opacity(0.8))
            .padding(.leading, 9).padding(.trailing, 12).frame(height: 28)
            .background(on ? accent.opacity(light ? 0.12 : 0.25) : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(on ? accent.opacity(0.35) : LibraryPalette.border, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!usable)
        .opacity(usable ? 1 : 0.38)
        .accessibilityLabel(field.label)
        .accessibilityAddTraits(on ? [.isToggle, .isSelected] : .isToggle)
    }
}

/// A dark sample task row with only the chosen readings, in DeepSeek's blue.
private struct RowPreview: View {
    let options: ExpandedPanelOptions
    private static let label = Color(red: 245 / 255, green: 245 / 255, blue: 247 / 255)
    private static let secondary = Color(red: 152 / 255, green: 152 / 255, blue: 157 / 255)
    private static let time = Color(red: 199 / 255, green: 199 / 255, blue: 204 / 255)
    private static let cost = Color(red: 229 / 255, green: 229 / 255, blue: 234 / 255)

    private var oneLine: Bool { options.rowStyle == .oneLine }
    private func shows(_ field: ExpandedPanelOptions.RowField) -> Bool {
        options.rowFields.contains(field) && (!oneLine || field.showsInOneLine)
    }

    var body: some View {
        let tint = AgentProvider.deepseek.shade(light: false)
        let icon: CGFloat = oneLine ? 22 : 28
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 2.2)
                Circle().trim(from: 0, to: 0.3).stroke(tint, style: StrokeStyle(lineWidth: 2.2, lineCap: .round)).rotationEffect(.degrees(-90))
                Circle().fill(tint).frame(width: 6, height: 6)
            }
            .padding(1.1)
            .frame(width: icon, height: icon)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(L10n.text("panel.preview.title")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Self.label)
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        if shows(.rate) {
                            Text("48.2").font(.system(size: 13, weight: .semibold)).foregroundStyle(Self.label)
                            Text(" t/s").font(.system(size: 10))
                        }
                        if shows(.rate), shows(.turnTime) { Text(" · ") }
                        if shows(.turnTime) { Text(L10n.text("dashboard.countdown_minutes", 12)).foregroundStyle(Self.time) }
                    }
                    .font(.system(size: 12)).foregroundStyle(Self.secondary).monospacedDigit().fixedSize()
                }
                if !oneLine {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        HStack(spacing: 10) {
                            Text(L10n.text("panel.preview.status"))
                            if shows(.subagents) { Label("2", systemImage: "person.2") }
                            if shows(.source) { Label("devbox", systemImage: "server.rack") }
                        }
                        .labelStyle(PreviewLabelStyle())
                        .foregroundStyle(Self.secondary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if shows(.cost) { Text("¥0.12").foregroundStyle(Self.cost) }
                            if shows(.model) { Text(ModelDisplay.name("deepseek-v4-pro")).foregroundStyle(tint) }
                        }
                        .fixedSize()
                    }
                    .font(.system(size: 11))
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, oneLine ? 8 : 10)
        .background(Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.04)))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("panel.preview.accessibility"))
    }
}

private struct PreviewLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 9.5))
            configuration.title
        }
    }
}
