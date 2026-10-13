import AppKit
import PacerCore
import SwiftUI

/// First-launch guide for 3.0 in two steps: what the island shows, drawn with
/// the real components on the Appearance wallpaper, then which services to
/// follow. Settings → Help keeps the full legend.
struct WelcomeView: View {
    static let size = CGSize(width: 560, height: 532)

    @ObservedObject var model: IslandModel
    @ObservedObject var notificationPreference: SystemNotificationPreference
    @ObservedObject var launchAtLogin: LaunchAtLoginPreference
    let onOpenSettings: (SettingsPane) -> Void
    let onDone: () -> Void
    @State private var step = 0
    @State private var modules = ProviderModules.load()

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if step == 0 { islandStep } else { servicesStep }
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.locale, L10n.locale)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("welcome.title")).font(.system(size: 20, weight: .semibold))
                Text(L10n.text("welcome.subtitle")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 4)
    }

    private func stepTitle(_ key: String) -> some View {
        Text(L10n.text(key)).font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 8)
    }

    // MARK: Step 1

    private var islandStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepTitle("welcome.step.island")
            WelcomeIslandMap()
            HStack(alignment: .top, spacing: 12) {
                column("welcome.badges") {
                    badgeRow(L10n.text("welcome.badge.running")) {
                        ActivityBadge(activity: .init(core: .count(2), activeCount: 2, orbit: [.codex: 1, .claude: 1]))
                    }
                    Divider().padding(.leading, 52)
                    badgeRow(L10n.text("welcome.badge.waiting"), tint: PacerPalette.attention) {
                        ActivityBadge(activity: .init(core: .count(1), activeCount: 1, orbit: [:], attention: .input))
                    }
                    Divider().padding(.leading, 52)
                    badgeRow(L10n.text("welcome.badge.ended"), hint: L10n.text("welcome.badge.ended_hint")) {
                        ActivityBadge(activity: .init(core: .symbol(StatusSymbols.complete), activeCount: 0, orbit: [:], ending: .completed(.codex)))
                    }
                }
                column("welcome.gestures") { WelcomeGestureDemo() }
            }
            .padding(.top, 14)
        }
    }

    private func column<Content: View>(_ key: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text(key)).font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 10)
            VStack(spacing: 0) { content() }.welcomeGroup()
        }
        .frame(maxWidth: .infinity)
    }

    /// Badges sit on a bar-colored swatch, as they appear on the island.
    private func badgeRow<Badge: View>(_ title: String, hint: String? = nil, tint: Color = .primary,
                                       @ViewBuilder badge: () -> Badge) -> some View {
        HStack(spacing: 10) {
            badge().foregroundStyle(PacerPalette.primary)
                .frame(width: 30, height: 26).background(Color.black, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            HStack(spacing: 4) {
                Text(title).foregroundStyle(tint)
                if let hint { Text("· " + hint).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12).frame(height: 38)
        .accessibilityElement(children: .combine)
    }

    // MARK: Step 2

    private var servicesStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepTitle("welcome.step.start")
            HStack(spacing: 10) {
                moduleCard(.codex)
                moduleCard(.claude)
            }
            Text(L10n.text("welcome.modules_note")).font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 8)
            stepTitle("welcome.section.personalize").padding(.top, 6)
            VStack(spacing: 0) {
                personalizeRow(.collapsedBar, title: L10n.text("welcome.layout.title"), detail: L10n.text("welcome.layout.detail")) {
                    Button(L10n.text("welcome.go")) { onOpenSettings(.collapsedBar) }
                }
                Divider().padding(.leading, 50)
                personalizeRow(.reminders, title: L10n.text("settings.system_notifications"),
                               detail: L10n.text(notificationPreference.denied ? "settings.notification_denied" : "welcome.notifications_detail"),
                               detailTint: notificationPreference.denied ? .orange : .secondary) {
                    Toggle(L10n.text("settings.system_notifications"), isOn: Binding(get: { notificationPreference.enabled },
                        set: { notificationPreference.setEnabled($0) })).labelsHidden().toggleStyle(.switch)
                }
                Divider().padding(.leading, 50)
                personalizeRow(.general, title: L10n.text("settings.open_at_login"), detail: launchAtLoginDetail,
                               detailTint: launchAtLogin.needsApproval || launchAtLogin.failure != nil ? .orange : .secondary) {
                    Toggle(L10n.text("settings.open_at_login"), isOn: Binding(get: { launchAtLogin.enabled },
                        set: { launchAtLogin.setEnabled($0) })).labelsHidden().toggleStyle(.switch)
                }
            }
            .welcomeGroup()
        }
    }

    private var launchAtLoginDetail: String {
        launchAtLogin.failure ?? L10n.text(launchAtLogin.needsApproval ? "settings.login_item_approval" : "welcome.login_detail")
    }

    private func moduleEnabled(_ provider: AgentProvider) -> Bool {
        switch modules.mode(for: provider) {
        case .automatic: model.providerDetected(provider)
        case .enabled: true
        case .disabled: false
        }
    }

    /// The same explicit choice as the module switch in Settings.
    private func setModule(_ provider: AgentProvider, enabled: Bool) {
        modules.setMode(enabled ? .enabled : .disabled, for: provider)
        modules.save()
        model.applySettings(sourceChanged: false)
    }

    private func moduleCard(_ provider: AgentProvider) -> some View {
        let enabled = moduleEnabled(provider)
        let status = moduleStatus(provider, enabled: enabled)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                SettingsIconTile(symbol: provider.glyph, tint: provider.tint, glyph: Color.black.opacity(0.72), size: 34)
                    .saturation(enabled ? 1 : 0).opacity(enabled ? 1 : 0.5)
                Spacer()
                Toggle(provider.displayName, isOn: Binding(get: { enabled }, set: { setModule(provider, enabled: $0) }))
                    .labelsHidden().toggleStyle(.switch)
            }
            Text(provider.displayName).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(enabled ? .primary : .secondary).padding(.top, 9)
            HStack(spacing: 6) {
                if status.ready {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
                }
                Text(status.text).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                if let action = status.action {
                    Button(action.title, action: action.perform).controlSize(.small)
                }
            }
            .font(.system(size: 11))
            .frame(minHeight: 22).padding(.top, 3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .welcomeGroup()
    }

    private struct ModuleStatus {
        var text: String
        var ready = false
        var action: (title: String, perform: () -> Void)?
    }

    /// Mirrors the module and Claude account states shown in Settings.
    private func moduleStatus(_ provider: AgentProvider, enabled: Bool) -> ModuleStatus {
        guard enabled else { return ModuleStatus(text: L10n.text("welcome.module.off", provider.displayName)) }
        let settings: (title: String, perform: () -> Void) = (L10n.text("welcome.module.settings"),
            { onOpenSettings(provider == .codex ? .codex : .claude) })
        guard model.providerDetected(provider) else {
            return ModuleStatus(text: L10n.text(provider == .codex ? "welcome.module.codex_missing" : "welcome.module.claude_missing"),
                                action: settings)
        }
        let ready = ModuleStatus(text: L10n.text("welcome.module.ready") +
            (modules.mode(for: provider) == .automatic ? " · " + L10n.text("welcome.module.automatic") : ""), ready: true)
        guard provider == .claude else { return ready }
        if model.claudeNeedsOrganizationSelection {
            return ModuleStatus(text: L10n.text("claude.account.workspace_needed"),
                                action: (L10n.text("claude.quota.choose_workspace"), { model.chooseClaudeOrganization() }))
        }
        if !model.claudeConnectionNeeded && model.claudeQuotaSource != nil { return ready }
        if !model.claudeConnectionNeeded && model.providerRefreshing(.claude) {
            return ModuleStatus(text: L10n.text("claude.account.checking"))
        }
        return ModuleStatus(text: L10n.text("welcome.module.sign_in_detail"),
                            action: (L10n.text("welcome.module.sign_in"), { model.signInClaudeQuota() }))
    }

    private func personalizeRow<Control: View>(_ pane: SettingsPane, title: String, detail: String, detailTint: Color = .secondary,
                                               @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            SettingsIconTile(symbol: pane.symbol, tint: pane.tint, glyph: pane.glyphColor, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.system(size: 11)).foregroundStyle(detailTint).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(0..<2, id: \.self) { index in
                    Circle().fill(Color.primary.opacity(index == step ? 0.8 : 0.22)).frame(width: 7, height: 7)
                }
            }
            .accessibilityElement().accessibilityLabel(L10n.text("welcome.step_of", step + 1, 2))
            Spacer(minLength: 8)
            if step == 0 {
                Button(L10n.text("welcome.all_marks")) { onOpenSettings(.help) }
                Button(L10n.text("welcome.next")) { step = 1 }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            } else {
                Button(L10n.text("welcome.back")) { step = 0 }
                Button(L10n.text("welcome.done"), action: onDone)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}

