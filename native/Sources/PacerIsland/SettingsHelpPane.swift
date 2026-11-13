import AppKit
import PacerCore
import SwiftUI

/// Help: three ways in (the welcome guide, the user guide, an issue), then
/// what each mark means, one topic at a time. Each entry says what you see
/// and what it means, in a sentence; troubleshooting and the rules behind the
/// numbers live in the guide. Samples are the real components on a swatch
/// shaped like the bar, so the help stays accurate as the UI changes and
/// reads in both light and dark Settings.
struct SettingsHelpPane: View {
    private static let repository = "https://github.com/RyanZhangNTU/codex-pacer"
    var onShowWelcome: (() -> Void)?
    @State private var topic = HelpTopic.collapsed

    init(onShowWelcome: (() -> Void)? = nil) {
        self.onShowWelcome = onShowWelcome
    }

    var body: some View {
        HStack(spacing: 10) {
            if let onShowWelcome {
                QuickTile(symbol: "hand.wave", title: L10n.text("help.quick.welcome"),
                          detail: L10n.text("help.quick.welcome_detail"), action: onShowWelcome)
            }
            QuickTile(symbol: "book", title: L10n.text("help.link.guide"), detail: L10n.text("help.quick.guide_detail"),
                      external: true) { NSWorkspace.shared.open(Self.guide) }
            QuickTile(symbol: "exclamationmark.bubble", title: L10n.text("help.link.issues"),
                      detail: L10n.text("help.quick.issues_detail"), external: true) {
                NSWorkspace.shared.open(URL(string: Self.repository + "/issues")!)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 10) {
            TopicChips(selection: $topic)
            MainCard(footer: topic.isModule ? L10n.text("help.enable.detail") : nil) {
                switch topic {
                case .collapsed: collapsedRows
                case .expanded: expandedRows
                case .module(.codex): codexRows
                case .module(.claude): claudeRows
                case .module(.deepseek): deepseekRows
                }
            }
        }
    }

    private static var guide: URL {
        URL(string: repository + (L10n.language == .simplifiedChinese ? "/blob/main/docs/guide.zh-CN.md" : "/blob/main/docs/guide.md"))!
    }

    @ViewBuilder private var collapsedRows: some View {
        // Under one accent the services are its shades, as the tiles draw them.
        row("help.services", detail: PacerAccent.current == .multicolor ? nil : "help.services.shades") {
            ForEach(HarnessRegistry.legacyIDs, id: \.self) { ProviderTile(provider: $0) }
        }
        row("help.tasks") {
            ActivityBadge(activity: .init(core: .count(1), activeCount: 1, orbit: [.codex: 1]))
            ActivityBadge(activity: .init(core: .count(2), activeCount: 2, orbit: [.codex: 1, .claude: 1]))
            ActivityBadge(activity: .init(core: .count(3), activeCount: 3, orbit: [.codex: 1, .claude: 1, .deepseek: 1]))
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
        row("help.warnings") {
            FiveHourAlertGlyph(alert: .low(12), tint: AgentProvider.codex.tint)
            DeepSeekAlertGlyph(alert: .lowBalance)
            Image(systemName: StatusSymbols.freshness).font(.system(size: 11, weight: .semibold))
        }
        row("help.customize", symbol: "slider.horizontal.3")
        row("help.move") { MoveSample() }
    }

    @ViewBuilder private var expandedRows: some View {
        row("help.hover", symbol: "cursorarrow.rays")
        row("help.open", symbol: "arrow.up.forward.app")
        row("help.app_buttons") {
            ForEach(HarnessRegistry.legacyIDs, id: \.self) { provider in
                ProviderAppIcon(provider: provider, size: 14, outline: true)
                    .foregroundStyle(PacerPalette.secondary)
            }
        }
        row("help.read", symbol: "checkmark.rectangle.stack")
        row("help.pace") {
            PaceTickSample()
            QuotaVerdictChip(verdict: .spare)
        }
    }

    @ViewBuilder private var codexRows: some View {
        quotaRow("help.codex.quota", provider: .codex, remaining: 58)
        fiveHourRow("help.codex.windows", provider: .codex)
        row("help.codex.remote", symbol: "network", tint: AgentProvider.codex.tint)
        row("help.codex.apps", symbol: "square.on.square", tint: AgentProvider.codex.tint)
    }

    @ViewBuilder private var claudeRows: some View {
        quotaRow("help.claude.quota", provider: .claude, remaining: 81)
        fiveHourRow("help.claude.windows", provider: .claude)
        row("help.claude.cloud", symbol: "cloud", tint: AgentProvider.claude.tint)
        row("help.claude.remote", symbol: "network", tint: AgentProvider.claude.tint)
        row("help.claude.apps", symbol: "square.on.square", tint: AgentProvider.claude.tint)
    }

    @ViewBuilder private var deepseekRows: some View {
        row("help.deepseek.balance") {
            ProviderTile(provider: .deepseek)
            Text("¥86").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(AgentProvider.deepseek.tint)
        }
        row("help.deepseek.mode") {
            Group {
                Image(systemName: "clock")
                Image(systemName: "chart.pie")
            }
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(AgentProvider.deepseek.tint)
        }
        row("help.deepseek.cost") {
            Text("≈¥0.42").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(AgentProvider.deepseek.tint)
        }
        row("help.deepseek.peak") {
            Text("×2").font(.system(size: 12, weight: .semibold)).foregroundStyle(PacerPalette.attention)
        }
        row("help.deepseek.clock") {
            // A Tuesday afternoon: spend in the morning and since 14:00, peak arcs at 9–12 and 14–18.
            PriceClockGlyph(hourly: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0.6, 1.2, 0.4, 0, 0, 0.9, 0.5] + Array(repeating: 0, count: 8),
                peaks: [135...180, 210...270], now: 236)
        }
        row("help.deepseek.alerts") {
            DeepSeekAlertGlyph(alert: .lowBalance)
            DeepSeekAlertGlyph(alert: .spike)
            DeepSeekAlertGlyph(alert: .nearingBudget(.day))
            DeepSeekAlertGlyph(alert: .overBudget(.week))
        }
        row("help.deepseek.speed") { SpeedBarsSample() }
    }

    private func quotaRow(_ key: String, provider: AgentProvider, remaining: Double) -> some View {
        row(key) {
            QuotaRingsGlyph(rings: [.init(tint: provider.tint, remaining: remaining, stale: false)])
            Text("\(Int(remaining))%").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(provider.tint)
        }
    }

    private func fiveHourRow(_ key: String, provider: AgentProvider) -> some View {
        row(key) {
            FiveHourAlertGlyph(alert: .low(12), tint: provider.tint)
            FiveHourAlertGlyph(alert: .exhausted, tint: provider.tint)
        }
    }

    private func row(_ key: String, symbol: String, tint: Color = PacerPalette.primary) -> some View {
        row(key) { Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint) }
    }

