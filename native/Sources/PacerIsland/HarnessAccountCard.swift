import PacerCore
import SwiftUI

struct HarnessAccountCard: View {
    @ObservedObject var connection: HarnessAccountConnection
    var style: ExpandedQuotaStyle?
    var size: CGFloat = 104
    var showsDetails = true
    var showsName = false
    var openSettings: (() -> Void)?
    private var foreground: Color { style != nil ? PacerPalette.secondary : .secondary }
    private var primary: Color { style != nil ? PacerPalette.primary : .primary }

    var body: some View {
        Group {
            if let style {
                if showsDetails {
                    HStack(spacing: 20) {
                        dial(style)
                        VStack(alignment: .leading, spacing: 5) { details }
                    }
                } else {
                    VStack(spacing: 6) {
                        dial(style)
                        if showsName {
                            HStack(spacing: 5) {
                                ProviderAppIcon(provider: .workbuddy, size: 13)
                                Text(AgentProvider.workbuddy.displayName)
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(primary)
                            }
                        }
                        if connection.reading == nil, let openSettings {
                            QuotaLinkButton(title: L10n.text("harness.account.connect"), action: openSettings)
                                .help(stateText)
                        } else if connection.state == .unavailable {
                            Text(L10n.text("common.not_updated")).font(.system(size: 10))
                        } else if let value = connection.reading, let expiry = expirationText(value) {
                            Text(expiry).font(.system(size: 10))
                                .foregroundStyle(expirationColor(value))
                                .frame(maxWidth: 130)
                        }
                    }.multilineTextAlignment(.center)
                }
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    if let value = connection.reading {
                        Text(L10n.text("harness.account.remaining", number(value.remaining)))
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundStyle(primary).monospacedDigit()
                    }
                    details
                }
            }
        }
        .font(.system(size: 12)).foregroundStyle(foreground)
        .frame(maxWidth: .infinity, alignment: showsDetails ? .leading : .top)
    }

    @ViewBuilder private var details: some View {
        if let value = connection.reading {
            if let plan = value.plan { Text(plan).fontWeight(.semibold).foregroundStyle(primary) }
            if let cycle = value.cycle {
                Text(L10n.text("harness.account.cycle_remaining", number(cycle.remaining), number(cycle.total)))
                if let used = cycle.used { Text(L10n.text("harness.account.cycle_used", number(used))) }
                if let reset = cycle.resetsAt, reset > Date() { Text(L10n.text("harness.account.cycle_reset", date(reset))) }
            }
            if let expiry = expirationText(value) {
                Text(expiry).foregroundStyle(expirationColor(value))
            }
            if style == nil {
                Text(L10n.text("harness.account.total", number(value.total)))
                if value.reserved > 0 { Text(L10n.text("harness.account.reserved", number(value.reserved))) }
            }
            if connection.state == .unavailable { Text(stateText) }
        } else {
            Text(stateText)
            if let openSettings { QuotaLinkButton(title: L10n.text("common.open_settings"), action: openSettings) }
        }
    }

    private func dial(_ style: ExpandedQuotaStyle) -> some View {
        let value = connection.reading
        let stale = connection.state == .unavailable
        return ZStack {
            if let value {
                if let fraction = value.fraction {
                    QuotaRingGauge(fraction: fraction, tint: AgentProvider.workbuddy.tint, stale: stale,
                        geometry: style == .classic ? .classic : .gauge)
                } else {
                    Circle().stroke(PacerPalette.track, lineWidth: 1.5)
                }
                VStack(spacing: 3) {
                    Text(number(value.remaining))
                        .font(.system(size: size * 0.22, weight: .semibold, design: .rounded))
                        .foregroundStyle(primary).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.35)
                    Text(L10n.text("harness.account.available_label"))
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1).minimumScaleFactor(0.75)
                }.frame(width: size * 0.72).opacity(stale ? 0.55 : 1)
            } else {
                Circle().stroke(PacerPalette.track, lineWidth: 1.5)
                ProviderAppIcon(provider: .workbuddy, size: 24)
            }
        }.frame(width: size, height: size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(value.map { L10n.text("harness.account.remaining", number($0.remaining)) } ?? stateText)
            .accessibilityHint(value.map(readingHelp) ?? "")
            .help(value.map(readingHelp) ?? stateText)
    }

    private func readingHelp(_ value: HarnessAccountCredits.Reading) -> String {
        var lines = [L10n.text("harness.account.total", number(value.total))]
        if let cycle = value.cycle {
            lines.append(L10n.text("harness.account.cycle_remaining", number(cycle.remaining), number(cycle.total)))
            if let reset = cycle.resetsAt, reset > Date() { lines.append(L10n.text("harness.account.cycle_reset", date(reset))) }
        }
        if let expiry = expirationText(value) { lines.append(expiry) }
        return lines.joined(separator: "\n")
    }

    private func expirationText(_ value: HarnessAccountCredits.Reading) -> String? {
        guard let expiration = value.expiring, expiration.date > Date() else { return nil }
        return L10n.text("harness.account.expiring", number(expiration.credits), date(expiration.date))
    }

    private func expirationColor(_ value: HarnessAccountCredits.Reading) -> Color {
        guard style != nil, let expiry = value.expiring, expiry.date.timeIntervalSinceNow < 3 * 86_400 else { return foreground }
        return PacerPalette.attention
    }

    private var stateText: String {
        L10n.text("harness.account." + (connection.busy ? "reading" : connection.state == .unavailable ? "unavailable" : "sign_in"))
    }

    private func number(_ value: Double) -> String {
        if value > 0, value < 0.01 { return "<0.01" }
        return value.formatted(.number.precision(.fractionLength(0...2)).locale(L10n.locale))
    }

    private func date(_ value: Date) -> String {
        value.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(L10n.locale))
    }
}

struct WorkBuddyAccountSettings: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var connection: HarnessAccountConnection
    @State private var site = "automatic"

    var body: some View {
        MainCard(title: L10n.text("harness.account.title")) {
            HarnessAccountCard(connection: connection)
                .padding(.horizontal, 14).padding(.vertical, 8)
            CardRow(title: L10n.text("harness.account.connection")) {
                Button(L10n.text(connection.reading == nil ? "harness.account.connect" : "harness.account.switch")) { connection.connect() }
                    .buttonStyle(.main)
                Button(L10n.text("common.refresh")) { connection.refresh() }.buttonStyle(.main)
                if connection.canDisconnect {
                    Button(L10n.text("harness.account.disconnect")) { connection.disconnect() }.buttonStyle(.main)
                }
            }
            .disabled(connection.busy || model.isDemo)
            CardRow(title: L10n.text("harness.account.site")) {
                Picker(L10n.text("harness.account.site"), selection: $site) {
                    Text(L10n.text("provider.automatic")).tag("automatic")
                    Text("workbuddy.cn").tag("china")
                    Text("workbuddy.ai").tag("international")
                }
                .labelsHidden()
                .disabled(connection.busy || model.isDemo)
            }
        }
        .onAppear { site = model.workBuddyAccountSite }
        .onChange(of: site) { _, new in
            if new != model.workBuddyAccountSite { model.setWorkBuddyAccountSite(new) }
        }
    }
}
