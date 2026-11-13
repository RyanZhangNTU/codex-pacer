import AppKit
import PacerCore
import SwiftUI

/// The first-launch guide, drawn like the main window: a page per idea with
/// a large title. The island's parts, its mode, the services to follow and a
/// few choices. Settings → Help & Updates keeps the full legend of badges.
struct WelcomeView: View {
    @Environment(\.pacerAccent) private var accent
    static let size = CGSize(width: 640, height: 500)
    /// The guide's pages, in order.
    enum Step: Int, CaseIterable { case welcome, mode, services, finish }

    @ObservedObject var model: IslandModel
    @ObservedObject var notificationPreference: SystemNotificationPreference
    @ObservedObject var launchAtLogin: LaunchAtLoginPreference
    let onOpenSettings: (SettingsPane) -> Void
    let onDone: () -> Void
    /// The page the guide opens on; checks render each page directly.
    var startStep = Step.welcome
    @State private var chosenStep: Step?
    private var step: Step { chosenStep ?? startStep }
    @State private var forward = true
    @State private var modules = ProviderModules.load()
    @AppStorage(IslandModel.claudeProgressRingKey) private var claudeRing = true
    @AppStorage(IslandModel.codexProgressRingKey) private var codexRing = true
    @AppStorage(IslandModel.deepseekProgressRingKey) private var deepseekRing = true
    /// Read so a mode chosen here, or a drag of the island, redraws the cards.
    @AppStorage("islandDisplayMode") private var displayModeValue = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                page(step).id(step)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .offset(x: forward ? 36 : -36).combined(with: .opacity), removal: .opacity))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(MainPalette.page)
        .environment(\.locale, L10n.locale)
    }

    @ViewBuilder private func page(_ step: Step) -> some View {
        switch step {
        case .welcome: welcomePage
        case .mode: modePage
        case .services: servicesPage
        case .finish: finishPage
        }
    }

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 24, weight: .bold)).accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }

    // MARK: Pages

    private var welcomePage: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
                .frame(width: 84, height: 84).accessibilityHidden(true)
            header(L10n.text("main.welcome.title"), L10n.text("welcome.subtitle")).padding(.top, 8)
            WelcomeIslandMap().padding(.top, 26)
        }
        .padding(.horizontal, 32).padding(.top, 40)
    }

    /// The island's two modes, each shown moving. Choosing one moves the
    /// real island at once, the same choice as Appearance → Position.
    private var modePage: some View {
        VStack(spacing: 24) {
            header(L10n.text("main.welcome.mode_title"), L10n.text("main.welcome.mode_subtitle"))
            HStack(alignment: .top, spacing: Self.modeSpacing) {
                modeCard(attached: true, title: L10n.text("main.welcome.mode_island"),
                         detail: L10n.text("main.welcome.mode_island_detail")) {
                    WelcomeHoverScene(width: Self.modeArtWidth)
                }
                modeCard(attached: false, title: L10n.text("main.welcome.mode_free"),
                         detail: L10n.text("appearance.free_move_detail")) {
                    WelcomeDragScene(width: Self.modeArtWidth)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Self.pageMargin).padding(.top, 44)
    }

    private static let pageMargin: CGFloat = 32
    private static let modeSpacing: CGFloat = 14
    private static let modePadding: CGFloat = 12
    private static let modeArtWidth = (size.width - pageMargin * 2 - modeSpacing) / 2 - modePadding * 2

    /// Whether the island hangs from the top edge now: a choice of Notch, or
    /// a notched display before any choice.
    private var attachesNow: Bool {
        _ = displayModeValue
        return IslandDisplayMode.load().layout(safeAreaTop: model.screenNotchSize.height,
                                               hardwareNotchWidth: model.screenNotchSize.width, size: CompactBarSize.load()).attached
    }

    private func chooseMode(attached: Bool) {
        if attached {
            IslandDisplayMode.notch.save()
        } else {
            // Free Move starts where Appearance would: the saved spot, or a
            // corner when the island leaves the notch.
            IslandPosition.custom(saved: IslandPosition.saved(), attached: attachesNow).save()
            IslandDisplayMode.floating.save()
        }
        model.applySettings(sourceChanged: false)
    }

    private func modeCard<Art: View>(attached: Bool, title: String, detail: String, @ViewBuilder art: () -> Art) -> some View {
        let selected = attachesNow == attached
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button { chooseMode(attached: attached) } label: {
            VStack(alignment: .leading, spacing: 0) {
                art()
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 4)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 17))
                        .foregroundStyle(selected ? accent : Color.secondary.opacity(0.5))
                        .accessibilityHidden(true)
                }
                .padding(.top, 12)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 3)
            }
            .padding(Self.modePadding).padding(.bottom, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(MainPalette.card, in: shape)
            .overlay(shape.strokeBorder(selected ? accent : MainPalette.cardBorder, lineWidth: selected ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var servicesPage: some View {
        VStack(spacing: 24) {
            header(L10n.text("main.welcome.services_title"), L10n.text("welcome.modules_note"))
            HStack(spacing: 12) {
                moduleCard(.codex)
                moduleCard(.claude)
                moduleCard(.deepseek)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 32).padding(.top, 44)
    }

    /// Titles only, like the main window: what a row does sits behind ⓘ,
    /// and only a problem the user must fix shows under the title.
    private var finishPage: some View {
        VStack(spacing: 24) {
            header(L10n.text("main.welcome.finish_title"), L10n.text("main.welcome.finish_subtitle"))
            MainCard {
                WelcomeChoiceRow(symbol: "circle.dashed", tint: Color(red: 0.19, green: 0.69, blue: 0.78),
                                 title: L10n.text("main.claude.ring"), info: L10n.text("main.welcome.ring_info")) {
                    Toggle(L10n.text("main.claude.ring"), isOn: ringsBinding).labelsHidden().toggleStyle(.switch)
                }
                WelcomeChoiceRow(symbol: SettingsPane.notifications.tileSymbol, tint: SettingsPane.notifications.tint,
                                 title: L10n.text("settings.system_notifications"), info: L10n.text("main.welcome.notifications_info"),
                                 problem: notificationPreference.denied ? L10n.text("settings.notification_denied") : nil) {
                    Toggle(L10n.text("settings.system_notifications"), isOn: Binding(get: { notificationPreference.enabled },
                        set: { notificationPreference.setEnabled($0) })).labelsHidden().toggleStyle(.switch)
                }
                WelcomeChoiceRow(symbol: "power", tint: Color(red: 0.2, green: 0.74, blue: 0.4),
                                 title: L10n.text("settings.open_at_login"), info: L10n.text("main.welcome.login_info"),
                                 problem: launchAtLogin.failure ?? (launchAtLogin.needsApproval ? L10n.text("settings.login_item_approval") : nil)) {
                    Toggle(L10n.text("settings.open_at_login"), isOn: Binding(get: { launchAtLogin.enabled },
                        set: { launchAtLogin.setEnabled($0) })).labelsHidden().toggleStyle(.switch)
                }
                WelcomeChoiceRow(symbol: SettingsPane.collapsedBar.tileSymbol, tint: SettingsPane.collapsedBar.tint,
                                 title: L10n.text("welcome.layout.title"), info: L10n.text("main.welcome.layout_info")) {
                    Button(L10n.text("welcome.go")) { onOpenSettings(.collapsedBar) }.buttonStyle(.main)
                }
            }
        }
        .padding(.horizontal, 56).padding(.top, 44)
    }

    /// One switch for every service's ring; Settings keeps one per service.
    private var ringsBinding: Binding<Bool> {
        Binding(get: { claudeRing || codexRing || deepseekRing }, set: { value in
            claudeRing = value; codexRing = value; deepseekRing = value
            model.applySettings(sourceChanged: false)
        })
    }

    // MARK: Services

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
                ProviderAppIcon(provider: provider, size: 40)
                    .saturation(enabled ? 1 : 0).opacity(enabled ? 1 : 0.5)
                Spacer()
                Toggle(provider.displayName, isOn: Binding(get: { enabled }, set: { setModule(provider, enabled: $0) }))
                    .labelsHidden().toggleStyle(.switch)
            }
            Text(provider.displayName).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(enabled ? .primary : .secondary).padding(.top, 12)
            statusLabel(status).padding(.top, 4)
            Spacer(minLength: 12)
            // Every card keeps the action's place, so the buttons line up.
            statusAction(status, provider: provider).frame(height: 26, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .mainCardSurface(radius: 14)
    }

    private func statusLabel(_ status: ModuleStatus) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if status.ready {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(MainPalette.positive).accessibilityHidden(true)
            }
            Text(status.text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11.5))
    }

    /// Connecting is what the card is waiting for, so it takes the provider's
    /// color; Settings for a missing install stays an ordinary button.
    @ViewBuilder private func statusAction(_ status: ModuleStatus, provider: AgentProvider) -> some View {
        if let action = status.action {
            if action.connects {
                Button(action.title, action: action.perform)
                    .buttonStyle(MainButtonStyle(prominent: true, height: 26, fill: provider.shade(light: false), label: Color.black.opacity(0.8)))
            } else {
                Button(action.title, action: action.perform).buttonStyle(MainButtonStyle(height: 26))
            }
        }
    }

    private struct ModuleStatus {
        var text: String
        var ready = false
        var action: (title: String, connects: Bool, perform: () -> Void)?
    }

    /// Mirrors the module and Claude account states shown in Settings.
    private func moduleStatus(_ provider: AgentProvider, enabled: Bool) -> ModuleStatus {
        guard enabled else { return ModuleStatus(text: L10n.text("welcome.module.off", provider.displayName)) }
        let settings: (title: String, connects: Bool, perform: () -> Void) = (L10n.text("welcome.module.settings"), false,
            { onOpenSettings(SettingsPane(provider: provider)) })
        guard model.providerDetected(provider) else {
            return ModuleStatus(text: L10n.text("welcome.module.\(provider.rawValue)_missing"), action: settings)
        }
        let ready = ModuleStatus(text: L10n.text("welcome.module.ready") +
            (modules.mode(for: provider) == .automatic ? " · " + L10n.text("welcome.module.automatic") : ""), ready: true)
        if provider == .deepseek { return deepseekStatus(ready: ready) }
        guard provider == .claude else { return ready }
        if model.claudeNeedsOrganizationSelection {
            return ModuleStatus(text: L10n.text("claude.account.workspace_needed"),
                                action: (L10n.text("claude.quota.choose_workspace"), true, { model.chooseClaudeOrganization() }))
        }
        if !model.claudeConnectionNeeded && model.claudeQuotaSource != nil { return ready }
        if !model.claudeConnectionNeeded && model.providerRefreshing(.claude) {
            return ModuleStatus(text: L10n.text("claude.account.checking"))
        }
        return ModuleStatus(text: L10n.text("welcome.module.sign_in_detail"),
                            action: (L10n.text("welcome.module.sign_in"), true, { model.signInClaudeQuota() }))
    }

    /// The card's action follows how Harness bills: sign in, or paste a key.
    private func deepseekStatus(ready: ModuleStatus) -> ModuleStatus {
        if model.deepseekBalance != nil { return ready }
        if model.deepseekRefreshing { return ModuleStatus(text: L10n.text("claude.account.checking")) }
        if model.deepseekBalanceMode == .apiKey {
            return ModuleStatus(text: L10n.text("welcome.module.balance_detail"),
                                action: (L10n.text("deepseek.paste_key_short"), true, { onOpenSettings(.deepseek) }))
        }
        return ModuleStatus(text: L10n.text("welcome.module.balance_sign_in_detail"),
                            action: (L10n.text("welcome.module.sign_in"), true, { model.connectDeepSeek() }))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { index in
                    Capsule().fill(Color.primary.opacity(index == step ? 0.75 : 0.18))
                        .frame(width: index == step ? 16 : 6, height: 6)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: step)
            .accessibilityElement().accessibilityLabel(L10n.text("welcome.step_of", step.rawValue + 1, Step.allCases.count))
            Spacer(minLength: 8)
            if step != .welcome {
                Button(L10n.text("welcome.back")) { go(-1) }.buttonStyle(MainButtonStyle(height: 32))
            }
            Button(L10n.text(step == .finish ? "welcome.done" : "main.welcome.continue")) {
                if step == .finish { onDone() } else { go(1) }
            }
            .buttonStyle(MainButtonStyle(prominent: true, height: 32))
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 20)
    }

    private func go(_ offset: Int) {
        guard let next = Step(rawValue: step.rawValue + offset) else { return }
        forward = offset > 0
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { chosenStep = next }
    }
}

