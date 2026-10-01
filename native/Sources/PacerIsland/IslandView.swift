import SwiftUI
import PacerCore

struct IslandView: View {
    @ObservedObject var model: IslandModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let secondary = Color(red: 0.67, green: 0.69, blue: 0.73)
    private var attached: Bool { model.notchWidth > 0 }

    var body: some View {
        VStack(spacing: 0) {
            Button { model.togglePin() } label: {
                HStack(spacing: 6) {
                    Circle().fill(model.accent).frame(width: 6, height: 6)
                    Text(model.compactStatus).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    if let rate = model.rate, model.notice == nil {
                        Text(String(format: "≈%.0f", rate)).font(.system(size: 10)).monospacedDigit()
                        Text("t/s").font(.system(size: 9)).foregroundStyle(secondary)
                    }
                    if attached { Spacer(minLength: model.notchWidth + 8) }
                    else { Spacer(minLength: 10) }
                    Text(model.quotaSummary).font(.system(size: 12, weight: .medium)).monospacedDigit()
                    Text(model.compactWindow).font(.system(size: 10)).foregroundStyle(secondary)
                    if model.stale || model.errorMessage != nil {
                        Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(secondary)
                    }
                }
                .padding(.horizontal, 15)
                .frame(height: model.topHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(model.compactStatus)，\(model.compactWindow)\(model.quotaSummary)。点击固定展开")

            if model.expanded {
                VStack(alignment: .leading, spacing: 0) {
                    if model.page == .tasks {
                        HStack(alignment: .firstTextBaseline) {
                            Text(model.statusTitle).font(.system(size: 19, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 8)
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(model.rate == nil ? model.rateText : "≈" + model.rateText).font(.system(size: 20, weight: .medium)).monospacedDigit()
                                Text("token/s").font(.system(size: 11)).foregroundStyle(secondary)
                            }
                            .help("所选任务的近期输出速度估算")
                        }.padding(.top, 12).padding(.bottom, 16)
                    }
                    if model.isDemo {
                        Text("演示").font(.system(size: 11)).foregroundStyle(secondary).padding(.bottom, 8)
                    }

                    Picker("查看内容", selection: $model.page) {
                        Text("任务").tag(IslandPage.tasks)
                        Text("额度").tag(IslandPage.quota)
                    }.pickerStyle(.segmented).labelsHidden().padding(.top, model.page == .quota ? 12 : 0).padding(.bottom, 14)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if let notice = model.notice {
                                Label(notice.title + "：" + notice.detail, systemImage: "bell")
                                    .font(.system(size: 11)).foregroundStyle(model.accent)
                            }
                            if model.page == .tasks {
                                taskContent
                            } else {
                                quotaContent
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }.scrollIndicators(.hidden).frame(maxHeight: .infinity)
                    footer
                }
                .padding(.horizontal, 23)
                .transition(.opacity)
            }
        }
        .foregroundStyle(Color(red: 0.95, green: 0.96, blue: 0.97))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(red: 0.045, green: 0.047, blue: 0.056))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: attached ? 0 : 25,
            bottomLeadingRadius: model.expanded ? 27 : 19,
            bottomTrailingRadius: model.expanded ? 27 : 19,
            topTrailingRadius: attached ? 0 : 25))
        .onHover { model.hover($0) }
        .onExitCommand { model.close() }
        .animation(reduceMotion ? nil : .smooth(duration: 0.26), value: model.expanded)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var taskContent: some View {
        if model.visibleActivities.isEmpty {
            Text("暂无任务").font(.system(size: 13)).foregroundStyle(secondary).padding(.vertical, 12)
        } else {
            ForEach(model.visibleActivities) { activity in
                Button { model.select(activity) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: activityIcon(activity.observedPhase(at: model.now)))
                            .font(.system(size: 14))
                            .foregroundStyle(activity.observedPhase(at: model.now) == .waitingForInput ? model.accent : secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.projectName(activity)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(activity.detail(at: model.now)).font(.system(size: 11)).foregroundStyle(secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if let rate = activity.tokensPerSecond(at: model.now) {
                            Text(String(format: "≈%.1f t/s", rate)).font(.system(size: 11)).monospacedDigit()
                        }
                        if model.focusedActivity?.id == activity.id {
                            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(secondary)
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(model.focusedActivity?.id == activity.id ? 0.06 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help([activity.modelName, observedAge(activity)].compactMap { $0 }.joined(separator: " · "))
                .accessibilityLabel("\(model.projectName(activity))，\(activity.observedPhase(at: model.now).label)。选择任务")
            }

        }
        Rectangle().fill(.white.opacity(0.09)).frame(height: 1)
        if let window = model.selectedWindow {
            HStack {
                Text(window.label).font(.system(size: 11)).foregroundStyle(secondary)
                Spacer()
                Text(window.remainingPercent.map { "剩余 \(Int($0.rounded()))%" } ?? "暂不可用")
                Text(model.pace.map { "配速 \(Int($0.rounded()))%" } ?? "配速 —")
            }.font(.system(size: 11)).monospacedDigit()
        }
        Button { model.onOpenCodex?() } label: {
            Label(model.canOpenConversation ? "打开所选会话" : "打开 Codex", systemImage: "arrow.up.forward.app")
        }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(model.accent)
    }

    @ViewBuilder private var quotaContent: some View {
        if let message = model.errorMessage {
            Label("额度暂不可用", systemImage: "exclamationmark.circle")
                .font(.system(size: 12)).foregroundStyle(secondary).help(message)
        }
        if let quota = model.quota, !quota.windows.isEmpty {
            ForEach(quota.buckets) { bucket in
                if quota.buckets.count > 1 {
                    Text(bucket.name ?? bucket.id).font(.system(size: 11, weight: .medium)).foregroundStyle(secondary)
                }
                ForEach(bucket.windows) { window in
                    QuotaWindowView(window: window, now: model.now,
                        allowPace: !model.stale && model.errorMessage == nil, accent: model.accent, secondary: secondary)
                }
            }
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
        .padding(.top, 14).padding(.bottom, 17)
    }
    private func observedAge(_ activity: SessionActivity) -> String {
        guard let date = activity.lastObserved else { return "未确认" }
        let seconds = max(0, Int(model.now.timeIntervalSince(date)))
        return seconds < 60 ? "\(seconds) 秒前有活动" : "\(seconds / 60) 分钟前有活动"
    }
    private func activityIcon(_ phase: ActivityPhase) -> String {
        switch phase {
        case .running: return "terminal"
        case .waitingForInput: return "text.bubble"
        case .completed: return "minus.circle"
        case .interrupted: return "stop.circle"
        case .unknown: return "questionmark.circle"
        }
    }
}

private struct QuotaWindowView: View {
    let window: QuotaWindow
    let now: Date
    let allowPace: Bool
    let accent: Color
    let secondary: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(.system(size: 12))
                Spacer()
                if let remaining = window.remainingPercent {
                    Text("\(Int(remaining.rounded()))").font(.system(size: 24, weight: .medium)).monospacedDigit()
                    Text("% 剩余").font(.system(size: 10)).foregroundStyle(secondary)
                } else { Text("暂不可用").font(.system(size: 12)).foregroundStyle(secondary) }
            }
            GeometryReader { geometry in
                Capsule().fill(.white.opacity(0.08)).overlay(alignment: .leading) {
                    if let remaining = window.remainingPercent {
                        Capsule().fill(accent).frame(width: geometry.size.width * remaining / 100)
                    }
                }
            }.frame(height: 4)
            HStack {
                Text(resetText)
                Spacer()
                if allowPace, let pace = window.pacePercent(at: now) {
                    Text("配速 \(Int(pace.rounded()))%").foregroundStyle(pace < 85 ? Color.orange : pace > 115 ? accent : secondary)
                        .help("剩余额度比例 ÷ 剩余时间比例 × 100。100% 表示与均匀配速一致；85% 以下需放慢，115% 以上较充裕。")
                } else { Text("配速 —") }
            }.font(.system(size: 10)).foregroundStyle(secondary)
        }.accessibilityElement(children: .combine)
    }
    private var resetText: String {
        guard let reset = window.resetsAt else { return "重置时间暂不可用" }
        let seconds = Int(reset.timeIntervalSince(now))
        if seconds <= 0 { return "等待重置" }
        if seconds < 86400 {
            let hours = seconds / 3600, minutes = max(1, seconds % 3600 / 60)
            return hours > 0 ? "\(hours) 小时 \(minutes) 分钟后重置" : "\(minutes) 分钟后重置"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEE HH:mm"
        return "\(formatter.string(from: reset)) 重置"
    }
}
