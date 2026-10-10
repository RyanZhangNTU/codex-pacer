import PacerCore
import SwiftUI

/// A short legend for the island. Each sample is the real component on a
/// swatch shaped like the bar, so the help stays accurate as the UI changes
/// and reads in both light and dark Settings.
struct SettingsHelpPane: View {
    private static let repository = "https://github.com/RyanZhangNTU/codex-pacer"

    var body: some View {
        Section(L10n.text("help.section.collapsed")) {
            row("help.tasks") {
                ActivityBadge(activity: .init(core: .count(2), activeCount: 2, orbit: [.codex: 1, .claude: 1]))
            }
            row("help.attention") {
                ActivityBadge(activity: .init(core: .count(2), activeCount: 2, orbit: [.codex: 1], attention: .approval))
            }
            row("help.endings") {
                ActivityBadge(activity: .init(core: .symbol(StatusSymbols.complete), activeCount: 0, orbit: [:], ending: .completed(.codex)))
                ActivityBadge(activity: .init(core: .symbol(StatusSymbols.tool), activeCount: 1, orbit: [.claude: 1], ending: .completed(.codex)))
            }
            row("help.quota") {
                QuotaRingsGlyph(rings: [.init(tint: AgentProvider.codex.tint, remaining: 58, stale: false),
                    .init(tint: AgentProvider.claude.tint, remaining: 81, stale: false)])
                AlternatingQuotaText(entries: [.init(text: "58%", color: NSColor(AgentProvider.codex.tint)),
                    .init(text: "81%", color: NSColor(AgentProvider.claude.tint))], animates: true)
            }
            row("help.five_hour") {
                FiveHourAlertGlyph(alert: .low(12), tint: AgentProvider.codex.tint)
                FiveHourAlertGlyph(alert: .exhausted, tint: AgentProvider.claude.tint)
            }
            row("help.status") {
                Image(systemName: StatusSymbols.freshness).font(.system(size: 11, weight: .semibold))
                Image(systemName: StatusSymbols.sshWarning).font(.system(size: 11, weight: .semibold))
            }
        }
        Section(L10n.text("help.section.expanded")) {
            row("help.pace") {
                PaceTickSample()
                QuotaVerdictChip(verdict: .spare)
            }
            row("help.rows") {
                Image(systemName: StatusTile.tileSymbol(StatusSymbols.thinking)).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AgentProvider.codex.tint)
                Text(CompactDuration.text(180)).font(.system(size: 10, weight: .medium)).foregroundStyle(PacerPalette.secondary)
            }
        }
        Section(L10n.text("help.section.actions")) {
            Label(L10n.text("help.action.hover"), systemImage: "cursorarrow.rays")
            Label(L10n.text("help.action.menu"), systemImage: "contextualmenu.and.cursorarrow")
        }
        Section(L10n.text("help.section.more")) {
            Link(destination: URL(string: Self.repository + (L10n.language == .simplifiedChinese ? "/blob/main/README.zh-CN.md" : "#readme"))!) {
                Label(L10n.text("help.link.guide"), systemImage: "book")
            }
            Link(destination: URL(string: Self.repository + "/issues")!) {
                Label(L10n.text("help.link.issues"), systemImage: "exclamationmark.bubble")
            }
        }
    }

    private func row<Sample: View>(_ key: String, @ViewBuilder sample: () -> Sample) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) { sample() }
                .foregroundStyle(PacerPalette.attention)
                .frame(width: 84, height: 32)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .environment(\.colorScheme, .dark)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(key + ".title"))
                Text(L10n.text(key + ".detail")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A miniature expanded ring: remaining quota as the arc and the even-pace tick.
private struct PaceTickSample: View {
    var body: some View {
        ZStack {
            Circle().stroke(PacerPalette.track, lineWidth: 3)
            Circle().trim(from: 0, to: 0.62)
                .stroke(AgentProvider.codex.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Capsule().fill(Color.white).frame(width: 1.5, height: 7)
                .offset(y: -10).rotationEffect(.degrees(0.45 * 360))
        }
        .frame(width: 20, height: 20)
    }
}
