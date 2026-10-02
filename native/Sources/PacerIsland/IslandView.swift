import SwiftUI
import PacerCore

struct IslandView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var presentation: IslandPresentation
    private var attached: Bool { model.notchWidth > 0 }

    var body: some View {
        VStack(spacing: 0) {
            IslandHeader(model: model)
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
    }
}

private struct IslandHeader: View {
    @ObservedObject var model: IslandModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let secondary = Color(red: 0.67, green: 0.69, blue: 0.73)
    private let completionColor = Color(red: 0.56, green: 0.84, blue: 0.79)
    private var attached: Bool { model.notchWidth > 0 }

    var body: some View {
        HStack(spacing: 6) {
            Button { model.openCompletionOrPin() } label: {
                HStack(spacing: attached ? 4 : 6) {
                    if !model.pendingCompletions.isEmpty {
                        Image(systemName: model.pendingCompletions.first?.phase == .interrupted ? "pause.circle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 12)).foregroundStyle(completionColor)
                            .symbolEffect(.bounce, value: reduceMotion ? nil : model.pendingCompletions.first?.phaseChangedAt)
                    } else {
                        Circle().fill(model.accent).frame(width: 6, height: 6)
                    }
                    Text(model.pendingCompletions.isEmpty ? model.compactStatus : model.completionSummary)
                        .font(.system(size: 11, weight: .medium)).lineLimit(1)
                    if model.showsRate, let rate = model.rate {
                        Text(String(format: "%.0f", rate))
                            .font(.system(size: 10)).monospacedDigit()
                            .foregroundStyle(model.rateIsFresh ? Color.primary : secondary)
                        Text("t/s").font(.system(size: 9)).foregroundStyle(secondary)
                    }
                }.frame(height: model.topHeight).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: attached ? .infinity : nil, alignment: .leading)
            .help(model.pendingCompletions.first.map { "打开会话 · " + model.projectName($0) } ?? "固定展开")
            .accessibilityLabel(model.pendingCompletions.isEmpty ? "\(model.compactStatus)。点击固定展开" : "\(model.completionSummary)。点击打开会话")
            if attached { Color.clear.frame(width: model.notchWidth + 8, height: model.topHeight) }
            else { Spacer(minLength: 10) }
            Button { model.togglePin() } label: {
                HStack(spacing: 6) {
                    Text(model.quotaSummary).font(.system(size: 12, weight: .medium)).monospacedDigit()
                    Text(model.compactWindow).font(.system(size: 10)).foregroundStyle(secondary)
                    if model.stale || model.errorMessage != nil {
                        Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(secondary)
                    }
                }.frame(height: model.topHeight).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: attached ? .infinity : nil, alignment: .trailing)
            .accessibilityLabel("\(model.compactWindow)\(model.quotaSummary)。点击固定展开")
        }.padding(.horizontal, 15)
    }
}

private struct IslandExpandedContent: View {
    @ObservedObject var model: IslandModel
    private let secondary = Color(red: 0.67, green: 0.69, blue: 0.73)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.statusTitle).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 12)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(model.rateText)
                        .font(.system(size: 22, weight: .medium)).monospacedDigit()
                    Text("token/s").font(.system(size: 10)).foregroundStyle(secondary)
                }
                .foregroundStyle(model.rateIsFresh ? Color.primary : secondary)
                .help(model.rateIsFresh ? "运行中任务的合计输出速度" : "最近已知估算，等待完整的新 token 采样")
            }.padding(.top, 13).padding(.bottom, 14)
            if model.isDemo {
                Text("演示").font(.system(size: 11)).foregroundStyle(secondary).padding(.bottom, 8)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let notice = model.notice {
                        Label(notice.title + "：" + notice.detail, systemImage: "bell")
                            .font(.system(size: 11)).foregroundStyle(model.accent)
                    }
                    taskContent
                    Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.vertical, 2)
                    quotaContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }.scrollIndicators(.hidden).frame(maxHeight: .infinity)
            footer
        }
    }

    @ViewBuilder private var taskContent: some View {
        if model.visibleActivities.isEmpty {
            Text("暂无运行任务").font(.system(size: 12)).foregroundStyle(secondary).padding(.vertical, 8)
        } else {
            VStack(spacing: 8) {
                ForEach(model.visibleActivities) { activity in
                    TaskRowView(activity: activity, name: model.projectName(activity), now: model.now,
                        enabled: model.canOpen(activity), unread: model.isUnreadCompletion(activity), accent: model.accent) { model.open(activity) }
                }
            }
        }
        if !model.unavailableSSH.isEmpty {
            Label("SSH 未连接", systemImage: "network").font(.system(size: 11)).foregroundStyle(secondary)
                .help(model.unavailableSSH.joined(separator: "、"))
        }
    }

    @ViewBuilder private var quotaContent: some View {
        if let message = model.errorMessage {
            Label("额度暂不可用", systemImage: "exclamationmark.circle")
                .font(.system(size: 12)).foregroundStyle(secondary).help(message)
        }
        if let quota = model.quota, !quota.buckets.isEmpty || quota.resetCredits != nil {
            ForEach(quota.buckets) { bucket in
                if quota.buckets.count > 1 {
                    Text(bucket.name ?? bucket.id).font(.system(size: 11, weight: .medium)).foregroundStyle(secondary)
                }
                ForEach(bucket.windows) { window in
                    QuotaWindowView(window: window, now: model.now,
                        allowPace: !model.stale && model.errorMessage == nil, accent: model.accent, secondary: secondary)
                }
            }
            AccountUsageView(snapshot: quota, now: model.now)
            if let cycle = model.currentCycle {
                QuotaCycleChart(cycle: cycle, accent: model.accent)
            } else if model.weeklyWindow != nil {
                Text("等待采样").font(.system(size: 12)).foregroundStyle(secondary)
            }
            if let warning = model.historyWarning {
                Label("曲线记录异常", systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(secondary).help(warning)
            }
        } else if model.errorMessage == nil {
            Text(model.refreshing ? "正在读取账户额度" : "尚未连接 Codex").font(.system(size: 13))
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if model.stale || model.errorMessage != nil {
                Label("未更新", systemImage: "clock").font(.system(size: 11)).help(model.freshnessText)
            }
            Spacer(minLength: 4)
            Button { model.togglePin() } label: { Image(systemName: model.pinned ? "pin.fill" : "pin") }
                .help(model.pinned ? "取消固定" : "固定展开").accessibilityLabel(model.pinned ? "取消固定" : "固定展开")
            Button { model.refreshQuota(); model.refreshActivity() } label: { Image(systemName: "arrow.clockwise") }
                .disabled(model.refreshing).help("刷新 · " + model.freshnessText).accessibilityLabel("刷新")
            Button { model.onSettings?() } label: { Image(systemName: "gearshape") }
                .help("设置").accessibilityLabel("设置")
            Button { model.close() } label: { Image(systemName: "chevron.up") }
                .help("收起").accessibilityLabel("收起")
        }
        .font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(secondary)
        .padding(.top, 12).padding(.bottom, 14)
    }
}