/// A row of the guide's last page: a tile, the title with ⓘ, then its
/// control. A problem shows under the title in amber; the explanation opens
/// under the row, as in the main window.
private struct WelcomeChoiceRow<Control: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let info: String
    var problem: String? = nil
    @ViewBuilder let control: Control
    @State private var showsInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                SettingsIconTile(symbol: symbol, tint: tint, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(title).font(.system(size: 13))
                        InfoButton(title: title, isOn: $showsInfo)
                    }
                    if let problem {
                        Text(problem).font(.system(size: 11.5)).foregroundStyle(MainPalette.attention)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                control
            }
            if showsInfo { InfoBox(text: info).padding(.leading, 40) }
        }
    }
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
        .frame(width: WelcomeView.size.width - 64, height: 196)
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
        // The bar under the camera is black, as the island draws it at the
        // notch, unless the island shows light glass's light tone now.
        .modifier(IslandSurface(appearance: IslandAppearance.stored, attached: true, expanded: false,
            notchBlack: PacerPalette.light ? 0 : 1))
        .environment(\.colorScheme, PacerPalette.light ? .light : .dark)
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

// MARK: - Mode scenes

/// Both mode cards draw a small screen in the same points, then scale it.
private enum WelcomeScreen {
    static let size = CGSize(width: 528, height: 352)
    static let menuBar: CGFloat = 32

