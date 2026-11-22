import AppKit
import PacerCore
import SwiftUI

/// Collaboration's colors: Codex's own in the window's tone; a result is done
/// in Codex's color, stopped in gray and failed in red, as on Windows.
@MainActor enum SettingsCollaborationInk {
    static func codex(_ scheme: ColorScheme) -> Color { AgentProvider.codex.shade(light: scheme == .light) }
    static func result(_ tone: String, _ scheme: ColorScheme) -> Color {
        tone == "ok" ? codex(scheme) : tone == "failed" ? Color(nsColor: .systemRed) : .secondary
    }
}

/// The strip's count of runs going now; it observes the model on its own so
/// the rest of the page is not redrawn every second.
struct SettingsCollaborationRunningPill: View {
    @ObservedObject var model: IslandModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let count = model.runningDelegations.count
        if count > 0 {
            SettingsCollaborationPill(text: L10n.text("collaboration.status.running") + " " + String(count),
                                      tint: SettingsCollaborationInk.codex(scheme))
        }
    }
}

/// Runs going now across Claude tasks, each with its own Stop. It redraws
/// every second, apart from the statistics.
struct SettingsCollaborationRunningCard: View {
    @ObservedObject var model: IslandModel
    let limit: Int
    @State private var stopping: Set<String> = []
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let running = model.runningDelegations
        if !running.isEmpty {
            let count = Text(L10n.text("collaboration.running.limit", running.count, limit))
                .font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
            MainCard(title: L10n.text("collaboration.running.title"), titleTrailing: AnyView(count)) {
                ForEach(running) { row($0) }
            }
        }
    }

    private func row(_ item: RunningDelegation) -> some View {
        let run = item.row, codex = SettingsCollaborationInk.codex(scheme)
        let numbers = [run.turnTime, run.rateText.map { $0 + " t/s" }, run.model + (run.effort.map { " " + $0 } ?? "")]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return HStack(spacing: 10) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2.5)
                Circle().trim(from: 0, to: CGFloat(run.progressRing?.fraction ?? 0))
                    .stroke(codex, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
            }
            .frame(width: 16, height: 16)
            .accessibilityLabel(run.progressRing?.accessibilityText ?? "")
            .accessibilityHidden(run.progressRing == nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text([item.parentTitle, run.status].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(numbers).font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            Button {
                stopping.insert(item.id)
                if !model.stopDelegation(run.activity) { stopping.remove(item.id) }
            } label: {
                Image(systemName: "stop.fill").font(.system(size: 8, weight: .bold))
                    .frame(width: 22, height: 22).background(MainPalette.button, in: Circle()).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!run.canStopDelegation || stopping.contains(item.id))
            .help(L10n.text("delegation.stop"))
            .accessibilityLabel(L10n.text("delegation.stop"))
        }
        // The same lines as the island's hover card: no brief or output.
        .help(run.delegationDetail.map { $0.label + "  " + $0.value }.joined(separator: "\n"))
    }
}

/// The period's numbers, a stacked bar a day, Codex's quota now and where
/// runs went, as on Windows.
struct SettingsCollaborationStatisticsCard: View {
    let stats: CodexDelegationStatistics
    let quota: String?
    @Binding var days: Int
    @Environment(\.colorScheme) private var scheme
    private static let chartHeight: CGFloat = 92

