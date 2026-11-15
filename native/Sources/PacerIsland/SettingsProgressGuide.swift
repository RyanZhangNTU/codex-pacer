import AppKit
import PacerCore
import PacerMacSupport
import SwiftUI

/// The progress ring card for a module whose app must trust Pacer's tool,
/// as Core words it: the title with ⓘ, a chip and the switch; then the
/// steps while setting up, or one line and its action for a problem. Ready,
/// it is the switch row alone, like any other service's ring.
struct ProgressGuideRows: View {
    @ObservedObject var model: IslandModel
    let provider: AgentProvider
    @Binding var isOn: Bool
    /// The connectors link did not open; the app itself opened instead, if it could.
    @State private var openFailed = false
    static let anchor = "progress-guide"

    /// The card shown: nothing while the ring is off, unless removing the tool failed.
    static func guide(_ model: IslandModel, _ provider: AgentProvider, isOn: Bool) -> HarnessProgressGuide? {
        let guide = model.progressGuide(provider)
        return isOn || guide?.stage == .cleanupFailed ? guide : nil
    }
    /// Steps or a problem to show under the header.
    static func opens(_ guide: HarnessProgressGuide?) -> Bool { guide.map(ProgressGuideBody.shows) == true }

    var body: some View {
        let guide = Self.guide(model, provider, isOn: isOn)
        VStack(alignment: .leading, spacing: 0) {
            ProgressGuideHeader(guide: guide, info: guide?.info ?? model.progressGuideInfo(provider), isOn: $isOn)
                .frame(minHeight: 28)
            if let guide, Self.opens(guide) {
                Rectangle().fill(MainPalette.separator).frame(height: 1).padding(.top, 8)
                ProgressGuideBody(guide: guide, provider: provider, perform: perform).padding(.top, 4)
                if openFailed, guide.action == .openConnectors {
                    Text(L10n.text("harness.progress_state.open_failed")).font(.system(size: 12)).foregroundStyle(MainPalette.attention)
                        .fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
                }
            }
        }
        .id(Self.anchor)
        .onChange(of: guide?.stage) { _, _ in openFailed = false }
        // While the card waits on the app, check again until the user is done there.
        .task(id: guide?.waiting == true) {
            guard guide?.waiting == true else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                model.recheckLocalHarnessProgress(provider)
            }
        }
    }

    private func perform(_ action: HarnessProgressGuide.Action) {
        switch action {
        case .retry: model.syncLocalHarnessProgress(force: provider)
        case .openApp: Task { _ = await MacLocalHarnessApplication.openApplication(provider: provider) }
        case .openConnectors:
            // Without the connectors link, the app itself is the next best place.
            Task {
                openFailed = !(await MacLocalHarnessApplication.openProgressConnectors(provider: provider))
                if openFailed { _ = await MacLocalHarnessApplication.openApplication(provider: provider) }
            }
        }
    }
}

/// The title, ⓘ, the chip and the switch; Ready reads as a green check at the end.
private struct ProgressGuideHeader: View {
    let guide: HarnessProgressGuide?
    let info: String
    @Binding var isOn: Bool
    @State private var showsInfo = false

    var body: some View {
        let title = L10n.text("main.claude.ring")
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 13, weight: ProgressGuideRows.opens(guide) ? .semibold : .regular))
                InfoButton(title: title, isOn: $showsInfo).padding(.leading, -4)
                if let guide, guide.tone != .success { ProgressGuideChip(text: guide.chip, tone: guide.tone) }
                Spacer(minLength: 8)
                if let guide, guide.tone == .success {
                    Label(guide.chip, systemImage: "checkmark").labelStyle(.titleAndIcon)
                        .font(.system(size: 12)).foregroundStyle(ProgressGuideChip.ink(.success))
                }
                Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch)
            }
            if showsInfo { InfoBox(text: info) }
        }
        .accessibilityElement(children: .contain)
    }
}

struct ProgressGuideChip: View {
    let text: String
    let tone: HarnessProgressGuide.Tone
    @Environment(\.pacerAccent) private var accent

    var body: some View {
        let ink = tone == .info ? accent : Self.ink(tone)
        Text(text).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
            .foregroundStyle(ink)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(ink.opacity(tone == .neutral ? 0.1 : 0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// Notice colors for attention, the accent for info; darker inks on the light page.
    static func ink(_ tone: HarnessProgressGuide.Tone) -> Color {
        func adaptive(light: UInt32, dark: NSColor) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark
                    : NSColor(srgbRed: CGFloat(light >> 16 & 0xFF) / 255, green: CGFloat(light >> 8 & 0xFF) / 255,
                              blue: CGFloat(light & 0xFF) / 255, alpha: 1)
            })
        }
        return switch tone {
        case .attention: adaptive(light: 0xA44A00, dark: NSColor(PacerPalette.attention))
        case .info: Color.accentColor
        case .success: adaptive(light: 0x1E7B34, dark: .systemGreen)
        case .error: adaptive(light: 0xB42318, dark: .systemRed)
        case .neutral: .secondary
        }
    }
}

