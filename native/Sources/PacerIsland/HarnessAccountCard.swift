import PacerCore
import SwiftUI

/// A module's account credits in the panel and on Overview: Core's dial,
/// and its lines beside it when the module has the row to itself. Signed
/// out, the cell offers sign-in right there.
struct HarnessAccountCard: View {
    @ObservedObject var connection: HarnessAccountConnection
    var settings: HarnessCreditsSettings = .default
    var style: ExpandedQuotaStyle?
    var size: CGFloat = 104
    var showsDetails = true
    var showsName = false
    var openSettings: (() -> Void)?
    var now = Date()

    private var island: Bool { style != nil }
    private var tint: Color { connection.provider.tint }
    private var geometry: QuotaRingGeometry { style == .classic ? .classic : .gauge }
    private var primary: Color { island ? PacerPalette.primary : .primary }
    private var secondary: Color { island ? PacerPalette.secondary : .secondary }

    var body: some View {
        Group {
            if let presentation = HarnessCreditsPresentation(credits: connection.credits, settings: settings, now: now) {
                if showsDetails {
                    HStack(spacing: 20) {
                        VStack(spacing: 6) {
                            dial(presentation)
                            // A failed or stale read says so in either layout.
                            if connection.state == .unavailable { Text(L10n.text("common.not_updated")).font(.system(size: 10)) }
                        }
                        CreditsLines(presentation: presentation, tint: tint, island: island)
                    }
                } else {
                    VStack(spacing: 6) {
                        dial(presentation)
                        if showsName { name }
                        if connection.state == .unavailable { Text(L10n.text("common.not_updated")).font(.system(size: 10)) }
                    }
                }
            } else {
                VStack(spacing: 6) {
                    ZStack {
                        QuotaRingGauge(fraction: nil, tint: tint, geometry: geometry)
                        ProviderAppIcon(provider: connection.provider, size: 24)
                    }
                    .frame(width: size, height: size)
                    .accessibilityElement(children: .ignore).accessibilityLabel(stateText)
                    if showsName { name }
                    if !connection.signedIn {
                        QuotaLinkButton(title: L10n.text("welcome.module.sign_in"), prominent: true) { connection.connect() }
                            .help(stateText).disabled(connection.busy)
                    } else {
                        Text(stateText).font(.system(size: 10)).multilineTextAlignment(.center).frame(maxWidth: 140)
                        if let openSettings { QuotaLinkButton(title: L10n.text("common.open_settings"), action: openSettings) }
                    }
                }
            }
        }
        .font(.system(size: 12)).foregroundStyle(secondary)
        .frame(maxWidth: .infinity, alignment: showsDetails ? .leading : .top)
    }

    private func dial(_ presentation: HarnessCreditsPresentation) -> some View {
        CreditsDial(dial: presentation.dial, tint: tint, geometry: geometry, size: size,
                    stale: connection.state == .unavailable, island: island)
    }

    private var name: some View {
        HStack(spacing: 5) {
            ProviderAppIcon(provider: connection.provider, size: 13)
            Text(connection.provider.displayName).font(.system(size: 11, weight: .semibold)).foregroundStyle(primary)
        }
    }

    private var stateText: String {
        L10n.text("harness.account." + (connection.busy ? "reading" : connection.state == .unavailable ? "unavailable" : "sign_in"))
    }
}