extension View {
    /// A grouped-form box that reads in light and dark appearance.
    func welcomeGroup() -> some View {
        background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(WelcomeColors.group))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

private enum WelcomeColors {
    static let group = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.055) : NSColor(white: 1, alpha: 0.85)
    })
}

// MARK: - Island map

/// The collapsed bar hanging from a notched menu bar, with callouts tied to
/// each part by measured anchors.
private struct WelcomeIslandMap: View {
    enum Part: CaseIterable { case task, rate, quota, warning }
    enum Mark: Hashable { case part(Part), label(Part) }
    struct Anchors: PreferenceKey {
        static var defaultValue: [Mark: Anchor<CGRect>] = [:]
        static func reduce(value: inout [Mark: Anchor<CGRect>], nextValue: () -> [Mark: Anchor<CGRect>]) {
            value.merge(nextValue()) { $1 }
        }
    }

    private static let barHeight: CGFloat = 32
    private static let wing: CGFloat = 100
    private static let camera: CGFloat = 130
    @State private var focus: Part?

    var body: some View {
        ZStack(alignment: .top) {
            Wallpaper()
            menuBar
            bar
            labels.frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 14)
        }
        .frame(width: WelcomeView.size.width - 40, height: 176)
        .overlayPreferenceValue(Anchors.self) { anchors in
            GeometryReader { proxy in
                ForEach(Part.allCases, id: \.self) { part in
                    if let from = anchors[.part(part)], let to = anchors[.label(part)] {
                        let start = CGPoint(x: proxy[from].midX, y: proxy[from].maxY + 3), end = CGPoint(x: proxy[to].midX, y: proxy[to].minY)
                        Path { path in path.move(to: start); path.addLine(to: end) }
                            .stroke(Color.white.opacity(0.55), lineWidth: 1)
                        Circle().fill(Color.white).frame(width: 4, height: 4).position(start)
                    }
                }
            }
            .opacity(focus == nil ? 1 : 0.6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
    }

    private var menuBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "apple.logo").font(.system(size: 12))
            ForEach([26, 22], id: \.self) { Capsule().frame(width: CGFloat($0), height: 6).opacity(0.55) }
            Spacer()
            ForEach([14, 34], id: \.self) { Capsule().frame(width: CGFloat($0), height: 6).opacity(0.55) }
        }
        .foregroundStyle(Color.white.opacity(0.8))
        .padding(.horizontal, 14)
        .frame(height: Self.barHeight)
        .background(Color.black.opacity(0.22))
        .accessibilityHidden(true)
    }

    private var bar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                ActivityBadge(activity: .init(core: .count(2), activeCount: 2, orbit: [.codex: 1, .claude: 1])).mark(.task, focus)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("42").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    Text("t/s").font(.system(size: 9, weight: .medium)).foregroundStyle(PacerPalette.tertiary)
                }
                .mark(.rate, focus)
            }
            .frame(width: Self.wing)
            Color.clear.frame(width: Self.camera)
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    QuotaRingsGlyph(rings: [.init(tint: AgentProvider.codex.tint, remaining: 58, stale: false),
                        .init(tint: AgentProvider.claude.tint, remaining: 81, stale: false)])
                    AlternatingQuotaText(entries: [.init(text: "58%", color: NSColor(AgentProvider.codex.tint)),
                        .init(text: "81%", color: NSColor(AgentProvider.claude.tint))], animates: true)
                }
                .mark(.quota, focus)
                FiveHourAlertGlyph(alert: .low(12), tint: AgentProvider.codex.tint).mark(.warning, focus)
            }
            .frame(width: Self.wing)
        }
        .foregroundStyle(PacerPalette.primary)
        .frame(height: Self.barHeight)
        .modifier(IslandSurface(appearance: .classic, attached: true, expanded: false))
        .accessibilityHidden(true)
    }

    private var labels: some View {
        HStack(alignment: .bottom, spacing: 8) {
            label(.task, L10n.text("welcome.part.task")) { Text(L10n.text("welcome.part.task_detail")) }
            label(.rate, L10n.text("welcome.part.rate")) { Text(L10n.text("welcome.part.rate_detail")) }
            Spacer(minLength: 0)
            label(.quota, L10n.text("welcome.part.quota")) {
                HStack(spacing: 4) {
                    Circle().fill(AgentProvider.codex.tint).frame(width: 6, height: 6)
                    Text(AgentProvider.codex.displayName)
                    Circle().fill(AgentProvider.claude.tint).frame(width: 6, height: 6).padding(.leading, 4)
                    Text(AgentProvider.claude.displayName)
                }
            }
            label(.warning, L10n.text("welcome.part.warning")) { Text(L10n.text("welcome.part.warning_detail")) }
        }
        .padding(.horizontal, 12)
    }

    private func label<Detail: View>(_ part: Part, _ title: String, @ViewBuilder detail: () -> Detail) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
            detail().font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.75))
        }
        .fixedSize()
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .anchorPreference(key: Anchors.self, value: .bounds) { [.label(part): $0] }
        .onHover { focus = $0 ? part : (focus == part ? nil : focus) }
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    func mark(_ part: WelcomeIslandMap.Part, _ focus: WelcomeIslandMap.Part?) -> some View {
        anchorPreference(key: WelcomeIslandMap.Anchors.self, value: .bounds) { [.part(part): $0] }
            .opacity(focus == nil || focus == part ? 1 : 0.25)
            .animation(.easeOut(duration: 0.15), value: focus)
    }
}

