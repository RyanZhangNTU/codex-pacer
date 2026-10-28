import PacerCore
import SwiftUI

/// Help in two parts: what every module shares, then one module's details
/// chosen with a switch. Each entry says what you see and what it means, in a
/// sentence; troubleshooting and the rules behind the numbers live in the guide.
/// Samples are the real components on a swatch shaped like the bar, so the
/// help stays accurate as the UI changes and reads in both light and dark Settings.
struct SettingsHelpPane: View {
    private static let repository = "https://github.com/RyanZhangNTU/codex-pacer"
    var onShowWelcome: (() -> Void)?
    @State private var module: AgentProvider

    init(module: AgentProvider = .codex, onShowWelcome: (() -> Void)? = nil) {
        _module = State(initialValue: module)
        self.onShowWelcome = onShowWelcome
    }

    var body: some View {
        Section(L10n.text("help.section.services")) {
            row("help.enable", symbol: "switch.2")
            row("help.services") {
                ForEach(AgentProvider.allCases, id: \.self) { ProviderTile(provider: $0) }
            }
        }
        Section(L10n.text("help.section.collapsed")) {
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
        }
        Section(L10n.text("help.section.expanded")) {
            row("help.hover", symbol: "cursorarrow.rays")
            row("help.open", symbol: "arrow.up.forward.app")
            row("help.app_buttons") {
                ForEach(AgentProvider.allCases, id: \.self) { provider in
                    Image(systemName: provider.glyph).font(.system(size: 12, weight: .semibold)).foregroundStyle(provider.tint)
                }
            }
            row("help.read", symbol: "checkmark.rectangle.stack")
            row("help.pace") {
                PaceTickSample()
                QuotaVerdictChip(verdict: .spare)
            }
        }
        Section {
            Picker(L10n.text("help.section.modules"), selection: $module) {
                ForEach(AgentProvider.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            switch module {
            case .codex: codexRows
            case .claude: claudeRows
            case .deepseek: deepseekRows
            }
        } header: {
            Text(L10n.text("help.section.modules"))
        }
        Section(L10n.text("help.section.more")) {
            if let onShowWelcome {
                Button(action: onShowWelcome) { Label(L10n.text("help.show_welcome"), systemImage: "hand.wave") }
                    .buttonStyle(.link)
            }
            Link(destination: URL(string: Self.repository + (L10n.language == .simplifiedChinese ? "/blob/main/docs/guide.zh-CN.md" : "/blob/main/docs/guide.md"))!) {
                Label(L10n.text("help.link.guide"), systemImage: "book")
            }
            Link(destination: URL(string: Self.repository + "/issues")!) {
                Label(L10n.text("help.link.issues"), systemImage: "exclamationmark.bubble")
            }
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

    private func row<Sample: View>(_ key: String, @ViewBuilder sample: () -> Sample) -> some View {
        HStack(spacing: 14) {
            IslandSampleSwatch(content: sample)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(key + ".title"))
                Text(L10n.text(key + ".detail")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
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
            .background(Color.black, in: RoundedRectangle(cornerRadius: width < 84 ? 8 : 9, style: .continuous))
            .environment(\.colorScheme, .dark)
            .accessibilityHidden(true)
    }
}

/// A provider's tile as the island draws it.
private struct ProviderTile: View {
    let provider: AgentProvider

    var body: some View {
        Image(systemName: provider.glyph).font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.72))
            .frame(width: 18, height: 18)
            .background(provider.tint, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
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
