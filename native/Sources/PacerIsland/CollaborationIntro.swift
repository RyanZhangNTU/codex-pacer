import AppKit
import PacerCore
import SwiftUI

/// Where Settings → Collaboration's guide stands: the pair is on with nothing
/// keeping it from working, a run has been seen, and one has ended.
struct CollaborationIntroState: Equatable {
    var on = false
    var ran = false
    var finished = false
    /// Claude starts runs only from the command, so the guide offers that.
    var commandOnly = false

    var allDone: Bool { on && ran && finished }
    /// The step to do next, counted from 0; nil once all three are done.
    var current: Int? { [on, ran, finished].firstIndex(of: false) }

    init(on: Bool = false, ran: Bool = false, finished: Bool = false, commandOnly: Bool = false) {
        self.on = on; self.ran = ran; self.finished = finished; self.commandOnly = commandOnly
    }
    /// From the saved choices and whether something keeps the pair from
    /// working. A run that ended was also a run.
    init(preferences: CodexDelegationPreferences, blocked: Bool) {
        on = preferences.enabled && !blocked
        finished = preferences.introFinished
        ran = finished || preferences.introRan
        commandOnly = preferences.trigger == .command
    }
}

/// How Claude calls Codex, as on Windows: a looping demo of what happens
/// beside three steps. In Settings → Collaboration it is the first-run guide,
/// whose steps tick from the real state and which closes for good; in Help →
/// Collaboration the same card is a plain list with a way to the settings.
struct CollaborationIntro: View {
    enum Mode { case settings, help }
    let mode: Mode
    var state = CollaborationIntroState()
    /// What keeps the pair from working, with the pair card's own action.
    var problem: (text: String, action: AnyView?)? = nil
    var canTurnOn = true
    var turnOn: () -> Void = {}
    var dismiss: () -> Void = {}
    var openSettings: () -> Void = {}
    @State private var copied: String?
    @State private var copyReset: Task<Void, Never>?
    @Environment(\.pacerAccent) private var accent

