import AppKit
import SwiftUI
import PacerCore

struct TaskPagerView: View {
    @ObservedObject var model: IslandModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    @State private var direction: CGFloat = 1
    private let rowHeight: CGFloat = 74
    private let rowSpacing: CGFloat = 2

    private var tasks: [SessionActivity] { model.visibleActivities }
    private var pagination: TaskPagination { TaskPagination(itemCount: tasks.count) }
    private var currentPage: Int { pagination.clampedPage(page) }
    private var pageTasks: [SessionActivity] { Array(tasks[pagination.range(on: currentPage)]) }
    private var pageHeight: CGFloat {
        CGFloat(pagination.rowCapacity) * rowHeight + CGFloat(max(0, pagination.rowCapacity - 1)) * rowSpacing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if pagination.isPaginated {
                HStack(spacing: 8) {
                    Text(L10n.text("activity.task_count", tasks.count))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    pageButton(delta: -1, symbol: "chevron.left", title: L10n.text("activity.previous_page"))
                    Text("\(currentPage + 1) / \(pagination.pageCount)")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(minWidth: 32)
                        .accessibilityLabel(L10n.text("activity.page_number", currentPage + 1, pagination.pageCount))
                    pageButton(delta: 1, symbol: "chevron.right", title: L10n.text("activity.next_page"))
                }
                .padding(.horizontal, 8)
            }

            ZStack(alignment: .topLeading) {
                VStack(spacing: rowSpacing) {
                    ForEach(pageTasks) { activity in
                        TaskRowView(attention: model.attentionKind(for: activity), activity: activity, name: model.projectName(activity), now: model.now,
                            enabled: model.canOpen(activity), unread: model.isUnreadCompletion(activity), accent: model.taskAccent) {
                                model.open(activity)
                            }
                            .frame(height: rowHeight)
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(enabled ? 0.78 : 0.22))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(enabled ? 0.045 : 0)))
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