    static func ease(_ value: Double) -> Double {
        let clamped = min(1, max(0, value))
        return clamped * clamped * (3 - 2 * clamped)
    }

    static var desk: some View {
        ZStack(alignment: .top) {
            Wallpaper().frame(width: size.width, height: size.height)
            Rectangle().fill(Color.black.opacity(0.22)).frame(width: size.width, height: menuBar)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// Island mode: the island's own spring, scaled down. The pointer arrives and
/// the bar opens from the notch, then it leaves and the bar closes. Reduce
/// Motion shows it open.
struct WelcomeHoverScene: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let width: CGFloat
    private static let screen = WelcomeScreen.size
    private static let collapsed = CGRect(x: (screen.width - 300) / 2, y: screen.height - 32, width: 300, height: 32)
    private static let expanded = CGRect(x: (screen.width - 404) / 2, y: screen.height - 232, width: 404, height: 232)
    private static let period: TimeInterval = 5
    private static let opensAt: TimeInterval = 0.9, leavesAt: TimeInterval = 2.9, closesAt: TimeInterval = 3.3
    private static let opening = IslandMotion(from: .resting(at: collapsed, expanded: false), to: expanded, opening: true, start: opensAt)
    private static let closing = IslandMotion(from: .resting(at: expanded, expanded: true), to: collapsed, opening: false, start: closesAt)

    var body: some View {
        let scale = width / Self.screen.width
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { context in
            let time = reduceMotion ? 1.6 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period)
            scene(at: time)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: width, height: Self.screen.height * scale, alignment: .topLeading)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }

    private func scene(at time: TimeInterval) -> some View {
        let sample = time < Self.closesAt ? Self.opening.sample(at: time) : Self.closing.sample(at: time)
        let frame = sample.frame
        return ZStack(alignment: .topLeading) {
            WelcomeScreen.desk
            panelContent.opacity(sample.content)
                .frame(width: frame.width, height: frame.height, alignment: .top)
                .modifier(IslandSurface(appearance: .classic, attached: true, expanded: false, progress: sample.expansion))
                .offset(x: frame.minX, y: Self.screen.height - frame.maxY)
            WelcomePointer().frame(width: 26, height: 42).offset(pointerPosition(at: time))
        }
        .frame(width: Self.screen.width, height: Self.screen.height, alignment: .topLeading)
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
        let away = CGSize(width: Self.screen.width * 0.82, height: Self.screen.height * 0.8)
        let over = CGSize(width: Self.screen.width / 2 + 40, height: 8)
        let fraction: Double
        switch time {
        case ..<0.3: fraction = 0
        case ..<Self.opensAt: fraction = WelcomeScreen.ease((time - 0.3) / (Self.opensAt - 0.3))
        case ..<Self.leavesAt: fraction = 1
        case ..<Self.closesAt: fraction = 1 - WelcomeScreen.ease((time - Self.leavesAt) / (Self.closesAt - Self.leavesAt))
        default: fraction = 0
        }
        return CGSize(width: away.width + (over.width - away.width) * fraction, height: away.height + (over.height - away.height) * fraction)
    }
}

/// Free Move: the pointer grabs the floating bar and drags it toward the
/// right edge, where it snaps into a strip. Reduce Motion shows it mid-drag.
struct WelcomeDragScene: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let width: CGFloat
    private static let screen = WelcomeScreen.size
    private static let period: TimeInterval = 4.6
    private static let bar = CGSize(width: 210, height: 32)
    private static let strip = CGSize(width: 28, height: 132)
    private static let startX: CGFloat = 170, endX: CGFloat = 400, rowY: CGFloat = 150