    var body: some View {
        let period = MainSegmented(options: [7, 30].map { (value: $0, title: L10n.text("collaboration.stats.days", $0)) },
                                   selection: $days, label: L10n.text("collaboration.stats.title"))
        MainCard(title: L10n.text("collaboration.stats.title"), titleTrailing: AnyView(period)) {
            kpis
            VStack(alignment: .leading, spacing: 8) {
                legend
                chart
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(stats.summary)
            if !stats.breakdowns.isEmpty { breakdowns }
        }
    }

    private var kpis: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(stats.kpis.enumerated()), id: \.offset) { _, kpi in
                VStack(alignment: .leading, spacing: 1) {
                    Text(kpi.title).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    Text(kpi.value).font(.system(size: 20, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    if let note = kpi.note {
                        Text(note).font(.system(size: 11))
                            .foregroundStyle(kpi.tone == "good" ? MainPalette.positive : kpi.tone == "warn" ? MainPalette.attention : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(MainPalette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(["ok", "stopped", "failed"], id: \.self) { key in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(SettingsCollaborationInk.result(key, scheme)).frame(width: 8, height: 8)
                    Text(L10n.text("collaboration.stats." + key))
                }
            }
            Spacer(minLength: 8)
            if let quota { Text(L10n.text("collaboration.stats.quota") + "  " + quota).monospacedDigit().lineLimit(1) }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
    }

    /// One bar a day, stacked done / stopped / failed, on one scale.
    private var chart: some View {
        VStack(spacing: 3) {
            HStack(alignment: .bottom, spacing: stats.chart.count > 7 ? 3 : 10) {
                ForEach(Array(stats.chart.enumerated()), id: \.offset) { _, day in bar(day) }
            }
            .frame(height: Self.chartHeight)
            Rectangle().fill(MainPalette.separator).frame(height: 1)
            if let first = stats.chart.first, let last = stats.chart.last {
                ZStack {
                    Text(first.label).frame(maxWidth: .infinity, alignment: .leading)
                    Text(stats.chart[stats.chart.count / 2].label).frame(maxWidth: .infinity, alignment: .center)
                    Text(last.label).frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
                .accessibilityHidden(true)
            }
        }
    }

    private func bar(_ day: CodexDelegationStatistics.Day) -> some View {
        let text = [day.label, L10n.text("collaboration.stats.ok") + " " + String(day.ok),
                    L10n.text("collaboration.stats.stopped") + " " + String(day.stopped),
                    L10n.text("collaboration.stats.failed") + " " + String(day.failed)].joined(separator: " · ")
        return VStack(spacing: 0) {
            segment(day.failed, "failed")
            segment(day.stopped, "stopped")
            segment(day.ok, "ok")
        }
        .frame(maxWidth: 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .contentShape(Rectangle())
        .help(text)
        .accessibilityElement().accessibilityLabel(text)
    }

    @ViewBuilder private func segment(_ count: Int, _ tone: String) -> some View {
        if count > 0 {
            RoundedRectangle(cornerRadius: 1.5).fill(SettingsCollaborationInk.result(tone, scheme))
                .frame(height: max(2, CGFloat(count) / CGFloat(max(1, stats.chartMax)) * Self.chartHeight))
        }
    }

    /// Use, model, project and problems, each with its top shares.
    private var breakdowns: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(Array(stats.breakdowns.enumerated()), id: \.offset) { _, breakdown in
                VStack(alignment: .leading, spacing: 5) {
                    Text(breakdown.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(Array(breakdown.shares.enumerated()), id: \.offset) { _, share in shareRow(share) }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func shareRow(_ share: CodexDelegationStatistics.Share) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(share.name).font(.system(size: 11.5)).lineLimit(1).truncationMode(.tail)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(MainPalette.fill)
                        Capsule().fill(SettingsCollaborationInk.codex(scheme))
                            .frame(width: min(proxy.size.width, max(3, proxy.size.width * CGFloat(share.fraction))))
                    }
                }
                .frame(height: 5)
            }
            Text(String(share.count)).font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 28, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(share.name + " " + String(share.count))
    }
}

/// The last runs: time, label and project, use and model, time taken and result.
struct SettingsCollaborationRecentCard: View {
    let recent: [CodexDelegationStatistics.Recent]
    let clear: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // Clearing removes labels and projects; with none left there is nothing to clear.
        let clearButton = recent.contains { $0.project != nil }
            ? AnyView(Button(L10n.text("collaboration.recent.clear"), action: clear).buttonStyle(.main)) : nil
        MainCard(title: L10n.text("collaboration.recent.title"), titleTrailing: clearButton) {
            if recent.isEmpty {
                Text(L10n.text("collaboration.recent.empty")).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(recent.prefix(10).enumerated()), id: \.offset) { _, run in row(run) }
            }
        }
    }

    private func row(_ run: CodexDelegationStatistics.Recent) -> some View {
        let tint = SettingsCollaborationInk.result(run.tone, scheme)
        return HStack(spacing: 8) {
            Text(run.time).foregroundStyle(.secondary).monospacedDigit().frame(width: 44, alignment: .leading)
            HStack(spacing: 0) {
                Text(run.title).font(.system(size: 12.5))
                if let project = run.project { Text(" · " + project).foregroundStyle(.secondary) }
            }
            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            Text(run.detail).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 170, alignment: .leading)
            Text(run.duration).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).frame(width: 64, alignment: .trailing)
            Text(run.result).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tint).lineLimit(1)
                .padding(.horizontal, 7).padding(.vertical, 1)
                .background(tint.opacity(0.15), in: Capsule())
        }
        .font(.system(size: 11.5))
        .accessibilityElement(children: .combine)
    }
}