    /// Two columns while both fit: the 300-point demo, a 16-point gap and 211 for the steps,
    /// so the Settings window at its smallest (860 wide) still shows them side by side.
    static let gap: CGFloat = 16, stepsWidth: CGFloat = 211
    static let sideBySide: CGFloat = CollaborationDemo.size.width + gap + stepsWidth
    /// A done step's mark: a check on green.
    static let success = Color(red: 0x24 / 255, green: 0x8A / 255, blue: 0x3D / 255)
    /// "Copied", readable on the card in either appearance.
    static let copiedInk = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x4A / 255, green: 0xDE / 255, blue: 0x6A / 255, alpha: 1)
            : NSColor(srgbRed: 0x1E / 255, green: 0x7B / 255, blue: 0x34 / 255, alpha: 1)
    })
    /// Puts a phrase on the clipboard. Tests swap it so they leave the user's clipboard alone.
    nonisolated(unsafe) static var writeClipboard: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 14) {
            header
            // The demo beside the steps, stacked when the page is narrow.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Self.gap) {
                    CollaborationDemo()
                    steps.frame(minWidth: Self.stepsWidth, idealWidth: Self.stepsWidth, maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 16) {
                    CollaborationDemo()
                    steps
                }
            }
            if mode == .settings { footer }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("collab.intro.title"))
        switch mode {
        case .settings:
            content.padding(EdgeInsets(top: 16, leading: 16, bottom: 14, trailing: 16))
                .frame(maxWidth: .infinity, alignment: .leading)
                .mainCardSurface(radius: 14)
        case .help:
            content.padding(EdgeInsets(top: 14, leading: 6, bottom: 16, trailing: 6))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Header and footer

    /// Claude's icon with Codex's over its corner, as on the pair card, then the title.
    private var header: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .topLeading) {
                ProviderAppIcon(provider: .claude, size: 22)
                ProviderAppIcon(provider: .codex, size: 20).offset(x: 14, y: 7)
            }
            .frame(width: 36, height: 28, alignment: .topLeading)
            .accessibilityHidden(true)
            Text(L10n.text("collab.intro.title")).font(.system(size: 15, weight: .semibold))
                .lineLimit(1).truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if mode == .settings {
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("collab.intro.close"))
            }
        }
    }

    /// "Got it", or "Done" in the accent once all three steps are done.
    private var footer: some View {
        VStack(spacing: 12) {
            Rectangle().fill(MainPalette.separator).frame(height: 1)
            HStack {
                Spacer()
                Button(L10n.text(state.allDone ? "collab.done" : "collab.intro.got_it"), action: dismiss)
                    .buttonStyle(MainButtonStyle(prominent: state.allDone, height: 28))
                    .frame(minWidth: 72, alignment: .trailing)
            }
        }
    }

    // MARK: Steps

    private enum Mark { case done, current, idle }

    /// Help lists the steps as they are; nothing is ticked or highlighted.
    private func mark(_ index: Int) -> Mark {
        guard mode == .settings else { return .idle }
        if [state.on, state.ran, state.finished][index] { return .done }
        return state.current == index ? .current : .idle
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 16) {
            step(0, title: L10n.text(mode == .help ? "collab.intro.step.on_help" : "collab.intro.step.on")) {
                if mode == .settings {
                    if state.on { note(L10n.text("collab.intro.on")) }
                    else if problem == nil {
                        Button(L10n.text("collab.intro.turn_on"), action: turnOn)
                            .buttonStyle(MainButtonStyle(prominent: true, height: 26)).disabled(!canTurnOn)
                    }
                }
            } details: {
                if mode == .help {
                    Button(L10n.text("collab.intro.open_settings"), action: openSettings).buttonStyle(.main)
                } else if let problem {
                    Text(problem.text).font(.system(size: 12)).foregroundStyle(MainPalette.attention)
                        .fixedSize(horizontal: false, vertical: true)
                    if let action = problem.action { action }
                }
            }
            step(1, title: L10n.text("collab.intro.step.ask")) {
                if mode == .settings, state.ran { note(L10n.text("collab.intro.asked")) }
            } details: {
                if mode == .help {
                    phrases(["collab.intro.phrase.review", "collab.intro.phrase.opinion"])
                    commandHint
                } else if !state.ran {
                    phrases(state.commandOnly ? ["collab.intro.phrase.command"] : ["collab.intro.phrase.review", "collab.intro.phrase.opinion"])
                    if state.commandOnly { note(L10n.text("collab.intro.command_only")) }
                }
            }
            step(2, title: L10n.text("collab.intro.step.watch")) {
                if mode == .settings, state.finished { note(L10n.text("collab.intro.watched")) }
            } details: {
                if mode == .help || !state.finished { note(L10n.text("collab.intro.watch_detail")) }
            }
        }
        .padding(.top, 4)
    }

    /// One numbered step: its mark (a number, or a check once done), its title
    /// with what sits at the end of the line, and what follows below.
    private func step<Trailing: View, Details: View>(_ index: Int, title: String, @ViewBuilder trailing: () -> Trailing,
                                                      @ViewBuilder details: () -> Details) -> some View {
        let mark = mark(index)
        return HStack(alignment: .top, spacing: 12) {
            badge(index, mark).padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                // What ends the line moves under the title rather than squeezing it onto two lines.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text(title).font(.system(size: 13.5, weight: .semibold)).fixedSize()
                        Spacer(minLength: 8)
                        trailing()
                    }
                    .frame(minHeight: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.system(size: 13.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                            .frame(minHeight: 24)
                        trailing()
                    }
                }
                details()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(index + 1). " + title + (mark == .done ? " · " + L10n.text("collab.intro.step_done") : ""))
    }

    /// A done step shows a check on green; the step to do next is ringed in the accent.
    private func badge(_ index: Int, _ mark: Mark) -> some View {
        ZStack {
            switch mark {
            case .done:
                Circle().fill(Self.success)
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            case .current:
                Circle().strokeBorder(accent, lineWidth: 1.5)
                Text("\(index + 1)").font(.system(size: 12, weight: .semibold)).foregroundStyle(accent)
            case .idle:
                Circle().fill(MainPalette.fill)
                Text("\(index + 1)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Phrases to say to Claude, each copied with one click.
    private func phrases(_ keys: [String]) -> some View {
        FlowRow(spacing: 6, lineSpacing: 6) {
            ForEach(keys, id: \.self) { key in
                let text = L10n.text(key)
                PhraseChip(text: text, copied: copied == text) { copy(text) }
            }
        }
        .padding(.top, 2)
    }

    private func copy(_ text: String) {
        Self.writeClipboard(text)
        copied = text
        copyReset?.cancel()
        copyReset = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { copied = nil }
        }
    }

    /// "Or type /pacer:codex followed by what to hand over", the command in code type.
    private var commandHint: some View {
        let parts = L10n.text("collab.intro.command_hint").components(separatedBy: "%@")
        return (Text(parts[0])
            + Text("/pacer:codex").font(.system(size: 12, design: .monospaced)).foregroundColor(.primary)
            + Text(parts.count > 1 ? parts[1] : ""))
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One phrase to copy: the words, then a copy mark, or "Copied" for a moment.
private struct PhraseChip: View {
    let text: String
    let copied: Bool
    let copy: () -> Void
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Button(action: copy) {
            HStack(spacing: 6) {
                Text(text).font(text.hasPrefix("/") ? .system(size: 12, design: .monospaced) : .system(size: 12))
                    .foregroundStyle(.primary).lineLimit(1)
                if copied {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                        Text(L10n.text("collab.intro.copied")).font(.system(size: 12))
                    }
                    .foregroundStyle(CollaborationIntro.copiedInk)
                } else {
                    Image(systemName: "doc.on.doc").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(hovered ? MainPalette.button : MainPalette.infoFill, in: shape)
            .overlay(shape.strokeBorder(MainPalette.cardBorder))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(L10n.text("collab.intro.copy", text))
    }
}

/// The guide's demo, about ten seconds a loop: you ask in Claude, Pacer starts
/// Codex under that Claude task, its progress fills, the result goes back to
/// Claude, and the run is cleaned up when the turn ends. Without motion it
/// stays on the progress frame; the dots move between frames either way and
/// carry on the loop from there. The pictures are hidden from VoiceOver; the
/// dots name each step. It runs only while shown.
struct CollaborationDemo: View {
    static let size = CGSize(width: 300, height: 260)
    static let loop = 10.4
    static let starts: [Double] = [0, 2.4, 3.8, 7.0, 8.6]
    /// The moment each step shows when nothing moves.
    static let stills: [Double] = [2.2, 2.8, 5.4, 7.3, 9.8]
    /// The island's panel, dark in either appearance.
    static let panel = Color(red: 0x24 / 255, green: 0x24 / 255, blue: 0x28 / 255)
    static let ink = Color(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF5 / 255)
    static let quiet = Color(red: 0xA1 / 255, green: 0xA1 / 255, blue: 0xA6 / 255)
    static let codexInk = Color(red: 0x10 / 255, green: 0x30 / 255, blue: 0x2A / 255)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var still: Int
    @State private var origin = Date()
    @State private var from = 0.0
    @State private var shown = false
    private let animates: Bool
    private var moving: Bool { animates && !reduceMotion && shown }

    /// `still` is the step shown without motion: the progress, unless a dot picks another.
    init(still: Int = 2, animates: Bool = true) { _still = State(initialValue: still); self.animates = animates }

    /// One moment of the loop: what each part of the picture shows.
    struct Frame: Equatable {
        let t: Double
        let moving: Bool
        var beat: Int { CollaborationDemo.starts.lastIndex { t >= $0 } ?? 0 }
        func typed(_ prompt: String) -> String {
            beat == 0 ? String(prompt.prefix(Int(t / 1.8 * Double(prompt.count)))) : prompt
        }
        var caret: Bool { beat == 0 && Int(t / 0.4) % 2 == 0 }
        var sent: Bool { beat > 0 || t > 1.9 }
        var status: String {
            switch beat {
            case 0: "collab.intro.demo.thinking"
            case 1, 2: "collab.intro.demo.waiting"
            case 3: "collab.intro.demo.replying"
            default: "collab.intro.demo.finished"
            }
        }
        /// The run's progress: none while it starts, filling, then done.
        var fraction: Double {
            let starts = CollaborationDemo.starts
            return beat == 2 ? min(1, max(0, (t - starts[2]) / (starts[3] - starts[2]))) : beat > 2 ? 1 : 0
        }
        var readings: String {
            if beat == 1 { return "— t/s · 0:00" }
            let rate = beat == 2 ? 82 + Int((5 * sin(t * 1000 / 260) + 3 * sin(t * 1000 / 97)).rounded()) : 74
            let seconds = beat == 2 ? Int(fraction * 80) : beat > 2 ? 80 : 0
            return "\(rate) t/s · \(seconds / 60):" + String(format: "%02d", seconds % 60)
        }
        /// Eased like the island's own changes, 0.45 seconds after `start`.
        private func ease(after start: Double) -> Double {
            guard moving else { return 1 }
            let progress = min(1, max(0, (t - start) / 0.45))
            return 1 - (1 - progress) * (1 - progress)
        }
        /// The run's line fades in and rises 6 points as it starts, and fades
        /// out when the turn ends.
        var runOpacity: Double {
            switch beat {
            case 1: ease(after: CollaborationDemo.starts[1])
            case 2, 3: 1
            case 4: 1 - ease(after: CollaborationDemo.starts[4])
            default: 0
            }
        }
        var runOffset: Double { beat == 0 ? 6 : beat == 1 ? 6 * (1 - ease(after: CollaborationDemo.starts[1])) : 0 }
        var cleanedOpacity: Double { beat == 4 ? ease(after: CollaborationDemo.starts[4] + 0.25) : 0 }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { context in
            let t = moving ? (from + max(0, context.date.timeIntervalSince(origin))).truncatingRemainder(dividingBy: Self.loop)
                : Self.stills[still]
            content(Frame(t: t, moving: moving))
        }
        .padding(14)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(MainPalette.page, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear { origin = Date(); shown = true }
        .onDisappear { shown = false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("collab.intro.demo"))
    }

    /// A dot jumps to its step: the loop carries on from there, or the still frame changes.
    private func show(_ step: Int) {
        still = step
        from = Self.starts[step]; origin = Date()
    }

    private func content(_ frame: Frame) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                bubble(frame)
                Image(systemName: "arrow.down").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .opacity(0.55).padding(.vertical, 3)
                miniPanel(frame)
                Spacer(minLength: 0)
            }
            .accessibilityHidden(true)
            footer(frame)
        }
    }

    // MARK: The ask

    private func bubble(_ frame: Frame) -> some View {
        let prompt = L10n.text("collab.intro.phrase.review")
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return HStack(spacing: 0) {
            Spark().fill(AgentProvider.claude.tint).frame(width: 16, height: 16).padding(.trailing, 8)
            HStack(spacing: 1) {
                Text(frame.typed(prompt)).font(.system(size: 12.5)).foregroundStyle(.primary).lineLimit(1)
                Rectangle().fill(AgentProvider.claude.tint).frame(width: 1.5, height: 14).opacity(frame.caret ? 1 : 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading).clipped()
            ZStack {
                Circle().fill(frame.sent ? AgentProvider.claude.tint : MainPalette.fill)
                Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(frame.sent ? MainPalette.card : Color.secondary)
            }
            .frame(width: 24, height: 24).padding(.leading, 6)
        }
        .padding(.leading, 10).padding(.trailing, 6)
        .frame(height: 40)
        .background(MainPalette.card, in: shape)
        .overlay(shape.strokeBorder(MainPalette.cardBorder))
    }

    // MARK: Pacer's panel

    /// Pacer's panel as it shows the Claude task and its Codex run, always on the island's dark surface.
    private func miniPanel(_ frame: Frame) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ZStack {
                    Circle().stroke(AgentProvider.claude.tint.opacity(0.35), lineWidth: 1.6).frame(width: 21, height: 21)
                    if frame.beat == 4 {
                        CheckMark().stroke(AgentProvider.claude.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .frame(width: 10, height: 8)
                    } else {
                        Spark().fill(AgentProvider.claude.tint).frame(width: 12, height: 12)
                    }
                }
                .frame(width: 24, height: 24).padding(.trailing, 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("collab.intro.demo.task")).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Self.ink).lineLimit(1)
                    Text(L10n.text(frame.status)).font(.system(size: 11)).foregroundStyle(Self.quiet).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(L10n.text("collab.intro.demo.claude_model")).font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(AgentProvider.claude.tint).lineLimit(1)
            }
            .frame(height: 40)
            ZStack(alignment: .leading) {
                runLine(frame).opacity(frame.runOpacity).offset(y: frame.runOffset)
                HStack(spacing: 6) {
                    Image(systemName: "trash").font(.system(size: 10))
                    Text(L10n.text("collab.intro.demo.cleaned")).font(.system(size: 11)).lineLimit(1)
                }
                .foregroundStyle(Self.quiet).opacity(frame.cleanedOpacity)
            }
            .padding(.leading, 10)
            .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
            .overlay(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(frame.beat == 0 ? 0 : 0.16)).frame(width: 1.5)
            }
            .padding(.leading, 11)
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 6, trailing: 12))
        .background(Self.panel, in: shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.08)))
        .environment(\.colorScheme, .dark)
    }

    private func runLine(_ frame: Frame) -> some View {
        HStack(spacing: 0) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 1.8).frame(width: 13, height: 13)
                if frame.beat <= 1 {
                    Circle().stroke(AgentProvider.codex.tint, style: StrokeStyle(lineWidth: 1.8, dash: [2.6, 2.6]))
                        .frame(width: 13, height: 13).opacity(0.75)
                } else if frame.beat == 2 {
                    Circle().trim(from: 0, to: max(0.001, frame.fraction))
                        .stroke(AgentProvider.codex.tint, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                        .rotationEffect(.degrees(-90)).frame(width: 13, height: 13)
                } else {
                    Circle().fill(AgentProvider.codex.tint).frame(width: 14, height: 14)
                    CheckMark().stroke(Self.codexInk, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                        .frame(width: 6.5, height: 4.6)
                }
            }
            .frame(width: 16, height: 16).padding(.trailing, 8)
            Text(L10n.text("collab.intro.demo.run")).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Self.ink)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Text(frame.readings).font(.system(size: 10.5, weight: .medium)).monospacedDigit().foregroundStyle(Self.quiet).lineLimit(1)
            Text(L10n.text("collab.intro.demo.codex_model")).font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(AgentProvider.codex.tint).lineLimit(1).padding(.leading, 6)
        }
    }

    // MARK: Steps

    /// Five dots, the current one long in Codex's color, and what it shows.
    private func footer(_ frame: Frame) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { index in
                    let caption = L10n.text("collab.intro.demo.\(index + 1)")
                    Button { show(index) } label: {
                        Capsule().fill(index == frame.beat ? AgentProvider.codex.tint : Color.secondary)
                            .frame(width: index == frame.beat ? 18 : 6, height: 6)
                            .opacity(index == frame.beat ? 1 : 0.45)
                            .padding(.horizontal, 4).frame(height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("collab.intro.demo.step", index + 1, caption))
                }
            }
            .padding(.trailing, 6)
            Text(L10n.text("collab.intro.demo.\(frame.beat + 1)")).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
        }
        .frame(height: 20).padding(.top, 8)
    }
}

/// Claude's four-pointed spark.
private struct Spark: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x / 13 * w, y: rect.minY + y / 13 * h) }
        var path = Path()
        // addLines starts its own subpath at the first point, so the top point leads.
        path.addLines([point(6.5, 0), point(7.9, 5.1), point(13, 6.5), point(7.9, 7.9), point(6.5, 13), point(5.1, 7.9), point(0, 6.5), point(5.1, 5.1)])
        path.closeSubpath()
        return path
    }
}

/// A check drawn across its frame.
private struct CheckMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