    var body: some View {
        let scale = width / Self.screen.width
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { context in
            let time = reduceMotion ? 1.4 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period)
            scene(at: time)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: width, height: Self.screen.height * scale, alignment: .topLeading)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }

    private func scene(at time: TimeInterval) -> some View {
        // 0–0.5 reach, 0.5–0.7 press, 0.7–2.0 drag, 2.0–2.4 snap, then hold and fade.
        let drag = WelcomeScreen.ease((time - 0.7) / 1.3)
        let snap = WelcomeScreen.ease((time - 2.0) / 0.4)
        let fade = 1 - WelcomeScreen.ease((time - 4.0) / 0.5)
        let centerX = Self.startX + (Self.endX - Self.startX) * drag
        let docked = CGRect(x: Self.screen.width - Self.strip.width + 10, y: Self.rowY - Self.strip.height / 2,
                            width: Self.strip.width, height: Self.strip.height)
        let floating = CGRect(x: centerX - Self.bar.width / 2, y: Self.rowY - Self.bar.height / 2,
                              width: Self.bar.width, height: Self.bar.height)
        let frame = CGRect(x: floating.minX + (docked.minX - floating.minX) * snap, y: floating.minY + (docked.minY - floating.minY) * snap,
                           width: floating.width + (docked.width - floating.width) * snap,
                           height: floating.height + (docked.height - floating.height) * snap)
        let reach = WelcomeScreen.ease(time / 0.5)
        let rest = CGPoint(x: Self.screen.width * 0.3, y: Self.screen.height * 0.86)
        let grip = CGPoint(x: centerX + 30, y: Self.rowY + 4)
        let pointer = time < 2.0
            ? CGPoint(x: rest.x + (grip.x - rest.x) * reach, y: rest.y + (grip.y - rest.y) * reach)
            : CGPoint(x: grip.x - 70 * snap, y: grip.y + 60 * snap)
        return ZStack(alignment: .topLeading) {
            WelcomeScreen.desk
            // The way the bar travels, faint so the motion reads as a drag.
            Path { path in
                path.move(to: CGPoint(x: Self.startX + Self.bar.width / 2 + 16, y: Self.rowY))
                path.addLine(to: CGPoint(x: Self.screen.width - 44, y: Self.rowY))
            }
            .stroke(Color.white.opacity(0.4 * (1 - snap)), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [2, 12]))
            RoundedRectangle(cornerRadius: min(frame.width, frame.height) / 2, style: .continuous)
                .fill(Color.black)
                .overlay(barContent.opacity(1 - snap))
                .overlay(RoundedRectangle(cornerRadius: min(frame.width, frame.height) / 2, style: .continuous)
                    .strokeBorder(AgentProvider.codex.shade(light: false).opacity(snap), lineWidth: 3))
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
            WelcomePointer().frame(width: 26, height: 42).offset(x: pointer.x, y: pointer.y)
        }
        .opacity(time > 4.0 ? fade : 1)
        .frame(width: Self.screen.width, height: Self.screen.height, alignment: .topLeading)
    }

    /// A ring and a value, where the collapsed bar shows them.
    private var barContent: some View {
        HStack(spacing: 10) {
            Circle().trim(from: 0, to: 0.62).stroke(AgentProvider.codex.shade(light: false), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90)).frame(width: 16, height: 16)
            Capsule().fill(Color.white.opacity(0.7)).frame(width: 34, height: 9)
            Spacer(minLength: 0)
            Capsule().fill(Color.white.opacity(0.35)).frame(width: 44, height: 9)
        }
        .padding(.horizontal, 14)
    }
}

/// The standard pointer: white with a black outline.
private struct WelcomePointer: View {
    var body: some View {
        PointerArrow().fill(Color.white).overlay(PointerArrow().stroke(Color.black, lineWidth: 2.5))
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
