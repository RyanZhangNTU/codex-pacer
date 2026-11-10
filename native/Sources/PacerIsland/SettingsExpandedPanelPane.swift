import PacerCore
import SwiftUI

/// What the Expanded Panel page's settings card describes: a block, or the
/// panel's buttons, which always sit in the first block's header.
enum ExpandedPanelSelection: Hashable {
    case block(ExpandedPanelLayout.Block)
    case actions
}

/// The Expanded Panel page: the panel as a sketch of its blocks to click and
/// drag, every block by group to add or remove, and the settings of the one
/// selected. Each change is saved at once and reaches the real panel.
struct SettingsExpandedPanelPane: View {
    @Environment(\.pacerAccent) private var accent
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
        HStack(alignment: .top, spacing: 16) {
            sketch.frame(width: 248)
            VStack(alignment: .leading, spacing: 18) {
                library
                inspector
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    /// The sketch's rows: adjacent quota blocks share a row while paired.
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

    // MARK: Sketch

    private var sketch: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("main.panel.shown")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.leading, 4).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 6) {
                let rows = Self.rows(visible, arrange: options.quotaArrange)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 6) {
                        ForEach(row) { block in
                            sketchTile(block, first: index == 0 && block == row.first, shared: row.count > 1)
                        }
                    }
                }
                endZone
            }
            .padding(8)
            .islandSurface(radius: 16)
            footer
        }
    }

    /// A tile sharing its row names only its service, so the name fits.
    private func sketchTile(_ block: ExpandedPanelLayout.Block, first: Bool, shared: Bool) -> some View {
        let isSelected = selected == .block(block)
        let target = dropTarget == .block(block)
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if !shared { Image(systemName: block.symbol).font(.system(size: 9.5, weight: .semibold)).frame(width: 12) }
                Text(shared ? block.provider?.displayName ?? block.label : block.label)
                    .font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 2)
                // Room for the buttons' chip, drawn over the tile so it stays its own control.
                if first { Color.clear.frame(width: 22, height: 14) }
            }
            .foregroundStyle(PacerPalette.secondary)
            SketchContent(block: block, options: options, alone: !shared)
        }
        .padding(.horizontal, 9).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(PacerPalette.overlay(isSelected ? 0.1 : 0.04), in: shape)
        .overlay(shape.strokeBorder(isSelected ? accent : PacerPalette.overlay(0.08), lineWidth: isSelected ? 1.5 : 1))
        .overlay(alignment: .top) {
            if target { Capsule().fill(accent).frame(height: 3).offset(y: -4.5).accessibilityHidden(true) }
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
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { selection = .block(block) }
        .accessibilityAction(named: L10n.text("main.panel.move_up")) { shift(block, by: -1) }
        .accessibilityAction(named: L10n.text("main.panel.move_down")) { shift(block, by: 1) }
        .overlay(alignment: .topTrailing) {
            if first { actionsChip.padding(.top, 8).padding(.trailing, 9) }
        }
    }

    /// The panel's buttons ride in the first block's header.
    private var actionsChip: some View {
        let isSelected = selected == .actions
        return Image(systemName: "ellipsis").font(.system(size: 9, weight: .bold))
            .foregroundStyle(isSelected ? Color.white : PacerPalette.secondary)
            .frame(width: 22, height: 14)
            .background(isSelected ? accent : PacerPalette.overlay(0.1), in: Capsule())
            .contentShape(Capsule())
            .onTapGesture { selection = .actions }
            .help(L10n.text("panel.block.actions"))
            .accessibilityElement()
            .accessibilityLabel(L10n.text("panel.block.actions"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { selection = .actions }
    }

    /// Dropping below the last block moves a block to the end.
    private var endZone: some View {
        Color.clear.frame(height: 12)
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

    @ViewBuilder private var footer: some View {
        if savedLayout == nil {
            Text(L10n.text("main.panel.automatic")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        } else {
            Button(L10n.text("main.panel.restore")) { savedLayout = nil }.buttonStyle(.main).padding(.leading, 2)
        }
    }

    // MARK: Library

    private var library: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("main.panel.blocks")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.leading, 4).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(ExpandedPanelLayout.Group.allCases, id: \.self) { group in
                    let blocks = group.blocks.filter { $0.isAvailable(for: providerSet) }
                    if !blocks.isEmpty {
                        libraryGroup(group.label) { ForEach(blocks) { tile(.block($0)) } }
                    }
                }
                libraryGroup(L10n.text("panel.group.panel")) { tile(.actions) }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .mainCardSurface()
        }
    }

    private func libraryGroup<Tiles: View>(_ title: String, @ViewBuilder tiles: () -> Tiles) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], alignment: .leading, spacing: 6) { tiles() }
        }
    }

    private func tile(_ item: ExpandedPanelSelection) -> some View {
        let block: ExpandedPanelLayout.Block? = if case .block(let block) = item { block } else { nil }
        let on = block.map(layout.blocks.contains) ?? true
        let locked = block.map { on && layout.isLastVisible($0, providers: providerSet) } ?? false
        let isSelected = selected == item
        let label = block?.label ?? L10n.text("panel.block.actions")
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return HStack(spacing: 0) {
            Button { selection = item } label: {
                HStack(spacing: 7) {
                    Image(systemName: block?.symbol ?? "ellipsis").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(on ? Color.primary : Color.secondary).frame(width: 16)
                    Text(label).font(.system(size: 12.5)).lineLimit(1).minimumScaleFactor(0.85)
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                    Spacer(minLength: 4)
                }
                .padding(.leading, 10).frame(maxHeight: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityValue(L10n.text(on ? "main.panel.shown" : "main.panel.hidden"))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            if let block {
                Button { selection = item; toggle(block) } label: {
                    Image(systemName: on ? "checkmark" : "plus").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(on ? accent : Color.secondary)
                        .frame(width: 30).frame(maxHeight: .infinity).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(locked)
                .help(locked ? L10n.text("main.panel.last") : L10n.text(on ? "main.collapsed.remove" : "main.collapsed.add"))
                .accessibilityLabel(L10n.text(on ? "main.collapsed.remove" : "main.collapsed.add") + " " + label)
            } else {
                Text(L10n.text("main.panel.always")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.horizontal, 10)
            }
        }
        .frame(height: 32)
        .background(on ? MainPalette.fill : .clear, in: shape)
        .overlay(shape.strokeBorder(isSelected ? accent : MainPalette.cardBorder, lineWidth: isSelected ? 1.5 : 1))
    }

    // MARK: Selected block

    private var inspector: some View {
        let item = selected
        return PanelBlockInspector(item: item, placed: placed(item), canShift: canShift(item), locked: locked(item),
            unavailable: unavailableProvider(item),
            toggle: { if case .block(let block) = item { toggle(block) } },
            shift: { offset in if case .block(let block) = item { shift(block, by: offset) } }) {
            settings(item)
        }
    }

    private func placed(_ item: ExpandedPanelSelection) -> Bool {
        if case .block(let block) = item { return layout.blocks.contains(block) }
        return true
    }

    /// Up and down, each when the block can move that way among those shown.
    private func canShift(_ item: ExpandedPanelSelection) -> (up: Bool, down: Bool)? {
        guard case .block(let block) = item, let index = visible.firstIndex(of: block) else { return nil }
        return (index > 0, index < visible.count - 1)
    }

    private func locked(_ item: ExpandedPanelSelection) -> Bool {
        if case .block(let block) = item { return layout.blocks.contains(block) && layout.isLastVisible(block, providers: providerSet) }
        return false
    }

    private func unavailableProvider(_ item: ExpandedPanelSelection) -> AgentProvider? {
        guard case .block(let block) = item, !block.isAvailable(for: providerSet) else { return nil }
        return block.provider
    }

    private var show: [(Bool, String)] { [(true, L10n.text("main.panel.show")), (false, L10n.text("main.panel.hide"))] }

    /// Only what changes the selected block. Style, arrangement, details and
    /// the pace tick are shared by every quota.
    @ViewBuilder private func settings(_ item: ExpandedPanelSelection) -> some View {
        switch item {
        case .block(.tasks):
            OptionSegments(title: L10n.text("main.panel.page_size"), hint: L10n.text("main.panel.page_size_help"),
                           selection: $options.pageSize, options: ExpandedPanelOptions.pageSizes.map { ($0, "\($0)") })
            OptionSegments(title: L10n.text("main.panel.row_style"), hint: L10n.text("main.panel.row_style_help"),
                           selection: $options.rowStyle, options: [(.twoLine, L10n.text("main.panel.row_two")),
                                                                   (.oneLine, L10n.text("main.panel.row_one"))])
            fields
            CardPicker(title: L10n.text("reminders.retention"), selection: $retention, options: [
                (5, L10n.text("settings.five_minutes")), (15, L10n.text("settings.fifteen_minutes")),
                (30, L10n.text("settings.thirty_minutes")), (60, L10n.text("settings.one_hour")),
                (240, L10n.text("settings.four_hours")), (0, L10n.text("settings.until_clicked"))])
            CardRow(title: L10n.text("settings.hide_projects")) {
                Button(L10n.text("main.panel.in_general"), action: openGeneral).buttonStyle(.link).font(.system(size: 12.5))
            }
        case .block(.codex), .block(.claude):
            if case .block(let block) = item, let provider = block.provider { quota(provider) }
        case .block(.deepseek):
            OptionSegments(title: L10n.text("main.panel.dial"), hint: L10n.text("main.panel.dial_help"),
                           selection: $options.deepseekDial, options: [(.budget, L10n.text("main.panel.dial_budget")),
                                                                       (.day, L10n.text("main.panel.dial_day"))])
            OptionSegments(title: L10n.text("main.panel.peak"), hint: L10n.text("main.panel.peak_help"),
                           selection: $options.deepseekPeak, options: show)
            CardRow(title: L10n.text("main.panel.budget_link")) {
                Button(L10n.text("main.panel.in_deepseek"), action: openDeepSeek).buttonStyle(.link).font(.system(size: 12.5))
            }
        case .block(.deepseekSpend):
            OptionSegments(title: L10n.text("main.panel.spend_tasks"), hint: L10n.text("main.panel.spend_tasks_help"),
                           selection: $options.spendTasks,
                           options: ExpandedPanelOptions.spendTaskChoices.map { ($0, L10n.text("main.panel.spend_count", $0)) })
            OptionSegments(title: L10n.text("main.panel.elsewhere"), hint: L10n.text("main.panel.elsewhere_help"),
                           selection: $options.spendElsewhere, options: show)
        case .block(.deepseekWeek):
            OptionSegments(title: L10n.text("main.panel.week_line"), hint: L10n.text("main.panel.week_line_help"),
                           selection: $options.weekLine, options: show)
        case .actions:
            Checklist(title: L10n.text("main.panel.actions"), hint: L10n.text("main.panel.actions_help"), items: [
                (L10n.text("panel.action.apps"), nil, $showsAppButtons),
                (L10n.text("panel.action.markRead"), nil, action(.markRead)),
                (L10n.text("panel.action.pin"), nil, action(.pin)),
                (L10n.text("panel.action.settings"), nil, action(.settings))])
        }
    }

    /// One line of a two-line row; a one-line row keeps only speed and turn time.
    private var fields: some View {
        Checklist(title: L10n.text("main.panel.fields"), hint: L10n.text("main.panel.fields_help"),
                  items: ExpandedPanelOptions.RowField.allCases.map { field in
                      let note: String? = switch field {
                      case .source: L10n.text("panel.field.source_note")
                      case .cost: L10n.text("panel.field.cost_note")
                      default: nil
                      }
                      return (field.label, note, Binding(get: { options.rowFields.contains(field) }, set: { on in
                          if on { options.rowFields.insert(field) } else { options.rowFields.remove(field) }
                      }))
                  },
                  disabled: { index in
                      options.rowStyle == .oneLine && !ExpandedPanelOptions.RowField.allCases[index].showsInOneLine
                  })
    }

    @ViewBuilder private func quota(_ provider: AgentProvider) -> some View {
        OptionSegments(title: L10n.text("main.panel.periods"), selection: Binding(get: { options.periods(for: provider) },
                       set: { options.setPeriods($0, for: provider) }),
                       options: [(.both, L10n.text("main.panel.periods_both")), (.weekly, L10n.text("main.panel.periods_weekly")),
                                 (.fiveHour, L10n.text("main.panel.periods_five"))])
        OptionSegments(title: L10n.text("main.panel.style"), selection: $quotaStyle,
                       options: ExpandedQuotaStyle.allCases.map { ($0, $0.label) })
        if providers.filter({ ExpandedPanelLayout.Block.quotaBlock(for: $0) != nil }).count > 1 {
            OptionSegments(title: L10n.text("main.panel.arrange"), selection: $options.quotaArrange,
                           options: [(.pair, L10n.text("main.panel.arrange_pair")), (.stack, L10n.text("main.panel.arrange_stack"))])
        }
        OptionSegments(title: L10n.text("main.panel.details"), hint: L10n.text("main.panel.details_help"),
                       selection: $options.quotaDetails, options: show)
        OptionSegments(title: L10n.text("main.panel.pace_tick"), hint: L10n.text("main.panel.pace_tick_help"),
                       selection: $options.paceTick, options: show)
        Text(L10n.text("main.panel.shared_note")).font(.system(size: 11.5)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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

/// A rough drawing of what a block shows, enough to tell the blocks apart.
private struct SketchContent: View {
    let block: ExpandedPanelLayout.Block
    let options: ExpandedPanelOptions
    /// A quota with a row to itself shows its details beside the ring.
    let alone: Bool

    var body: some View {
        switch block {
        case .tasks:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<min(options.pageSize, 3), id: \.self) { index in
                    HStack(spacing: 5) {
                        Circle().strokeBorder(PacerPalette.overlay(0.3), lineWidth: 1.5).frame(width: 9, height: 9)
                        bar(width: index == 0 ? 70 : 54)
                        Spacer(minLength: 4)
                        bar(width: 22, opacity: 0.12)
                    }
                    if options.rowStyle == .twoLine { bar(width: 40, opacity: 0.1).padding(.leading, 14) }
                }
            }
        case .codex, .claude, .deepseek:
            HStack(spacing: 8) {
                Circle().trim(from: 0, to: 0.72).stroke(block.provider?.tint ?? PacerPalette.secondary,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 24, height: 24)
                if alone ? options.quotaDetails || block == .deepseek : block == .deepseek {
                    VStack(alignment: .leading, spacing: 4) { bar(width: 46); bar(width: 32, opacity: 0.12) }
                }
            }
        case .deepseekSpend:
            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 2).fill(AgentProvider.deepseek.tint.opacity(0.9)).frame(width: 60, height: 6)
                RoundedRectangle(cornerRadius: 2).fill(AgentProvider.deepseek.tint.opacity(0.5)).frame(width: 40, height: 6)
                RoundedRectangle(cornerRadius: 2).fill(PacerPalette.overlay(0.16)).frame(height: 6)
            }
        case .deepseekWeek:
            HStack(alignment: .bottom, spacing: 5) {
                ForEach([8, 14, 10, 18, 12, 16, 20], id: \.self) { height in
                    RoundedRectangle(cornerRadius: 1.5).fill(AgentProvider.deepseek.tint.opacity(height == 20 ? 1 : 0.5))
                        .frame(width: 8, height: CGFloat(height))
                }
            }
        }
    }

    private func bar(width: CGFloat, opacity: Double = 0.2) -> some View {
        Capsule().fill(PacerPalette.overlay(opacity)).frame(width: width, height: 4)
    }
}

/// The selected block's card: its name with ⓘ, moving and Add or Remove,
/// then the options that change it.
private struct PanelBlockInspector<Options: View>: View {
    @Environment(\.pacerAccent) private var accent
    let item: ExpandedPanelSelection
    let placed: Bool
    let canShift: (up: Bool, down: Bool)?
    let locked: Bool
    let unavailable: AgentProvider?
    let toggle: () -> Void
    let shift: (Int) -> Void
    @ViewBuilder let options: () -> Options
    @State private var showsInfo = false

    private var block: ExpandedPanelLayout.Block? { if case .block(let block) = item { block } else { nil } }
    private var name: String { block?.label ?? L10n.text("panel.block.actions") }

    var body: some View {
        MainCard(title: L10n.text("main.panel.selected")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: block?.symbol ?? "ellipsis").font(.system(size: 12, weight: .medium)).foregroundStyle(accent)
                        .frame(width: 26, height: 26)
                        .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .accessibilityHidden(true)
                    Text(name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
                    InfoButton(title: name, isOn: $showsInfo)
                    Spacer(minLength: 4)
                    if let canShift {
                        HStack(spacing: 2) {
                            Button { shift(-1) } label: { Image(systemName: "chevron.up") }
                                .disabled(!canShift.up).help(L10n.text("main.panel.move_up"))
                                .accessibilityLabel(L10n.text("main.panel.move_up"))
                                .keyboardShortcut(.upArrow, modifiers: .option)
                            Button { shift(1) } label: { Image(systemName: "chevron.down") }
                                .disabled(!canShift.down).help(L10n.text("main.panel.move_down"))
                                .accessibilityLabel(L10n.text("main.panel.move_down"))
                                .keyboardShortcut(.downArrow, modifiers: .option)
                        }
                        .buttonStyle(MainButtonStyle(height: 24)).font(.system(size: 10, weight: .semibold))
                    }
                    if block != nil {
                        if placed {
                            Button(L10n.text("main.collapsed.remove"), action: toggle).buttonStyle(.main).disabled(locked)
                        } else {
                            Button(L10n.text("main.collapsed.add"), action: toggle).buttonStyle(.mainProminent)
                        }
                    }
                }
                if showsInfo { InfoBox(text: block?.detail ?? L10n.text("panel.block_detail.actions")) }
                if locked {
                    Text(L10n.text("main.panel.last")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            if let unavailable {
                CardRow(title: L10n.text("main.panel.unavailable", unavailable.displayName))
            } else if placed {
                options()
            }
        }
        .onChange(of: item) { _, _ in showsInfo = false }
    }
}

/// A titled list of checkboxes, two to a row, each with an optional note.
private struct Checklist: View {
    let title: String
    let hint: String
    let items: [(String, String?, Binding<Bool>)]
    var disabled: (Int) -> Bool = { _ in false }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(hint).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    // The card's rows draw switches; a checkbox here leads its label.
                    HStack(spacing: 6) {
                        Toggle(item.1.map { item.0 + ", " + $0 } ?? item.0, isOn: item.2).labelsHidden().toggleStyle(.checkbox)
                        HStack(spacing: 4) {
                            Text(item.0).font(.system(size: 12.5))
                            if let note = item.1 { Text(note).font(.system(size: 11)).foregroundStyle(.secondary) }
                        }
                        .lineLimit(1)
                        .contentShape(Rectangle())
                        .onTapGesture { if !disabled(index) { item.2.wrappedValue.toggle() } }
                        .accessibilityHidden(true)
                    }
                    .disabled(disabled(index))
                    .opacity(disabled(index) ? 0.5 : 1)
                }
            }
        }
    }
}
