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
                HStack(spacing: 7) {
                    Circle().fill(model.accent).frame(width: 6, height: 6)
                    Text(model.compactStatus).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    if attached { Spacer(minLength: model.notchWidth + 8) }
                    else { Spacer(minLength: 16) }
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
            .accessibilityLabel("\(model.compactStatus)，额度\(model.quotaSummary)。点击固定展开")

            if model.expanded {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Codex Pacer").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text(model.isDemo ? "演示数据" : (model.quota?.buckets.first?.plan?.capitalized ?? "本地账户"))
                            .font(.system(size: 11)).foregroundStyle(secondary)
                    }
                    .padding(.top, 11)
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.statusTitle).font(.system(size: 20, weight: .semibold))
                        Spacer()
                        Text("本机活动").font(.system(size: 11)).foregroundStyle(secondary)
                    }.padding(.top, 16).padding(.bottom, 18)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if let message = model.errorMessage {
                                Label(message, systemImage: "exclamationmark.circle")
                                    .font(.system(size: 12)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            if let quota = model.quota, !quota.windows.isEmpty {
                                ForEach(quota.buckets) { bucket in
                                    if quota.buckets.count > 1 {
                                        Text(bucket.name ?? bucket.id).font(.system(size: 11, weight: .medium)).foregroundStyle(secondary)
                                    }
                                    ForEach(bucket.windows) { window in
                                        QuotaWindowView(window: window, now: model.now, accent: model.accent, secondary: secondary)
                                    }
                                }
                            } else if model.errorMessage == nil {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(model.refreshing ? "正在读取账户额度" : "尚未连接 Codex")
                                    Text("使用当前 Codex 登录账户，无需填写 API key。")
                                        .font(.system(size: 11)).foregroundStyle(secondary)
                                }.padding(.vertical, 12)
                            }
                            Rectangle().fill(.white.opacity(0.09)).frame(height: 1)
                            activityContent
                        }
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxHeight: .infinity)

                    HStack(spacing: 12) {
                        Text(model.freshnessText).font(.system(size: 10)).foregroundStyle(secondary)
                        Spacer(minLength: 4)
                        Button { model.togglePin() } label: {
                            Image(systemName: model.pinned ? "pin.fill" : "pin")
                        }.help(model.pinned ? "取消固定" : "固定展开")
                        Button { model.refreshQuota() } label: {
                            Image(systemName: "arrow.clockwise")
                        }.disabled(model.refreshing).help("刷新额度")
                        Button { model.onSettings?() } label: {
                            Image(systemName: "gearshape")
                        }.help("设置")
                        Button { model.close() } label: {
                            Image(systemName: "chevron.up")
                        }.help("收起")
                    }
                    .font(.system(size: 12))
                    .buttonStyle(.plain)
                    .foregroundStyle(secondary)
                    .padding(.top, 15).padding(.bottom, 17)
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

    @ViewBuilder private var activityContent: some View {
        let visible = model.running.isEmpty ? Array(model.activities.prefix(2)) : Array(model.running.prefix(3))
        if visible.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("没有观测到近期本地任务").font(.system(size: 12))
                Text("目前读取本机 Codex 日志，远程和未接入的任务不会显示。")
                    .font(.system(size: 11)).foregroundStyle(secondary)
            }
        } else {
            ForEach(visible) { activity in
                HStack(spacing: 10) {
                    Image(systemName: activityIcon(activity.observedPhase(at: model.now)))
                        .foregroundStyle(secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(activity.project).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(activity.observedPhase(at: model.now).label).font(.system(size: 11)).foregroundStyle(secondary)
                    }
                    Spacer()
                }
            }
            if model.running.count > visible.count {
                Text("另有 \(model.running.count - visible.count) 个本地任务")
                    .font(.system(size: 11)).foregroundStyle(secondary)
            }
        }
    }
    private func activityIcon(_ phase: ActivityPhase) -> String {
        switch phase {
        case .running: return "terminal"
        case .completed: return "minus.circle"
        case .interrupted: return "stop.circle"
        case .unknown: return "questionmark.circle"
        }
    }
}

private struct QuotaWindowView: View {
    let window: QuotaWindow
    let now: Date
    let accent: Color
    let secondary: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(.system(size: 12))
                Spacer()
                if let remaining = window.remainingPercent {
                    Text("\(Int(remaining.rounded()))").font(.system(size: 26, weight: .medium)).monospacedDigit()
                    Text("% 剩余").font(.system(size: 10)).foregroundStyle(secondary)
                } else {
                    Text("暂不可用").font(.system(size: 12)).foregroundStyle(secondary)
                }
            }
            GeometryReader { geometry in
                Capsule().fill(.white.opacity(0.08))
                    .overlay(alignment: .leading) {
                        if let remaining = window.remainingPercent {
                            Capsule().fill(accent).frame(width: geometry.size.width * remaining / 100)
                        }
                    }
            }.frame(height: 4)
            Text(resetText).font(.system(size: 10)).foregroundStyle(secondary)
        }
        .accessibilityElement(children: .combine)
    }
    private var resetText: String {
        guard let reset = window.resetsAt else { return "重置时间暂不可用" }
        let seconds = Int(reset.timeIntervalSince(now))
        if seconds <= 0 { return "已到重置时间，等待额度更新" }
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
