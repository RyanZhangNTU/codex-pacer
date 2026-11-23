import AppKit
import SwiftUI
import PacerCore

struct TaskPagerView: View {
    @ObservedObject var model: IslandModel
    var language: AppLanguage = L10n.language
    /// The task list opens the panel and carries its buttons after the page controls.
    var actions = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    @State private var direction: CGFloat = 1
    private var rowHeight: CGFloat { TaskRowView.height(model.panelOptions.rowStyle) }
    private let rowSpacing: CGFloat = 2

    private var tasks: [SessionActivity] { model.taskPresentation.visibleActivities }
    private var pagination: TaskPagination { model.taskPresentation.pagination }
    private var currentPage: Int { pagination.clampedPage(page) }
    private var pageRows: [ActivityTaskRowPresentation] { Array(model.taskPresentation.rows[pagination.range(on: currentPage)]) }
    /// Every page keeps a full page's height; a page whose Claude tasks list
    /// Codex for Claude runs grows by their lines.
    private var pageHeight: CGFloat {
        let full = CGFloat(pagination.rowCapacity) * rowHeight + CGFloat(max(0, pagination.rowCapacity - 1)) * rowSpacing
        let rows = pageRows
        return max(full, rows.map(height).reduce(0, +) + CGFloat(max(0, rows.count - 1)) * rowSpacing)
    }
    private func height(_ row: ActivityTaskRowPresentation) -> CGFloat { rowHeight + DelegationList.height(row.delegations.count) }

    var header: some View {
        IslandSectionHeader(title: L10n.text("layout.group.tasks", language: language), detail: model.taskPresentation.taskCountText) {
            if pagination.isPaginated {
                HStack(spacing: 2) {
                    pageButton(delta: -1, symbol: "chevron.left", title: L10n.text("activity.previous_page"))
                    Text("\(currentPage + 1) / \(pagination.pageCount)")
                        .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(PacerPalette.secondary)
                        .frame(minWidth: 30)
                        .accessibilityLabel(L10n.text("activity.page_number", currentPage + 1, pagination.pageCount))
                    pageButton(delta: 1, symbol: "chevron.right", title: L10n.text("activity.next_page"))
                }
                if actions {
                    Rectangle().fill(PacerPalette.hairline).frame(width: 1, height: 14).padding(.horizontal, 4).accessibilityHidden(true)
                }
            }
            if actions { IslandPanelControls(model: model, language: language) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text(tasks.count == 1 ? "activity.task_count_singular" : "activity.task_count", tasks.count))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            ForEach(model.progressGuideHints, id: \.provider) { hint in
                ProgressGuideHint(text: hint.summary, language: language,
                                  open: { model.openSettings(for: hint.provider) },
                                  dismiss: { model.dismissProgressGuideHint(hint.provider) })
            }
            ZStack(alignment: .topLeading) {
                VStack(spacing: rowSpacing) {
                    ForEach(pageRows, id: \.activity.id) { row in
                        let activity = row.activity
                        VStack(spacing: 0) {
                            TaskRowView(presentation: row, group: model.taskGroup(for: activity), now: model.now,
                                enabled: model.canOpen(activity), accent: model.taskAccent,
                                costHelp: model.deepseekCostHelp(activity), options: model.panelOptions) {
                                    model.open(activity)
                                }
                                .frame(height: rowHeight)
                            if !row.delegations.isEmpty {
                                DelegationList(rows: row.delegations, enabled: model.canOpen(activity),
                                               open: { model.open(activity) }, stop: { model.stopDelegation($0) })
                            }
                        }
                        .frame(height: height(row), alignment: .top)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .id(currentPage)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .offset(x: direction * 18).combined(with: .opacity),
                    removal: .offset(x: -direction * 18).combined(with: .opacity)))
            }
            .frame(height: pageHeight, alignment: .topLeading)
            .clipped()
            .background(TaskPageWheelHandler(enabled: pagination.isPaginated) { delta in changePage(delta) }
                .frame(maxWidth: .infinity, maxHeight: .infinity))
            .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { value in
                guard pagination.isPaginated,
                      abs(value.translation.width) > max(40, abs(value.translation.height) * 1.5) else { return }
                changePage(value.translation.width < 0 ? 1 : -1)
            })
            .accessibilityElement(children: .contain)
            .accessibilityLabel(pagination.isPaginated ? L10n.text("activity.page_region") : L10n.text("activity.task_list"))
        }
        .onChange(of: tasks.map(\.id)) { _, _ in
            page = pagination.clampedPage(page)
        }
    }

    private func pageButton(delta: Int, symbol: String, title: String) -> some View {
        let enabled = delta < 0 ? currentPage > 0 : currentPage + 1 < pagination.pageCount
        return Button { changePage(delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(enabled ? PacerPalette.primary : PacerPalette.tertiary.opacity(0.6))
                .frame(width: 22, height: 22)
                .background(Circle().fill(enabled ? PacerPalette.fill : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled)
        .accessibilityLabel(title).help(title)
        .keyboardShortcut(delta < 0 ? .leftArrow : .rightArrow, modifiers: .option)
    }

    private func changePage(_ delta: Int) {
        let destination = pagination.clampedPage(currentPage + delta)
        guard destination != currentPage else { return }
        direction = delta < 0 ? -1 : 1
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            page = destination
        }
    }
}

private struct TaskPageWheelHandler: NSViewRepresentable {
    let enabled: Bool
    let onPage: (Int) -> Void

    func makeNSView(context: Context) -> WheelView { WheelView() }
    func updateNSView(_ view: WheelView, context: Context) {
        view.enabled = enabled
        view.onPage = onPage
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WheelView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    final class WheelView: NSView {
        var enabled = false
        var onPage: ((Int) -> Void)?
        private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var advancedInGesture = false
        private var lastEventTime: TimeInterval = 0

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.enabled, let window = self.window,
                      event.window == nil || event.window === window,
                      self.bounds.contains(self.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)),
                      abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return event }
                if !event.momentumPhase.isEmpty { return nil }
                if event.phase.contains(.began) || event.timestamp - self.lastEventTime > 0.3 {
                    self.accumulated = 0
                    self.advancedInGesture = false
                }
                self.lastEventTime = event.timestamp
                self.accumulated -= event.scrollingDeltaX
                if !self.advancedInGesture, abs(self.accumulated) >= 42 {
                    self.advancedInGesture = true
                    self.onPage?(self.accumulated > 0 ? 1 : -1)
                }
                if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                    self.accumulated = 0
                    self.advancedInGesture = false
                }
                return nil
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

/// A running task has no ring because its app still needs a step: one line
/// above the rows, until the user opens Settings or closes it.
private struct ProgressGuideHint: View {
    let text: String
    let language: AppLanguage
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(PacerPalette.attention).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(text).font(.system(size: 12)).foregroundStyle(PacerPalette.primary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Button(L10n.text("progress_guide.hint.open", language: language), action: open)
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(PacerPalette.attention)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(PacerPalette.tertiary)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("progress_guide.hint.close", language: language))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(PacerPalette.attention.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, IslandMetrics.rowInset - 4).padding(.bottom, 2)
        .accessibilityElement(children: .contain)
    }
}