/// The steps, or a problem's line and action, under the header.
private struct ProgressGuideBody: View {
    let guide: HarnessProgressGuide
    let provider: AgentProvider
    let perform: (HarnessProgressGuide.Action) -> Void

    static func shows(_ guide: HarnessProgressGuide) -> Bool { !guide.steps.isEmpty || guide.line != nil || guide.action != nil }

    var body: some View {
        if guide.steps.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if let line = guide.line {
                    Text(line).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                }
                actionButton
            }
            .padding(.vertical, 4)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                    if index > 0 { DashedRule() }
                    stepRow(index + 1, step)
                }
            }
        }
    }

    @ViewBuilder private func stepRow(_ number: Int, _ step: HarnessProgressGuide.Step) -> some View {
        let current = step.state == .current
        HStack(alignment: .top, spacing: 12) {
            StepDot(number: number, state: step.state)
            VStack(alignment: .leading, spacing: 10) {
                Text(step.title)
                    .font(.system(size: current ? 13.5 : 13, weight: current ? .semibold : .regular))
                    .foregroundStyle(step.state == .done ? AnyShapeStyle(.secondary) : step.state == .pending ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .fixedSize(horizontal: false, vertical: true)
                if current, guide.action != nil || guide.waitingText != nil {
                    // The button keeps its whole title; the waiting line moves under it when they don't fit side by side.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { actionButton; waitingLabel }
                        VStack(alignment: .leading, spacing: 8) { actionButton; waitingLabel }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if current, guide.showsTrustCard { TrustCardSample(provider: provider) }
        }
        .padding(.vertical, current ? 12 : 10)
        .accessibilityElement(children: .contain)
        .accessibilityValue(L10n.text("progress_guide.state." + step.state.rawValue))
    }

    /// Opening the app is prominent, like signing in; Retry is an ordinary button.
    @ViewBuilder private var actionButton: some View {
        if let action = guide.action, let title = guide.actionTitle {
            Button(title) { perform(action) }.buttonStyle(MainButtonStyle(prominent: action != .retry, height: 28)).fixedSize()
        }
    }

    @ViewBuilder private var waitingLabel: some View {
        if let waiting = guide.waitingText {
            Label(waiting, systemImage: "clock").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
        }
    }
}

private struct StepDot: View {
    let number: Int
    let state: HarnessProgressGuide.StepState
    @Environment(\.pacerAccent) private var accent

    var body: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(ProgressGuideChip.ink(.success))
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            case .current:
                Circle().fill(accent)
                Text("\(number)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            case .pending:
                Circle().strokeBorder(Color.primary.opacity(0.22), lineWidth: 1.5)
                Text("\(number)").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

private struct DashedRule: View {
    var body: some View {
        Line().stroke(MainPalette.cardBorder, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(height: 1)
    }
    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { $0.move(to: CGPoint(x: 0, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) }
        }
    }
}

/// A small drawing of the app's connectors page, so the user knows what
/// to click there: ① Custom Connector at the top right, then ② Trust on
/// Pacer's entry.
private struct TrustCardSample: View {
    let provider: AgentProvider
    /// The connector's name as the app lists it.
    private static let server = "pacer_progress"
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.pacerAccent) private var accent

    var body: some View {
        let light = colorScheme == .light
        let brand = provider.shade(light: light)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Text(L10n.text("progress_guide.trust_card.tab")).font(.system(size: 11, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                number(1)
                // The app's own black button, drawn as it looks there.
                Label(L10n.text("progress_guide.trust_card.custom"), systemImage: "square.and.pencil")
                    .font(.system(size: 10.5, weight: .semibold)).lineLimit(1).foregroundStyle(.white)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(Color(red: 0x1D / 255, green: 0x1D / 255, blue: 0x1F / 255), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(light ? 0 : 0.18)))
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(red: 0.19, green: 0.69, blue: 0.78)).frame(width: 16, height: 16)
                    Text(Self.server).font(.system(size: 12, weight: .semibold))
                }
                Text(L10n.text("progress_guide.trust_card.caption")).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                Text(L10n.text("progress_guide.trust_card.detail")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    Spacer(minLength: 0)
                    number(2)
                    Text(L10n.text("progress_guide.trust_card.button")).font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(light ? .white : Color.black.opacity(0.8))
                        .padding(.horizontal, 12).frame(height: 24)
                        .background(brand, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(MainPalette.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(MainPalette.cardBorder))
        }
        .padding(10)
        .frame(width: 268)
        .background(MainPalette.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        // A picture of the app's page; the step above already says what to do.
        .accessibilityHidden(true)
    }

    /// Which click comes first, in Pacer's accent.
    private func number(_ value: Int) -> some View {
        Text("\(value)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            .frame(width: 16, height: 16).background(accent, in: Circle())
    }
}
