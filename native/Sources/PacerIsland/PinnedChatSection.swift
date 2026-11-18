import AppKit
import SwiftUI
import PacerCore

struct PinnedChatViewSwitch: View {
    @ObservedObject var model: IslandModel
    var body: some View {
        if model.pinProfile != nil {
            let text = L10n.text(model.showsPinnedChats ? "conversation_groups.all_tasks" : "conversation_groups.title")
            Button(text) { model.togglePinnedView() }
                .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("island.switch_pinned_chats")
        }
    }
}

struct PinnedChatSection: View {
    @ObservedObject var model: IslandModel
    let actions: Bool

    var body: some View {
        let rows = model.pinnedChatRows
        let sections = PinnedConversationGroups.sections(model.savedChatGroups, ids: rows.map(\.activity.id),
            running: Set(rows.filter { $0.live?.phase == .running }.map(\.activity.id)))
        let rowHeight = TaskRowView.height(model.panelOptions.rowStyle)
        let height = sections.reduce(CGFloat.zero) { total, section in
            total + 32 + (section.group?.collapsed == true ? 0 : CGFloat(section.members.count) * (rowHeight + 2))
        }
        VStack(alignment: .leading, spacing: 4) {
            IslandSectionHeader(title: L10n.text("conversation_groups.title"), detail: String(rows.count)) {
                PinnedChatViewSwitch(model: model)
                if actions { IslandPanelControls(model: model) }
            }
            if rows.isEmpty {
                Label(L10n.text(model.pinCatalog.available ? "conversation_groups.empty" : "conversation_groups.unavailable"),
                      systemImage: "moon").font(.system(size: 12)).foregroundStyle(PacerPalette.secondary)
                    .frame(height: 44).padding(.horizontal, IslandMetrics.rowInset)
            } else {
                PinnedChatOutline(model: model, rows: rows, sections: sections)
                    .frame(height: min(360, max(44, height)))
                    .help(model.pinCatalog.available ? "" : L10n.text("conversation_groups.unavailable"))
            }
        }
    }
}