    /// `detail` replaces the entry's own explanation when one applies.
    private func row<Sample: View>(_ key: String, detail: String? = nil, @ViewBuilder sample: () -> Sample) -> some View {
        HStack(spacing: 14) {
            IslandSampleSwatch(content: sample)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(key + ".title")).font(.system(size: 13))
                Text(L10n.text(detail ?? key + ".detail")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// What the legend shows: the bar, the panel or one module's own marks.
private enum HelpTopic: Hashable {
    case collapsed, expanded, module(AgentProvider)

    static var all: [HelpTopic] { [.collapsed, .expanded] + HarnessRegistry.legacyIDs.map(HelpTopic.module) }
    var isModule: Bool { if case .module = self { true } else { false } }
    var title: String {
        switch self {
        case .collapsed: L10n.text("help.section.collapsed")
        case .expanded: L10n.text("help.section.expanded")
        case .module(let provider): provider.displayName
        }
    }
}

/// The topics as a row of pills; the chosen one fills with the accent.
private struct TopicChips: View {
    @Binding var selection: HelpTopic
    @Environment(\.pacerAccent) private var accent

    var body: some View {
        HStack(spacing: 6) {
            ForEach(HelpTopic.all, id: \.self) { topic in
                let selected = topic == selection
                Button { selection = topic } label: {
                    HStack(spacing: 5) {
                        if case .module(let provider) = topic {
                            ProviderAppIcon(provider: provider, size: 13)
                        }
                        Text(topic.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                    }
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .padding(.horizontal, 12).frame(height: 26)
                    .background(selected ? accent : MainPalette.fill, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(topic.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("settings.pane.help"))
    }
}

/// A way into more help: a symbol, a title and what it opens. Links out of
/// Pacer carry an arrow.
private struct QuickTile: View {
    let symbol: String
    let title: String
    let detail: String
    var external = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    FeatureSymbol(symbol: symbol, size: 30)
                    Spacer(minLength: 4)
                    if external {
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .mainCardSurface()
            .overlay(shape.fill(Color.primary.opacity(hovering ? 0.035 : 0)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
        .accessibilityAddTraits(external ? .isLink : .isButton)
    }
}

/// A small bar, an arrow and the screen edge it snaps to.
private struct MoveSample: View {
    var body: some View {
        HStack(spacing: 5) {
            Capsule().fill(Color.white.opacity(0.25)).overlay(Capsule().stroke(Color.white.opacity(0.55), lineWidth: 1))
                .frame(width: 20, height: 8)
            Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.white)
            RoundedRectangle(cornerRadius: 1.5).fill(AgentProvider.codex.tint).frame(width: 3, height: 18)
        }
    }
}

/// A black swatch shaped like the bar, so island marks read as they do on
/// screen in both light and dark Settings. Help and Reminders share it.
struct IslandSampleSwatch<Content: View>: View {
    static var compactWidth: CGFloat { 44 }
    let width: CGFloat
    let content: Content

    init(width: CGFloat = 84, @ViewBuilder content: () -> Content) {
        self.width = width; self.content = content()
    }

    var body: some View {
        HStack(spacing: 6) { content }
            .foregroundStyle(PacerPalette.attention)
            .frame(width: width, height: width < 84 ? 28 : 32)
            .background(PacerPalette.surface, in: RoundedRectangle(cornerRadius: width < 84 ? 8 : 9, style: .continuous))
            .environment(\.colorScheme, PacerPalette.light ? .light : .dark)
            .accessibilityHidden(true)
    }
}

/// A provider's tile as the island draws it.
private struct ProviderTile: View {
    let provider: AgentProvider

    var body: some View {
        ProviderAppIcon(provider: provider, size: 18)
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

/// DeepSeek's speed bars: spend in each 10 minutes, the newest solid.
private struct SpeedBarsSample: View {
    private static let values: [Double] = [0.2, 0.35, 0.15, 0.5, 0.3, 0.7]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Self.values.indices, id: \.self) { index in
                Rectangle().fill(AgentProvider.deepseek.tint.opacity(index == Self.values.count - 1 ? 1 : 0.5))
                    .frame(width: 5, height: 18 * Self.values[index])
            }
        }
        .frame(height: 18, alignment: .bottom)
    }
}