// MARK: - Gestures

/// The island's own spring, scaled down: the pointer arrives and the bar
/// opens, then it leaves and the bar closes. Reduce Motion shows it open.
private struct WelcomeGestureDemo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let scale: CGFloat = 0.25
    private static let canvas = CGSize(width: 132, height: 88)
    private static let screen = CGSize(width: canvas.width / scale, height: canvas.height / scale)
    private static let collapsed = CGRect(x: (screen.width - 300) / 2, y: screen.height - 32, width: 300, height: 32)
    private static let expanded = CGRect(x: (screen.width - 404) / 2, y: screen.height - 232, width: 404, height: 232)
    private static let period: TimeInterval = 5
    private static let opensAt: TimeInterval = 0.9, leavesAt: TimeInterval = 2.9, closesAt: TimeInterval = 3.3
    private static let opening = IslandMotion(from: .resting(at: collapsed, expanded: false), to: expanded, opening: true, start: opensAt)
    private static let closing = IslandMotion(from: .resting(at: expanded, expanded: true), to: collapsed, opening: false, start: closesAt)

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { context in
            let time = reduceMotion ? 1.6 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period)
            let hovering = time >= 0.3 && time < Self.closesAt
            HStack(spacing: 12) {
                scene(at: time)
                    .frame(width: Self.canvas.width, height: Self.canvas.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    gesture("welcome.gesture.hover", "welcome.gesture.expand", active: reduceMotion || hovering)
                    Divider()
                    gesture("welcome.gesture.leave", "welcome.gesture.collapse", active: reduceMotion || !hovering)
                }
            }
            .padding(10)
        }
    }

    /// One line where it fits, otherwise the result under the gesture.
    private func gesture(_ verb: String, _ result: String, active: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                Text(L10n.text(verb)).foregroundStyle(.secondary)
                Text(L10n.text(result))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.text(verb)).foregroundStyle(.secondary)
                Text(L10n.text(result))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(size: 13))
        .opacity(active ? 1 : 0.4)
        .animation(.easeOut(duration: 0.2), value: active)
        .frame(height: 44)
        .accessibilityElement(children: .combine)
    }

    private func scene(at time: TimeInterval) -> some View {
        let sample = time < Self.closesAt ? Self.opening.sample(at: time) : Self.closing.sample(at: time)
        let frame = sample.frame
        return ZStack(alignment: .topLeading) {
            Wallpaper().frame(width: Self.screen.width, height: Self.screen.height)
            Rectangle().fill(Color.black.opacity(0.22)).frame(width: Self.screen.width, height: 32)
            panelContent.opacity(sample.content)
                .frame(width: frame.width, height: frame.height, alignment: .top)
                .modifier(IslandSurface(appearance: .classic, attached: true, expanded: false, progress: sample.expansion))
                .offset(x: frame.minX, y: Self.screen.height - frame.maxY)
            pointer.offset(pointerPosition(at: time))
        }
        .frame(width: Self.screen.width, height: Self.screen.height, alignment: .topLeading)
        .scaleEffect(Self.scale, anchor: .topLeading)
        .frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .topLeading)
    }

    /// Rows and rings in the expanded panel's places, without real data.
    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach([AgentProvider.codex, .claude], id: \.self) { provider in
                HStack(spacing: 16) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(provider.tint.opacity(0.35)).frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 9) {
                        Capsule().fill(Color.white.opacity(0.7)).frame(width: 170, height: 11)
                        Capsule().fill(Color.white.opacity(0.3)).frame(width: 110, height: 9)
                    }
                }
            }
            HStack(spacing: 70) {
                ForEach([AgentProvider.codex, .claude], id: \.self) { provider in
                    Circle().trim(from: 0, to: provider == .codex ? 0.58 : 0.81)
                        .stroke(provider.tint, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90)).frame(width: 54, height: 54)
                }
            }
            .padding(.leading, 60)
        }
        .padding(.top, 50).padding(.horizontal, 30)
    }

    /// The pointer rests below the open panel, travels onto the bar, then leaves.
    private func pointerPosition(at time: TimeInterval) -> CGSize {
        let away = CGSize(width: Self.screen.width * 0.84, height: Self.screen.height * 0.84)
        let over = CGSize(width: Self.screen.width / 2 + 40, height: 8)
        func ease(_ value: Double) -> Double { value * value * (3 - 2 * value) }
        let fraction: Double
        switch time {
        case ..<0.3: fraction = 0
        case ..<Self.opensAt: fraction = ease((time - 0.3) / (Self.opensAt - 0.3))
        case ..<Self.leavesAt: fraction = 1
        case ..<Self.closesAt: fraction = 1 - ease((time - Self.leavesAt) / (Self.closesAt - Self.leavesAt))
        default: fraction = 0
        }
        return CGSize(width: away.width + (over.width - away.width) * fraction, height: away.height + (over.height - away.height) * fraction)
    }

    private var pointer: some View {
        PointerArrow().fill(Color.white)
            .overlay(PointerArrow().stroke(Color.black, lineWidth: 3))
            .frame(width: 41, height: 66)
    }
}

/// The standard arrow pointer, tip at the top-left corner.
private struct PointerArrow: Shape {
    func path(in rect: CGRect) -> Path {
        let points: [CGPoint] = [.init(x: 0, y: 0), .init(x: 0, y: 17), .init(x: 4, y: 13), .init(x: 7, y: 19.5),
                                 .init(x: 9.5, y: 18.5), .init(x: 6.7, y: 12.2), .init(x: 12, y: 12.2)]
        let scale = rect.height / 19.5
        var path = Path()
        path.addLines(points.map { CGPoint(x: rect.minX + $0.x * scale, y: rect.minY + $0.y * scale) })
        path.closeSubpath()
        return path
    }
}