/// The native outline owns pointer tracking, scrolling, disclosure, and drag cancellation.
/// A drag exposes only a random token to this outline's own local dragging session.
struct PinnedChatOutline: NSViewRepresentable {
    let model: IslandModel
    let rows: [CodexPinnedThreads.Row]
    let sections: [PinnedConversationGroups.Section]

    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.makeScrollView() }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.update(self) }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) { coordinator.finish() }

    enum Key: Hashable { case group(String?), chat(String) }
    final class Node: NSObject {
        let key: Key
        init(_ key: Key) { self.key = key }
    }
    final class Outline: NSOutlineView {
        weak var owner: Coordinator?
        override func menu(for event: NSEvent) -> NSMenu? {
            let index = row(at: convert(event.locationInWindow, from: nil))
            guard index >= 0, let node = item(atRow: index) as? Node else { return nil }
            return owner?.menu(for: node)
        }
    }
    final class Cell: NSTableCellView {
        var press: (() -> Void)?
        override func accessibilityPerformPress() -> Bool {
            guard let press else { return false }; press(); return true
        }
    }
    /// The outline handles clicks and drags even for a chat that has no navigation link.
    final class RowHost: NSHostingView<AnyView> {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
        let model: IslandModel
        let outline = Outline()
        private var latest: PinnedChatOutline?
        private var nodes: [Key: Node] = [:], roots: [Node] = [], children: [Key: [Node]] = [:]
        private var rows: [String: CodexPinnedThreads.Row] = [:]
        private var sections: [PinnedConversationGroups.Section] = []
        private var profile: String?, privateNames = false, updating = false
        private var rowHeight: CGFloat = 54
        private static let pasteboardType = NSPasteboard.PasteboardType("com.codexpacer.pinned-chat-drag")
        private typealias Drag = (key: Key, token: String, profile: String)
        private var preparedDrag: Drag?, drag: Drag?
        private var editor: (id: String, profile: String, field: NSTextField)?
        private var cancelEdit = false
        init(_ model: IslandModel) { self.model = model }

        func makeScrollView() -> NSScrollView {
            let scroll = NSScrollView()
            scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            let column = NSTableColumn(identifier: .init("chat")); column.resizingMask = .autoresizingMask
            outline.addTableColumn(column); outline.outlineTableColumn = column; outline.headerView = nil
            outline.style = .plain; outline.backgroundColor = .clear; outline.selectionHighlightStyle = .none
            outline.indentationPerLevel = 12; outline.intercellSpacing = NSSize(width: 0, height: 2)
            outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            outline.autoresizesOutlineColumn = false; outline.autosaveExpandedItems = false
            outline.owner = self; outline.delegate = self; outline.dataSource = self
            outline.target = self; outline.action = #selector(clickRow)
            outline.registerForDraggedTypes([Self.pasteboardType])
            outline.setDraggingSourceOperationMask(.move, forLocal: true)
            outline.setDraggingSourceOperationMask([], forLocal: false)
            outline.setAccessibilityIdentifier("island.conversations")
            outline.setAccessibilityLabel(L10n.text("conversation_groups.title"))
            scroll.documentView = outline
            return scroll
        }

        func update(_ value: PinnedChatOutline) {
            latest = value
            let scope = model.pinProfile, privacy = model.hideProjects
            let changedScope = scope != profile || privacy != privateNames
            if changedScope { cancelInteraction() }
            if (editor != nil || drag != nil) && !changedScope { return }
            let height = TaskRowView.height(model.panelOptions.rowStyle)
            let rebuild = value.sections != sections || changedScope || rowHeight != height
            profile = scope; privateNames = privacy; rowHeight = height
            rows = Dictionary(uniqueKeysWithValues: value.rows.map { ($0.activity.id, $0) })
            if rebuild {
                updating = true
                defer { updating = false }
                let scroll = outline.enclosingScrollView, origin = scroll?.contentView.bounds.origin
                sections = value.sections
                var next: [Key: Node] = [:]
                func node(_ key: Key) -> Node { let n = nodes[key] ?? Node(key); next[key] = n; return n }
                children = [:]
                roots = sections.map { section in
                    let parent = node(.group(section.group?.id))
                    children[parent.key] = section.members.map { node(.chat($0)) }
                    return parent
                }
                nodes = next
                outline.reloadData()
                for (parent, section) in zip(roots, sections) {
                    if section.group?.collapsed == true { outline.collapseItem(parent) } else { outline.expandItem(parent) }
                }
                if let scroll, let origin { scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView) }
            } else if outline.numberOfRows > 0 {
                // Only replace the SwiftUI content of visible task cells. Native row identity and scrolling survive metrics updates.
                let range = outline.rows(in: outline.visibleRect)
                if range.location != NSNotFound {
                    for index in range.location..<min(NSMaxRange(range), outline.numberOfRows) {
                        guard let node = outline.item(atRow: index) as? Node, case let .chat(id) = node.key, let row = rows[id],
                              let cell = outline.view(atColumn: 0, row: index, makeIfNecessary: false) as? Cell,
                              let host = cell.subviews.first as? RowHost else { continue }
                        host.rootView = content(row)
                        cell.setAccessibilityLabel(row.title + ", " + (row.live?.status ?? L10n.text("activity.idle")))
                        cell.press = openAction(row)
                    }
                }
            }
        }

        private func section(_ id: String?) -> PinnedConversationGroups.Section? { sections.first { $0.group?.id == id } }
        private func groupName(_ group: PinnedConversationGroups.Group?) -> String {
            guard let group else { return L10n.text("conversation_groups.ungrouped") }
            return privateNames ? L10n.text("conversation_groups.hidden") : group.name
        }
        private func content(_ row: CodexPinnedThreads.Row) -> AnyView {
            let view: AnyView
            if let live = row.live {
                view = AnyView(TaskRowView(presentation: live, group: model.taskGroup(for: row.activity), now: model.now,
                    enabled: model.canOpenPinned(row), accent: model.taskAccent, options: model.panelOptions, action: {}))
            } else {
                view = AnyView(HStack(spacing: 9) {
                    StatusGlyph(symbol: StatusSymbols.idle, tint: PacerPalette.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(PacerPalette.primary).lineLimit(1)
                        if model.panelOptions.rowStyle == .twoLine {
                            Text(L10n.text("activity.idle")).font(.system(size: 11)).foregroundStyle(PacerPalette.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 4))
            }
            return AnyView(view.environment(\.colorScheme, model.lightTone ? .light : .dark).accessibilityHidden(true))
        }
        private func openAction(_ row: CodexPinnedThreads.Row) -> (() -> Void)? {
            guard let scope = profile, model.canOpenPinned(row) else { return nil }
            return { [weak model] in model?.openPinned(row.activity.id, profile: scope) }
        }
        private func pin(_ view: NSView, to cell: Cell) {
            cell.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: cell.trailingAnchor), view.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? Node).map { children[$0.key]?.count ?? 0 } ?? roots.count
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if let node = item as? Node { return children[node.key]![index] }
            return roots[index]
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? Node, case .group = node.key else { return false }
            return !(children[node.key]?.isEmpty ?? true)
        }
        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            if let node = item as? Node, case .group = node.key { return 30 }; return rowHeight
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node else { return nil }
            let cell = Cell()
            switch node.key {
            case let .chat(id):
                guard let row = rows[id] else { return nil }
                let host = RowHost(rootView: content(row))
                pin(host, to: cell); host.heightAnchor.constraint(equalTo: cell.heightAnchor).isActive = true
                cell.press = openAction(row)
                cell.setAccessibilityIdentifier("island.chat." + id)
                cell.setAccessibilityLabel(row.title + ", " + (row.live?.status ?? L10n.text("activity.idle")))
            case let .group(id):
                guard let section = section(id) else { return nil }
                let name = groupName(section.group)
                let field = NSTextField(labelWithString: name + "  " + String(section.members.count))
                field.font = .systemFont(ofSize: 12, weight: .semibold); field.lineBreakMode = .byTruncatingTail
                field.textColor = .secondaryLabelColor; cell.textField = field; pin(field, to: cell)
                if let id, !privateNames { cell.press = { [weak self, weak cell] in
                    guard let self, let cell else { return }; self.rename(id, cell: cell)
                } }
                cell.toolTip = id == nil ? nil : L10n.text("conversation_groups.drag_help")
                cell.setAccessibilityIdentifier("island.group.header." + (id ?? "ungrouped"))
                cell.setAccessibilityLabel(name)
            }
            cell.setAccessibilityElement(true)
            cell.setAccessibilityRole(cell.press == nil ? .staticText : .button)
            return cell
        }

        @objc private func clickRow() {
            let index = outline.clickedRow
            guard index >= 0, drag == nil, editor == nil,
                  let cell = outline.view(atColumn: 0, row: index, makeIfNecessary: false) as? Cell else { return }
            cell.press?()
        }
        func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
            guard let node = item as? Node, case .group(nil) = node.key else { return true }
            return false
        }
        func outlineViewItemDidExpand(_ notification: Notification) { disclosure(notification, collapsed: false) }
        func outlineViewItemDidCollapse(_ notification: Notification) { disclosure(notification, collapsed: true) }
        private func disclosure(_ note: Notification, collapsed: Bool) {
            guard !updating, drag == nil, let profile, let node = note.userInfo?["NSObject"] as? Node,
                  case let .group(id?) = node.key else { return }
            var groups = model.savedChatGroups
            guard let i = groups.firstIndex(where: { $0.id == id }), groups[i].collapsed != collapsed else { return }
            groups[i].collapsed = collapsed; model.saveChatGroups(groups, profile: profile)
        }

        private func rename(_ id: String, cell: Cell) {
            guard let profile, !model.hideProjects, let group = section(id)?.group, let field = cell.textField else { return }
            model.onFocusRequested?()
            editor = (id, profile, field); model.pinInteraction = true
            field.stringValue = group.name; field.isEditable = true; field.isSelectable = true
            field.isBordered = true; field.delegate = self
            field.selectText(nil)
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                cancelEdit = true; outline.window?.makeFirstResponder(outline); return true
            }
            return false
        }
        func controlTextDidEndEditing(_ obj: Notification) {
            guard let edit = editor else { return }
            let text = edit.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let save = !cancelEdit && !model.hideProjects && edit.profile == model.pinProfile && !text.isEmpty && text.utf16.count <= 64
            editor = nil; cancelEdit = false; model.pinInteraction = false
            edit.field.delegate = nil; edit.field.isEditable = false; edit.field.isSelectable = false; edit.field.isBordered = false
            if save, let i = model.savedChatGroups.firstIndex(where: { $0.id == edit.id }) {
                var groups = model.savedChatGroups; groups[i].name = text; model.saveChatGroups(groups, profile: edit.profile)
            }
            if let section = section(edit.id) { edit.field.stringValue = groupName(section.group) + "  " + String(section.members.count) }
            if let latest { update(latest) }
        }
        private func cancelInteraction() {
            preparedDrag = nil; drag = nil
            if let edit = editor {
                editor = nil; edit.field.delegate = nil; edit.field.abortEditing()
            }
            model.pinInteraction = false
        }
        func finish() { cancelInteraction(); latest = nil }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard editor == nil, let profile, let node = item as? Node, node.key != .group(nil) else { return nil }
            let token = UUID().uuidString
            let pb = NSPasteboardItem(); pb.setString(token, forType: Self.pasteboardType)
            preparedDrag = (node.key, token, profile)
            return pb
        }
        func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt point: NSPoint, forItems items: [Any]) {
            drag = preparedDrag; preparedDrag = nil
            model.pinInteraction = drag != nil
        }
        func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt point: NSPoint, operation: NSDragOperation) {
            drag = nil; model.pinInteraction = false
            if let latest { update(latest) }
        }

        private struct Target { var group: String?; var chat: String?; var after: Bool }
        private func target(_ info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Target? {
            guard let drag, let source = info.draggingSource as? NSOutlineView, source === outline,
                  drag.profile == model.pinProfile, info.draggingPasteboard.string(forType: Self.pasteboardType) == drag.token else { return nil }
            let point = outline.convert(info.draggingLocation, from: nil)
            let hit = outline.row(at: point)
            guard hit >= 0, let node = outline.item(atRow: hit) as? Node else {
                return Target(group: nil, chat: nil, after: true)
            }
            switch node.key {
            case let .group(id):
                return Target(group: id, chat: nil, after: point.y >= outline.rect(ofRow: hit).midY)
            case let .chat(id):
                guard let parent = outline.parent(forItem: node) as? Node, case let .group(g) = parent.key else { return nil }
                return Target(group: g, chat: id, after: true)
            }
        }
        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard let drag, let dest = target(info, item: item, childIndex: index) else { return [] }
            switch drag.key {
            case let .group(id):
                let merge = NSEvent.modifierFlags.contains(.shift)
                guard dest.group != id, !merge || dest.group != nil else { return [] }
                if merge { outline.setDropItem(nodes[.group(dest.group)], dropChildIndex: NSOutlineViewDropOnItemIndex) }
                else {
                    let i = roots.firstIndex { $0.key == .group(dest.group) } ?? roots.count
                    outline.setDropItem(nil, dropChildIndex: min(roots.count, i + (dest.group != nil && dest.after ? 1 : 0)))
                }
            case let .chat(id):
                guard dest.chat != id else { return [] }
                outline.setDropItem(dest.chat.flatMap { nodes[.chat($0)] } ?? nodes[.group(dest.group)], dropChildIndex: NSOutlineViewDropOnItemIndex)
            }
            return .move
        }
        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            guard let drag, let dest = target(info, item: item, childIndex: index) else { return false }
            let groups = model.savedChatGroups
            let result: [PinnedConversationGroups.Group]
            switch drag.key {
            case let .group(id?):
                result = PinnedConversationGroups.dropGroup(id, in: groups, at: dest.group, after: dest.after, merge: NSEvent.modifierFlags.contains(.shift))
            case let .chat(id):
                guard rows[id] != nil, dest.chat != id else { return false }
                if let other = dest.chat, dest.group == nil {
                    result = PinnedConversationGroups.move([id, other], in: groups, to: UUID().uuidString, name: L10n.text("conversation_groups.new"))
                } else { result = PinnedConversationGroups.move([id], in: groups, to: dest.group) }
            default: return false
            }
            model.saveChatGroups(result, profile: drag.profile)
            return true
        }

        func menu(for node: Node) -> NSMenu? {
            guard case let .chat(id) = node.key, let profile else { return nil }
            let menu = NSMenu()
            let destinations: [PinnedConversationGroups.Group?] = [nil] + model.savedChatGroups.map(Optional.some)
            for group in destinations {
                let action = NSMenuItem(title: L10n.text("conversation_groups.move", groupName(group)), action: #selector(moveFromMenu(_:)), keyEquivalent: "")
                action.target = self; action.representedObject = [profile, id, group?.id ?? ""]
                menu.addItem(action)
            }
            return menu
        }
        @objc private func moveFromMenu(_ item: NSMenuItem) {
            guard let values = item.representedObject as? [String], values.count == 3, values[0] == model.pinProfile,
                  model.pinnedChatRows.contains(where: { $0.activity.id == values[1] }) else { return }
            let dest = values[2].isEmpty ? nil : values[2]
            model.saveChatGroups(PinnedConversationGroups.move([values[1]], in: model.savedChatGroups, to: dest), profile: values[0])
        }
    }
}
